package dev.viasix.app

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.VpnService
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.viasix.app.mihomo.ControllerClient
import dev.viasix.app.prefs.DefaultProfile
import dev.viasix.app.prefs.SessionPrefs
import dev.viasix.app.prefs.SessionPrefsStore
import dev.viasix.app.session.ConnectionPhase
import dev.viasix.app.session.RuntimeProcessIdentity
import dev.viasix.app.session.SessionRuntimeStatus
import dev.viasix.app.session.SessionRuntimeStore
import dev.viasix.app.session.SessionStartGate
import dev.viasix.app.session.VpnSessionCommands
import dev.viasix.app.session.sessionKey
import dev.viasix.app.tun.Socks5Client
import dev.viasix.app.tun.Socks5UdpRelay
import dev.viasix.app.vpn.ViaSixVpnService
import dev.viasix.core.projection.MihomoProjection
import dev.viasix.core.projection.ProjectOptions
import dev.viasix.core.projection.RoutingMode
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Device behavior tests against the packaged Go executable and Android VpnService.
 * Requires installed native binaries and VPN consent for dev.viasix.app before execution.
 * No public network is needed. The app excludes its own UID from the VPN, so socket
 * assertions exercise the real mixed/SOCKS listener, rather than claiming TUN coverage.
 */
@RunWith(AndroidJUnit4::class)
class AndroidVpnDeviceTest : IsolatedVpnDeviceTest() {
    @Test
    fun freshInstallHasReadyVlessPagesProfileWithoutImport() {
        SessionPrefsStore(context).clear()
        val prefs = SessionPrefsStore(context).load()
        assertTrue("Fresh preferences must use the bundled profile", DefaultProfile.yaml == prefs.profileYaml)
        assertEquals(DefaultProfile.selectedAddress, prefs.selectedAddress)
        assertTrue(InetAddress.getByName(prefs.selectedAddress) is Inet6Address)
        assertFalse("A documentation-only address cannot connect", prefs.selectedAddress.startsWith("2001:db8:"))
        assertEquals(SessionStartGate.Result.Ok, VpnSessionCommands.evaluateStart(prefs))

        val projected = MihomoProjection.project(
            prefs.profileYaml,
            ProjectOptions(selectedAddress = prefs.selectedAddress),
        )
        val proxy = (projected["proxies"] as List<*>).single() as Map<*, *>
        assertEquals("ViaSix Cloudflare Pages", proxy["name"])
        assertEquals("vless", proxy["type"])
        assertEquals("ws", proxy["network"])
        assertEquals(true, proxy["tls"])
        assertEquals(prefs.selectedAddress, proxy["server"])
        assertTrue((proxy["uuid"] as String).isNotBlank())
        assertEquals("viasix.miofelix.com", proxy["servername"])
    }

    @Test
    fun preferencesSurviveStoreRecreationIncludingUnappliedDraft() {
        val expected = SessionPrefs(
            profileYaml = DefaultProfile.yaml,
            profileDraft = "draft is intentionally incomplete: [",
            selectedAddress = DefaultProfile.selectedAddress,
            selectedSection = "settings",
            routingMode = "global",
            vpnMtu = "1280",
            vpnMetered = false,
            bypassLocalNetwork = true,
            ipv6RoutingMode = "block",
            dnsRoutingMode = "direct",
            dnsServer = "9.9.9.9",
            appRoutingMode = "bypass_selected",
            selectedAppPackages = listOf("com.android.chrome", "com.android.settings"),
            candidateAddresses = listOf(DefaultProfile.selectedAddress, "2606:4700:4700::1111"),
            notificationPermissionRequested = true,
        )
        SessionPrefsStore(context).save(expected)
        assertTrue("Session preferences did not survive store recreation", expected == SessionPrefsStore(context).load())
        assertEquals(SessionStartGate.Result.Ok, VpnSessionCommands.evaluateStart(SessionPrefsStore(context).load()))
    }

