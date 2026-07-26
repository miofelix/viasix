package dev.viasix.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.service.quicksettings.TileService
import android.system.OsConstants
import android.util.Log
import dev.viasix.app.MainActivity
import dev.viasix.app.R
import dev.viasix.app.mihomo.ControllerClient
import dev.viasix.app.mihomo.MihomoInstaller
import dev.viasix.app.mihomo.MihomoProcess
import dev.viasix.app.mihomo.TrafficSampler
import dev.viasix.app.prefs.SessionPrefsStore
import dev.viasix.app.session.AppRoutingMode
import dev.viasix.app.session.AppRoutingPolicy
import dev.viasix.app.session.ConnectionPhase
import dev.viasix.app.session.DnsRoutingMode
import dev.viasix.app.session.DnsSettingsPolicy
import dev.viasix.app.session.GenerationGate
import dev.viasix.app.session.Ipv6RoutingMode
import dev.viasix.app.session.LatestRequestGate
import dev.viasix.app.session.LocalNetworkBypassPolicy
import dev.viasix.app.session.RuntimeEventSequence
import dev.viasix.app.session.RuntimeProcessIdentity
import dev.viasix.app.session.RuntimeStackFailure
import dev.viasix.app.session.RuntimeStackHealth
import dev.viasix.app.session.ShutdownRestartGate
import dev.viasix.app.session.ShutdownSubmission
import dev.viasix.app.session.UnderlyingNetworkPresentation
import dev.viasix.app.session.UnderlyingNetworkSelection
import dev.viasix.app.session.VpnStartOrigin
import dev.viasix.app.session.VpnStartupCancelledException
import dev.viasix.app.session.VpnStartupGate
import dev.viasix.app.session.VpnMtuPolicy
import dev.viasix.app.tile.ViaSixTileService
import dev.viasix.app.tun.Tun2SocksEngine
import dev.viasix.app.ui.AppSection
import dev.viasix.core.formatting.ByteRateFormatter
import dev.viasix.core.projection.MihomoProjection
import dev.viasix.core.projection.ProjectError
import dev.viasix.core.projection.ProjectOptions
import dev.viasix.core.projection.RoutingMode
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.Inet6Address
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Full-path Android network access:
 * 1) Project profile → start user-space mihomo (mixed/SOCKS on loopback)
 * 2) Establish VPN with default routes (IPv4 + IPv6 when full tunnel)
 * 3) Exclude this app UID from the VPN (prevents routing loops for mihomo)
 * 4) Userspace IPv4/IPv6 TCP→SOCKS CONNECT + general UDP→per-client SOCKS UDP ASSOCIATE
 *    ([Tun2SocksEngine]); DNS uses SOCKS by default with an explicit protected-direct option
 *
 * Supports restart with new profile/node without leaving a half-live stack.
 * Emits a circular event log into SharedPreferences for the UI log pane.
 */
class ViaSixVpnService : VpnService() {
    @Volatile
    private var tunnel: ParcelFileDescriptor? = null
    private var mihomo: MihomoProcess? = null
    private var tunEngine: Tun2SocksEngine? = null
    private val startRequests = LatestRequestGate<StartRequest>()
    private val shutdownGate = ShutdownRestartGate<StartRequest>()
    private val trafficLoopGate = GenerationGate()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var trafficThread: Thread? = null
    private var activeSecret: String = ""
    private lateinit var connectivityManager: ConnectivityManager
    private var networkCallbackRegistered = false
    private val underlyingNetworkLock = Any()

    @Volatile
    private var underlyingNetworkSelection = UnderlyingNetworkSelection<Network>()

    private data class StartRequest(
        val profile: String,
        val selectedIp: String?,
        val mode: RoutingMode,
        val fullTunnel: Boolean,
        val vpnMtuInput: String,
        val vpnMetered: Boolean,
        val bypassLocalNetwork: Boolean,
        val ipv6RoutingMode: Ipv6RoutingMode,
        val dnsRoutingMode: DnsRoutingMode,
        val dnsServerInput: String,
        val appRoutingMode: AppRoutingMode,
        val selectedAppPackages: List<String>,
        val reason: String,
    )

