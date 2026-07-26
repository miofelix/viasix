package dev.viasix.app

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import dev.viasix.app.cfst.CfstInstaller
import dev.viasix.app.cfst.CfstRunOutcome
import dev.viasix.app.cfst.CfstRunner
import dev.viasix.app.mihomo.ControllerClient
import dev.viasix.app.mihomo.MihomoInstaller
import dev.viasix.app.mihomo.TrafficSampler
import dev.viasix.app.mihomo.TrafficSnapshot
import dev.viasix.app.net.ExitIPDetectionMode
import dev.viasix.app.net.ExitIPDetector
import dev.viasix.app.net.ExitIPRoutePolicy
import dev.viasix.app.prefs.SessionPrefsStore
import dev.viasix.app.runtime.RuntimeComponentCondition
import dev.viasix.app.runtime.RuntimeComponentId
import dev.viasix.app.runtime.RuntimeComponentInfo
import dev.viasix.app.session.AppRoutingMode
import dev.viasix.app.session.AppRoutingPolicy
import dev.viasix.app.session.BatteryOptimizationState
import dev.viasix.app.session.ConnectionPhase
import dev.viasix.app.session.DnsRoutingMode
import dev.viasix.app.session.InstalledAppsRepository
import dev.viasix.app.session.Ipv6RoutingMode
import dev.viasix.app.session.NotificationPermissionFlow
import dev.viasix.app.session.NotificationPermissionState
import dev.viasix.app.session.POST_NOTIFICATIONS_PERMISSION
import dev.viasix.app.session.ProfileDraftGate
import dev.viasix.app.session.ProfileImportText
import dev.viasix.app.session.RuntimeEventCursor
import dev.viasix.app.session.RuntimeSessionKey
import dev.viasix.app.session.SessionRuntimeStore
import dev.viasix.app.session.SessionStartGate
import dev.viasix.app.session.VpnPermissionState
import dev.viasix.app.session.VpnSessionCommands
import dev.viasix.app.session.sessionKey
import dev.viasix.app.state.DelayTestState
import dev.viasix.app.state.LogLevel
import dev.viasix.app.state.LogSource
import dev.viasix.app.state.SessionUiState
import dev.viasix.app.state.appendLog
import dev.viasix.app.state.rememberCandidate
import dev.viasix.app.tile.ViaSixTileService
import dev.viasix.app.ui.AppSection
import dev.viasix.app.ui.ViaSixApp
import dev.viasix.app.vpn.ViaSixVpnService
import dev.viasix.core.net.Ipv6Address
import dev.viasix.core.projection.MihomoProjection
import dev.viasix.core.projection.ProjectError
import dev.viasix.core.projection.ProjectOptions
import dev.viasix.core.projection.RoutingMode
import dev.viasix.core.speedtest.IPSourceMode
import dev.viasix.core.speedtest.SpeedTestParameters
import dev.viasix.core.speedtest.resolveForRun
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray

class MainActivity : ComponentActivity() {
    private var pendingVpnStartReason: String? = null
    private var pendingNotificationStartReason: String? = null
    private lateinit var prefsStore: SessionPrefsStore
    private lateinit var runtimeStore: SessionRuntimeStore
    private var trafficSampler = TrafficSampler()
    private val cfstRunner = CfstRunner()
    private var lastImportedEventId: Long = 0L
    private var trafficSessionKey: RuntimeSessionKey? = null
    /** Wall clock when STARTING began; used for start-timeout reconcile. */
    private var startingSinceMillis: Long = 0L
    private var onVpnPermissionResult: ((granted: Boolean) -> Unit)? = null
    private var onNotificationPermissionResult: ((granted: Boolean, pendingReason: String?) -> Unit)? = null
    private var onRefreshNotificationPermission: (() -> Unit)? = null
    private var onRefreshVpnPermission: (() -> Unit)? = null
    private var onRefreshBatteryOptimization: (() -> Unit)? = null
    private var onLaunchIntent: ((Intent) -> Unit)? = null

    private fun resetTrafficSampling() {
        trafficSampler = TrafficSampler()
        trafficSessionKey = null
    }