    @Test
    fun repeatedConnectDisconnectReleasesPortsAndRotatesControllerSecret() {
        val secrets = mutableSetOf<String>()
        repeat(3) {
            val status = startSession(directPrefs())
            assertTrue("Each connection needs a new controller secret", secrets.add(status.secret))
            assertTrue(ControllerClient.probe("127.0.0.1", status.controllerPort, status.secret).ok)
            assertFalse("Controller must reject unauthenticated requests", ControllerClient.probe("127.0.0.1", status.controllerPort, "").ok)
            assertTrue(ControllerClient.connectionsTotals("127.0.0.1", status.controllerPort, status.secret).live)
            stopSession()
            assertFalse(SessionRuntimeStore(context).load().running)
            assertNull(SessionRuntimeStore(context).load().sessionKey())
        }
    }

    @Test
    fun stopDuringStartupAllowsImmediateRestartWithoutResurrectingOldSession() {
        dispatchStart(directPrefs().copy(vpnMtu = "1500"))
        awaitCondition("Initial startup never began", 10_000) {
            SessionRuntimeStore(context).load().phase.isActiveOrTransitioning
        }
        assertEquals("Regression must interrupt startup before it publishes running", ConnectionPhase.STARTING, SessionRuntimeStore(context).load().phase)
        context.startService(VpnSessionCommands.buildStopIntent(context))
        val restarted = startSession(directPrefs().copy(vpnMtu = "1280"))
        assertTrue(restarted.eventsJson.contains("mtu=1280"))
        assertTrue(ControllerClient.probe("127.0.0.1", restarted.controllerPort, restarted.secret).ok)
        // A cancelled startup/old service teardown must not later stop the new stack.
        SystemClock.sleep(1_000)
        assertEquals(restarted.sessionKey(), SessionRuntimeStore(context).load().sessionKey())
        stopSession()
    }

    @Test
    fun startRequestedDuringStopCreatesAHealthyNewSession() {
        val initial = startSession(directPrefs())
        context.startService(VpnSessionCommands.buildStopIntent(context))
        dispatchStart(directPrefs().copy(vpnMtu = "1280", dnsRoutingMode = "direct"))
        awaitCondition("Restart during shutdown did not publish a fresh session", 25_000) {
            val status = SessionRuntimeStore(context).load()
            status.phase == ConnectionPhase.RUNNING && status.secret.isNotBlank() && status.secret != initial.secret
        }
        val restarted = SessionRuntimeStore(context).load()
        assertTrue(restarted.eventsJson.contains("mtu=1280"))
        assertTrue(ControllerClient.probe("127.0.0.1", restarted.controllerPort, restarted.secret).ok)
        assertFalse(ControllerClient.probe("127.0.0.1", restarted.controllerPort, initial.secret).ok)
        SystemClock.sleep(1_000)
        assertEquals(restarted.sessionKey(), SessionRuntimeStore(context).load().sessionKey())
    }

    @Test
    fun runtimeStateIsRecoverableAndForeignProcessStateIsRejected() {
        val running = startSession(directPrefs())
        val restored = SessionRuntimeStore(context).load()
        assertEquals(running.sessionKey(), restored.sessionKey())
        assertEquals(RuntimeProcessIdentity.token, restored.processToken)
        assertEquals(ConnectionPhase.RUNNING, VpnSessionCommands.runtimePhase(context))
        assertEquals(ConnectionPhase.RUNNING, ConnectionPhase.restore(restored.phase))
        assertTrue(restored.toUiSnapshot().running)
        assertNotNull(restored.startedAtMillis)

        val stale = restored.forProcess("different-process-after-kill")
        assertEquals(ConnectionPhase.STOPPED, stale.phase)
        assertFalse(stale.running)
        assertTrue(stale.secret.isEmpty())
        assertNull(stale.startedAtMillis)
        stopSession()
        assertEquals(ConnectionPhase.STOPPED, SessionRuntimeStore(context).load().phase)
    }

