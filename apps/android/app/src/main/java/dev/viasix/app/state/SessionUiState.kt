package dev.viasix.app.state

import dev.viasix.app.mihomo.ProxyDelayResult
import dev.viasix.app.mihomo.TrafficSnapshot
import dev.viasix.app.net.ExitIPDetectionMode
import dev.viasix.app.net.ExitIPInfo
import dev.viasix.app.prefs.SessionPrefs
import dev.viasix.app.runtime.RuntimeComponentsState
import dev.viasix.app.session.AppRoutingMode
import dev.viasix.app.session.AppRoutingPolicy
import dev.viasix.app.session.AppRoutingState
import dev.viasix.app.session.BatteryOptimizationState
import dev.viasix.app.session.ConnectionPhase
import dev.viasix.app.session.DnsRoutingMode
import dev.viasix.app.session.DnsSettingsPolicy
import dev.viasix.app.session.DnsSettingsState
import dev.viasix.app.session.Ipv6RoutingMode
import dev.viasix.app.session.MemoizedProfileSummaryParser
import dev.viasix.app.session.NotificationPermissionState
import dev.viasix.app.session.ProfileDraftGate
import dev.viasix.app.session.VpnMtuPolicy
import dev.viasix.app.session.VpnPermissionState
import dev.viasix.core.net.Ipv6Address
import dev.viasix.core.profile.ProfileSummary
import dev.viasix.core.projection.RoutingMode
import dev.viasix.core.speedtest.IPSourceMode
import dev.viasix.core.speedtest.NodeResultSorting
import dev.viasix.core.speedtest.NodeSortKey
import dev.viasix.core.speedtest.SpeedTestParameters
import dev.viasix.core.speedtest.SpeedTestResult
import dev.viasix.core.speedtest.parameterSummary
import dev.viasix.core.speedtest.previewValidationMessage
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

enum class LogLevel {
    Info,
    Success,
    Warning,
    Error,
}

enum class LogSource(val label: String) {
    Session("会话"),
    Proxy("代理"),
    Node("节点"),
    Network("网络"),
    System("系统"),
}

data class LogEntry(
    val id: Long,
    val timestamp: String,
    val message: String,
    val level: LogLevel = LogLevel.Info,
    val source: LogSource = LogSource.Session,
)

data class RuntimeSnapshot(
    val running: Boolean = false,
    val health: String = "—",
    val traffic: TrafficSnapshot = TrafficSnapshot.Idle,
    val controllerPort: Int = 9090,
    val mixedPort: Int = 11451,
    val mihomoVersion: String? = null,
    val secretPresent: Boolean = false,
    val startedAtMillis: Long? = null,
    val underlyingNetwork: String = "正在检测",
)

data class ExitIPState(
    val isDetecting: Boolean = false,
    val info: ExitIPInfo? = null,
    val errorMessage: String? = null,
    val mode: ExitIPDetectionMode = ExitIPDetectionMode.AUTOMATIC,
    val endpoint: String = "https://api.myip.la/cn?json",
)

data class DelayTestState(
    val isRunning: Boolean = false,
    val last: ProxyDelayResult? = null,
)

/**
 * CloudflareSpeedTest (IPv6 优选) session state.
 * Results feed the same apply-node / reconnect path as manual candidates.
 */
data class SpeedTestUiState(
    val isRunning: Boolean = false,
    /** True while a single-IP “当前节点测速” run is active. */
    val isNodeTest: Boolean = false,
    /** Placeholder until the async component inspection overwrites it with CFST detail. */
    val message: String = "正在检查 CFST 组件…",
    val results: List<SpeedTestResult> = emptyList(),
    /** Live CFST bar progress (macOS speedTest.current / total). 0 total = unknown. */
    val progressCurrent: Int = 0,
    val progressTotal: Int = 0,
    /** macOS [IPSourceMode] — Nodes picker excludes IPv4. */
    val ipSourceMode: IPSourceMode = IPSourceMode.IPV6,
    /** Full CFST parameters (macOS [SpeedTestParameters]). */
    val parameters: SpeedTestParameters = SpeedTestParameters.defaultsForRange(),
    /** User-selected IP list path when [ipSourceMode] is [IPSourceMode.FILE]. */
    val customIpFilePath: String = "",
    val binaryReady: Boolean = false,
    val sortKey: NodeSortKey = NodeSortKey.LATENCY,
    val sortAscending: Boolean = true,
    val parametersExpanded: Boolean = false,
) {
    val sortedResults: List<SpeedTestResult>
        get() = NodeResultSorting.sorted(results, sortKey, sortAscending)

    val hasProgress: Boolean
        get() = isRunning && progressTotal > 0

    val progressFraction: Float
        get() =
            if (progressTotal <= 0) {
                0f
            } else {
                (progressCurrent.toFloat() / progressTotal.toFloat()).coerceIn(0f, 1f)
            }

    val parameterSummaryText: String
        get() = parameters.parameterSummary(ipSourceMode)

    /** macOS [NodesViewState.parameterValidationMessage] for current form values. */
    val parameterValidationMessage: String?
        get() =
            parameters.previewValidationMessage(
                mode = ipSourceMode,
                customIpFilePath = customIpFilePath,
            )

    val canStartSpeedTest: Boolean
        get() = !isRunning && parameterValidationMessage == null
}