    private val underlyingNetworkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                connectivityManager.getNetworkCapabilities(network)?.let { capabilities ->
                    handleUnderlyingNetwork(network, capabilities)
                }
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                handleUnderlyingNetwork(network, networkCapabilities)
            }

            override fun onLost(network: Network) {
                val handoverLabel =
                    synchronized(underlyingNetworkLock) {
                        val current = underlyingNetworkSelection
                        val updated = current.lost(network)
                        if (updated == current) {
                            null
                        } else {
                            underlyingNetworkSelection = updated
                            applyUnderlyingNetwork(null)
                            updated.label
                        }
                    }
                if (handoverLabel == null) return

                writeUnderlyingNetworkStatus(handoverLabel)
                appendEvent("底层网络丢失，等待系统切换", "warning")
            }
        }

    override fun onCreate() {
        super.onCreate()
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        writeUnderlyingNetworkStatus(underlyingNetworkSelection.label)
        try {
            connectivityManager.registerDefaultNetworkCallback(underlyingNetworkCallback)
            networkCallbackRegistered = true
        } catch (error: Exception) {
            Log.w(TAG, "default network callback: ${error.message}")
            writeUnderlyingNetworkStatus("网络检测不可用")
            appendEvent("无法监听底层网络：${error.message}", "warning")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            appendEvent("用户停止会话", "info")
            shutdownAll(
                reason = "stopped by user",
                stopService = true,
                asynchronous = true,
            )
            return START_NOT_STICKY
        }

        val startOrigin =
            VpnStartOrigin.detect(
                intentPresent = intent != null,
                action = intent?.action,
            )
        val restoredPrefs =
            if (startOrigin.restoreSavedSession) SessionPrefsStore(this).load() else null
        val profile = intent?.getStringExtra(EXTRA_PROFILE) ?: restoredPrefs?.profileYaml.orEmpty()
        val selectedIp =
            intent?.getStringExtra(EXTRA_SELECTED_IP) ?: restoredPrefs?.selectedAddress
        val modeWire = intent?.getStringExtra(EXTRA_MODE) ?: restoredPrefs?.routingMode ?: "rule"
        val mode = RoutingMode.parse(modeWire) ?: RoutingMode.RULE
        val fullTunnel =
            intent?.getBooleanExtra(EXTRA_FULL_TUNNEL, restoredPrefs?.fullTunnel ?: true)
                ?: restoredPrefs?.fullTunnel
                ?: true
        val vpnMtuInput =
            intent?.getStringExtra(EXTRA_VPN_MTU)
                ?: restoredPrefs?.vpnMtu
                ?: VpnMtuPolicy.DEFAULT.toString()
        val vpnMetered =
            intent?.getBooleanExtra(EXTRA_VPN_METERED, restoredPrefs?.vpnMetered ?: true)
                ?: restoredPrefs?.vpnMetered
                ?: true
        val bypassLocalNetwork =
            intent?.getBooleanExtra(
                EXTRA_BYPASS_LOCAL_NETWORK,
                restoredPrefs?.bypassLocalNetwork ?: false,
            ) ?: restoredPrefs?.bypassLocalNetwork ?: false
        val ipv6RoutingMode =
            Ipv6RoutingMode.parse(
                intent?.getStringExtra(EXTRA_IPV6_ROUTING_MODE)
                    ?: restoredPrefs?.ipv6RoutingMode,
            )
        val dnsRoutingMode =
            DnsRoutingMode.parse(
                intent?.getStringExtra(EXTRA_DNS_ROUTING_MODE)
                    ?: restoredPrefs?.dnsRoutingMode,
            )
        val dnsServerInput =
            intent?.getStringExtra(EXTRA_DNS_SERVER)
                ?: restoredPrefs?.dnsServer
                ?: DnsSettingsPolicy.DEFAULT_SERVER
        val appRoutingMode =
            AppRoutingMode.parse(
                intent?.getStringExtra(EXTRA_APP_ROUTING_MODE)
                    ?: restoredPrefs?.appRoutingMode,
            )
        val selectedAppPackages =
            intent?.getStringArrayListExtra(EXTRA_SELECTED_APP_PACKAGES)?.toList()
                ?: restoredPrefs?.selectedAppPackages
                ?: emptyList()
        val reason =
            intent?.getStringExtra(EXTRA_REASON).orEmpty().ifBlank {
                startOrigin.reason
            }
        val request =
            StartRequest(
                profile = profile,
                selectedIp = selectedIp,
                mode = mode,
                fullTunnel = fullTunnel,
                vpnMtuInput = vpnMtuInput,
                vpnMetered = vpnMetered,
                bypassLocalNetwork = bypassLocalNetwork,
                ipv6RoutingMode = ipv6RoutingMode,
                dnsRoutingMode = dnsRoutingMode,
                dnsServerInput = dnsServerInput,
                appRoutingMode = appRoutingMode,
                selectedAppPackages = selectedAppPackages,
                reason = reason,
            )

        startForeground(NOTIFICATION_ID, buildNotification("Starting ViaSix…"))
        appendEvent(
            "启动请求（$reason） mode=${mode.wire} fullTunnel=$fullTunnel mtu=$vpnMtuInput " +
                "metered=$vpnMetered " +
                "bypassLocal=$bypassLocalNetwork " +
                "ipv6=${ipv6RoutingMode.wire} " +
                "appRouting=${appRoutingMode.wire} apps=${selectedAppPackages.size}",
            "info",
        )

        if (shutdownGate.submit(request) == ShutdownSubmission.QUEUED) {
            appendEvent("关停进行中，已保留最新启动请求", "info")
            return START_STICKY
        }

        if (!startRequests.submit(request)) {
            appendEvent("已有启动任务进行中，已合并为最新请求", "info")
            return START_STICKY
        }
        launchStartupWorker()
        return START_STICKY
    }

    private fun launchStartupWorker() {
        thread(name = "viasix-vpn-start", isDaemon = true) {
            while (!shutdownGate.isShuttingDown()) {
                val request = startRequests.takeNext() ?: break
                try {
                    requireStartupActive("before restart cleanup")
                    writeRuntimeStatus(
                        phase = ConnectionPhase.STARTING,
                        healthMessage = "starting",
                        secret = "",
                        version = null,
                        startedAt = null,
                    )
                    // Tear down any previous stack before applying new parameters
                    // (node apply / reconnect path).
                    stopStackOnly("restart for ${request.reason}")
                    requireStartupActive("after restart cleanup")
                    startStack(
                        request.profile,
                        request.selectedIp,
                        request.mode,
                        request.fullTunnel,
                        request.vpnMtuInput,
                        request.vpnMetered,
                        request.bypassLocalNetwork,
                        request.ipv6RoutingMode,
                        request.dnsRoutingMode,
                        request.dnsServerInput,
                        request.appRoutingMode,
                        request.selectedAppPackages,
                    )
                } catch (error: VpnStartupCancelledException) {
                    Log.i(TAG, error.message.orEmpty())
                    break
                } catch (error: Exception) {
                    if (shutdownGate.isShuttingDown()) {
                        Log.i(TAG, "startup stopped during ${error.javaClass.simpleName}")
                    } else {
                        Log.e(TAG, "start failed", error)
                        appendEvent("启动失败：${error.message}", "error")
                        updateNotification("Start failed: ${error.message}")
                        shutdownAll("start failed", stopService = true)
                    }
                    break
                }
            }
        }
    }

    private fun startStack(
        profile: String,
        selectedIp: String?,
        mode: RoutingMode,
        fullTunnel: Boolean,
        vpnMtuInput: String,
        vpnMetered: Boolean,
        bypassLocalNetwork: Boolean,
        ipv6RoutingMode: Ipv6RoutingMode,
        dnsRoutingMode: DnsRoutingMode,
        dnsServerInput: String,
        appRoutingMode: AppRoutingMode,
        selectedAppPackages: List<String>,
    ) {
        requireStartupActive("configuration validation")
        val vpnMtu =
            VpnMtuPolicy.normalize(vpnMtuInput)
                ?: throw IllegalArgumentException(
                    "VPN MTU must be ${VpnMtuPolicy.MIN}..${VpnMtuPolicy.MAX}: $vpnMtuInput",
                )
        val normalizedDnsServer = DnsSettingsPolicy.normalizeServer(dnsServerInput)
        if (fullTunnel && normalizedDnsServer == null) {
            throw IllegalArgumentException("invalid DNS server: $dnsServerInput")
        }
        val dnsServer = normalizedDnsServer ?: DnsSettingsPolicy.DEFAULT_SERVER
        val dnsAddress = InetAddress.getByName(dnsServer)
        if (
            fullTunnel &&
                ipv6RoutingMode != Ipv6RoutingMode.TUNNEL &&
                dnsAddress is Inet6Address
        ) {
            throw IllegalArgumentException(
                "${ipv6RoutingMode.label} IPv6 mode requires an IPv4 DNS server",
            )
        }
        val secret = UUID.randomUUID().toString().replace("-", "")
        val options =
            ProjectOptions(
                routingMode = mode,
                selectedAddress = if (mode == RoutingMode.DIRECT) null else selectedIp,
                listenAddress = "127.0.0.1",
                mixedPort = MIXED_PORT,
                controllerPort = CONTROLLER_PORT,
                controllerSecret = secret,
            )

        val yaml =
            try {
                MihomoProjection.projectYaml(
                    if (mode == RoutingMode.DIRECT) null else profile,
                    options,
                )
            } catch (error: ProjectError) {
                throw IllegalArgumentException("projection: ${error.contractCode}", error)
            }

        requireStartupActive("runtime installation")
        appendEvent("投影完成，启动 mihomo…", "info")
        val binary = MihomoInstaller.installIfNeeded(this)
        requireStartupActive("mihomo launch")
        val workDir = File(filesDir, "mihomo-runtime")
        val process = MihomoProcess(binary, workDir)
        process.start(yaml)
        mihomo = process
        requireStartupActive("after mihomo launch")

        ControllerClient.sleepQuietly(400)
        val health = ControllerClient.probe("127.0.0.1", CONTROLLER_PORT, secret)
        requireStartupActive("after controller probe")
        if (!health.ok) {
            Log.w(TAG, "controller not healthy yet: ${health.message}")
            appendEvent("控制器尚未就绪：${health.message}", "warning")
        } else {
            appendEvent("控制器就绪 ${health.version ?: ""}".trim(), "success")
        }

        val builder =
            Builder()
                .setSession("ViaSix")
                .setMtu(vpnMtu)
                // Tun2SocksEngine uses blocking FileChannel reads; the platform default
                // is a non-blocking TUN descriptor whose EAGAIN would stop the reader.
                .setBlocking(fullTunnel)
                .setConfigureIntent(buildConfigureIntent())
                .addAddress("10.10.0.2", 32)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(vpnMetered)
        }
        applyAppRouting(builder, appRoutingMode, selectedAppPackages)

        if (fullTunnel) {
            builder.addRoute("0.0.0.0", 0)
            if (dnsAddress !is Inet6Address) {
                builder.addDnsServer(dnsServer)
            }
            applyLocalNetworkBypass(
                builder = builder,
                enabled = bypassLocalNetwork,
                prefixes = LocalNetworkBypassPolicy.IPV4_PREFIXES,
            )
            preserveDnsVpnRoute(
                builder = builder,
                enabled = bypassLocalNetwork && dnsAddress !is Inet6Address,
                dnsAddress = dnsAddress,
            )
            when (ipv6RoutingMode) {
                Ipv6RoutingMode.TUNNEL -> {
                    try {
                        builder.addAddress("fd00:10:10::2", 128)
                        builder.addRoute("::", 0)
                        if (dnsAddress is Inet6Address) {
                            builder.addDnsServer(dnsServer)
                        }
                    } catch (error: Exception) {
                        throw IllegalStateException(
                            "IPv6 VPN route is required but could not be applied: ${error.message}",
                            error,
                        )
                    }
                    applyLocalNetworkBypass(
                        builder = builder,
                        enabled = bypassLocalNetwork,
                        prefixes = LocalNetworkBypassPolicy.IPV6_PREFIXES,
                    )
                    preserveDnsVpnRoute(
                        builder = builder,
                        enabled = bypassLocalNetwork && dnsAddress is Inet6Address,
                        dnsAddress = dnsAddress,
                    )
                }
                Ipv6RoutingMode.BLOCK -> Unit
                Ipv6RoutingMode.BYPASS -> builder.allowFamily(OsConstants.AF_INET6)
            }
        } else {
            // HTTP proxy-only publishes metadata without a default route; do not let the
            // VpnService default address-family policy accidentally block device IPv6.
            builder.allowFamily(OsConstants.AF_INET6)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setHttpProxy(
                android.net.ProxyInfo.buildDirectProxy(
                    "127.0.0.1",
                    MIXED_PORT,
                    listOf("localhost", "127.0.0.1", "::1"),
                ),
            )
        }

        requireStartupActive("VPN establish")
        val established =
            builder.establish()
                ?: throw IllegalStateException("VpnService.Builder.establish() returned null")
        tunnel = established
        requireStartupActive("after VPN establish")
        synchronized(underlyingNetworkLock) {
            applyUnderlyingNetwork(underlyingNetworkSelection.network)
        }
        requireStartupActive("after underlying network binding")
        appendEvent("VPN MTU：$vpnMtu", "info")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appendEvent(
                "VPN 计费属性：${if (vpnMetered) "按流量计费" else "不计费"}",
                "info",
            )
        }
        if (bypassLocalNetwork && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appendEvent("局域网绕过：私网、链路本地与组播流量不进入 VPN", "info")
        }
        if (fullTunnel) {
            appendEvent("IPv6 应用流量：${ipv6RoutingMode.label}", "info")
        }

        if (fullTunnel) {
            val engine =
                Tun2SocksEngine(
                    vpnService = this,
                    tun = established,
                    socksHost = "127.0.0.1",
                    socksPort = MIXED_PORT,
                    dnsRoutingMode = dnsRoutingMode,
                    dnsUpstream = dnsAddress,
                    mtu = vpnMtu,
                )
            engine.start()
            tunEngine = engine
            requireStartupActive("after TUN forwarding launch")
            requireRuntimeStackHealthy(
                mihomoRunning = process.isRunning,
                fullTunnel = true,
            )
            updateNotification(
                if (health.ok) {
                    "全量隧道 · mixed :$MIXED_PORT · ${health.version ?: "ok"}"
                } else {
                    "全量隧道 · mixed :$MIXED_PORT · 控制器预热中"
                },
            )
            appendEvent("全量隧道已建立（TCP/UDP IPv4/IPv6 → SOCKS）", "success")
            appendEvent(
                "DNS：$dnsServer · ${dnsRoutingMode.label}",
                "info",
            )
        } else {
            updateNotification(
                if (health.ok) {
                    "代理 VPN · mixed :$MIXED_PORT · ${health.version ?: "ok"}"
                } else {
                    "代理 VPN · mixed :$MIXED_PORT · 控制器预热中"
                },
            )
            appendEvent("HTTP 代理 VPN 会话已建立（无默认路由）", "success")
        }

        requireStartupActive("runtime publication")
        requireRuntimeStackHealthy(
            mihomoRunning = process.isRunning,
            fullTunnel = fullTunnel,
        )
        // Publish running only after mihomo, the VPN interface and optional TUN forwarding
        // are all owned by this still-active startup.
        writeRuntimeStatus(
            phase = ConnectionPhase.RUNNING,
            healthMessage = health.message,
            secret = secret,
            version = health.version,
            startedAt = System.currentTimeMillis(),
        )
        requireStartupActive("after runtime publication")
        activeSecret = secret
        startTrafficNotificationLoop(secret, fullTunnel)
        requireStartupActive("after traffic supervision launch")
        Log.i(TAG, "stack ready fullTunnel=$fullTunnel health=${health.message}")
    }

    private fun requireRuntimeStackHealthy(
        mihomoRunning: Boolean,
        fullTunnel: Boolean,
    ) {
        when (
            RuntimeStackHealth.failure(
                mihomoRunning = mihomoRunning,
                fullTunnel = fullTunnel,
                tunnelRunning = tunEngine?.isRunning == true,
            )
        ) {
            RuntimeStackFailure.MIHOMO_EXITED ->
                throw IllegalStateException("mihomo exited before VPN stack became ready")
            RuntimeStackFailure.TUNNEL_EXITED ->
                throw IllegalStateException("TUN forwarding exited before VPN stack became ready")
            null -> Unit
        }
    }

    private fun requireStartupActive(stage: String) {
        VpnStartupGate.requireActive(
            shuttingDown = shutdownGate.isShuttingDown(),
            stage = stage,
        )
    }

    private fun applyAppRouting(
        builder: Builder,
        mode: AppRoutingMode,
        selectedAppPackages: List<String>,
    ) {
        val rules = AppRoutingPolicy.rules(mode, selectedAppPackages, packageName)
        var allowedCount = 0
        rules.allowedPackages.forEach { selectedPackage ->
            try {
                builder.addAllowedApplication(selectedPackage)
                allowedCount += 1
            } catch (_: android.content.pm.PackageManager.NameNotFoundException) {
                appendEvent("已忽略不存在的应用：$selectedPackage", "warning")
            }
        }
        rules.disallowedPackages.forEach { selectedPackage ->
            try {
                builder.addDisallowedApplication(selectedPackage)
            } catch (_: android.content.pm.PackageManager.NameNotFoundException) {
                appendEvent("已忽略不存在的绕过应用：$selectedPackage", "warning")
            }
        }
        if (mode == AppRoutingMode.ONLY_SELECTED && allowedCount == 0) {
            throw IllegalArgumentException("仅代理所选应用模式没有可用应用")
        }
        appendEvent(
            when (mode) {
                AppRoutingMode.ALL -> "应用路由：所有应用"
                AppRoutingMode.BYPASS_SELECTED ->
                    "应用路由：绕过 ${rules.disallowedPackages.size - 1} 个所选应用"
                AppRoutingMode.ONLY_SELECTED -> "应用路由：仅代理 $allowedCount 个所选应用"
            },
            "info",
        )
    }

    /** Clash-style live rates in the ongoing VPN notification. */
    private fun startTrafficNotificationLoop(
        secret: String,
        fullTunnel: Boolean,
    ) {
        stopTrafficNotificationLoop()
        val generation = trafficLoopGate.next()
        val sampler = TrafficSampler(maxHistory = 30)
        val supervisor =
            Thread(
                {
                    while (trafficLoopGate.isCurrent(generation)) {
                        val failure =
                            RuntimeStackHealth.failure(
                                mihomoRunning = mihomo?.isRunning == true,
                                fullTunnel = fullTunnel,
                                tunnelRunning = tunEngine?.isRunning == true,
                            )
                        if (failure != null) {
                            if (!trafficLoopGate.claim(generation)) break
                            val component =
                                when (failure) {
                                    RuntimeStackFailure.MIHOMO_EXITED -> "mihomo"
                                    RuntimeStackFailure.TUNNEL_EXITED -> "TUN 转发"
                                }
                            appendEvent("$component 异常退出，正在结束会话", "error")
                            shutdownAll("$component exited unexpectedly", stopService = true)
                            break
                        }
                        try {
                            val snap = sampler.sample("127.0.0.1", CONTROLLER_PORT, secret)
                            if (!trafficLoopGate.isCurrent(generation)) break
                            if (snap.live) {
                                val line =
                                    "↑ ${ByteRateFormatter.formatCompactRate(snap.upBps)}  " +
                                        "↓ ${ByteRateFormatter.formatCompactRate(snap.downBps)}  ·  " +
                                        "conn ${snap.connectionCount}"
                                updateNotification(line)
                            }
                        } catch (error: Exception) {
                            if (trafficLoopGate.isCurrent(generation)) {
                                Log.w(TAG, "traffic sample: ${error.message}")
                            }
                        }
                        try {
                            Thread.sleep(TRAFFIC_POLL_MS)
                        } catch (_: InterruptedException) {
                            break
                        }
                    }
                },
                "viasix-vpn-traffic",
            ).apply { isDaemon = true }
        trafficThread = supervisor
        supervisor.start()
    }

    private fun stopTrafficNotificationLoop() {
        trafficLoopGate.invalidate()
        val supervisor = trafficThread
        trafficThread = null
        try {
            if (supervisor !== Thread.currentThread()) supervisor?.interrupt()
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        if (networkCallbackRegistered) {
            try {
                connectivityManager.unregisterNetworkCallback(underlyingNetworkCallback)
            } catch (error: Exception) {
                Log.w(TAG, "unregister network callback: ${error.message}")
            }
            networkCallbackRegistered = false
        }
        shutdownAll("destroyed", stopService = false)
        super.onDestroy()
    }

    override fun onRevoke() {
        appendEvent("系统撤销 VPN 权限", "warning")
        shutdownAll(
            reason = "vpn permission revoked",
            stopService = true,
            asynchronous = true,
        )
        super.onRevoke()
    }

    /** Stop engines/process but keep the service if a restart is about to begin. */
    private fun stopStackOnly(reason: String) {
        Log.i(TAG, "stop stack: $reason")
        stopTrafficNotificationLoop()
        activeSecret = ""
        try {
            tunEngine?.stop()
        } catch (error: Exception) {
            Log.w(TAG, "tun stop: ${error.message}")
        }
        tunEngine = null
        try {
            mihomo?.stop()
        } catch (error: Exception) {
            Log.w(TAG, "mihomo stop: ${error.message}")
        }
        mihomo = null
        try {
            tunnel?.close()
        } catch (_: Exception) {
        }
        tunnel = null
    }

    private fun shutdownAll(
        reason: String,
        stopService: Boolean,
        asynchronous: Boolean = false,
    ) {
        if (!shutdownGate.beginShutdown()) return
        startRequests.cancelPending()
        Log.i(TAG, "shutdown: $reason")
        writeRuntimeStatus(
            phase = ConnectionPhase.STOPPING,
            healthMessage = "stopping",
            secret = "",
            version = null,
            startedAt = null,
        )
        val teardown = {
            stopStackOnly(reason)
            writeRuntimeStatus(
                phase = ConnectionPhase.STOPPED,
                healthMessage = "stopped",
                secret = "",
                version = null,
                startedAt = null,
            )
            appendEvent("会话结束：$reason", "info")
            val restart = shutdownGate.completeTeardown()
            if (restart != null) {
                appendEvent("关停完成，正在执行最新启动请求", "info")
                if (startRequests.submit(restart)) launchStartupWorker()
            } else if (stopService) {
                mainHandler.post {
                    if (!shutdownGate.commitServiceStop()) return@post
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
        if (asynchronous) {
            thread(name = "viasix-vpn-stop", isDaemon = true, block = teardown)
        } else {
            teardown()
        }
    }

    private fun applyLocalNetworkBypass(
        builder: Builder,
        enabled: Boolean,
        prefixes: List<String>,
    ) {
        if (!enabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        prefixes.forEach { prefix ->
            val separator = prefix.lastIndexOf('/')
            require(separator > 0) { "invalid local-network prefix: $prefix" }
            val address = InetAddress.getByName(prefix.substring(0, separator))
            val prefixLength = prefix.substring(separator + 1).toInt()
            builder.excludeRoute(IpPrefix(address, prefixLength))
        }
    }

    private fun preserveDnsVpnRoute(
        builder: Builder,
        enabled: Boolean,
        dnsAddress: InetAddress,
    ) {
        if (!enabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        builder.addRoute(dnsAddress, if (dnsAddress is Inet6Address) 128 else 32)
    }

    private fun handleUnderlyingNetwork(
        network: Network,
        capabilities: NetworkCapabilities,
    ) {
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) return

        val label =
            UnderlyingNetworkPresentation.label(
                wifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
                cellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
                ethernet = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET),
                validated =
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            )
        val changed =
            synchronized(underlyingNetworkLock) {
                val current = underlyingNetworkSelection
                val updated = current.updated(network, label)
                if (updated == current) {
                    false
                } else {
                    underlyingNetworkSelection = updated
                    if (current.network != network) {
                        applyUnderlyingNetwork(network)
                    }
                    true
                }
            }
        if (!changed) return

        writeUnderlyingNetworkStatus(label)
        appendEvent("底层网络：$label", "info")
    }

    private fun applyUnderlyingNetwork(network: Network?) {
        if (tunnel == null) return
        try {
            val accepted =
                if (network == null) {
                    setUnderlyingNetworks(null)
                } else {
                    setUnderlyingNetworks(arrayOf(network))
                }
            if (!accepted) {
                appendEvent("系统未接受底层网络绑定", "warning")
            }
        } catch (error: Exception) {
            Log.w(TAG, "set underlying network: ${error.message}")
            appendEvent("底层网络绑定失败：${error.message}", "warning")
        }
    }

    private fun writeUnderlyingNetworkStatus(label: String) {
        getSharedPreferences(RUNTIME_PREFS, MODE_PRIVATE)
            .edit()
            .putString(KEY_UNDERLYING_NETWORK, label)
            .apply()
    }

    private fun writeRuntimeStatus(
        phase: ConnectionPhase,
        healthMessage: String,
        secret: String,
        version: String?,
        startedAt: Long?,
    ) {
        val running = phase == ConnectionPhase.RUNNING
        getSharedPreferences(RUNTIME_PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_RUNNING, running)
            .putString(KEY_PHASE, phase.wire)
            .putString(KEY_HEALTH, healthMessage)
            .putString(KEY_SECRET, secret)
            .putInt(KEY_CONTROLLER_PORT, CONTROLLER_PORT)
            .putInt(KEY_MIXED_PORT, MIXED_PORT)
            .putString(KEY_VERSION, version.orEmpty())
            .putLong(KEY_STARTED_AT, startedAt ?: 0L)
            .putString(
                KEY_PROCESS_TOKEN,
                if (phase.isActiveOrTransitioning) RuntimeProcessIdentity.token else "",
            )
            .apply()
        notifyTileRefresh()
    }

    /** Keep the Quick Settings tile in sync with VPN runtime (no polling required). */
    private fun notifyTileRefresh() {
        try {
            TileService.requestListeningState(
                this,
                ComponentName(this, ViaSixTileService::class.java),
            )
        } catch (error: Exception) {
            Log.w(TAG, "tile refresh: ${error.message}")
        }
    }

    @Synchronized
    private fun appendEvent(message: String, level: String) {
        try {
            val prefs = getSharedPreferences(RUNTIME_PREFS, MODE_PRIVATE)
            val existing = prefs.getString(KEY_EVENTS, "[]") ?: "[]"
            val array =
                try {
                    JSONArray(existing)
                } catch (_: Exception) {
                    JSONArray()
                }
            var previousEventId = prefs.getLong(KEY_EVENT_SEQUENCE, 0L)
            for (i in 0 until array.length()) {
                previousEventId =
                    maxOf(
                        previousEventId,
                        array.optJSONObject(i)?.optLong("id", 0L) ?: 0L,
                    )
            }
            val eventId =
                RuntimeEventSequence.next(
                    previousId = previousEventId,
                    wallClockMillis = System.currentTimeMillis(),
                )
            val entry =
                JSONObject()
                    .put("ts", formatEventTime())
                    .put("level", level)
                    .put("message", message)
                    .put("id", eventId)
            // newest first
            val next = JSONArray()
            next.put(entry)
            val limit = 100
            for (i in 0 until minOf(array.length(), limit - 1)) {
                next.put(array.get(i))
            }
            prefs.edit()
                .putLong(KEY_EVENT_SEQUENCE, eventId)
                .putString(KEY_EVENTS, next.toString())
                .apply()
        } catch (error: Exception) {
            Log.w(TAG, "appendEvent failed: ${error.message}")
        }
    }

    private fun formatEventTime(): String =
        SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())

    private fun updateNotification(content: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(content))
    }

    private fun buildConfigureIntent(): PendingIntent =
        PendingIntent.getActivity(
            this,
            REQUEST_CONFIGURE_VPN,
            Intent(this, MainActivity::class.java)
                .putExtra(MainActivity.EXTRA_OPEN_SECTION, AppSection.SETTINGS.wire)
                .addFlags(
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun buildNotification(content: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                "ViaSix VPN",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "ViaSix 连接状态、实时速率与会话控制"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            }
        manager.createNotificationChannel(channel)
        val launch =
            PendingIntent.getActivity(
                this,
                REQUEST_OPEN_APP,
                Intent(this, MainActivity::class.java)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    ),
                PendingIntent.FLAG_IMMUTABLE,
            )
        val disconnect =
            PendingIntent.getService(
                this,
                REQUEST_DISCONNECT,
                Intent(this, ViaSixVpnService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val disconnectAction =
            Notification.Action.Builder(
                Icon.createWithResource(this, R.drawable.ic_viasix_notification),
                "断开",
                disconnect,
            ).build()
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("ViaSix")
            .setContentText(content)
            .setSmallIcon(R.drawable.ic_viasix_notification)
            .setColor(0xFF007AFF.toInt())
            .setContentIntent(launch)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .addAction(disconnectAction)
            .build()
    }

    companion object {
        const val ACTION_STOP = "dev.viasix.app.vpn.STOP"
        const val EXTRA_PROFILE = "profile"
        const val EXTRA_SELECTED_IP = "selected_ip"
        const val EXTRA_MODE = "mode"
        const val EXTRA_FULL_TUNNEL = "full_tunnel"
        const val EXTRA_VPN_MTU = "vpn_mtu"
        const val EXTRA_VPN_METERED = "vpn_metered"
        const val EXTRA_BYPASS_LOCAL_NETWORK = "bypass_local_network"
        const val EXTRA_IPV6_ROUTING_MODE = "ipv6_routing_mode"
        const val EXTRA_DNS_ROUTING_MODE = "dns_routing_mode"
        const val EXTRA_DNS_SERVER = "dns_server"
        const val EXTRA_APP_ROUTING_MODE = "app_routing_mode"
        const val EXTRA_SELECTED_APP_PACKAGES = "selected_app_packages"
        const val EXTRA_REASON = "reason"
        const val MIXED_PORT = 11451
        const val CONTROLLER_PORT = 9090
        const val RUNTIME_PREFS = "viasix_runtime"
        const val KEY_RUNNING = "running"
        const val KEY_PHASE = "phase"
        const val KEY_HEALTH = "health"
        const val KEY_SECRET = "secret"
        const val KEY_CONTROLLER_PORT = "controllerPort"
        const val KEY_MIXED_PORT = "mixedPort"
        const val KEY_VERSION = "version"
        const val KEY_STARTED_AT = "startedAt"
        const val KEY_EVENTS = "events"
        const val KEY_EVENT_SEQUENCE = "eventSequence"
        const val KEY_PROCESS_TOKEN = "processToken"
        const val KEY_UNDERLYING_NETWORK = "underlyingNetwork"

        private const val CHANNEL_ID = "viasix_vpn"
        private const val NOTIFICATION_ID = 42
        private const val REQUEST_OPEN_APP = 43
        private const val REQUEST_DISCONNECT = 44
        private const val REQUEST_CONFIGURE_VPN = 45
        private const val TRAFFIC_POLL_MS = 1_500L
        private const val TAG = "ViaSixVpnService"
    }
}