    @Test
    fun systemStartRestoresPersistedSessionAndSettings() {
        val saved = directPrefs().copy(
            vpnMtu = "1280",
            vpnMetered = false,
            dnsRoutingMode = "direct",
            ipv6RoutingMode = "block",
        )
        SessionPrefsStore(context).save(saved)
        requireVpnConsent()
        // Android always-on/system intents omit profile extras; the service must load prefs.
        context.startForegroundService(
            Intent(context, ViaSixVpnService::class.java).setAction(VpnService.SERVICE_INTERFACE),
        )
        val running = awaitRunning()
        assertTrue(ControllerClient.probe("127.0.0.1", running.controllerPort, running.secret).ok)
        val events = running.eventsJson
        assertTrue(events.contains("system-start"))
        assertTrue(events.contains("mtu=1280"))
        assertTrue(events.contains("ipv6=block"))
        assertTrue("System start changed saved session preferences", saved == SessionPrefsStore(context).load())
    }

    @Test
    fun actualMihomoTcpRelayPreservesLargeBinaryPayloadForIpv4AndIpv6() {
        val runtime = startSession(directPrefs())
        listOf("127.0.0.1", "::1").forEach { address ->
            val loopback = InetAddress.getByName(address)
            val payload = ByteArray(256 * 1024) { ((it * 31 + 17) and 0xff).toByte() }
            ServerSocket(0, 1, loopback).use { server ->
                server.soTimeout = 8_000
                val executor = Executors.newSingleThreadExecutor()
                try {
                    val peer = executor.submit(Callable {
                        server.accept().use { socket ->
                            socket.soTimeout = 8_000
                            val received = readFully(socket.getInputStream(), payload.size)
                            assertArrayEquals("Loopback server received corrupted TCP bytes", payload, received)
                            assertEquals("Client half-close must reach upstream", -1, socket.getInputStream().read())
                            socket.getOutputStream().write(received)
                            socket.getOutputStream().flush()
                            socket.shutdownOutput()
                        }
                    })
                    Socks5Client.connect(
                        proxyHost = "127.0.0.1",
                        proxyPort = runtime.mixedPort,
                        targetHost = loopback,
                        targetPort = server.localPort,
                        connectTimeoutMs = 8_000,
                        handshakeTimeoutMs = 8_000,
                    ).use { client ->
                        client.soTimeout = 8_000
                        client.getOutputStream().write(payload)
                        client.getOutputStream().flush()
                        client.shutdownOutput()
                        assertArrayEquals("SOCKS relay corrupted TCP reply for $address", payload, client.getInputStream().readBytes())
                    }
                    peer.get(10, TimeUnit.SECONDS)
                } finally {
                    executor.shutdownNow()
                }
            }
        }
    }

    @Test
    fun actualMihomoUdpRelayReturnsDnsRepliesForIpv4AndIpv6() {
        val runtime = startSession(directPrefs())
        listOf("127.0.0.1", "::1").forEach { address ->
            val loopback = InetAddress.getByName(address)
            val query = dnsQuery()
            val answer = dnsAnswer(query)
            DatagramSocket(InetSocketAddress(loopback, 0)).use { server ->
                server.soTimeout = 8_000
                val executor = Executors.newSingleThreadExecutor()
                try {
                    val peer = executor.submit(Callable {
                        val packet = DatagramPacket(ByteArray(512), 512)
                        server.receive(packet)
                        assertArrayEquals(query, packet.data.copyOfRange(packet.offset, packet.offset + packet.length))
                        server.send(DatagramPacket(answer, answer.size, packet.socketAddress))
                    })
                    Socks5UdpRelay.open("127.0.0.1", runtime.mixedPort, connectTimeoutMs = 8_000).use { relay ->
                        relay.send(loopback, server.localPort, query)
                        val response = relay.receive(8_000)
                        assertNotNull("No SOCKS UDP DNS reply for $address", response)
                        requireNotNull(response)
                        assertEquals(loopback, response.remote)
                        assertEquals(server.localPort, response.remotePort)
                        assertArrayEquals("DNS answer or transaction ID changed", answer, response.payload)
                        assertTrue(relay.isOpen)
                    }
                    peer.get(10, TimeUnit.SECONDS)
                } finally {
                    executor.shutdownNow()
                }
            }
        }
    }