/**
 * Full UI state for the Android shell. Session fields persist via [SessionPrefs];
 * runtime is polled from the VPN service + controller.
 */
data class SessionUiState(
    /** Last validated profile used to build new VPN sessions. */
    val profileYaml: String = "",
    /** Editable, persisted draft; never used by the runtime until explicitly applied. */
    val profileDraft: String = "",
    val selectedAddress: String = "2001:db8::1",
    val candidateAddresses: List<String> = emptyList(),
    val routingMode: RoutingMode = RoutingMode.RULE,
    val routingModeSyncing: Boolean = false,
    val fullTunnel: Boolean = true,
    val vpnMtu: String = VpnMtuPolicy.DEFAULT.toString(),
    val vpnMetered: Boolean = true,
    val bypassLocalNetwork: Boolean = false,
    val ipv6RoutingMode: Ipv6RoutingMode = Ipv6RoutingMode.TUNNEL,
    val dnsSettings: DnsSettingsState = DnsSettingsState(),
    val appRouting: AppRoutingState = AppRoutingState(),
    val notificationPermission: NotificationPermissionState = NotificationPermissionState(),
    val vpnPermission: VpnPermissionState = VpnPermissionState(),
    val batteryOptimization: BatteryOptimizationState = BatteryOptimizationState(),
    val runtimeComponents: RuntimeComponentsState = RuntimeComponentsState(),
    val runtime: RuntimeSnapshot = RuntimeSnapshot(),
    /** UI connection lifecycle; reconciled with [runtime.running] each poll. */
    val connectionPhase: ConnectionPhase = ConnectionPhase.STOPPED,
    val exitIP: ExitIPState = ExitIPState(),
    val delayTest: DelayTestState = DelayTestState(),
    val speedTest: SpeedTestUiState = SpeedTestUiState(),
    val statusMessage: String = "就绪",
    val statusLevel: LogLevel = LogLevel.Info,
    val logs: List<LogEntry> = emptyList(),
    val configPreview: String = "",
    val notice: AppNotice? = null,
) {
    // Memoized: getters run per recomposition and per 1.2s status poll; repeat
    // parses of an unchanged YAML string must not hit SnakeYAML on the main thread.
    val profileSummary: ProfileSummary
        get() = MemoizedProfileSummaryParser.shared.summaryFor(profileYaml)

    val profileDraftSummary: ProfileSummary
        get() = MemoizedProfileSummaryParser.shared.summaryFor(profileDraft)

    val profileHasUnsavedChanges: Boolean
        get() = profileDraft != profileYaml

    val profileDraftIssue: String?
        get() =
            when (val gate = ProfileDraftGate.evaluate(profileDraft)) {
                ProfileDraftGate.Result.Ok -> null
                is ProfileDraftGate.Result.Blocked -> gate.message
            }

    val selectedIsIpv6: Boolean
        get() = Ipv6Address.isValid(selectedAddress)

    val configurationReady: Boolean
        get() =
            routingMode == RoutingMode.DIRECT ||
                (profileYaml.isNotBlank() && selectedIsIpv6 && profileSummary.primary != null)

    fun toPrefs(): SessionPrefs =
        SessionPrefs(
            profileYaml = profileYaml,
            profileDraft = profileDraft,
            notificationPermissionRequested = notificationPermission.wasRequested,
            selectedAddress = selectedAddress,
            routingMode = routingMode.wire,
            fullTunnel = fullTunnel,
            vpnMtu = vpnMtu.trim(),
            vpnMetered = vpnMetered,
            bypassLocalNetwork = bypassLocalNetwork,
            ipv6RoutingMode = ipv6RoutingMode.wire,
            dnsRoutingMode = dnsSettings.mode.wire,
            dnsServer = dnsSettings.server.trim(),
            appRoutingMode = appRouting.mode.wire,
            selectedAppPackages = appRouting.selectedPackages,
            candidateAddresses = candidateAddresses,
            exitIPEndpoint = exitIP.endpoint,
            exitIPDetectionMode = exitIP.mode.wire,
            ipSourceMode = speedTest.ipSourceMode.wire,
            speedParameters = speedTest.parameters,
            customIpFilePath = speedTest.customIpFilePath,
        )

    companion object {
        val defaultProfile =
            """
            proxies:
              - name: My VLESS
                type: vless
                server: origin.example.com
                port: 443
                uuid: 11111111-1111-4111-1111-111111111111
            x-viasix:
              version: 1
              primary-server: selected-ip
            """.trimIndent()

        fun fromPrefs(prefs: SessionPrefs): SessionUiState {
            val profile = prefs.profileYaml.ifBlank { defaultProfile }
            val selected = prefs.selectedAddress.ifBlank { "2001:db8::1" }
            val candidates =
                (listOf(selected) + prefs.candidateAddresses)
                    .mapNotNull { Ipv6Address.normalize(it) }
                    .distinct()
                    .take(50)
            return SessionUiState(
                profileYaml = profile,
                profileDraft = prefs.profileDraft ?: profile,
                notificationPermission =
                    NotificationPermissionState(
                        wasRequested = prefs.notificationPermissionRequested,
                    ),
                selectedAddress = selected,
                candidateAddresses = candidates,
                routingMode = RoutingMode.parse(prefs.routingMode) ?: RoutingMode.RULE,
                fullTunnel = prefs.fullTunnel,
                vpnMtu = prefs.vpnMtu.trim(),
                vpnMetered = prefs.vpnMetered,
                bypassLocalNetwork = prefs.bypassLocalNetwork,
                ipv6RoutingMode = Ipv6RoutingMode.parse(prefs.ipv6RoutingMode),
                dnsSettings =
                    DnsSettingsState(
                        mode = DnsRoutingMode.parse(prefs.dnsRoutingMode),
                        server =
                            prefs.dnsServer.trim().ifBlank { DnsSettingsPolicy.DEFAULT_SERVER },
                    ),
                appRouting =
                    AppRoutingState(
                        mode = AppRoutingMode.parse(prefs.appRoutingMode),
                        selectedPackages =
                            prefs.selectedAppPackages
                                .map(String::trim)
                                .filter(AppRoutingPolicy::isValidPackageName)
                                .distinct()
                                .sorted()
                                .take(200),
                    ),
                exitIP =
                    ExitIPState(
                        mode = ExitIPDetectionMode.parse(prefs.exitIPDetectionMode),
                        endpoint = prefs.exitIPEndpoint,
                    ),
                speedTest =
                    SpeedTestUiState(
                        ipSourceMode = IPSourceMode.parse(prefs.ipSourceMode),
                        parameters = prefs.speedParameters,
                        customIpFilePath = prefs.customIpFilePath,
                    ),
            )
        }
    }
}