    private val vpnPermission =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val granted =
                result.resultCode == Activity.RESULT_OK &&
                    VpnService.prepare(this) == null
            if (granted) {
                pendingVpnStartReason?.let { reason ->
                    resetTrafficSampling()
                    startingSinceMillis = System.currentTimeMillis()
                    startForegroundService(
                        VpnSessionCommands.buildStartIntent(
                            this,
                            prefsStore.load(),
                            reason,
                        ),
                    )
                }
            } else {
                startingSinceMillis = 0L
            }
            pendingVpnStartReason = null
            onVpnPermissionResult?.invoke(granted)
        }

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            val pending = pendingNotificationStartReason
            pendingNotificationStartReason = null
            onNotificationPermissionResult?.invoke(granted, pending)
        }

    private val openDocument =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri == null) return@registerForActivityResult
            // Reading (cloud providers can be slow or fail) happens on Dispatchers.IO
            // inside the compose scope; failures surface like clipboard import does.
            profileImportUriHandler?.invoke(uri)
        }

    private var profileImportUriHandler: ((Uri) -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingVpnStartReason = savedInstanceState?.getString(STATE_PENDING_VPN_START_REASON)
        pendingNotificationStartReason =
            savedInstanceState?.getString(STATE_PENDING_NOTIFICATION_START_REASON)
        startingSinceMillis = savedInstanceState?.getLong(STATE_STARTING_SINCE_MILLIS) ?: 0L
        prefsStore = SessionPrefsStore(this)
        runtimeStore = SessionRuntimeStore(this)
        lastImportedEventId = runtimeStore.clearedEventId()
        val initialPrefs = prefsStore.load()
        val initialRuntime = runtimeStore.load()
        trafficSessionKey = initialRuntime.sessionKey()
        val initial =
            SessionUiState.fromPrefs(initialPrefs).copy(
                notificationPermission =
                    currentNotificationPermissionState(
                        wasRequested = initialPrefs.notificationPermissionRequested,
                    ),
                vpnPermission = currentVpnPermissionState(),
                batteryOptimization = currentBatteryOptimizationState(),
                runtime = initialRuntime.toUiSnapshot(),
                connectionPhase =
                    ConnectionPhase.restore(
                        runtimePhase = initialRuntime.phase,
                        hasPendingStart =
                            pendingVpnStartReason != null ||
                                pendingNotificationStartReason != null ||
                                startingSinceMillis > 0L,
                    ),
            )

        setContent {
            var state by remember { mutableStateOf(initial) }
            var selectedSection by remember {
                mutableStateOf(AppSection.parse(initialPrefs.selectedSection))
            }
            val scope = rememberCoroutineScope()

            fun persist(
                next: SessionUiState,
                section: AppSection = selectedSection,
            ) {
                prefsStore.save(next.toPrefs().copy(selectedSection = section.wire))
            }

            fun update(transform: (SessionUiState) -> SessionUiState) {
                val next = transform(state)
                state = next
                persist(next)
            }

            fun selectSection(section: AppSection) {
                if (selectedSection == section) return
                selectedSection = section
                persist(state, section)
            }

            fun logOnly(transform: (SessionUiState) -> SessionUiState) {
                // Runtime / log updates that should not thrash session prefs writes.
                state = transform(state)
            }

            onVpnPermissionResult = { granted ->
                update {
                    val next = it.copy(vpnPermission = VpnPermissionState(granted))
                    if (granted) {
                        next.appendLog(
                            "已授予 VPN 权限",
                            LogLevel.Success,
                            LogSource.Network,
                        )
                    } else {
                        next.copy(connectionPhase = ConnectionPhase.STOPPED)
                            .appendLog(
                                "VPN 权限被拒绝",
                                LogLevel.Error,
                                LogSource.Network,
                                asNotice = true,
                            )
                    }
                }
            }

            onRefreshNotificationPermission = {
                logOnly {
                    it.copy(
                        notificationPermission =
                            currentNotificationPermissionState(
                                wasRequested = it.notificationPermission.wasRequested,
                            ),
                    )
                }
            }

            onRefreshVpnPermission = {
                logOnly {
                    it.copy(vpnPermission = currentVpnPermissionState())
                }
            }

            onRefreshBatteryOptimization = {
                logOnly {
                    it.copy(batteryOptimization = currentBatteryOptimizationState())
                }
            }

            fun refreshInstalledApps() {
                if (state.appRouting.isLoadingApps) return
                logOnly {
                    it.copy(appRouting = it.appRouting.copy(isLoadingApps = true))
                }
                scope.launch {
                    try {
                        val apps =
                            withContext(Dispatchers.IO) {
                                InstalledAppsRepository(this@MainActivity).load()
                            }
                        logOnly {
                            it.copy(
                                appRouting =
                                    it.appRouting
                                        .withInstalledApps(apps)
                                        .copy(isLoadingApps = false),
                            )
                        }
                    } catch (error: Exception) {
                        update {
                            it.copy(
                                appRouting = it.appRouting.copy(isLoadingApps = false),
                            ).appendLog(
                                "读取应用列表失败：${error.message}",
                                LogLevel.Warning,
                                LogSource.System,
                            )
                        }
                    }
                }
            }

            LaunchedEffect("installed-apps") {
                refreshInstalledApps()
            }

            fun importProfileFromUri(uri: Uri) {
                scope.launch {
                    val text =
                        try {
                            withContext(Dispatchers.IO) {
                                contentResolver.openInputStream(uri)
                                    ?.bufferedReader()
                                    ?.use { it.readText() }
                                    .orEmpty()
                            }
                        } catch (error: Exception) {
                            update {
                                it.appendLog(
                                    "读取配置文件失败：${error.message ?: "文件不可访问"}",
                                    LogLevel.Warning,
                                    LogSource.Proxy,
                                    asNotice = true,
                                )
                            }
                            return@launch
                        }
                    if (text.isBlank()) {
                        update {
                            it.appendLog(
                                "所选文件为空，未导入配置",
                                LogLevel.Warning,
                                LogSource.Proxy,
                                asNotice = true,
                            )
                        }
                        return@launch
                    }
                    update {
                        it.copy(profileDraft = text, configPreview = "")
                            .appendLog(
                                "已导入配置草稿（${text.length} 字符），校验后请应用",
                                LogLevel.Success,
                                LogSource.Proxy,
                            )
                    }
                }
            }

            profileImportUriHandler = ::importProfileFromUri

            LaunchedEffect(Unit) {
                while (true) {
                    // Publish phase/events before any controller I/O. Traffic sampling can
                    // stall on some OEM VPN stacks even with URLConnection timeouts, and must
                    // never freeze connectionPhase updates (UI stuck on 连接中 while runtime
                    // is already RUNNING).
                    var runtimeStatus = runtimeStore.load()
                    val sampleKey = runtimeStatus.sessionKey()
                    if (sampleKey != trafficSessionKey) {
                        resetTrafficSampling()
                        trafficSessionKey = sampleKey
                    }

                    // Merge VPN service events into UI logs (newest first, skip known).
                    val imported = mutableListOf<Triple<Long, String, LogLevel>>()
                    try {
                        val arr = JSONArray(runtimeStatus.eventsJson)
                        for (i in 0 until arr.length()) {
                            val o = arr.getJSONObject(i)
                            val id = o.optLong("id", 0L)
                            if (id <= lastImportedEventId) continue
                            val level =
                                when (o.optString("level")) {
                                    "error" -> LogLevel.Error
                                    "success" -> LogLevel.Success
                                    "warning" -> LogLevel.Warning
                                    else -> LogLevel.Info
                                }
                            imported += Triple(id, o.optString("message"), level)
                        }
                        if (imported.isNotEmpty()) {
                            lastImportedEventId = imported.maxOf { it.first }
                        }
                    } catch (_: Exception) {
                    }

                    var stopStuckStartup = false
                    val running = runtimeStatus.running
                    logOnly { current ->
                        var phase =
                            ConnectionPhase.reconcile(
                                current.connectionPhase,
                                runtimeStatus.phase,
                            )
                        // STARTING without RUNNING for too long → failed start.
                        // Includes runtime stuck in STARTING (not only never-started STOPPED).
                        val now = System.currentTimeMillis()
                        if (
                            ConnectionPhase.shouldApplyStartTimeout(
                                uiPhase = phase,
                                runtimePhase = runtimeStatus.phase,
                                runtimeRunning = running,
                                startingSinceMillis = startingSinceMillis,
                                nowMillis = now,
                                timeoutMs = START_TIMEOUT_MS,
                            )
                        ) {
                            if (runtimeStatus.phase == ConnectionPhase.STARTING) {
                                stopStuckStartup = true
                            }
                            phase =
                                ConnectionPhase.afterStartTimeout(
                                    current.connectionPhase,
                                    runtimePhase = runtimeStatus.phase,
                                )
                            startingSinceMillis = 0L
                        }
                        if (phase == ConnectionPhase.RUNNING || phase == ConnectionPhase.STOPPED) {
                            startingSinceMillis = 0L
                        }

                        val currentExitRoute = ExitIPRoutePolicy.routeForRuntime(running)
                        val exitIP =
                            if (current.exitIP.info?.route != null &&
                                current.exitIP.info.route != currentExitRoute
                            ) {
                                current.exitIP.copy(info = null, errorMessage = null)
                            } else {
                                current.exitIP
                            }
                        var next =
                            current.copy(
                                runtime = runtimeStatus.toUiSnapshot(current.runtime.traffic),
                                connectionPhase = phase,
                                exitIP = exitIP,
                            )
                        if (
                            current.connectionPhase == ConnectionPhase.STARTING &&
                                phase == ConnectionPhase.STOPPED &&
                                !running
                        ) {
                            next =
                                next.appendLog(
                                    "启动超时或失败，请查看日志",
                                    LogLevel.Error,
                                    LogSource.Session,
                                    asNotice = true,
                                )
                        }
                        // Import oldest-first so list stays newest-first after prepend.
                        imported.sortedBy { it.first }.forEach { (_, message, level) ->
                            next =
                                next.appendLog(
                                    message,
                                    level,
                                    LogSource.System,
                                )
                        }
                        next
                    }
                    if (stopStuckStartup) {
                        // Tear down a VPN worker that published STARTING but never RUNNING.
                        startService(
                            Intent(this@MainActivity, ViaSixVpnService::class.java)
                                .setAction(ViaSixVpnService.ACTION_STOP),
                        )
                    }

                    if (sampleKey != null) {
                        val sampler = trafficSampler
                        val port = runtimeStatus.controllerPort
                        val secret = runtimeStatus.secret
                        val sampled =
                            try {
                                withContext(Dispatchers.IO) {
                                    kotlinx.coroutines.withTimeout(6_000L) {
                                        sampler.sample(
                                            host = "127.0.0.1",
                                            port = port,
                                            secret = secret,
                                        )
                                    }
                                }
                            } catch (_: Exception) {
                                TrafficSnapshot.Idle
                            }
                        val latestRuntime = runtimeStore.load()
                        val latestKey = latestRuntime.sessionKey()
                        if (latestKey == sampleKey && trafficSampler === sampler) {
                            logOnly { current ->
                                current.copy(
                                    runtime = latestRuntime.toUiSnapshot(sampled),
                                    connectionPhase =
                                        ConnectionPhase.reconcile(
                                            current.connectionPhase,
                                            latestRuntime.phase,
                                        ),
                                )
                            }
                        } else if (trafficSampler === sampler) {
                            resetTrafficSampling()
                            trafficSessionKey = latestKey
                        }
                    }

                    kotlinx.coroutines.delay(1200)
                }
            }

            fun continueStartVpn(reason: String) {
                val prepare = VpnService.prepare(this@MainActivity)
                if (prepare != null) {
                    pendingVpnStartReason = reason
                    vpnPermission.launch(prepare)
                    update {
                        it.copy(connectionPhase = ConnectionPhase.STARTING)
                            .appendLog("请求 VPN 权限…", LogLevel.Info, LogSource.Network)
                    }
                    // Start timeout begins only after consent, not while the system dialog is open.
                    startingSinceMillis = 0L
                } else {
                    resetTrafficSampling()
                    startingSinceMillis = System.currentTimeMillis()
                    startForegroundService(
                        VpnSessionCommands.buildStartIntent(
                            this@MainActivity,
                            state.toPrefs().copy(selectedSection = selectedSection.wire),
                            reason,
                        ),
                    )
                    update {
                        it.copy(connectionPhase = ConnectionPhase.STARTING)
                            .appendLog("正在启动 VPN + mihomo…", LogLevel.Info, LogSource.Session)
                    }
                }
            }

            onNotificationPermissionResult = { granted, pendingReason ->
                val permissionState =
                    currentNotificationPermissionState(wasRequested = true)
                        .copy(granted = granted)
                update {
                    it.copy(notificationPermission = permissionState)
                        .appendLog(
                            if (granted) {
                                "已允许会话通知"
                            } else {
                                "未允许会话通知；VPN 可继续运行，但实时速率和通知断开按钮可能不可见"
                            },
                            if (granted) LogLevel.Success else LogLevel.Warning,
                            LogSource.System,
                            asNotice = !granted,
                            noticeActionOpenSettings = !granted,
                        )
                }
                pendingReason?.let(::continueStartVpn)
            }

            fun startVpn(reason: String = "connect") {
                if (state.runtimeComponents.repairing == RuntimeComponentId.MIHOMO) {
                    update {
                        it.appendLog(
                            "mihomo 正在修复，完成后再启动 VPN",
                            LogLevel.Warning,
                            LogSource.System,
                            asNotice = true,
                        )
                    }
                    return
                }
                // Avoid double-start from tile + home; allow apply-node restart while running.
                when (state.connectionPhase) {
                    ConnectionPhase.STARTING -> return
                    ConnectionPhase.STOPPING -> return
                    ConnectionPhase.RUNNING ->
                        if (reason == "connect" || reason == "quick-settings") return
                    ConnectionPhase.STOPPED -> Unit
                }

                when (
                    val gate =
                        SessionStartGate.evaluate(
                            routingMode = state.routingMode,
                            selectedAddress = state.selectedAddress,
                            summary = state.profileSummary,
                            appRoutingMode = state.appRouting.mode,
                            selectedAppPackages = state.appRouting.selectedPackages,
                            dnsServer = state.dnsSettings.server,
                            fullTunnel = state.fullTunnel,
                            vpnMtu = state.vpnMtu,
                            ipv6RoutingMode = state.ipv6RoutingMode,
                        )
                ) {
                    is SessionStartGate.Result.Blocked -> {
                        update {
                            it.appendLog(
                                gate.message,
                                LogLevel.Error,
                                when (gate.sectionWire) {
                                    "profiles" -> LogSource.Proxy
                                    "nodes" -> LogSource.Node
                                    else -> LogSource.System
                                },
                                asNotice = true,
                            )
                        }
                        selectSection(AppSection.parse(gate.sectionWire))
                        return
                    }
                    SessionStartGate.Result.Ok -> Unit
                }

                when (NotificationPermissionFlow.beforeStart(state.notificationPermission)) {
                    NotificationPermissionFlow.BeforeStart.REQUEST_PERMISSION -> {
                        pendingNotificationStartReason = reason
                        notificationPermission.launch(POST_NOTIFICATIONS_PERMISSION)
                        update {
                            it.copy(connectionPhase = ConnectionPhase.STARTING)
                                .appendLog(
                                    "请求通知权限，以显示实时速率和断开控制…",
                                    LogLevel.Info,
                                    LogSource.System,
                                )
                        }
                        return
                    }
                    NotificationPermissionFlow.BeforeStart.CONTINUE -> Unit
                }

                if (state.notificationPermission.required &&
                    !state.notificationPermission.granted
                ) {
                    update {
                        it.appendLog(
                            "会话通知已关闭；VPN 将继续启动，可在设置中开启",
                            LogLevel.Warning,
                            LogSource.System,
                        )
                    }
                }
                continueStartVpn(reason)
            }

            fun importClipboardProfile() {
                val cm = getSystemService(ClipboardManager::class.java)
                val raw =
                    runCatching {
                        cm.primaryClip?.getItemAt(0)?.coerceToText(this@MainActivity)?.toString()
                    }.getOrNull()
                val yaml = ProfileImportText.extractYaml(raw)
                if (yaml == null) {
                    update {
                        it.appendLog(
                            if (ProfileImportText.looksLikeBareUrl(raw.orEmpty())) {
                                "剪贴板是订阅 URL，请先下载 YAML 再导入（暂不支持在线拉取）"
                            } else {
                                "剪贴板不是有效的 mihomo/Clash YAML 配置"
                            },
                            LogLevel.Warning,
                            LogSource.Proxy,
                            asNotice = true,
                        )
                    }
                    return
                }
                update {
                    it.copy(profileDraft = yaml, configPreview = "")
                        .appendLog(
                            "已从剪贴板导入配置草稿（${yaml.length} 字符），校验后请应用",
                            LogLevel.Success,
                            LogSource.Proxy,
                            asNotice = true,
                        )
                }
            }

            fun handleLaunchIntent(launchIntent: Intent) {
                val requestStart =
                    launchIntent.getBooleanExtra(VpnSessionCommands.EXTRA_REQUEST_START, false)
                val requestedSection = launchIntent.getStringExtra(EXTRA_OPEN_SECTION)
                val gateMessage =
                    launchIntent.getStringExtra(ViaSixTileService.EXTRA_GATE_MESSAGE)
                val gateSection =
                    launchIntent.getStringExtra(ViaSixTileService.EXTRA_GATE_SECTION)
                launchIntent.removeExtra(VpnSessionCommands.EXTRA_REQUEST_START)
                launchIntent.removeExtra(EXTRA_OPEN_SECTION)
                launchIntent.removeExtra(ViaSixTileService.EXTRA_GATE_MESSAGE)
                launchIntent.removeExtra(ViaSixTileService.EXTRA_GATE_SECTION)

                requestedSection?.let { selectSection(AppSection.parse(it)) }
                if (!gateMessage.isNullOrBlank()) {
                    update {
                        it.appendLog(gateMessage, LogLevel.Error, LogSource.Session, asNotice = true)
                    }
                    val target =
                        when (gateSection) {
                            "profiles" -> AppSection.PROFILES
                            "nodes" -> AppSection.NODES
                            else -> null
                        }
                    target?.let(::selectSection)
                }
                if (requestStart) {
                    startVpn(reason = "quick-settings")
                }
            }

            onLaunchIntent = ::handleLaunchIntent

            // Quick Settings tile / cold start: honor request-to-start extras once.
            LaunchedEffect(Unit) {
                intent?.let(::handleLaunchIntent)
            }

            fun stopVpn() {
                if (state.connectionPhase == ConnectionPhase.STOPPED ||
                    state.connectionPhase == ConnectionPhase.STOPPING
                ) {
                    return
                }
                startService(
                    Intent(this@MainActivity, ViaSixVpnService::class.java)
                        .setAction(ViaSixVpnService.ACTION_STOP),
                )
                resetTrafficSampling()
                startingSinceMillis = 0L
                update {
                    it.copy(connectionPhase = ConnectionPhase.STOPPING)
                        .appendLog("已发送停止意图", LogLevel.Info, LogSource.Session)
                }
            }

            fun projectPreview() {
                try {
                    val previewMode =
                        if (state.routingMode == RoutingMode.DIRECT) {
                            RoutingMode.RULE
                        } else {
                            state.routingMode
                        }
                    val preview =
                        MihomoProjection.projectYaml(
                            state.profileDraft,
                            ProjectOptions(
                                routingMode = previewMode,
                                selectedAddress =
                                    Ipv6Address.normalize(state.selectedAddress)
                                        ?: PROFILE_VALIDATION_IPV6,
                            ),
                        )
                    update {
                        it.copy(configPreview = preview)
                            .appendLog("投影成功", LogLevel.Success, LogSource.Proxy)
                    }
                } catch (error: ProjectError) {
                    update {
                        it.copy(configPreview = error.contractCode)
                            .appendLog(
                                "投影失败：${error.contractCode}",
                                LogLevel.Error,
                                LogSource.Proxy,
                            )
                    }
                } catch (error: Exception) {
                    update {
                        it.copy(configPreview = error.message ?: "error")
                            .appendLog(
                                "投影失败：${error.message}",
                                LogLevel.Error,
                                LogSource.Proxy,
                            )
                    }
                }
            }

            fun applyProfileDraft(reconnect: Boolean) {
                val draft = state.profileDraft.trim()
                when (val gate = ProfileDraftGate.evaluate(draft)) {
                    is ProfileDraftGate.Result.Blocked -> {
                        update {
                            it.appendLog(
                                "配置草稿无法应用：${gate.message}",
                                LogLevel.Error,
                                LogSource.Proxy,
                                asNotice = true,
                            )
                        }
                        return
                    }
                    ProfileDraftGate.Result.Ok -> Unit
                }

                try {
                    // Validate projection independently from the currently selected node.
                    MihomoProjection.projectYaml(
                        draft,
                        ProjectOptions(
                            routingMode = RoutingMode.RULE,
                            selectedAddress = PROFILE_VALIDATION_IPV6,
                        ),
                    )
                } catch (error: ProjectError) {
                    update {
                        it.appendLog(
                            "配置草稿无法应用：${error.contractCode}",
                            LogLevel.Error,
                            LogSource.Proxy,
                            asNotice = true,
                        )
                    }
                    return
                } catch (error: Exception) {
                    update {
                        it.appendLog(
                            "配置草稿无法应用：${error.message ?: "unknown error"}",
                            LogLevel.Error,
                            LogSource.Proxy,
                            asNotice = true,
                        )
                    }
                    return
                }

                val wasRunning = state.runtime.running
                update {
                    it.copy(
                        profileYaml = draft,
                        profileDraft = draft,
                        configPreview = "",
                    ).appendLog(
                        when {
                            reconnect && wasRunning -> "配置已应用，正在重新连接"
                            wasRunning -> "配置已保存，当前会话保持不变"
                            else -> "配置已应用，下次连接将使用新配置"
                        },
                        LogLevel.Success,
                        LogSource.Proxy,
                        asNotice = true,
                    )
                }
                if (reconnect && wasRunning) {
                    startVpn(reason = "apply-profile")
                }
            }

            fun applyNode(address: String, reconnect: Boolean) {
                val wasRunning = state.runtime.running
                val normalized = Ipv6Address.normalize(address)
                if (normalized == null || !Ipv6Address.isValid(normalized)) {
                    update {
                        it.appendLog(
                            "无效 IPv6：$address",
                            LogLevel.Error,
                            LogSource.Node,
                        )
                    }
                    return
                }
                update {
                    it.rememberCandidate(normalized)
                        .appendLog("已选择节点 $normalized", LogLevel.Success, LogSource.Node)
                }
                if (reconnect && wasRunning) {
                    startVpn(reason = "apply-node")
                }
            }

            fun applySpeedProgress(current: Int, total: Int, phaseHint: String?) {
                if (total <= 0) return
                val progress =
                    dev.viasix.core.speedtest.CfstOutputParser.Progress(current, total)
                logOnly { currentState ->
                    if (!currentState.speedTest.isRunning) {
                        currentState
                    } else {
                        currentState.copy(
                            speedTest =
                                currentState.speedTest.copy(
                                    progressCurrent = current,
                                    progressTotal = total,
                                    message = progress.statusMessage(phaseHint),
                                ),
                        )
                    }
                }
            }

            fun applySpeedOutcome(result: CfstRunOutcome, installOk: Boolean, nodeTest: Boolean) {
                val componentInfo =
                    RuntimeComponentInfo(
                        condition =
                            if (installOk) {
                                RuntimeComponentCondition.READY
                            } else {
                                RuntimeComponentCondition.ERROR
                            },
                        detail =
                            if (installOk) {
                                "APK 原生目录内 AArch64 ELF 已通过启动检查"
                            } else {
                                (result as? CfstRunOutcome.Failed)?.message ?: "CFST 安装失败"
                            },
                    )
                when (result) {
                    is CfstRunOutcome.Success -> {
                        update {
                            it.copy(
                                runtimeComponents =
                                    it.runtimeComponents.withInfo(
                                        RuntimeComponentId.CFST,
                                        componentInfo,
                                    ),
                                speedTest =
                                    it.speedTest.copy(
                                        isRunning = false,
                                        isNodeTest = false,
                                        progressCurrent = 0,
                                        progressTotal = 0,
                                        message =
                                            if (nodeTest) {
                                                "当前节点测速完成：${result.results.size} 个结果"
                                            } else {
                                                result.message
                                            },
                                        results = result.results,
                                        binaryReady = true,
                                    ),
                            ).appendLog(
                                if (nodeTest) {
                                    "当前节点测速完成：${result.results.size} 个结果"
                                } else {
                                    result.message
                                },
                                LogLevel.Success,
                                LogSource.Node,
                            )
                        }
                    }
                    is CfstRunOutcome.Cancelled -> {
                        update {
                            it.copy(
                                runtimeComponents =
                                    it.runtimeComponents.withInfo(
                                        RuntimeComponentId.CFST,
                                        componentInfo,
                                    ),
                                speedTest =
                                    it.speedTest.copy(
                                        isRunning = false,
                                        isNodeTest = false,
                                        progressCurrent = 0,
                                        progressTotal = 0,
                                        message = "测速已取消",
                                        binaryReady = installOk,
                                    ),
                            ).appendLog("测速已取消", LogLevel.Warning, LogSource.Node)
                        }
                    }
                    is CfstRunOutcome.Failed -> {
                        update {
                            it.copy(
                                runtimeComponents =
                                    it.runtimeComponents.withInfo(
                                        RuntimeComponentId.CFST,
                                        componentInfo,
                                    ),
                                speedTest =
                                    it.speedTest.copy(
                                        isRunning = false,
                                        isNodeTest = false,
                                        progressCurrent = 0,
                                        progressTotal = 0,
                                        message = result.message,
                                        binaryReady = installOk,
                                    ),
                            ).appendLog(
                                "测速失败：${result.message}",
                                LogLevel.Error,
                                LogSource.Node,
                            )
                        }
                    }
                }
            }

            fun startSpeedTest() {
                if (state.speedTest.isRunning || cfstRunner.isRunning) {
                    update {
                        it.appendLog("测速已在进行中", LogLevel.Warning, LogSource.Node)
                    }
                    return
                }
                if (state.runtimeComponents.repairing == RuntimeComponentId.CFST) {
                    update {
                        it.appendLog(
                            "CFST 正在修复，完成后再开始测速",
                            LogLevel.Warning,
                            LogSource.System,
                            asNotice = true,
                        )
                    }
                    return
                }
                state.speedTest.parameterValidationMessage?.let { msg ->
                    update {
                        it.appendLog(msg, LogLevel.Error, LogSource.Node)
                    }
                    return
                }
                val mode = state.speedTest.ipSourceMode
                val baseParams = state.speedTest.parameters
                val customFile = state.speedTest.customIpFilePath
                update {
                    it.copy(
                        speedTest =
                            it.speedTest.copy(
                                isRunning = true,
                                isNodeTest = false,
                                progressCurrent = 0,
                                progressTotal = 0,
                                message = "正在测速…",
                            ),
                    ).appendLog("开始 IPv6 优选测速", LogLevel.Info, LogSource.Node)
                }
                scope.launch {
                    val outcome =
                        withContext(Dispatchers.IO) {
                            try {
                                val install = CfstInstaller.installIfNeeded(this@MainActivity)
                                val parameters =
                                    baseParams.resolveForRun(
                                        mode = mode,
                                        bundledIpv6ListPath = install.ipv6List.absolutePath,
                                        customIpFilePath = customFile,
                                    )
                                val work = CfstInstaller.workDir(this@MainActivity)
                                cfstRunner.run(
                                    install.binary,
                                    work,
                                    parameters,
                                    onProgress = { current, total, phase ->
                                        scope.launch(Dispatchers.Main.immediate) {
                                            applySpeedProgress(current, total, phase)
                                        }
                                    },
                                    sslContext = this@MainActivity,
                                ) to true
                            } catch (error: Exception) {
                                CfstRunOutcome.Failed(error.message ?: "CFST 安装失败") to false
                            }
                        }
                    applySpeedOutcome(outcome.first, outcome.second, nodeTest = false)
                }
            }

            fun startCurrentNodeTest() {
                if (state.speedTest.isRunning || cfstRunner.isRunning) {
                    update {
                        it.appendLog("测速已在进行中", LogLevel.Warning, LogSource.Node)
                    }
                    return
                }
                if (state.runtimeComponents.repairing == RuntimeComponentId.CFST) {
                    update {
                        it.appendLog(
                            "CFST 正在修复，完成后再测试当前节点",
                            LogLevel.Warning,
                            LogSource.System,
                            asNotice = true,
                        )
                    }
                    return
                }
                val normalized = Ipv6Address.normalize(state.selectedAddress)
                if (normalized == null || !Ipv6Address.isValid(normalized)) {
                    update {
                        it.appendLog(
                            "当前节点测速需要合法 IPv6",
                            LogLevel.Error,
                            LogSource.Node,
                        )
                    }
                    return
                }
                val parameters =
                    try {
                        state.speedTest.parameters.forCurrentNodeConfigurationTest(normalized)
                    } catch (error: Exception) {
                        update {
                            it.appendLog(
                                "当前节点测速参数无效：${error.message}",
                                LogLevel.Error,
                                LogSource.Node,
                            )
                        }
                        return
                    }
                update {
                    it.copy(
                        speedTest =
                            it.speedTest.copy(
                                isRunning = true,
                                isNodeTest = true,
                                progressCurrent = 0,
                                progressTotal = 0,
                                message = "正在对当前节点测速 $normalized…",
                            ),
                    ).appendLog(
                        "当前节点测速：$normalized",
                        LogLevel.Info,
                        LogSource.Node,
                    )
                }
                scope.launch {
                    val outcome =
                        withContext(Dispatchers.IO) {
                            try {
                                val install = CfstInstaller.installIfNeeded(this@MainActivity)
                                val work = CfstInstaller.workDir(this@MainActivity)
                                cfstRunner.run(
                                    install.binary,
                                    work,
                                    parameters,
                                    onProgress = { current, total, phase ->
                                        scope.launch(Dispatchers.Main.immediate) {
                                            applySpeedProgress(current, total, phase)
                                        }
                                    },
                                    sslContext = this@MainActivity,
                                ) to true
                            } catch (error: Exception) {
                                CfstRunOutcome.Failed(error.message ?: "CFST 安装失败") to false
                            }
                        }
                    applySpeedOutcome(outcome.first, outcome.second, nodeTest = true)
                }
            }

            fun stopSpeedTest() {
                val cancelled = cfstRunner.requestCancel()
                if (cancelled) {
                    logOnly {
                        it.copy(
                            speedTest =
                                it.speedTest.copy(message = "正在停止测速…"),
                        ).appendLog("正在停止测速…", LogLevel.Info, LogSource.Node)
                    }
                }
            }

            fun inspectRuntimeComponents(announce: Boolean = true) {
                if (state.runtimeComponents.busy) return
                logOnly {
                    it.copy(
                        runtimeComponents = it.runtimeComponents.copy(isInspecting = true),
                    )
                }
                scope.launch {
                    val (mihomoInfo, cfstInfo) =
                        withContext(Dispatchers.IO) {
                            MihomoInstaller.inspectInstalled(this@MainActivity) to
                                CfstInstaller.inspectInstalled(this@MainActivity)
                        }
                    logOnly { current ->
                        var next =
                            current.copy(
                                runtimeComponents =
                                    current.runtimeComponents.copy(
                                        mihomo = mihomoInfo,
                                        cfst = cfstInfo,
                                        isInspecting = false,
                                    ),
                                speedTest =
                                    current.speedTest.copy(
                                        binaryReady = cfstInfo.ready,
                                        message = cfstInfo.detail,
                                    ),
                            )
                        if (announce) {
                            next =
                                next.appendLog(
                                    "组件检查完成：mihomo ${mihomoInfo.condition.label}，" +
                                        "CFST ${cfstInfo.condition.label}",
                                    if (mihomoInfo.ready && cfstInfo.ready) {
                                        LogLevel.Success
                                    } else {
                                        LogLevel.Warning
                                    },
                                    LogSource.System,
                                )
                        }
                        next
                    }
                }
            }

            fun repairRuntimeComponent(component: RuntimeComponentId) {
                if (state.runtimeComponents.busy) return
                val blocked =
                    when (component) {
                        RuntimeComponentId.MIHOMO ->
                            state.connectionPhase.isActiveOrTransitioning
                        RuntimeComponentId.CFST -> state.speedTest.isRunning
                    }
                if (blocked) {
                    update {
                        it.appendLog(
                            when (component) {
                                RuntimeComponentId.MIHOMO -> "VPN 会话运行时不能替换 mihomo，请先断开"
                                RuntimeComponentId.CFST -> "测速运行时不能准备 CFST，请先停止测速"
                            },
                            LogLevel.Warning,
                            LogSource.System,
                            asNotice = true,
                        )
                    }
                    return
                }

                logOnly {
                    it.copy(
                        runtimeComponents =
                            it.runtimeComponents.copy(repairing = component),
                    )
                }
                scope.launch {
                    val info =
                        withContext(Dispatchers.IO) {
                            when (component) {
                                RuntimeComponentId.MIHOMO ->
                                    MihomoInstaller.repair(this@MainActivity)
                                RuntimeComponentId.CFST -> CfstInstaller.repair(this@MainActivity)
                            }
                        }
                    logOnly { current ->
                        val components =
                            current.runtimeComponents
                                .withInfo(component, info)
                                .copy(repairing = null)
                        val next =
                            current.copy(
                                runtimeComponents = components,
                                speedTest =
                                    if (component == RuntimeComponentId.CFST) {
                                        current.speedTest.copy(
                                            binaryReady = info.ready,
                                            message = info.detail,
                                        )
                                    } else {
                                        current.speedTest
                                    },
                            )
                        next.appendLog(
                            "${component.label}：${info.detail}",
                            if (info.ready) LogLevel.Success else LogLevel.Error,
                            LogSource.System,
                            asNotice = !info.ready,
                        )
                    }
                }
            }

            LaunchedEffect(Unit) {
                inspectRuntimeComponents(announce = false)
            }

            fun detectExitIp() {
                val detectionMode = state.exitIP.mode
                val detectionEndpoint = state.exitIP.endpoint
                val detectionSessionKey = runtimeStore.load().sessionKey()
                val proxy =
                    ExitIPRoutePolicy.proxyForRuntime(
                        running = state.runtime.running,
                        mixedPort = state.runtime.mixedPort,
                    )
                val route = ExitIPRoutePolicy.routeFor(proxy)
                val detectionServiceEndpoint =
                    ExitIPDetector.endpointFor(detectionMode, detectionEndpoint)
                fun requestIsCurrent(current: SessionUiState): Boolean {
                    val currentEndpoint =
                        ExitIPDetector.endpointFor(
                            current.exitIP.mode,
                            current.exitIP.endpoint,
                        )
                    return current.exitIP.mode == detectionMode &&
                        currentEndpoint == detectionServiceEndpoint &&
                        runtimeStore.load().sessionKey() == detectionSessionKey &&
                        ExitIPRoutePolicy.routeForRuntime(current.runtime.running) == route
                }
                update {
                    it.copy(exitIP = it.exitIP.copy(isDetecting = true, errorMessage = null))
                        .appendLog(
                            "正在通过${route.label}检测公网出口…",
                            LogLevel.Info,
                            LogSource.Network,
                        )
                }
                scope.launch {
                    val result =
                        withContext(Dispatchers.IO) {
                            ExitIPDetector.detect(
                                mode = detectionMode,
                                automaticEndpoint = detectionEndpoint,
                                proxy = proxy,
                            )
                        }
                    result.fold(
                        onSuccess = { info ->
                            update {
                                if (!requestIsCurrent(it)) {
                                    it.copy(exitIP = it.exitIP.copy(isDetecting = false))
                                        .appendLog(
                                            "出口检测条件已变化，已忽略旧结果",
                                            LogLevel.Warning,
                                            LogSource.Network,
                                        )
                                } else {
                                    it.copy(
                                        exitIP =
                                            it.exitIP.copy(
                                                isDetecting = false,
                                                info = info,
                                                errorMessage = null,
                                            ),
                                    ).appendLog(
                                        "出口 ${info.ip}" +
                                            " · ${info.route.label}" +
                                            (if (info.location.isNotBlank()) " · ${info.location}" else ""),
                                        LogLevel.Success,
                                        LogSource.Network,
                                    )
                                }
                            }
                        },
                        onFailure = { error ->
                            update {
                                if (!requestIsCurrent(it)) {
                                    it.copy(exitIP = it.exitIP.copy(isDetecting = false))
                                        .appendLog(
                                            "出口检测条件已变化，已忽略旧错误",
                                            LogLevel.Warning,
                                            LogSource.Network,
                                        )
                                } else {
                                    it.copy(
                                        exitIP =
                                            it.exitIP.copy(
                                                isDetecting = false,
                                                errorMessage = error.message,
                                            ),
                                    ).appendLog(
                                        "出口检测失败：${error.message}",
                                        LogLevel.Error,
                                        LogSource.Network,
                                    )
                                }
                            }
                        },
                    )
                }
            }

            fun runDelayTest() {
                if (!state.runtime.running) {
                    update {
                        it.appendLog("延迟测试需要先连接", LogLevel.Warning, LogSource.Proxy)
                    }
                    return
                }
                val name = state.profileSummary.primary?.name
                if (name.isNullOrBlank()) {
                    update {
                        it.appendLog("无法测试：缺少代理名称", LogLevel.Error, LogSource.Proxy)
                    }
                    return
                }
                val runtime = runtimeStore.load()
                val delaySessionKey = runtime.sessionKey()
                if (delaySessionKey == null) {
                    update {
                        it.appendLog(
                            "延迟测试会话已变化，请等待连接稳定后重试",
                            LogLevel.Warning,
                            LogSource.Proxy,
                        )
                    }
                    return
                }
                update {
                    it.copy(delayTest = DelayTestState(isRunning = true))
                        .appendLog("测试代理延迟：$name", LogLevel.Info, LogSource.Proxy)
                }
                scope.launch {
                    val result =
                        withContext(Dispatchers.IO) {
                            ControllerClient.proxyDelay(
                                host = "127.0.0.1",
                                port = runtime.controllerPort,
                                secret = runtime.secret,
                                proxyName = name,
                            )
                        }
                    update {
                        if (
                            runtimeStore.load().sessionKey() != delaySessionKey ||
                            it.profileSummary.primary?.name != name
                        ) {
                            it.copy(delayTest = it.delayTest.copy(isRunning = false))
                                .appendLog(
                                    "延迟测试会话或节点已变化，已忽略旧结果",
                                    LogLevel.Warning,
                                    LogSource.Proxy,
                                )
                        } else {
                            it.copy(delayTest = DelayTestState(isRunning = false, last = result))
                                .appendLog(
                                    if (result.ok) {
                                        "延迟 $name：${result.message}"
                                    } else {
                                        "延迟测试失败：$name · ${result.message}"
                                    },
                                    if (result.ok) LogLevel.Success else LogLevel.Error,
                                    LogSource.Proxy,
                                )
                        }
                    }
                }
            }

            fun patchRoutingMode(mode: RoutingMode) {
                if (
                    state.routingMode == mode ||
                    state.routingModeSyncing ||
                    state.connectionPhase.isBusy
                ) {
                    return
                }
                val phase = state.connectionPhase
                val runtime = runtimeStore.load()
                val routingSessionKey = runtime.sessionKey()
                val shouldPatch = phase == ConnectionPhase.RUNNING && routingSessionKey != null
                update { current ->
                    val next =
                        current.copy(
                            routingMode = mode,
                            routingModeSyncing = shouldPatch,
                        )
                    when {
                        shouldPatch ->
                            next.appendLog(
                                "正在同步运行中模式 → ${mode.wire}",
                                LogLevel.Info,
                                LogSource.Proxy,
                            )
                        phase == ConnectionPhase.RUNNING ->
                            next.appendLog(
                                "会话正在变化，${mode.wire} 模式已保存，下次连接生效",
                                LogLevel.Warning,
                                LogSource.Proxy,
                            )
                        else -> next
                    }
                }
                if (phase != ConnectionPhase.RUNNING || routingSessionKey == null) return

                scope.launch {
                    val ok =
                        withContext(Dispatchers.IO) {
                            ControllerClient.patchMode(
                                host = "127.0.0.1",
                                port = routingSessionKey.controllerPort,
                                secret = routingSessionKey.secret,
                                mode = mode.wire,
                            )
                        }
                    val sessionStillCurrent =
                        runtimeStore.load().sessionKey() == routingSessionKey
                    logOnly { current ->
                        val next = current.copy(routingModeSyncing = false)
                        when {
                            current.routingMode != mode ->
                                next.appendLog(
                                    "代理模式选择已变化，已忽略旧切换结果",
                                    LogLevel.Warning,
                                    LogSource.Proxy,
                                )
                            !sessionStillCurrent ->
                                next.appendLog(
                                    "会话已变化，${mode.wire} 模式已保存，下次连接生效",
                                    LogLevel.Warning,
                                    LogSource.Proxy,
                                )
                            ok ->
                                next.appendLog(
                                    "已切换运行中模式 → ${mode.wire}",
                                    LogLevel.Success,
                                    LogSource.Proxy,
                                )
                            else ->
                                next.appendLog(
                                    "运行中模式切换失败，下次连接生效：${mode.wire}",
                                    LogLevel.Warning,
                                    LogSource.Proxy,
                                )
                        }
                    }
                }
            }

            fun copyText(label: String, value: String) {
                val cm = getSystemService(ClipboardManager::class.java)
                cm.setPrimaryClip(ClipData.newPlainText(label, value))
                update {
                    it.appendLog("已复制 $label", LogLevel.Info, LogSource.Session)
                }
            }

            fun manageNotificationPermission() {
                val permission = state.notificationPermission
                if (!permission.required || permission.granted) return

                if (permission.canRequestInApp) {
                    pendingNotificationStartReason = null
                    notificationPermission.launch(POST_NOTIFICATIONS_PERMISSION)
                } else {
                    openAppNotificationSettings()
                }
            }

            fun manageVpnPermission() {
                val prepare = VpnService.prepare(this@MainActivity)
                if (prepare != null) {
                    pendingVpnStartReason = null
                    vpnPermission.launch(prepare)
                    update {
                        it.appendLog(
                            "请求 VPN 权限…",
                            LogLevel.Info,
                            LogSource.Network,
                        )
                    }
                } else {
                    openSystemVpnSettings()
                }
            }

            fun manageBatteryOptimization() {
                openBatteryOptimizationSettings()
            }

            fun changeAppRoutingMode(mode: AppRoutingMode) {
                if (state.connectionPhase.isActiveOrTransitioning) {
                    update {
                        it.appendLog(
                            "运行中无法切换分应用路由，请先断开 VPN",
                            LogLevel.Warning,
                            LogSource.Network,
                            asNotice = true,
                        )
                    }
                } else {
                    update { it.copy(appRouting = it.appRouting.copy(mode = mode)) }
                }
            }

            fun toggleAppRoutingPackage(packageName: String) {
                if (state.connectionPhase.isActiveOrTransitioning) return
                val normalized = packageName.trim()
                if (
                    !AppRoutingPolicy.isValidPackageName(normalized) ||
                        normalized == this@MainActivity.packageName
                ) {
                    update {
                        it.appendLog(
                            "无法添加应用包名：$normalized",
                            LogLevel.Warning,
                            LogSource.System,
                            asNotice = true,
                        )
                    }
                    return
                }
                update {
                    it.copy(appRouting = it.appRouting.togglePackage(normalized))
                }
            }

            fun clearSelectedAppPackages() {
                if (state.connectionPhase.isActiveOrTransitioning) return
                update {
                    it.copy(appRouting = it.appRouting.copy(selectedPackages = emptyList()))
                }
            }

            fun changeDnsRoutingMode(mode: DnsRoutingMode) {
                if (state.connectionPhase.isActiveOrTransitioning) return
                update { it.copy(dnsSettings = it.dnsSettings.copy(mode = mode)) }
            }

            fun changeDnsServer(server: String) {
                if (state.connectionPhase.isActiveOrTransitioning) return
                update { it.copy(dnsSettings = it.dnsSettings.copy(server = server)) }
            }

            fun changeVpnMtu(mtu: String) {
                if (state.connectionPhase.isActiveOrTransitioning) return
                update { it.copy(vpnMtu = mtu) }
            }

            fun changeVpnMetered(metered: Boolean) {
                if (state.connectionPhase.isActiveOrTransitioning) return
                update { it.copy(vpnMetered = metered) }
            }

            fun changeBypassLocalNetwork(enabled: Boolean) {
                if (state.connectionPhase.isActiveOrTransitioning) return
                update { it.copy(bypassLocalNetwork = enabled) }
            }

            fun changeIpv6RoutingMode(mode: Ipv6RoutingMode) {
                if (state.connectionPhase.isActiveOrTransitioning) return
                update { it.copy(ipv6RoutingMode = mode) }
            }

            ViaSixApp(
                state = state,
                selectedSection = selectedSection,
                onSectionChange = ::selectSection,
                onProfileChange = { yaml ->
                    update { it.copy(profileDraft = yaml, configPreview = "") }
                },
                onApplyProfile = ::applyProfileDraft,
                onRevertProfile = {
                    update {
                        it.copy(profileDraft = it.profileYaml, configPreview = "")
                            .appendLog("已还原为上一次应用的配置", LogLevel.Info, LogSource.Proxy)
                    }
                },
                onImportProfile = {
                    openDocument.launch(arrayOf("text/*", "application/*", "*/*"))
                },
                onImportClipboard = { importClipboardProfile() },
                onSelectedAddressChange = { ip -> update { it.copy(selectedAddress = ip) } },
                onApplyNode = { address, reconnect -> applyNode(address, reconnect) },
                onRemoveCandidate = { address ->
                    update {
                        it.copy(candidateAddresses = it.candidateAddresses.filter { c -> c != address })
                            .appendLog("已移除候选 $address", LogLevel.Info, LogSource.Node)
                    }
                },
                onSpeedParametersChange = { params ->
                    update { it.copy(speedTest = it.speedTest.copy(parameters = params)) }
                },
                onIpSourceModeChange = { mode ->
                    update { it.copy(speedTest = it.speedTest.copy(ipSourceMode = mode)) }
                },
                onCustomIpFilePathChange = { path ->
                    update { it.copy(speedTest = it.speedTest.copy(customIpFilePath = path)) }
                },
                onResetSpeedParameters = {
                    update {
                        it.copy(
                            speedTest =
                                it.speedTest.copy(
                                    ipSourceMode = IPSourceMode.IPV6,
                                    parameters = SpeedTestParameters.defaultsForRange(),
                                    customIpFilePath = "",
                                ),
                        ).appendLog("已恢复默认测速设置", LogLevel.Info, LogSource.Node)
                    }
                },
                onToggleParametersExpanded = {
                    update {
                        it.copy(
                            speedTest =
                                it.speedTest.copy(
                                    parametersExpanded = !it.speedTest.parametersExpanded,
                                ),
                        )
                    }
                },
                onStartSpeedTest = ::startSpeedTest,
                onStopSpeedTest = ::stopSpeedTest,
                onStartCurrentNodeTest = ::startCurrentNodeTest,
                onSpeedSortChange = { key ->
                    update {
                        val same = it.speedTest.sortKey == key
                        it.copy(
                            speedTest =
                                it.speedTest.copy(
                                    sortKey = key,
                                    sortAscending =
                                        if (same) !it.speedTest.sortAscending else true,
                                ),
                        )
                    }
                },
                onInspectRuntimeComponents = { inspectRuntimeComponents(announce = true) },
                onRepairRuntimeComponent = ::repairRuntimeComponent,
                onManageNotificationPermission = ::manageNotificationPermission,
                onManageVpnPermission = ::manageVpnPermission,
                onManageBatteryOptimization = ::manageBatteryOptimization,
                onAppRoutingModeChange = ::changeAppRoutingMode,
                onToggleAppRoutingPackage = ::toggleAppRoutingPackage,
                onClearSelectedAppPackages = ::clearSelectedAppPackages,
                onRefreshInstalledApps = ::refreshInstalledApps,
                onDnsRoutingModeChange = ::changeDnsRoutingMode,
                onDnsServerChange = ::changeDnsServer,
                onVpnMtuChange = ::changeVpnMtu,
                onVpnMeteredChange = ::changeVpnMetered,
                onBypassLocalNetworkChange = ::changeBypassLocalNetwork,
                onIpv6RoutingModeChange = ::changeIpv6RoutingMode,
                onRoutingModeChange = ::patchRoutingMode,
                onFullTunnelChange = { full ->
                    if (state.connectionPhase.isActiveOrTransitioning) {
                        update {
                            it.appendLog(
                                "运行中无法切换全量隧道，请先断开再改",
                                LogLevel.Warning,
                                LogSource.Network,
                                asNotice = true,
                            )
                        }
                    } else {
                        update { it.copy(fullTunnel = full) }
                    }
                },
                onStart = { startVpn("connect") },
                onStop = ::stopVpn,
                onProjectPreview = ::projectPreview,
                onDetectExitIp = ::detectExitIp,
                onExitIpModeChange = { mode ->
                    update {
                        it.copy(
                            exitIP =
                                it.exitIP.copy(
                                    mode = mode,
                                    info = null,
                                    errorMessage = null,
                                ),
                        )
                    }
                },
                onExitIpEndpointChange = { endpoint ->
                    update {
                        it.copy(
                            exitIP =
                                it.exitIP.copy(
                                    endpoint = endpoint,
                                    info =
                                        if (it.exitIP.mode == ExitIPDetectionMode.AUTOMATIC) {
                                            null
                                        } else {
                                            it.exitIP.info
                                        },
                                    errorMessage = null,
                                ),
                        )
                    }
                },
                onDelayTest = ::runDelayTest,
                onCopy = ::copyText,
                onClearLogs = {
                    val clearThrough =
                        maxOf(
                            lastImportedEventId,
                            RuntimeEventCursor.latestId(runtimeStore.load().eventsJson),
                        )
                    lastImportedEventId = clearThrough
                    runtimeStore.markEventsClearedThrough(clearThrough)
                    state = state.copy(logs = emptyList(), statusMessage = "日志已清空")
                },
                onDismissNotice = { state = state.copy(notice = null) },
                onClearSessionData = {
                    if (state.connectionPhase.isActiveOrTransitioning) {
                        update {
                            it.appendLog(
                                "运行中无法重置会话偏好，请先断开 VPN",
                                LogLevel.Warning,
                                LogSource.System,
                                asNotice = true,
                            )
                        }
                    } else {
                        prefsStore.clear()
                        val resetPrefs = prefsStore.load()
                        val currentRuntime = runtimeStore.load()
                        selectedSection = AppSection.OVERVIEW
                        state =
                            SessionUiState.fromPrefs(resetPrefs)
                                .copy(
                                    notificationPermission =
                                        currentNotificationPermissionState(
                                            wasRequested =
                                                resetPrefs.notificationPermissionRequested,
                                        ),
                                    vpnPermission = currentVpnPermissionState(),
                                    batteryOptimization = currentBatteryOptimizationState(),
                                    appRouting =
                                        state.appRouting.copy(
                                            mode = AppRoutingMode.ALL,
                                            selectedPackages = emptyList(),
                                            isLoadingApps = false,
                                        ),
                                    runtimeComponents = state.runtimeComponents,
                                    // No re-inspection after reset: reuse the retained CFST
                                    // check so the placeholder message never sticks.
                                    speedTest =
                                        SessionUiState.fromPrefs(resetPrefs).speedTest.copy(
                                            binaryReady = state.runtimeComponents.cfst.ready,
                                            message =
                                                state.runtimeComponents.cfst.detail
                                                    .ifBlank { "正在检查 CFST 组件…" },
                                        ),
                                    runtime = currentRuntime.toUiSnapshot(),
                                    connectionPhase =
                                        ConnectionPhase.restore(currentRuntime.phase),
                                )
                                .appendLog(
                                    "已重置会话偏好",
                                    LogLevel.Warning,
                                    LogSource.System,
                                )
                    }
                },
            )
        }
    }

    override fun onResume() {
        super.onResume()
        onRefreshNotificationPermission?.invoke()
        onRefreshVpnPermission?.invoke()
        onRefreshBatteryOptimization?.invoke()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        onLaunchIntent?.invoke(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_PENDING_VPN_START_REASON, pendingVpnStartReason)
        outState.putString(
            STATE_PENDING_NOTIFICATION_START_REASON,
            pendingNotificationStartReason,
        )
        outState.putLong(STATE_STARTING_SINCE_MILLIS, startingSinceMillis)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        cfstRunner.requestCancel()
        super.onDestroy()
    }

    private fun currentNotificationPermissionState(
        wasRequested: Boolean,
    ): NotificationPermissionState {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return NotificationPermissionState(
                required = false,
                granted = true,
                wasRequested = wasRequested,
            )
        }
        return NotificationPermissionState(
            required = true,
            granted =
                checkSelfPermission(POST_NOTIFICATIONS_PERMISSION) ==
                    PackageManager.PERMISSION_GRANTED,
            wasRequested = wasRequested,
            shouldShowRationale =
                shouldShowRequestPermissionRationale(POST_NOTIFICATIONS_PERMISSION),
        )
    }

    private fun currentVpnPermissionState(): VpnPermissionState =
        VpnPermissionState(granted = VpnService.prepare(this) == null)

    private fun currentBatteryOptimizationState(): BatteryOptimizationState {
        val powerManager = getSystemService(PowerManager::class.java)
        return BatteryOptimizationState(
            exempt = powerManager.isIgnoringBatteryOptimizations(packageName),
        )
    }

    private fun openBatteryOptimizationSettings() {
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: Exception) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                ),
            )
        }
    }

    private fun openSystemVpnSettings() {
        try {
            startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
        } catch (_: Exception) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                ),
            )
        }
    }

    private fun openAppNotificationSettings() {
        val notificationSettings =
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        try {
            startActivity(notificationSettings)
        } catch (_: Exception) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                ),
            )
        }
    }

    companion object {
        const val EXTRA_OPEN_SECTION = "dev.viasix.app.OPEN_SECTION"

        /** Fail STARTING if VPN runtime never becomes ready. */
        private const val START_TIMEOUT_MS = 25_000L
        private const val PROFILE_VALIDATION_IPV6 = "2001:db8::1"
        private const val STATE_PENDING_VPN_START_REASON = "pendingVpnStartReason"
        private const val STATE_PENDING_NOTIFICATION_START_REASON =
            "pendingNotificationStartReason"
        private const val STATE_STARTING_SINCE_MILLIS = "startingSinceMillis"
    }
}