    @Test
    fun defaultProfileStartsAndSupportsRuntimeModeChanges() {
        val runtime = startSession(SessionPrefs())
        assertTrue(ControllerClient.probe("127.0.0.1", runtime.controllerPort, runtime.secret).ok)
        listOf("direct", "global", "rule").forEach { mode ->
            val changed = ControllerClient.updateRoutingMode("127.0.0.1", runtime.controllerPort, runtime.secret, mode)
            assertTrue("Controller could not safely activate mode $mode: $changed", changed.ok)
            assertFalse(changed.restartRequired)
            assertEquals(mode, controllerJson(runtime, "/configs").getString("mode"))
            if (mode == "global") {
                assertEquals("ViaSix Cloudflare Pages", controllerJson(runtime, "/proxies/GLOBAL").getString("now"))
            }
        }
        assertEquals(ConnectionPhase.RUNNING, SessionRuntimeStore(context).load().phase)
    }

    @Test
    fun globalStartupSelectsTheManagedProxyAndKeepsRulesForALiveRuleSwitch() {
        val runtime = startSession(SessionPrefs(routingMode = "global"))
        assertEquals("global", controllerJson(runtime, "/configs").getString("mode"))
        assertEquals("ViaSix Cloudflare Pages", controllerJson(runtime, "/proxies/GLOBAL").getString("now"))
        assertManagedRules(runtime)

        val switched = ControllerClient.updateRoutingMode("127.0.0.1", runtime.controllerPort, runtime.secret, "rule")
        assertTrue("GLOBAL → RULE must retain managed routing rules", switched.ok)
        assertFalse(switched.restartRequired)
        assertEquals("rule", controllerJson(runtime, "/configs").getString("mode"))
        assertManagedRules(runtime)
        assertEquals(runtime.sessionKey(), SessionRuntimeStore(context).load().sessionKey())
    }

    @Test
    fun directOnlyRuntimeIsRebuiltBeforeActivatingRuleOrGlobal() {
        for (mode in listOf("rule", "global")) {
            val initial = startSession(directPrefs())
            assertFalse(controllerJson(initial, "/proxies").getJSONObject("proxies").has("ViaSix Cloudflare Pages"))
            val update = ControllerClient.updateRoutingMode("127.0.0.1", initial.controllerPort, initial.secret, mode)
            assertFalse("A mode-only PATCH would leave DIRECT routing active", update.ok)
            assertTrue("Missing proxies require a configuration rebuild", update.restartRequired)
            assertEquals("direct", controllerJson(initial, "/configs").getString("mode"))

            // This is the same service restart used by MainActivity when the
            // controller reports restartRequired; it must install real proxies/rules.
            dispatchStart(SessionPrefs(routingMode = mode))
            awaitCondition("Mode change did not rebuild the DIRECT-only runtime", 25_000) {
                val status = SessionRuntimeStore(context).load()
                status.running && status.secret.isNotBlank() && status.secret != initial.secret
            }
            val rebuilt = SessionRuntimeStore(context).load()
            assertTrue(controllerJson(rebuilt, "/proxies").getJSONObject("proxies").has("ViaSix Cloudflare Pages"))
            assertEquals(mode, controllerJson(rebuilt, "/configs").getString("mode"))
            assertManagedRules(rebuilt)
            if (mode == "global") {
                assertEquals("ViaSix Cloudflare Pages", controllerJson(rebuilt, "/proxies/GLOBAL").getString("now"))
            }
            stopSession()
        }
    }

    private fun assertManagedRules(runtime: SessionRuntimeStatus) {
        val rules = controllerJson(runtime, "/rules").getJSONArray("rules")
        assertTrue("The active rules must route through the managed proxy", (0 until rules.length()).any {
            val rule = rules.getJSONObject(it)
            rule.optString("type") == "Match" && rule.optString("proxy") == "ViaSix Cloudflare Pages"
        })
    }

    private fun controllerJson(runtime: SessionRuntimeStatus, path: String): org.json.JSONObject {
        val connection = ControllerClient.open("http://127.0.0.1:${runtime.controllerPort}$path", runtime.secret, 3_000)
        try {
            assertEquals(200, connection.responseCode)
            return org.json.JSONObject(ControllerClient.readBody(connection))
        } finally {
            connection.disconnect()
        }
    }