data class AppNotice(
    val id: Long,
    val message: String,
    val style: LogLevel,
    val actionOpenSettings: Boolean = false,
)

object LogClock {
    private var nextId = 1L

    fun now(): String = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())

    fun nextId(): Long = nextId++
}

fun SessionUiState.appendLog(
    message: String,
    level: LogLevel = LogLevel.Info,
    source: LogSource = LogSource.Session,
    maxEntries: Int = 500,
    asNotice: Boolean = false,
    noticeActionOpenSettings: Boolean = level == LogLevel.Error,
): SessionUiState {
    val entry =
        LogEntry(
            id = LogClock.nextId(),
            timestamp = LogClock.now(),
            message = message,
            level = level,
            source = source,
        )
    return copy(
        statusMessage = message,
        statusLevel = level,
        logs = (listOf(entry) + logs).take(maxEntries),
        notice =
            if (asNotice) {
                AppNotice(
                    id = entry.id,
                    message = message,
                    style = level,
                    actionOpenSettings = noticeActionOpenSettings,
                )
            } else {
                notice
            },
    )
}

fun SessionUiState.rememberCandidate(address: String): SessionUiState {
    val normalized = Ipv6Address.normalize(address) ?: return this
    val next =
        (listOf(normalized) + candidateAddresses.filter { it != normalized })
            .take(50)
    return copy(candidateAddresses = next, selectedAddress = normalized)
}