    private fun dnsQuery(): ByteArray = byteArrayOf(
        0x63, 0x17, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 'e'.code.toByte(), 'x'.code.toByte(), 'a'.code.toByte(), 'm'.code.toByte(), 'p'.code.toByte(), 'l'.code.toByte(), 'e'.code.toByte(),
        0x04, 't'.code.toByte(), 'e'.code.toByte(), 's'.code.toByte(), 't'.code.toByte(),
        0x00, 0x00, 0x01, 0x00, 0x01,
    )

    private fun dnsAnswer(query: ByteArray): ByteArray = query.copyOf().also {
        it[2] = 0x81.toByte()
        it[3] = 0x80.toByte()
        it[7] = 0x01
    } + byteArrayOf(0xc0.toByte(), 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 192.toByte(), 0, 2, 123)

    private fun readFully(input: InputStream, count: Int): ByteArray {
        val bytes = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(bytes, offset, count - offset)
            check(read > 0) { "TCP EOF after $offset of $count bytes" }
            offset += read
        }
        return bytes
    }
}

/** Saves the exact preference JSON, including an absent first-install entry. */
abstract class IsolatedVpnDeviceTest {
    protected val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var sessionPreferences: SharedPreferences
    private var originalSession: String? = null

    @Before
    fun isolatePreferencesAndStopExistingSession() {
        sessionPreferences = context.getSharedPreferences("viasix_session", Context.MODE_PRIVATE)
        originalSession = sessionPreferences.getString("session", null)
        stopSession()
    }

    @After
    fun stopAndRestorePreferences() {
        try {
            stopSession()
        } finally {
            val editor = sessionPreferences.edit()
            if (originalSession == null) editor.remove("session") else editor.putString("session", originalSession)
            assertTrue("Could not restore saved session preferences", editor.commit())
        }
    }

    protected fun directPrefs(): SessionPrefs = SessionPrefs(routingMode = "direct", fullTunnel = true)

    protected fun requireVpnConsent() {
        assertNull("Grant Android VPN consent for dev.viasix.app before running device tests", VpnService.prepare(context))
    }

    protected fun startSession(prefs: SessionPrefs): SessionRuntimeStatus {
        dispatchStart(prefs)
        return awaitRunning()
    }

    protected fun dispatchStart(prefs: SessionPrefs) {
        requireVpnConsent()
        assertEquals(SessionStartGate.Result.Ok, VpnSessionCommands.evaluateStart(prefs))
        SessionPrefsStore(context).save(prefs)
        context.startForegroundService(VpnSessionCommands.buildStartIntent(context, prefs, "instrumentation-test"))
    }

    protected fun awaitRunning(): SessionRuntimeStatus {
        awaitCondition("VPN did not reach running state", 25_000) {
            SessionRuntimeStore(context).load().phase == ConnectionPhase.RUNNING
        }
        return SessionRuntimeStore(context).load().also { status ->
            assertTrue(status.running)
            assertTrue(status.secret.isNotBlank())
            assertNotNull(status.sessionKey())
        }
    }

    protected fun stopSession() {
        if (SessionRuntimeStore(context).load().phase.isActiveOrTransitioning || isPortOpen(ViaSixVpnService.MIXED_PORT)) {
            context.startService(VpnSessionCommands.buildStopIntent(context))
        }
        awaitCondition("VPN did not stop or retained a listening socket", 15_000) {
            SessionRuntimeStore(context).load().phase == ConnectionPhase.STOPPED &&
                !isPortOpen(ViaSixVpnService.MIXED_PORT) && !isPortOpen(ViaSixVpnService.CONTROLLER_PORT)
        }
    }

    protected fun awaitCondition(message: String, timeoutMs: Long, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (!condition()) {
            if (SystemClock.elapsedRealtime() >= deadline) {
                val status = SessionRuntimeStore(context).load()
                fail("$message: phase=${status.phase}, health=${status.health}, events=${status.eventsJson}")
            }
            SystemClock.sleep(50)
        }
    }

    private fun isPortOpen(port: Int): Boolean = runCatching {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 100) }
    }.isSuccess
}
