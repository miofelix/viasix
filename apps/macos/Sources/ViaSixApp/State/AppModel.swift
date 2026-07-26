import Darwin
import Foundation
import Network
import Observation
import ViaSixCore
import ViaSixMihomoConfig
import ViaSixPrivilegedProtocol

protocol ProxyProfileReplacing: Sendable {
    func replaceProfile(
        with data: Data,
        selectedIP: String?,
        expectedProfileData: Data?
    ) async throws -> ProxyEndpoint
}

/// The app-facing boundary for operating-system proxy changes. Keeping this
/// behind a protocol makes lifecycle behavior deterministic in tests while
/// the production implementation remains the transactional core manager.
protocol SystemProxyManaging: Sendable {
    func enable(endpoint: ProxyEndpoint) async throws -> SystemProxySnapshot
    func disable() async throws -> SystemProxyRestoreReport
    func recoverIfNeeded() async throws -> SystemProxyRestoreReport
    func isEnabled() async -> Bool
}

extension SystemProxyManager: SystemProxyManaging {}

protocol ProxyCoreControlling: Sendable {
    var isRunning: Bool { get async }
    func start(onEvent: @escaping MihomoEventHandler) async throws
    func stop() async
    func restart(onEvent: @escaping MihomoEventHandler) async throws
}

extension MihomoController: ProxyCoreControlling {}

struct ProxyCoreControllerConfiguration: Sendable {
    let executableURL: URL
    let configURL: URL
    let homeURL: URL
    let environment: [String: String]
    let host: String
    let port: UInt16
}

typealias ProxyCoreControllerFactory = @Sendable (ProxyCoreControllerConfiguration) -> any ProxyCoreControlling

extension AppBootstrapper: ProxyProfileReplacing {
    func replaceProfile(
        with data: Data,
        selectedIP: String?,
        expectedProfileData: Data?
    ) throws -> ProxyEndpoint {
        if let expectedProfileData {
            let currentProfileData = try Data(contentsOf: paths.profileConfig)
            guard currentProfileData == expectedProfileData else {
                throw AppModelError.profileChangedExternally
            }
        }
        do {
            return try replaceProfileIfUnchanged(
                with: data,
                selectedIP: selectedIP,
                expectedProfileData: expectedProfileData
            )
        } catch AppBootstrapperError.profileChangedExternally {
            throw AppModelError.profileChangedExternally
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var state: AppState
    private(set) var switchingIP: String?

    var parameters: SpeedTestParameters {
        get { state.preferences.parameters }
        set {
            guard !isShuttingDown else { return }
            guard state.preferences.parameters != newValue else { return }
            prepareForSpeedTestSettingsChange()
            state.preferences.parameters = newValue
            schedulePreferencesSave()
        }
    }

    var ipSourceMode: IPSourceMode {
        state.preferences.ipSourceMode
    }

    var isCfstBusy: Bool {
        activeRunner != nil
    }

    var isTemplateOperationBusy: Bool {
        state.templateOperationPhase != .idle
    }

    var isProxyConfigurationReady: Bool {
        state.proxyConfigurationPhase == .ready && ipv6TransportReadinessIssue == nil
    }

    var effectiveNetworkAccessUsesTun: Bool {
        state.localProxyConfiguration.networkAccessMode == .virtualInterface
    }

    var ipv6TransportReadinessIssue: String? {
        if state.localProxyConfiguration.routingMode != .direct {
            let selected = state.preferences.selectedIP.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard IPv6Address(selected) != nil else {
                return "IPv6 模式需要先选择有效的 IPv6 节点"
            }
            guard state.proxySupportsNodeSelection else {
                return "当前配置无法注入 IPv6 节点，请更换为包含内联代理的配置"
            }
        }
        if effectiveNetworkAccessUsesTun, !canUseTunMode {
            if case .unavailable(let detail) = state.tun.servicePhase {
                return detail
            }
            return "虚拟网卡模式需要先准备 TUN 服务"
        }
        return nil
    }

    var isSystemProxyTransitioning: Bool {
        state.systemProxyPhase.isTransitioning || systemProxyTask != nil
    }

    var isNetworkAccessChanging: Bool {
        systemProxyTask != nil
    }

    var isTunTransitioning: Bool {
        state.tun.operationInProgress || state.tun.sessionPhase.isTransitioning
    }

    var hasForeignTunSession: Bool {
        state.tun.sessionPhase != .inactive
            && !state.tun.sessionPhase.isFailed
            && !state.tun.sessionOwnedByCurrentUser
            && proxyStartTask == nil
    }

    var canMaintainTunInstallation: Bool {
        !state.isProxyRunning
            && (state.tun.sessionPhase == .inactive
                || state.tun.sessionPhase.isFailed)
            && proxyStartTask == nil
            && proxyStopTask == nil
    }

    var canStopTunSession: Bool {
        state.tun.sessionPhase == .running
            && state.tun.sessionOwnedByCurrentUser
    }

    var canRecoverTunSession: Bool {
        state.tun.sessionOwnedByCurrentUser
            && state.tun.sessionPhase == .recoveryRequired
    }

    var canUseTunMode: Bool {
        let required: TunHelperFeature = [
            .fixedRuntimeManagement,
            .sessionLifecycle,
            .recovery,
            .ipv4,
            .ipv6,
            .systemRouting,
            .loopbackPrevention,
            .dnsManagement,
            .networkChangeRecovery,
            .loopbackController,
        ]
        return state.tun.isAvailable
            && TunHelperFeature(rawValue: state.tun.supportedFeatures).isSuperset(of: required)
    }

    var activeProxyRuntimeIsAvailable: Bool {
        if effectiveNetworkAccessUsesTun {
            return canUseTunMode
        }
        return hasProxyCoreExecutable
    }

    var isRoutingModeChanging: Bool {
        routingModeTask != nil
    }

    var currentConfigurationTestUnavailableReason: String? {
        if isShuttingDown { return "应用正在退出" }
        guard state.launchPhase == .ready else {
            return switch state.launchPhase {
            case .failed: "应用启动失败，请先重试"
            case .idle, .loading: "应用仍在准备，请稍后再试"
            case .ready: nil
            }
        }
        if runtimeTask != nil { return "运行组件操作进行中" }
        if state.templateOperationPhase != .idle { return "代理配置操作进行中" }
        if selectionTask != nil { return "正在应用节点，请稍后再试" }
        if activeRunner != nil { return "另一项测速正在进行" }
        if state.localProxyConfiguration.routingMode == .direct {
            return "直连模式不使用代理节点"
        }
        if !state.proxySupportsNodeSelection {
            return "当前代理配置不支持直接测速节点"
        }

        let selectedIP = state.preferences.selectedIP
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedIP.isEmpty else { return "请先选择当前节点" }
        guard
            resolvedExecutable(
                preferredPath: state.preferences.cfstPath,
                managedURL: state.runtimeStatus?.cfstURL,
                commandName: "cfst"
            ) != nil
        else {
            return "请先安装 CFST 运行组件"
        }

        do {
            _ = try currentConfigurationTestParameters(for: selectedIP)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var proxyConfigurationIssue: String? {
        if state.localProxyConfiguration.routingMode != .direct,
            case .needsSetup(let message) = state.proxyConfigurationPhase
        {
            return message
        }
        return ipv6TransportReadinessIssue
    }

    var runtimeIntegrityIssue: String? {
        guard let invalidFiles = state.runtimeStatus?.invalidFiles, !invalidFiles.isEmpty else {
            return nil
        }
        let names =
            invalidFiles
            .sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
            .map(\.rawValue)
            .joined(separator: "、")
        return "检测到无法使用的运行组件（\(names)），请重新安装或导入本地组件。"
    }

    var exitIPEndpoint: String {
        get { state.preferences.exitIPEndpoint }
        set {
            guard !isShuttingDown else { return }
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = normalized.isEmpty ? AppMetadata.defaultExitIPEndpoint : normalized
            guard state.preferences.exitIPEndpoint != value else { return }
            if state.preferences.exitIPDetectionMode == .automatic {
                cancelExitIPDetection()
            }
            state.preferences.exitIPEndpoint = value
            state.exit.errorMessage = nil
            schedulePreferencesSave()
        }
    }

    var exitIPDetectionMode: ExitIPDetectionMode {
        get { state.preferences.exitIPDetectionMode }
        set {
            guard !isShuttingDown else { return }
            guard state.preferences.exitIPDetectionMode != newValue else { return }
            cancelExitIPDetection()
            state.preferences.exitIPDetectionMode = newValue
            state.exit.errorMessage = nil
            schedulePreferencesSave()
        }
    }

    var exitIPResultIsStale: Bool {
        guard let context = state.exit.context else { return false }
        return context != currentExitIPDetectionContext
    }

    var exitIPRouteDescription: String? {
        guard let route = state.exit.context?.route else { return nil }
        switch route {
        case .direct:
            return "直连"
        case .proxy(let endpoint, _):
            return "本地代理 \(endpoint.displayAddress)"
        }
    }

    /// CFST and Mihomo are independent capabilities. Keeping them separate lets
    /// the UI offer node testing even when the proxy component is not installed.
    var hasCfstExecutable: Bool {
        resolvedExecutable(
            preferredPath: state.preferences.cfstPath,
            managedURL: state.runtimeStatus?.cfstURL,
            commandName: "cfst"
        ) != nil
    }

    var hasProxyCoreExecutable: Bool {
        let managedURL =
            state.runtimeStatus?.mihomoIsReady == true
            ? state.runtimeStatus?.mihomoURL
            : nil
        return resolvedExecutable(
            preferredPath: state.preferences.mihomoPath,
            managedURL: managedURL,
            commandName: "mihomo"
        ) != nil
    }

    let paths: AppPaths

    @ObservationIgnored private let preferencesStore: PreferencesStore
    @ObservationIgnored private let bootstrapper: AppBootstrapper
    @ObservationIgnored private let runtimeManager: RuntimeComponentManager
    @ObservationIgnored private let exitDetector: any ExitIPDetecting
    @ObservationIgnored private let profileReplacer: any ProxyProfileReplacing
    @ObservationIgnored private let systemProxyManager: any SystemProxyManaging
    @ObservationIgnored private let tunCoordinator: any TunModeCoordinating
    @ObservationIgnored private let proxyCoreControllerFactory: ProxyCoreControllerFactory

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeTask: Task<Void, Never>?
    @ObservationIgnored private var activeRuntimeOperationID: UUID?
    @ObservationIgnored private var templateImportTask: Task<Void, Never>?
    @ObservationIgnored private var templateSaveTask: Task<ProxyEndpoint, Error>?
    @ObservationIgnored private var speedTestTask: Task<Void, Never>?
    @ObservationIgnored private var configurationTestTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var exitIPEnrichmentTask: Task<Void, Never>?
    @ObservationIgnored private var activeExitDetectionID: UUID?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var proxyStartTask: Task<Void, Never>?
    @ObservationIgnored private var proxyStopTask: Task<Void, Never>?
    @ObservationIgnored private var systemProxyTask: Task<Void, Never>?
    @ObservationIgnored private var systemProxyCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var tunOperationTask: Task<Void, Never>?
    @ObservationIgnored private var tunMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var activeTunMonitorID: UUID?
    @ObservationIgnored private var routingModeTask: Task<Void, Never>?
    @ObservationIgnored private var trafficMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var trafficMonitorStopTask: Task<Void, Never>?
    @ObservationIgnored private var trafficMonitorRetryTask: Task<Void, Never>?
    @ObservationIgnored private var trafficMonitorGeneration = 0
    @ObservationIgnored private var trafficMonitorConfigurationRetries = 0
    @ObservationIgnored private var trafficMonitor = TrafficMonitor()
    @ObservationIgnored private var activeRunner: CfstRunner?
    @ObservationIgnored private var activeSpeedTestID: UUID?
    @ObservationIgnored private var activeConfigurationTestID: UUID?
    @ObservationIgnored private var activeProxyCore: (any ProxyCoreControlling)?
    @ObservationIgnored private var activeProxyCoreID: UUID?
    @ObservationIgnored private var proxyStopRequested = false
    @ObservationIgnored private var isShuttingDown = false

    init(
        paths: AppPaths,
        preferencesStore: PreferencesStore,
        bootstrapper: AppBootstrapper,
        runtimeManager: RuntimeComponentManager,
        exitDetector: any ExitIPDetecting,
        profileReplacer: (any ProxyProfileReplacing)? = nil,
        systemProxyManager: (any SystemProxyManaging)? = nil,
        tunCoordinator: (any TunModeCoordinating)? = nil,
        proxyCoreControllerFactory: ProxyCoreControllerFactory? = nil
    ) {
        self.paths = paths
        self.preferencesStore = preferencesStore
        self.bootstrapper = bootstrapper
        self.runtimeManager = runtimeManager
        self.exitDetector = exitDetector
        self.profileReplacer = profileReplacer ?? bootstrapper
        self.systemProxyManager = systemProxyManager ?? SystemProxyManager(paths: paths)
        self.tunCoordinator = tunCoordinator ?? TunModeCoordinator()
        self.proxyCoreControllerFactory =
            proxyCoreControllerFactory ?? { configuration in
                MihomoController(
                    executableURL: configuration.executableURL,
                    configURL: configuration.configURL,
                    homeURL: configuration.homeURL,
                    environment: configuration.environment,
                    host: configuration.host,
                    port: configuration.port
                )
            }
        self.state = AppState(
            preferences: UserPreferences(parameters: .defaults(ipv6File: paths.ipv6List))
        )
    }

    static func live() -> AppModel {
        let paths = AppPaths.live()
        return AppModel(
            paths: paths,
            preferencesStore: PreferencesStore(fileURL: paths.preferences),
            bootstrapper: AppBootstrapper(paths: paths),
            runtimeManager: RuntimeComponentManager(paths: paths),
            exitDetector: ExitIPDetector()
        )
    }

    func start() {
        guard !isShuttingDown, bootstrapTask == nil, state.launchPhase == .idle else { return }
        state.launchPhase = .loading
        bootstrapTask = Task { [weak self] in
            await self?.bootstrap()
        }
    }

    func retryBootstrap() {
        guard !isShuttingDown, case .failed = state.launchPhase, bootstrapTask == nil else { return }
        state.launchPhase = .idle
        start()
    }

    func refreshTunState() {
        guard !isShuttingDown, tunOperationTask == nil else { return }
        tunOperationTask = Task { [weak self] in
            guard let self else { return }
            defer { tunOperationTask = nil }
            await refreshTunState(recoverIfNeeded: false)
        }
    }

    func applicationDidBecomeActive() {
        guard state.launchPhase == .ready else { return }
        refreshTunState()
    }

    func installTunService() {
        guard
            !isShuttingDown,
            tunOperationTask == nil,
            canMaintainTunInstallation
        else { return }
        state.tun.operationInProgress = true
        state.tun.lastError = nil
        tunOperationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                state.tun.operationInProgress = false
                tunOperationTask = nil
            }
            do {
                let registration = try await tunCoordinator.registerService()
                applyTunRegistrationState(registration)
                if registration == .enabled {
                    let snapshot = try await tunCoordinator.installOrRepairRuntime()
                    applyTunSnapshot(snapshot)
                    showNotice("虚拟网卡服务已安装", style: .success)
                } else if registration == .requiresApproval {
                    showNotice("请在系统设置的登录项中允许 ViaSix 虚拟网卡服务")
                }
            } catch {
                recordTunFailure("安装虚拟网卡服务失败", error: error)
            }
        }
    }

    func repairTunService() {
        guard
            !isShuttingDown,
            tunOperationTask == nil,
            canMaintainTunInstallation
        else { return }
        state.tun.operationInProgress = true
        state.tun.lastError = nil
        tunOperationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                state.tun.operationInProgress = false
                tunOperationTask = nil
            }
            do {
                let registration = try await tunCoordinator.repairService()
                applyTunRegistrationState(registration)
                if registration == .enabled {
                    let snapshot = try await tunCoordinator.installOrRepairRuntime()
                    applyTunSnapshot(snapshot)
                    showNotice("虚拟网卡服务已修复", style: .success)
                } else if registration == .requiresApproval {
                    showNotice("服务已重新注册，请在系统设置中批准")
                }
            } catch {
                recordTunFailure("修复虚拟网卡服务失败", error: error)
            }
        }
    }

    func installOrRepairTunRuntime() {
        guard
            !isShuttingDown,
            tunOperationTask == nil,
            canMaintainTunInstallation,
            state.tun.serviceIsReady
        else { return }
        state.tun.operationInProgress = true
        state.tun.runtimePhase = .installing
        state.tun.lastError = nil
        tunOperationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                state.tun.operationInProgress = false
                tunOperationTask = nil
            }
            do {
                let snapshot = try await tunCoordinator.installOrRepairRuntime()
                applyTunSnapshot(snapshot)
                showNotice("特权 Mihomo 已就绪", style: .success)
            } catch {
                state.tun.runtimePhase = .failed(error.localizedDescription)
                recordTunFailure("安装特权 Mihomo 失败", error: error)
            }
        }
    }

    func recoverTunSession() {
        guard
            !isShuttingDown,
            tunOperationTask == nil,
            state.tun.serviceIsReady,
            canRecoverTunSession
        else { return }
        state.tun.operationInProgress = true
        state.tun.sessionPhase = .recovering
        state.tun.lastError = nil
        tunOperationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                state.tun.operationInProgress = false
                tunOperationTask = nil
            }
            do {
                let snapshot = try await tunCoordinator.recover()
                applyTunSnapshot(snapshot)
                if snapshot.sessionPhase == .running, snapshot.sessionOwnedByCaller {
                    state.proxyCorePhase = .running
                    beginTunStatusMonitoring()
                    syncTrafficMonitoring()
                    if state.localProxyConfiguration.systemProxyEnabled,
                        state.systemProxyPhase != .enabled,
                        !state.systemProxyPhase.isTransitioning
                    {
                        do {
                            try await applySystemProxyIfRequested(endpoint: state.proxyEndpoint)
                        } catch {
                            appendLog(
                                source: .app,
                                level: .warning,
                                message: "虚拟网卡已恢复，但系统代理启用失败：\(error.localizedDescription)"
                            )
                        }
                    }
                    showNotice("虚拟网卡已恢复运行", style: .success)
                } else {
                    if state.proxyCorePhase != .running {
                        state.proxyCorePhase = .stopped
                    }
                    stopTunStatusMonitoring()
                    syncTrafficMonitoring()
                    showNotice("虚拟网卡状态已恢复", style: .success)
                }
            } catch {
                state.tun.sessionPhase = .recoveryRequired
                recordTunFailure("恢复虚拟网卡失败", error: error)
            }
        }
    }

    func openTunApprovalSettings() {
        Task { [tunCoordinator] in
            await tunCoordinator.openApprovalSettings()
        }
    }

    private func refreshTunState(recoverIfNeeded: Bool) async {
        let registration = await tunCoordinator.registrationState()
        applyTunRegistrationState(registration)
        guard registration == .enabled else { return }
        do {
            var snapshot = try await tunCoordinator.helperStatus()
            if recoverIfNeeded,
                snapshot.recoveryRequired,
                snapshot.sessionOwnedByCaller
            {
                state.tun.sessionPhase = .recovering
                snapshot = try await tunCoordinator.recover()
            }
            applyTunSnapshot(snapshot)
        } catch {
            state.tun.servicePhase = .unavailable(error.localizedDescription)
            state.tun.lastError = error.localizedDescription
            appendLog(
                source: .app,
                level: .warning,
                message: "读取虚拟网卡服务状态失败：\(error.localizedDescription)"
            )
        }
    }

    private func applyTunRegistrationState(_ registration: TunHelperRegistrationState) {
        state.tun.servicePhase =
            switch registration {
            case .notRegistered: .notInstalled
            case .enabled: .ready
            case .requiresApproval: .requiresApproval
            case .notFound: .unavailable("当前应用包中未找到虚拟网卡服务")
            }
        if registration != .enabled {
            state.tun.runtimePhase = .unknown
            state.tun.supportedFeatures = 0
        }
    }

    private func applyTunSnapshot(_ snapshot: TunHelperStatusSnapshot) {
        state.tun.servicePhase = .ready
        state.tun.supportedFeatures = snapshot.supportedFeatures
        state.tun.runtimeVersion = snapshot.runtimeVersion
        state.tun.runtimePhase =
            switch snapshot.runtimeState {
            case .unavailable: .failed("当前 helper 不支持特权运行组件")
            case .notInstalled: .notInstalled
            case .ready: .ready
            case .repairRequired: .repairRequired
            case .installing: .installing
            case .failed: .failed(snapshot.lastError ?? "特权运行组件异常")
            }
        state.tun.sessionIdentifier = snapshot.sessionIdentifier
        state.tun.sessionOwnedByCurrentUser = snapshot.sessionOwnedByCaller
        state.tun.lastError = snapshot.lastError
        state.tun.sessionPhase =
            switch snapshot.sessionPhase {
            case .inactive: .inactive
            case .starting: .starting
            case .running: .running
            case .stopping: .stopping
            case .recovering: .recovering
            case .recoveryRequired: .recoveryRequired
            case .failed: .failed(snapshot.lastError ?? "TUN 会话异常")
            }
    }

    private func recordTunFailure(_ prefix: String, error: any Error) {
        state.tun.lastError = error.localizedDescription
        appendLog(source: .app, level: .error, message: "\(prefix)：\(error.localizedDescription)")
        showNotice("\(prefix)：\(error.localizedDescription)", style: .error)
    }

    func installRuntime(_ component: RuntimeComponent) {
        guard
            !isShuttingDown,
            runtimeTask == nil,
            state.templateOperationPhase == .idle,
            selectionTask == nil,
            runtimeComponentCanBeReplaced(component)
        else { return }
        let operationID = UUID()
        activeRuntimeOperationID = operationID
        state.runtimeOperation = .installing(component, .preparingInstallation)
        state.runtimeOperationError = nil
        appendLog(source: .app, message: "正在下载并校验 \(component.displayName)…")

        runtimeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishRuntimeOperation(operationID: operationID) }
            do {
                let status = try await runtimeManager.downloadAndInstall(
                    component: component
                ) { [weak self] stage in
                    await self?.receiveRuntimeInstallationStage(
                        stage,
                        component: component,
                        operationID: operationID
                    )
                }
                guard activeRuntimeOperationID == operationID else { return }
                state.runtimeStatus = status
                state.runtimeOperationError = nil
                refreshRuntimePhase()
                appendLog(
                    source: .app,
                    level: .success,
                    message: "\(component.displayName) 安装完成"
                )
                showNotice("\(component.displayName) 已安装", style: .success)
            } catch {
                await finishRuntimeOperationFailure(
                    error,
                    operationID: operationID,
                    failurePrefix: "\(component.displayName) 安装失败"
                )
            }
        }
    }

    private func runtimeComponentCanBeReplaced(_ component: RuntimeComponent) -> Bool {
        switch component {
        case .cfst:
            return activeRunner == nil
        case .mihomo:
            return activeProxyCore == nil
                && proxyStartTask == nil
                && proxyStopTask == nil
                && !state.tun.isRunning
                && !state.tun.sessionPhase.isTransitioning
        }
    }

    func cancelRuntimeOperation() {
        guard
            !isShuttingDown,
            runtimeTask != nil,
            state.runtimeOperation?.canCancel == true
        else { return }
        state.runtimeOperation = .cancelling
        appendLog(source: .app, level: .warning, message: "正在取消运行组件操作…")
        runtimeTask?.cancel()
    }

    private func receiveRuntimeInstallationStage(
        _ stage: RuntimeInstallationStage,
        component: RuntimeComponent,
        operationID: UUID
    ) {
        guard
            activeRuntimeOperationID == operationID,
            state.runtimeOperation != nil,
            state.runtimeOperation != .cancelling
        else { return }
        state.runtimeOperation = .installing(component, stage)
    }

    private func finishRuntimeOperationFailure(
        _ error: Error,
        operationID: UUID,
        failurePrefix: String
    ) async {
        guard activeRuntimeOperationID == operationID else { return }
        let cancelled =
            Task.isCancelled
            || error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || state.runtimeOperation == .cancelling
        let status = await runtimeManager.installedStatus()
        guard activeRuntimeOperationID == operationID else { return }

        state.runtimeStatus = status
        refreshRuntimePhase()
        if cancelled {
            state.runtimeOperationError = nil
            guard !isShuttingDown else { return }
            appendLog(source: .app, level: .warning, message: "运行组件操作已取消，现有组件保持不变")
            showNotice("已取消运行组件操作，现有组件保持不变")
            return
        }

        state.runtimeOperationError = error.localizedDescription
        appendLog(source: .app, level: .error, message: "\(failurePrefix)：\(error.localizedDescription)")
        showNotice("\(failurePrefix)：\(error.localizedDescription)", style: .error)
    }

    private func finishRuntimeOperation(operationID: UUID) {
        guard activeRuntimeOperationID == operationID else { return }
        activeRuntimeOperationID = nil
        runtimeTask = nil
        state.runtimeOperation = nil
    }

    func importProxyProfile(from url: URL) {
        guard !isShuttingDown else { return }
        guard state.launchPhase != .loading else {
            showNotice("应用仍在准备，请稍后再试", style: .error)
            return
        }
        guard ["yaml", "yml"].contains(url.pathExtension.lowercased()) else {
            let message = "仅支持导入 .yaml 或 .yml 配置文件"
            state.templateOperationError = message
            showNotice(message, style: .error)
            return
        }
        guard
            templateImportTask == nil,
            templateSaveTask == nil,
            state.templateOperationPhase == .idle,
            selectionTask == nil,
            runtimeTask == nil
        else { return }
        switch state.proxyCorePhase {
        case .validating, .starting, .running, .stopping:
            showNotice("请先停止本地代理再更换连接配置", style: .error)
            return
        case .stopped, .failed:
            break
        }

        let selectedIP = state.preferences.selectedIP
        state.templateOperationError = nil
        state.templateOperationPhase = .importing
        templateImportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                templateImportTask = nil
                state.templateOperationPhase = .idle
            }
            let isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessingSecurityScopedResource {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                state.proxyEndpoint = try await bootstrapper.importProfile(
                    from: url,
                    selectedIP: selectedIP
                )
                if let local = try? await bootstrapper.loadLocalProxyConfiguration() {
                    state.localProxyConfiguration = local
                }
                if let profileData = try? await bootstrapper.loadProfileConfiguration() {
                    updateNodeSelectionCapability(from: profileData)
                }
                state.proxyConfigurationPhase = .ready
                appendLog(source: .app, level: .success, message: "已导入代理配置")
                showNotice("代理配置已导入", style: .success)
            } catch {
                state.templateOperationError = error.localizedDescription
                appendLog(source: .app, level: .error, message: "导入代理配置失败：\(error.localizedDescription)")
                showNotice("导入失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func loadProfileConfiguration() async throws -> Data {
        try await Task.detached { [paths] in
            try Data(contentsOf: paths.profileConfig)
        }.value
    }

    func saveProfileConfiguration(
        _ data: Data,
        expectedProfileData: Data? = nil
    ) async throws {
        guard state.launchPhase != .loading else {
            throw AppModelError.appNotReady
        }
        guard
            templateImportTask == nil,
            templateSaveTask == nil,
            state.templateOperationPhase == .idle
        else {
            throw AppModelError.templateOperationInProgress
        }
        guard selectionTask == nil else {
            throw AppModelError.selectionInProgress
        }
        guard runtimeTask == nil else {
            throw AppModelError.runtimeOperationInProgress
        }
        guard !isShuttingDown else { throw CancellationError() }
        switch state.proxyCorePhase {
        case .validating, .starting, .running, .stopping:
            throw AppModelError.proxyMustBeStopped
        case .stopped, .failed:
            break
        }

        let selectedIP = state.preferences.selectedIP
        state.templateOperationError = nil
        state.templateOperationPhase = .saving
        let task = Task<ProxyEndpoint, Error> { [profileReplacer] in
            try Task.checkCancellation()
            let endpoint = try await profileReplacer.replaceProfile(
                with: data,
                selectedIP: selectedIP,
                expectedProfileData: expectedProfileData
            )
            try Task.checkCancellation()
            return endpoint
        }
        templateSaveTask = task
        defer {
            templateSaveTask = nil
            state.templateOperationPhase = .idle
        }

        do {
            let endpoint = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            state.proxyEndpoint = endpoint
            if let local = try? await bootstrapper.loadLocalProxyConfiguration() {
                state.localProxyConfiguration = local
            }
            updateNodeSelectionCapability(from: data)
            state.proxyConfigurationPhase = .ready
            appendLog(source: .app, level: .success, message: "代理配置已保存")
            showNotice("代理配置已保存", style: .success)
        } catch is CancellationError {
            throw CancellationError()
        } catch AppModelError.profileChangedExternally {
            appendLog(
                source: .app,
                level: .warning,
                message: "代理配置在编辑期间发生变化，已阻止覆盖外部修改"
            )
            state.templateOperationError = AppModelError.profileChangedExternally.localizedDescription
            throw AppModelError.profileChangedExternally
        } catch {
            state.templateOperationError = error.localizedDescription
            appendLog(source: .app, level: .error, message: "保存代理配置失败：\(error.localizedDescription)")
            throw error
        }
    }

    func saveLocalProxyConfiguration(_ configuration: LocalProxyConfiguration) async throws {
        guard state.launchPhase != .loading else { throw AppModelError.appNotReady }
        guard !isShuttingDown else { throw CancellationError() }
        if configuration.networkAccessMode == .virtualInterface, !canUseTunMode {
            throw AppModelError.virtualInterfaceUnavailable
        }
        switch state.proxyCorePhase {
        case .validating, .starting, .running, .stopping:
            throw AppModelError.proxyMustBeStopped
        case .stopped, .failed:
            break
        }
        guard state.templateOperationPhase == .idle else {
            throw AppModelError.templateOperationInProgress
        }
        let configuration = try configuration.validated()
        let selectedIP = state.preferences.selectedIP
        state.templateOperationPhase = .saving
        defer { state.templateOperationPhase = .idle }
        let endpoint = try await Task.detached { [bootstrapper] in
            try await bootstrapper.replaceLocalProxyConfiguration(with: configuration, selectedIP: selectedIP)
        }.value
        guard !isShuttingDown else { throw CancellationError() }
        state.localProxyConfiguration = configuration
        state.proxyEndpoint = endpoint
        state.proxyConfigurationPhase = .ready
        await refreshNodeSelectionCapability()
        if case .failed = state.systemProxyPhase {
            state.systemProxyPhase = .disabled
        }
        appendLog(source: .app, level: .success, message: "本机代理设置已保存")
        showNotice("本机代理设置已保存", style: .success)
    }

    func setRoutingMode(_ mode: ProxyRoutingMode) {
        guard
            !isShuttingDown,
            state.launchPhase == .ready,
            routingModeTask == nil,
            systemProxyTask == nil,
            runtimeTask == nil,
            state.templateOperationPhase == .idle,
            selectionTask == nil
        else { return }
        guard state.localProxyConfiguration.routingMode != mode else { return }
        switch state.proxyCorePhase {
        case .validating, .starting, .stopping:
            return
        case .stopped, .running, .failed:
            break
        }

        let selectedIP = state.preferences.selectedIP
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let previous = state.localProxyConfiguration
        var updated = previous
        updated.routingMode = mode
        let shouldRestart = state.isProxyRunning
        state.templateOperationError = nil
        state.templateOperationPhase = .saving
        routingModeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                routingModeTask = nil
                state.templateOperationPhase = .idle
            }
            do {
                let endpoint = try await bootstrapper.replaceLocalProxyConfiguration(
                    with: updated,
                    selectedIP: selectedIP
                )
                try Task.checkCancellation()
                state.localProxyConfiguration = updated
                state.proxyEndpoint = endpoint
                state.proxyConfigurationPhase = .ready
                await refreshNodeSelectionCapability()

                if shouldRestart {
                    state.proxyCorePhase = .stopping
                    try await restartActiveProxy()
                }
                appendLog(
                    source: .app,
                    level: .success,
                    message: "代理模式已切换为\(mode.displayName)"
                )
                showNotice("已切换到\(mode.displayName)模式", style: .success)
            } catch is CancellationError {
                return
            } catch {
                state.templateOperationError = error.localizedDescription
                appendLog(
                    source: .app,
                    level: .error,
                    message: "切换代理模式失败：\(error.localizedDescription)"
                )
                showNotice("切换代理模式失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func setNetworkAccessMode(_ mode: NetworkAccessMode) {
        guard
            !isShuttingDown,
            state.launchPhase == .ready,
            systemProxyTask == nil,
            routingModeTask == nil,
            runtimeTask == nil,
            state.templateOperationPhase == .idle
        else { return }
        switch state.proxyCorePhase {
        case .validating, .starting, .stopping:
            return
        case .stopped, .running, .failed:
            break
        }
        if mode == .virtualInterface, !canUseTunMode {
            showNotice("请先在设置中安装、批准并准备虚拟网卡服务", style: .error)
            return
        }
        let previous = state.localProxyConfiguration
        if state.isProxyRunning, mode == .localProxy, !hasProxyCoreExecutable {
            showNotice("请先安装 Mihomo，再关闭 TUN 模式", style: .error, action: .openSettings)
            return
        }

        guard previous.networkAccessMode != mode else { return }
        let shouldRestart = state.isProxyRunning
        var updated = previous
        updated.networkAccessMode = mode

        systemProxyTask = Task { [weak self] in
            guard let self else { return }
            defer { systemProxyTask = nil }
            do {
                if shouldRestart {
                    stopProxy()
                    if let stopTask = proxyStopTask {
                        await stopTask.value
                    }
                    guard state.proxyCorePhase == .stopped else {
                        throw AppModelError.proxyMustBeStopped
                    }
                }
                try await bootstrapper.saveLocalProxyPreference(
                    updated,
                    selectedIP: state.preferences.selectedIP
                )
                state.localProxyConfiguration = updated
                try Task.checkCancellation()
                if shouldRestart {
                    startProxy()
                }
                let message: String =
                    switch (mode, shouldRestart) {
                    case (.virtualInterface, true): "正在切换到 TUN 模式"
                    case (.virtualInterface, false): "已启用 TUN 模式偏好"
                    case (.localProxy, true): "正在关闭 TUN 并切换到本地代理"
                    case (.localProxy, false): "已关闭 TUN 模式偏好"
                    }
                showNotice(message, style: .success)
            } catch is CancellationError {
                return
            } catch {
                if shouldRestart, !state.isProxyRunning,
                    state.localProxyConfiguration.networkAccessMode == previous.networkAccessMode
                {
                    startProxy()
                }
                appendLog(
                    source: .app,
                    level: .error,
                    message: "更新网络接入方式失败：\(error.localizedDescription)"
                )
                showNotice("更新网络接入方式失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func setSystemProxyEnabled(_ enabled: Bool) {
        guard
            !isShuttingDown,
            state.launchPhase == .ready,
            systemProxyTask == nil,
            routingModeTask == nil,
            runtimeTask == nil,
            state.templateOperationPhase == .idle
        else { return }
        switch state.proxyCorePhase {
        case .validating, .starting, .stopping:
            return
        case .stopped, .running, .failed:
            break
        }

        let previous = state.localProxyConfiguration
        guard previous.systemProxyEnabled != enabled else { return }
        var updated = previous
        updated.systemProxyEnabled = enabled

        systemProxyTask = Task { [weak self] in
            guard let self else { return }
            defer { systemProxyTask = nil }
            var updatedPreferenceWasPersisted = false
            do {
                try await bootstrapper.saveLocalProxyPreference(
                    updated,
                    selectedIP: state.preferences.selectedIP
                )
                updatedPreferenceWasPersisted = true
                state.localProxyConfiguration = updated
                try Task.checkCancellation()

                if enabled, state.isProxyRunning {
                    try await applySystemProxyIfRequested(endpoint: state.proxyEndpoint)
                } else if !enabled {
                    try await restoreSystemProxyIfNeeded()
                } else {
                    state.systemProxyPhase = .disabled
                }
                let message =
                    if enabled, state.isProxyRunning {
                        "系统代理已启用"
                    } else if enabled {
                        "系统代理将在本地代理运行时启用"
                    } else {
                        "系统代理已关闭"
                    }
                showNotice(message, style: .success)
            } catch is CancellationError {
                if updatedPreferenceWasPersisted {
                    _ = await rollbackSystemProxyPreference(to: previous)
                }
            } catch {
                let rollbackError =
                    updatedPreferenceWasPersisted
                    ? await rollbackSystemProxyPreference(to: previous) : nil
                let detail =
                    if let rollbackError {
                        "\(error.localizedDescription)；恢复原设置失败：\(rollbackError.localizedDescription)"
                    } else {
                        error.localizedDescription
                    }
                appendLog(
                    source: .app,
                    level: .error,
                    message: "更新系统代理失败：\(detail)"
                )
                showNotice("更新系统代理失败：\(detail)", style: .error)
            }
        }
    }

    private func rollbackSystemProxyPreference(
        to configuration: LocalProxyConfiguration
    ) async -> (any Error)? {
        do {
            try await bootstrapper.saveLocalProxyPreference(
                configuration,
                selectedIP: state.preferences.selectedIP
            )
        } catch {
            state.systemProxyPhase = .failed("恢复系统代理偏好失败：\(error.localizedDescription)")
            appendLog(
                source: .app,
                level: .error,
                message: "恢复系统代理偏好失败：\(error.localizedDescription)"
            )
            return error
        }
        state.localProxyConfiguration = configuration
        if isShuttingDown {
            await restoreSystemProxyAfterProxyFailure()
            return nil
        }
        if configuration.systemProxyEnabled, state.isProxyRunning {
            do {
                try await applySystemProxyIfRequested(endpoint: state.proxyEndpoint)
            } catch {
                state.systemProxyPhase = .failed(error.localizedDescription)
            }
        } else if !configuration.systemProxyEnabled {
            await restoreSystemProxyAfterProxyFailure()
        }
        return nil
    }

    func selectIPSource(_ mode: IPSourceMode) {
        guard !isShuttingDown else { return }
        prepareForSpeedTestSettingsChange()
        state.preferences.ipSourceMode = mode
        switch mode {
        case .ipv6:
            state.preferences.parameters.ipFile = paths.ipv6List.path
            state.preferences.parameters.ipRange = ""
        case .ipv4:
            state.preferences.parameters.ipFile = paths.ipv4List.path
            state.preferences.parameters.ipRange = ""
        case .file:
            state.preferences.parameters.ipRange = ""
        case .range:
            state.preferences.parameters.ipFile = ""
        }
        schedulePreferencesSave()
    }

    func selectIPFile(_ url: URL) {
        guard !isShuttingDown else { return }
        prepareForSpeedTestSettingsChange()
        state.preferences.ipSourceMode = .file
        state.preferences.parameters.ipFile = url.path
        state.preferences.parameters.ipRange = ""
        schedulePreferencesSave()
    }

    func resetParameters() {
        guard !isShuttingDown else { return }
        prepareForSpeedTestSettingsChange()
        state.preferences.ipSourceMode = .ipv6
        state.preferences.parameters = .defaults(ipv6File: paths.ipv6List)
        schedulePreferencesSave()
        showNotice("测速参数已重置")
    }

    func setCustomExecutable(_ component: RuntimeComponent, url: URL?) {
        guard !isShuttingDown else { return }
        guard runtimeTask == nil else {
            showNotice("运行组件安装中，完成后再修改可执行文件路径", style: .error)
            return
        }
        switch component {
        case .cfst where activeRunner != nil:
            showNotice("测速进行中，完成或停止后再修改 CFST 路径", style: .error)
            return
        case .mihomo where activeProxyCore != nil || proxyStartTask != nil || proxyStopTask != nil:
            showNotice("本地代理运行中，停止后再修改 Mihomo 路径", style: .error)
            return
        default:
            break
        }
        let path = url?.path ?? ""
        switch component {
        case .cfst:
            state.preferences.cfstPath = path
        case .mihomo:
            state.preferences.mihomoPath = path
        }
        state.runtimeOperationError = nil
        schedulePreferencesSave()
        refreshRuntimePhase()
    }

    func startSpeedTest() {
        guard
            !isShuttingDown,
            runtimeTask == nil,
            activeRunner == nil,
            state.templateOperationPhase == .idle,
            selectionTask == nil
        else { return }
        guard state.launchPhase == .ready else {
            showNotice("应用仍在准备，请稍后再试", style: .error)
            return
        }
        do {
            _ = try state.preferences.parameters.validated()
        } catch {
            showNotice(error.localizedDescription, style: .error)
            return
        }
        guard
            let executableURL = resolvedExecutable(
                preferredPath: state.preferences.cfstPath,
                managedURL: state.runtimeStatus?.cfstURL,
                commandName: "cfst"
            )
        else {
            showNotice("请先安装 CFST 运行组件", style: .error)
            return
        }

        let runner = CfstRunner(
            executableURL: executableURL,
            resultURL: paths.resultCSV,
            workingDirectoryURL: executableURL.deletingLastPathComponent()
        )
        let runID = UUID()
        let snapshot = state.preferences.parameters
        invalidateConfigurationTestResult()
        activeRunner = runner
        activeSpeedTestID = runID
        state.speedTest = .init(phase: .running, startedAt: Date(), lastActivityAt: Date())
        appendLog(source: .speedTest, message: "开始节点测速")

        speedTestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await runner.run(parameters: snapshot) { [weak self] event in
                    await self?.receiveSpeedTestEvent(event, runID: runID)
                }
                try Task.checkCancellation()
                guard activeSpeedTestID == runID else { return }
                state.results = results
                state.preferences.lastSuccessfulSpeedTestParameters = snapshot
                schedulePreferencesSave()
                appendLog(source: .speedTest, level: .success, message: "测速完成，共 \(results.count) 个候选节点")
                showNotice("测速完成：\(results.count) 个候选节点", style: .success)
                finishSpeedTest(runID: runID, phase: .idle)
            } catch CfstRunnerError.userCancelled {
                guard activeSpeedTestID == runID else { return }
                appendLog(source: .speedTest, level: .warning, message: "测速已停止")
                finishSpeedTest(runID: runID, phase: .idle)
            } catch is CancellationError {
                guard activeSpeedTestID == runID else { return }
                finishSpeedTest(runID: runID, phase: .idle)
            } catch {
                guard activeSpeedTestID == runID else { return }
                appendLog(source: .speedTest, level: .error, message: error.localizedDescription)
                showNotice("测速失败：\(error.localizedDescription)", style: .error)
                finishSpeedTest(runID: runID, phase: .failed(error.localizedDescription))
            }
        }
    }

    func stopSpeedTest() {
        guard activeSpeedTestID != nil, let runner = activeRunner else { return }
        state.speedTest.phase = .stopping
        speedTestTask?.cancel()
        Task { await runner.cancel() }
    }

    func startCurrentConfigurationTest() {
        if let unavailableReason = currentConfigurationTestUnavailableReason {
            showNotice(unavailableReason, style: .error)
            return
        }
        let selectedIP = state.preferences.selectedIP
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let executableURL = resolvedExecutable(
                preferredPath: state.preferences.cfstPath,
                managedURL: state.runtimeStatus?.cfstURL,
                commandName: "cfst"
            )
        else {
            showNotice("请先安装 CFST 运行组件", style: .error)
            return
        }

        let parameters: SpeedTestParameters
        do {
            parameters = try currentConfigurationTestParameters(for: selectedIP)
        } catch {
            showNotice(error.localizedDescription, style: .error)
            return
        }

        let runID = UUID()
        let resultURL = paths.data.appendingPathComponent(".current-test-\(runID.uuidString).csv")
        let runner = CfstRunner(
            executableURL: executableURL,
            resultURL: resultURL,
            workingDirectoryURL: executableURL.deletingLastPathComponent()
        )
        activeRunner = runner
        activeConfigurationTestID = runID
        state.configurationTest = .init(phase: .running, startedAt: Date())
        appendLog(source: .speedTest, message: "开始测试当前节点：\(selectedIP)")

        configurationTestTask = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: resultURL) }
            do {
                let results = try await runner.run(parameters: parameters) { [weak self] event in
                    await self?.receiveConfigurationTestEvent(event, runID: runID)
                }
                try Task.checkCancellation()
                guard activeConfigurationTestID == runID else { return }
                guard
                    let returnedResult = results.first(where: {
                        Self.ipAddressesAreEquivalent($0.ip, selectedIP)
                    })
                else {
                    throw AppModelError.configurationTestResultMismatch(
                        expected: selectedIP,
                        actual: results.map(\.ip).joined(separator: "、")
                    )
                }
                let result = Self.speedTestResult(returnedResult, replacingIPWith: selectedIP)
                state.configurationTest.result = result
                state.configurationTest.parameters = parameters
                state.configurationTest.completedAt = Date()
                appendLog(source: .speedTest, level: .success, message: "当前节点测速完成")
                showNotice("当前节点测速完成", style: .success)
                finishConfigurationTest(runID: runID, phase: .idle)
            } catch CfstRunnerError.userCancelled {
                guard activeConfigurationTestID == runID else { return }
                appendLog(source: .speedTest, level: .warning, message: "当前节点测速已停止")
                finishConfigurationTest(runID: runID, phase: .idle)
            } catch is CancellationError {
                guard activeConfigurationTestID == runID else { return }
                finishConfigurationTest(runID: runID, phase: .idle)
            } catch {
                guard activeConfigurationTestID == runID else { return }
                appendLog(
                    source: .speedTest,
                    level: .error,
                    message: "当前节点测速失败：\(error.localizedDescription)"
                )
                showNotice("当前节点测速失败：\(error.localizedDescription)", style: .error)
                finishConfigurationTest(runID: runID, phase: .failed(error.localizedDescription))
            }
        }
    }

    func stopCurrentConfigurationTest() {
        guard activeConfigurationTestID != nil, let runner = activeRunner else { return }
        state.configurationTest.phase = .stopping
        configurationTestTask?.cancel()
        Task { await runner.cancel() }
    }

    func selectIP(_ ip: String) {
        if IPv6Address(ip) == nil {
            showNotice("ViaSix 只能应用 IPv6 节点", style: .error)
            return
        }
        guard !isShuttingDown else { return }
        guard state.launchPhase != .loading else {
            showNotice("应用仍在准备，请稍后再试", style: .error)
            return
        }
        guard state.proxySupportsNodeSelection else {
            showNotice(AppModelError.nodeSelectionUnsupported.localizedDescription, style: .error)
            return
        }
        guard
            selectionTask == nil,
            state.templateOperationPhase == .idle,
            activeRunner == nil,
            proxyStartTask == nil,
            proxyStopTask == nil
        else { return }
        switchingIP = ip
        selectionTask = Task { [weak self] in
            await self?.performIPSelection(ip)
        }
    }

    private func performIPSelection(_ ip: String) async {
        defer {
            if switchingIP == ip {
                switchingIP = nil
            }
            selectionTask = nil
        }

        let shouldRestartProxy =
            state.isProxyRunning
            && state.localProxyConfiguration.routingMode != .direct
        if shouldRestartProxy {
            cancelExitIPDetection()
        }
        do {
            try Task.checkCancellation()
            try await applySelection(ip)
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            if isShuttingDown || Task.isCancelled { return }
            appendLog(source: .app, level: .error, message: error.localizedDescription)
            showNotice("切换失败：\(error.localizedDescription)", style: .error)
            return
        }

        appendLog(source: .app, level: .success, message: "已切换节点：\(ip)")
        if shouldRestartProxy, activeProxyCore != nil || state.tun.isRunning {
            state.proxyCorePhase = .stopping
            do {
                try await restartActiveProxy()
            } catch {
                if isShuttingDown || Task.isCancelled { return }
                showNotice("节点已切换，但本地代理重新连接失败", style: .error)
                return
            }
        }
        showNotice("已切换到 \(ip)", style: .success)
    }

    func startProxy() {
        guard systemProxyCleanupTask == nil else {
            showNotice("正在恢复系统代理，请稍候")
            return
        }
        guard
            !isShuttingDown,
            runtimeTask == nil,
            state.templateOperationPhase == .idle,
            !state.isProxyRunning,
            activeProxyCore == nil,
            proxyStartTask == nil,
            proxyStopTask == nil,
            selectionTask == nil,
            tunOperationTask == nil
        else { return }
        guard isProxyConfigurationReady else {
            let message = proxyConfigurationIssue ?? "代理配置正在检查，请稍候"
            showNotice(message, style: .error, action: .openProfiles)
            return
        }
        if effectiveNetworkAccessUsesTun {
            startTunProxy()
            return
        }
        guard
            let executableURL = resolvedExecutable(
                preferredPath: state.preferences.mihomoPath,
                managedURL: state.runtimeStatus?.mihomoIsReady == true
                    ? state.runtimeStatus?.mihomoURL
                    : nil,
                commandName: "mihomo"
            )
        else {
            showNotice("请先安装代理运行组件", style: .error)
            return
        }

        cancelExitIPDetection()
        proxyStopRequested = false
        state.proxyCorePhase = .validating
        proxyStartTask = Task { [weak self] in
            guard let self else { return }
            defer { proxyStartTask = nil }
            var startedController: (any ProxyCoreControlling)?
            do {
                let selectedIP = state.preferences.selectedIP
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let proxyEndpoint = try await bootstrapper.prepareConfigForLaunch(ip: selectedIP)
                try Task.checkCancellation()
                state.proxyEndpoint = proxyEndpoint
                state.proxyConfigurationPhase = .ready
                appendLog(source: .app, message: "已应用当前节点与代理连接配置")

                let controller = proxyCoreControllerFactory(
                    ProxyCoreControllerConfiguration(
                        executableURL: executableURL,
                        configURL: paths.generatedConfig,
                        homeURL: paths.mihomoHome,
                        environment: [:],
                        host: proxyEndpoint.host,
                        port: UInt16(proxyEndpoint.port)
                    ))
                startedController = controller
                let controllerID = UUID()
                activeProxyCore = controller
                activeProxyCoreID = controllerID
                appendLog(source: .proxy, message: "正在检查连接配置并启动本地代理")

                try await controller.start { [weak self] event in
                    await self?.receiveProxyCoreEvent(event, controllerID: controllerID)
                }
                guard activeProxyCoreID == controllerID else { return }
                try await applySystemProxyIfRequested(endpoint: proxyEndpoint)
                guard activeProxyCoreID == controllerID, await controller.isRunning else {
                    throw AppModelError.proxyExitedDuringStart
                }
                if state.proxyCorePhase != .running {
                    state.proxyCorePhase = .running
                }
                syncTrafficMonitoring()
                appendLog(
                    source: .proxy,
                    level: .success,
                    message: "本地代理已启动，监听 \(proxyEndpoint.displayAddress)"
                )
                showNotice("本地代理已启动", style: .success)
                refreshExitIPAfterNetworkChangeIfNeeded()
            } catch MihomoControllerError.cancelled where proxyStopRequested || isShuttingDown {
                await handleCancelledProxyStart(startedController: startedController)
            } catch is CancellationError where proxyStopRequested || isShuttingDown {
                await handleCancelledProxyStart(startedController: startedController)
            } catch {
                if let startedController {
                    await startedController.stop()
                }
                await restoreSystemProxyAfterProxyFailure()
                if let configError = error as? MihomoConfigurationError {
                    state.proxyConfigurationPhase = .needsSetup(configError.localizedDescription)
                }
                state.proxyCorePhase = .failed(error.localizedDescription)
                syncTrafficMonitoring()
                appendLog(source: .proxy, level: .error, message: error.localizedDescription)
                let recoveryAction: AppNotice.Action? =
                    error is MihomoConfigurationError ? .openProfiles : nil
                showNotice(
                    "本地代理启动失败：\(error.localizedDescription)",
                    style: .error,
                    action: recoveryAction
                )
                activeProxyCore = nil
                activeProxyCoreID = nil
            }
        }
    }

    /// Teardown for a cancelled local-proxy start.
    ///
    /// `stopProxy` may have captured a nil controller if cancel raced with the
    /// assignment of `activeProxyCore`. Always stop the controller this start
    /// created when the user requested stop. During shutdown, leave a live
    /// controller for the exit path so system-proxy restore still has a listener.
    private func handleCancelledProxyStart(
        startedController: (any ProxyCoreControlling)?
    ) async {
        if proxyStopRequested {
            if let startedController {
                await startedController.stop()
            }
            activeProxyCore = nil
            activeProxyCoreID = nil
            // `stopProxy` owns the final phase transition (.stopping → .stopped /
            // .running). Avoid forcing .stopped here so a failed restore can
            // still report a live listener.
            syncTrafficMonitoring()
            return
        }

        // Shutdown cancelled the start task. Keep any live controller so
        // `shutdown()` can restore system proxy before deciding whether to stop.
        syncTrafficMonitoring()
    }

    private func startTunProxy() {
        guard !hasForeignTunSession else {
            showNotice(
                "虚拟网卡会话正由其他登录用户使用，当前用户无法启动或接管",
                style: .error,
                action: .openSettings
            )
            return
        }
        guard canUseTunMode else {
            let message: String =
                switch state.tun.servicePhase {
                case .notInstalled:
                    "请先在设置中安装虚拟网卡服务"
                case .requiresApproval:
                    "请先在系统设置中批准虚拟网卡服务"
                case .unavailable(let detail):
                    detail
                case .checking:
                    "正在检查虚拟网卡服务，请稍候"
                case .ready:
                    switch state.tun.runtimePhase {
                    case .notInstalled: "请先安装特权 Mihomo"
                    case .repairRequired: "请先修复特权 Mihomo"
                    case .failed(let detail): detail
                    case .unknown, .installing: "特权 Mihomo 尚未就绪"
                    case .ready: "虚拟网卡能力不完整，请修复服务"
                    }
                }
            showNotice(message, style: .error, action: .openSettings)
            return
        }

        cancelExitIPDetection()
        proxyStopRequested = false
        state.proxyCorePhase = .validating
        state.tun.sessionPhase = .starting
        proxyStartTask = Task { [weak self] in
            guard let self else { return }
            defer { proxyStartTask = nil }
            do {
                let selectedIP = state.preferences.selectedIP
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let endpoint = try await bootstrapper.validateProfileForLaunch(
                    selectedIP: selectedIP
                )
                let envelope = try await bootstrapper.privilegedTunConfigurationEnvelope(
                    selectedIP: selectedIP
                )
                try Task.checkCancellation()
                state.proxyEndpoint = endpoint
                state.proxyCorePhase = .starting
                let snapshot = try await tunCoordinator.startSession(
                    envelopePayload: envelope
                )
                applyTunSnapshot(snapshot)
                guard snapshot.sessionPhase == .running,
                    snapshot.sessionOwnedByCaller
                else {
                    throw AppModelError.virtualInterfaceStartNotConfirmed
                }
                state.proxyCorePhase = .running
                beginTunStatusMonitoring()
                syncTrafficMonitoring()
                try await applySystemProxyIfRequested(endpoint: endpoint)
                appendLog(
                    source: .proxy,
                    level: .success,
                    message: "虚拟网卡已启动，TUN 接管系统流量"
                )
                showNotice("虚拟网卡模式已启用", style: .success)
                refreshExitIPAfterNetworkChangeIfNeeded()
            } catch is CancellationError where proxyStopRequested || isShuttingDown {
                await handleCancelledTunStart()
            } catch {
                await refreshTunState(recoverIfNeeded: false)
                if state.tun.isRunning, state.tun.sessionOwnedByCurrentUser {
                    state.proxyCorePhase = .running
                    beginTunStatusMonitoring()
                    syncTrafficMonitoring()
                    if state.localProxyConfiguration.systemProxyEnabled,
                        case .failed(let message) = state.systemProxyPhase
                    {
                        appendLog(
                            source: .app,
                            level: .error,
                            message: "虚拟网卡已启动，但系统代理启用失败：\(message)"
                        )
                        showNotice("TUN 已启动，但系统代理启用失败：\(message)", style: .error)
                    } else {
                        showNotice("虚拟网卡已启动，但启动确认曾中断", style: .success)
                    }
                    return
                }
                state.tun.sessionPhase = .failed(error.localizedDescription)
                state.proxyCorePhase = .failed(error.localizedDescription)
                syncTrafficMonitoring()
                appendLog(
                    source: .proxy,
                    level: .error,
                    message: "虚拟网卡启动失败：\(error.localizedDescription)"
                )
                showNotice(
                    "虚拟网卡启动失败：\(error.localizedDescription)",
                    style: .error,
                    action: .openSettings
                )
            }
        }
    }

    /// Mirrors local-proxy cancel handling for TUN: stop only when the user
    /// requested stop; leave a live session for the shutdown finalizer.
    private func handleCancelledTunStart() async {
        if proxyStopRequested {
            // `stopTunProxy` owns session teardown and phase transitions.
            syncTrafficMonitoring()
            return
        }
        syncTrafficMonitoring()
    }

    func stopProxy() {
        guard proxyStopTask == nil else { return }
        let isStartingTun = effectiveNetworkAccessUsesTun && proxyStartTask != nil
        if isStartingTun
            || (state.tun.sessionPhase != .inactive
                && state.tun.sessionOwnedByCurrentUser)
        {
            stopTunProxy()
            return
        }
        let controller = activeProxyCore
        let startTask = proxyStartTask
        let pendingSelectionTask = selectionTask
        guard controller != nil || startTask != nil || pendingSelectionTask != nil else { return }

        cancelExitIPDetection()
        proxyStopRequested = true
        state.proxyCorePhase = .stopping
        proxyStopTask = Task { [weak self] in
            guard let self else { return }
            defer {
                proxyStopRequested = false
                proxyStopTask = nil
            }
            do {
                // Restore macOS while the local listener is still alive. If
                // restoration fails, preserving the running listener is safer
                // than leaving system applications pointed at a closed port.
                try await restoreSystemProxyIfNeeded()

                startTask?.cancel()
                pendingSelectionTask?.cancel()
                if let controller {
                    await controller.stop()
                }
                if let startTask {
                    await startTask.value
                }
                if let pendingSelectionTask {
                    await pendingSelectionTask.value
                }
                // Covers a start/stop race where enabling finished after the
                // first restoration check.
                try await restoreSystemProxyIfNeeded()

                activeProxyCore = nil
                activeProxyCoreID = nil
                state.proxyCorePhase = .stopped
                syncTrafficMonitoring()
                appendLog(source: .proxy, level: .warning, message: "本地代理已停止")
                showNotice("本地代理已停止")
                refreshExitIPAfterNetworkChangeIfNeeded()
            } catch {
                let controllerStillRunning = await controller?.isRunning == true
                state.proxyCorePhase = controllerStillRunning ? .running : .failed(error.localizedDescription)
                syncTrafficMonitoring()
                appendLog(
                    source: .app,
                    level: .error,
                    message: "恢复系统代理失败，已取消停止：\(error.localizedDescription)"
                )
                showNotice(
                    "无法恢复系统代理：\(error.localizedDescription)",
                    style: .error
                )
            }
        }
    }

    private func stopTunProxy() {
        let startTask = proxyStartTask
        guard
            startTask != nil
                || (state.tun.sessionPhase != .inactive
                    && state.tun.sessionOwnedByCurrentUser)
        else { return }

        cancelExitIPDetection()
        proxyStopRequested = true
        state.proxyCorePhase = .stopping
        state.tun.sessionPhase = .stopping
        proxyStopTask = Task { [weak self] in
            guard let self else { return }
            defer {
                proxyStopRequested = false
                proxyStopTask = nil
            }
            do {
                try await restoreSystemProxyIfNeeded()
                startTask?.cancel()
                if let startTask {
                    await startTask.value
                }
                let snapshot = try await tunCoordinator.stopSession()
                applyTunSnapshot(snapshot)
                state.proxyCorePhase = .stopped
                stopTunStatusMonitoring()
                syncTrafficMonitoring()
                appendLog(source: .proxy, level: .warning, message: "虚拟网卡已停止")
                showNotice("虚拟网卡模式已停止")
                refreshExitIPAfterNetworkChangeIfNeeded()
            } catch {
                await refreshTunState(recoverIfNeeded: false)
                if state.tun.sessionPhase == .inactive {
                    state.proxyCorePhase = .stopped
                    stopTunStatusMonitoring()
                    syncTrafficMonitoring()
                    return
                }
                state.proxyCorePhase = .failed(error.localizedDescription)
                syncTrafficMonitoring()
                appendLog(
                    source: .app,
                    level: .error,
                    message: "停止虚拟网卡失败：\(error.localizedDescription)"
                )
                showNotice("停止虚拟网卡失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func restartProxy() {
        guard !isShuttingDown,
            runtimeTask == nil,
            state.templateOperationPhase == .idle,
            state.isProxyRunning,
            isProxyConfigurationReady,
            effectiveNetworkAccessUsesTun
                ? state.tun.isRunning : activeProxyCore != nil,
            proxyStartTask == nil,
            proxyStopTask == nil,
            selectionTask == nil
        else { return }
        cancelExitIPDetection()
        state.proxyCorePhase = .stopping
        proxyStartTask = Task { [weak self] in
            guard let self else { return }
            defer { proxyStartTask = nil }
            do {
                try await restartActiveProxy()
                showNotice("本地代理已重新连接", style: .success)
            } catch {
                showNotice("本地代理重新连接失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func detectExitIP() {
        guard !isShuttingDown, detectTask == nil else { return }
        cancelExitIPDetection()
        let detectionID = UUID()
        let context = currentExitIPDetectionContext
        let proxy: ProxyEndpoint? =
            switch context.route {
            case .direct: nil
            case .proxy(let endpoint, _): endpoint
            }
        guard let endpoint = URL(string: context.serviceEndpoint) else {
            state.exit.errorMessage = ExitIPDetectionError.invalidEndpoint.localizedDescription
            showNotice("检测失败：\(ExitIPDetectionError.invalidEndpoint.localizedDescription)", style: .error)
            return
        }

        activeExitDetectionID = detectionID
        state.exit.isDetecting = true
        state.exit.errorMessage = nil
        detectTask = Task { [weak self] in
            guard let self else { return }
            var shouldKeepDetectionGeneration = false
            defer {
                if activeExitDetectionID == detectionID {
                    if !shouldKeepDetectionGeneration {
                        activeExitDetectionID = nil
                    }
                    state.exit.isDetecting = false
                    detectTask = nil
                }
            }
            do {
                let info = try await exitDetector.detect(
                    proxy: proxy,
                    endpoint: endpoint,
                    expectedFamily: context.mode.expectedAddressFamily
                )
                guard activeExitDetectionID == detectionID, !Task.isCancelled else { return }
                state.exit.info = info
                state.exit.detectedAt = Date()
                state.exit.context = context
                shouldKeepDetectionGeneration = true
                appendLog(
                    source: .app,
                    level: .success,
                    message: "出口 IP：\(info.ip)（\(exitIPRouteDescription ?? "未知路径")）"
                )
                startExitIPEnrichment(
                    for: info,
                    proxy: proxy,
                    context: context,
                    detectionID: detectionID
                )
            } catch is CancellationError {
                return
            } catch {
                guard activeExitDetectionID == detectionID, !Task.isCancelled else { return }
                state.exit.errorMessage = error.localizedDescription
                showNotice("检测失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func clearLogs() {
        state.logs.removeAll()
    }

    func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        state.notice = nil
    }

    @discardableResult
    func shutdown() async -> Bool {
        guard !isShuttingDown else { return false }
        isShuttingDown = true

        stopTrafficMonitoring()

        let pendingTasks = [
            bootstrapTask,
            runtimeTask,
            templateImportTask,
            speedTestTask,
            configurationTestTask,
            selectionTask,
            saveTask,
            detectTask,
            exitIPEnrichmentTask,
            noticeTask,
            proxyStartTask,
            proxyStopTask,
            systemProxyTask,
            systemProxyCleanupTask,
            tunOperationTask,
            tunMonitorTask,
            trafficMonitorTask,
            routingModeTask,
        ].compactMap { $0 }
        let pendingTemplateSaveTask = templateSaveTask
        pendingTasks.forEach { $0.cancel() }
        pendingTemplateSaveTask?.cancel()

        if let activeRunner {
            await activeRunner.cancel()
        }

        for task in pendingTasks {
            await task.value
        }
        if let pendingTemplateSaveTask {
            _ = try? await pendingTemplateSaveTask.value
        }
        do {
            // Network tasks are fully settled before this final restore, so no
            // cancelled rollback can re-enable a dead listener afterwards.
            try await restoreSystemProxyIfNeeded()
        } catch {
            appendLog(
                source: .app,
                level: .error,
                message: "退出前恢复系统代理失败：\(error.localizedDescription)"
            )
            isShuttingDown = false
            await reconcileProxyRuntimeAfterFailedShutdown()
            showNotice(
                "无法安全退出：系统代理恢复失败，请修复后重试。\(error.localizedDescription)",
                style: .error
            )
            return false
        }
        if state.tun.sessionPhase != .inactive,
            state.tun.sessionOwnedByCurrentUser
        {
            do {
                let snapshot = try await tunCoordinator.stopSession()
                applyTunSnapshot(snapshot)
                state.proxyCorePhase = .stopped
            } catch {
                await refreshTunState(recoverIfNeeded: false)
                if state.tun.sessionPhase != .inactive {
                    appendLog(
                        source: .app,
                        level: .error,
                        message: "退出前停止虚拟网卡失败：\(error.localizedDescription)"
                    )
                    isShuttingDown = false
                    await reconcileProxyRuntimeAfterFailedShutdown()
                    showNotice(
                        "无法安全退出：虚拟网卡仍在运行。\(error.localizedDescription)",
                        style: .error
                    )
                    return false
                }
            }
        }
        if let activeProxyCore {
            await activeProxyCore.stop()
        }
        await tunCoordinator.invalidate()
        stopTunStatusMonitoring()
        state.templateOperationPhase = .idle
        if state.launchPhase == .ready {
            try? await preferencesStore.save(state.preferences)
        }
        return true
    }

    private func bootstrap() async {
        defer { bootstrapTask = nil }
        do {
            try await bootstrapper.prepareDefaults()
            var systemProxyRecoveryWarning: String?
            var recoveredSystemProxyPhase: AppState.SystemProxyPhase = .disabled
            do {
                let report = try await systemProxyManager.recoverIfNeeded()
                if !report.skippedExternallyModifiedServiceIDs.isEmpty {
                    appendLog(
                        source: .app,
                        level: .warning,
                        message:
                            "启动时检测到其他应用已修改部分系统代理设置，已保留其当前值："
                            + report.skippedExternallyModifiedServiceIDs.joined(separator: "、")
                    )
                }
                if !report.missingServiceIDs.isEmpty {
                    appendLog(
                        source: .app,
                        level: .warning,
                        message:
                            "启动时部分网络服务已不存在，无法恢复其系统代理设置："
                            + report.missingServiceIDs.joined(separator: "、")
                    )
                }
            } catch {
                let warning = "恢复上次系统代理设置失败：\(error.localizedDescription)"
                systemProxyRecoveryWarning = warning
                recoveredSystemProxyPhase = .failed(error.localizedDescription)
                appendLog(
                    source: .app,
                    level: .error,
                    message: warning
                )
            }
            let defaults = UserPreferences(parameters: .defaults(ipv6File: paths.ipv6List))
            let preferencesLoadResult = try await preferencesStore.load(defaults: defaults)
            var preferences = preferencesLoadResult.preferences
            let loadedPreferences = preferences
            var preferencesRecoveryWarning: String?
            if case .recoveredCorruptFile(let backupURL) = preferencesLoadResult.source {
                let warning =
                    "偏好文件无法解析，已在原目录备份为 \(backupURL.lastPathComponent)，本次使用默认设置。"
                preferencesRecoveryWarning = warning
                appendLog(source: .app, level: .warning, message: warning)
            }
            normalizeBundledSourcePath(in: &preferences)
            if preferences.exitIPEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preferences.exitIPEndpoint = AppMetadata.defaultExitIPEndpoint
            }

            async let installedStatus = runtimeManager.installedStatus()
            let loadedResults: [SpeedTestResult]
            do {
                loadedResults = try await bootstrapper.loadResults()
            } catch {
                loadedResults = []
                appendLog(source: .speedTest, level: .warning, message: "忽略了损坏的历史测速结果：\(error.localizedDescription)")
            }
            if loadedResults.isEmpty {
                preferences.lastSuccessfulSpeedTestParameters = nil
            }

            var configurationWarning: String?
            var proxyEndpoint = ProxyEndpoint()
            var localProxyConfiguration = LocalProxyConfiguration()
            var proxyConfigurationPhase: AppState.ProxyConfigurationPhase = .checking
            var proxySupportsNodeSelection = false
            do {
                let configuration = try await bootstrapper.synchronizeConfiguration(
                    selectedIP: preferences.selectedIP
                )
                proxyEndpoint = configuration.endpoint
                localProxyConfiguration = configuration.local
                proxySupportsNodeSelection = configuration.supportsNodeSelection
                if let effectiveIP = configuration.effectiveIP {
                    preferences.selectedIP = effectiveIP
                } else if configuration.local.routingMode != .direct,
                    !configuration.supportsNodeSelection
                {
                    preferences.selectedIP = ""
                }
                if let issue = configuration.launchIssue {
                    proxyConfigurationPhase = .needsSetup(issue.localizedDescription)
                    if issue == .missingProxySource {
                        appendLog(source: .app, message: "代理连接尚未配置，可在设置中导入或编辑配置")
                    } else {
                        configurationWarning = issue.localizedDescription
                        appendLog(
                            source: .app,
                            level: .warning,
                            message: "代理配置需要修复：\(issue.localizedDescription)"
                        )
                    }
                } else {
                    proxyConfigurationPhase = .ready
                }
            } catch {
                configurationWarning = error.localizedDescription
                proxyConfigurationPhase = .needsSetup(error.localizedDescription)
                appendLog(source: .app, level: .warning, message: "代理配置需要修复：\(error.localizedDescription)")
            }

            guard !Task.isCancelled, !isShuttingDown else { return }
            state.preferences = preferences
            state.results = loadedResults
            state.runtimeStatus = await installedStatus
            state.proxyEndpoint = proxyEndpoint
            state.localProxyConfiguration = localProxyConfiguration
            state.proxyConfigurationPhase = proxyConfigurationPhase
            state.proxySupportsNodeSelection = proxySupportsNodeSelection
            state.systemProxyPhase = recoveredSystemProxyPhase
            refreshRuntimePhase()
            state.launchPhase = .ready
            await refreshTunState(recoverIfNeeded: true)
            if state.tun.isRunning, state.tun.sessionOwnedByCurrentUser {
                if localProxyConfiguration.networkAccessMode == .virtualInterface {
                    state.proxyCorePhase = .running
                    beginTunStatusMonitoring()
                    syncTrafficMonitoring()
                    appendLog(source: .app, level: .success, message: "已接管现有虚拟网卡会话")
                    if localProxyConfiguration.systemProxyEnabled {
                        do {
                            try await applySystemProxyIfRequested(endpoint: proxyEndpoint)
                        } catch {
                            appendLog(
                                source: .app,
                                level: .error,
                                message: "接管 TUN 后启用系统代理失败：\(error.localizedDescription)"
                            )
                        }
                    }
                } else {
                    do {
                        applyTunSnapshot(try await tunCoordinator.stopSession())
                    } catch {
                        appendLog(
                            source: .app,
                            level: .error,
                            message: "清理未请求的虚拟网卡会话失败：\(error.localizedDescription)"
                        )
                    }
                }
            }
            if preferences != loadedPreferences || preferencesRecoveryWarning != nil {
                schedulePreferencesSave()
            }
            appendLog(source: .app, level: .success, message: "应用已就绪")
            if let preferencesRecoveryWarning {
                showNotice(preferencesRecoveryWarning)
            }
            if let configurationWarning {
                showNotice(
                    "代理配置需要重新导入或修复：\(configurationWarning)",
                    style: .error,
                    action: .openProfiles
                )
            }
            if let systemProxyRecoveryWarning {
                showNotice(systemProxyRecoveryWarning, style: .error)
            }
        } catch {
            guard !Task.isCancelled, !isShuttingDown else { return }
            state.launchPhase = .failed(error.localizedDescription)
            appendLog(source: .app, level: .error, message: error.localizedDescription)
        }
    }

    private func normalizeBundledSourcePath(in preferences: inout UserPreferences) {
        switch preferences.ipSourceMode {
        case .ipv6:
            preferences.parameters.ipFile = paths.ipv6List.path
            preferences.parameters.ipRange = ""
        case .ipv4:
            preferences.parameters.ipFile = paths.ipv4List.path
            preferences.parameters.ipRange = ""
        case .file:
            if preferences.parameters.ipFile.isEmpty {
                preferences.ipSourceMode = .ipv6
                preferences.parameters.ipFile = paths.ipv6List.path
            }
            preferences.parameters.ipRange = ""
        case .range:
            preferences.parameters.ipFile = ""
        }
    }

    private func refreshRuntimePhase() {
        let cfst = resolvedExecutable(
            preferredPath: state.preferences.cfstPath,
            managedURL: state.runtimeStatus?.cfstURL,
            commandName: "cfst"
        )
        let managedMihomoURL =
            state.runtimeStatus?.mihomoIsReady == true
            ? state.runtimeStatus?.mihomoURL
            : nil
        let mihomo = resolvedExecutable(
            preferredPath: state.preferences.mihomoPath,
            managedURL: managedMihomoURL,
            commandName: "mihomo"
        )
        state.runtimePhase = cfst != nil && mihomo != nil ? .ready : .missing
    }

    private func resolvedExecutable(
        preferredPath: String,
        managedURL: URL?,
        commandName: String
    ) -> URL? {
        var candidates: [URL] = []
        if !preferredPath.isEmpty {
            candidates.append(URL(fileURLWithPath: preferredPath))
        }
        if let managedURL { candidates.append(managedURL) }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(commandName)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(commandName)"))
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(
                contentsOf: path.split(separator: ":").map {
                    URL(fileURLWithPath: String($0)).appendingPathComponent(commandName)
                })
        }
        // Match CFST/Mihomo launch rules: reject symlinks and non-regular files
        // so readiness UI never claims a path the runners will refuse.
        return candidates.first { Self.isLaunchableExecutable(at: $0) }
    }

    private nonisolated static func isLaunchableExecutable(at url: URL) -> Bool {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else { return false }
        let fileType = fileStatus.st_mode & S_IFMT
        guard fileType == S_IFREG else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func currentConfigurationTestParameters(
        for selectedIP: String
    ) throws -> SpeedTestParameters {
        var parameters = state.preferences.parameters

        // A single-node check should report the node even when the full scan's
        // filters would discard it. Keep transport and performance settings,
        // but remove result filters that otherwise turn a valid check into a
        // misleading "no results" failure.
        parameters.ipFile = ""
        parameters.ipRange = selectedIP
        parameters.allIP = false
        parameters.latencyUpperBound = 999_999
        parameters.latencyLowerBound = 0
        parameters.lossRateUpperBound = 1
        parameters.speedLowerBound = 0
        parameters.colo = ""
        // CFST does not create a CSV when a single node is unreachable. Keep
        // its diagnostic reason in the app log so that the resulting
        // no-results message is actionable instead of looking like a file
        // system failure.
        parameters.debug = true
        return try parameters.validated()
    }

    private func prepareForSpeedTestSettingsChange() {
        if activeConfigurationTestID != nil {
            stopCurrentConfigurationTest()
        }
        invalidateConfigurationTestResult()
    }

    private func invalidateConfigurationTestResult() {
        state.configurationTest.result = nil
        state.configurationTest.parameters = nil
        state.configurationTest.completedAt = nil
        if activeConfigurationTestID == nil {
            state.configurationTest.phase = .idle
            state.configurationTest.startedAt = nil
        }
    }

    private nonisolated static func ipAddressesAreEquivalent(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs == rhs { return true }
        if let lhs = IPv4Address(lhs), let rhs = IPv4Address(rhs) {
            return lhs.rawValue == rhs.rawValue
        }
        if let lhs = IPv6Address(lhs), let rhs = IPv6Address(rhs) {
            return lhs.rawValue == rhs.rawValue
        }
        return false
    }

    private nonisolated static func speedTestResult(
        _ result: SpeedTestResult,
        replacingIPWith ip: String
    ) -> SpeedTestResult {
        guard result.ip != ip else { return result }
        return SpeedTestResult(
            ip: ip,
            sent: result.sent,
            received: result.received,
            loss: result.loss,
            latency: result.latency,
            speed: result.speed,
            region: result.region
        )
    }

    private func applySelection(_ ip: String) async throws {
        let normalized = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if state.localProxyConfiguration.routingMode != .direct {
            guard try await bootstrapper.writeConfig(ip: normalized) else {
                state.proxySupportsNodeSelection = false
                throw AppModelError.nodeSelectionUnsupported
            }
        }
        state.preferences.selectedIP = normalized
        invalidateConfigurationTestResult()
        do {
            try await savePreferencesNow()
        } catch {
            appendLog(source: .app, level: .warning, message: "节点已应用，但偏好保存失败：\(error.localizedDescription)")
            schedulePreferencesSave()
        }
    }

    private func updateNodeSelectionCapability(from profileData: Data) {
        let profileSupportsNodeSelection =
            (try? MihomoServerConfiguration(data: profileData).hasReplaceablePrimaryServer) == true
        let isDirect = state.localProxyConfiguration.routingMode == .direct
        state.proxySupportsNodeSelection = !isDirect && profileSupportsNodeSelection
        guard !isDirect, !profileSupportsNodeSelection, !state.preferences.selectedIP.isEmpty else {
            return
        }
        state.preferences.selectedIP = ""
        invalidateConfigurationTestResult()
        schedulePreferencesSave()
    }

    private func refreshNodeSelectionCapability() async {
        guard let profileData = try? await bootstrapper.loadProfileConfiguration() else {
            state.proxySupportsNodeSelection = false
            return
        }
        updateNodeSelectionCapability(from: profileData)
    }

    private func restartActiveProxy() async throws {
        if effectiveNetworkAccessUsesTun {
            try await restartTunSession()
            return
        }
        guard let controller = activeProxyCore, let controllerID = activeProxyCoreID else {
            throw AppModelError.proxyNotActive
        }
        appendLog(source: .proxy, message: "节点已变更，正在重新连接本地代理")
        do {
            try await controller.restart { [weak self] event in
                await self?.receiveProxyCoreEvent(event, controllerID: controllerID)
            }
            guard activeProxyCoreID == controllerID else {
                throw AppModelError.proxyExitedDuringRestart
            }
            if state.proxyCorePhase != .running {
                state.proxyCorePhase = .running
            }
            // Restart emits stopping→running events that tear down and rebuild
            // the traffic subscription. Re-sync after the transition settles so
            // a late stop cannot leave monitoring permanently off.
            syncTrafficMonitoring()
            appendLog(source: .proxy, level: .success, message: "本地代理已应用新节点")
            refreshExitIPAfterNetworkChangeIfNeeded()
        } catch {
            if activeProxyCoreID == controllerID {
                state.proxyCorePhase = .failed(error.localizedDescription)
                appendLog(
                    source: .proxy,
                    level: .error,
                    message: "本地代理重新连接失败：\(error.localizedDescription)"
                )
                activeProxyCore = nil
                activeProxyCoreID = nil
            }
            await restoreSystemProxyAfterProxyFailure()
            throw error
        }
    }

    private func restartTunSession() async throws {
        stopTunStatusMonitoring()
        let selectedIP = state.preferences.selectedIP
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if state.tun.sessionPhase != .inactive {
                guard state.tun.sessionOwnedByCurrentUser else {
                    throw AppModelError.virtualInterfaceOwnedByAnotherUser
                }
                state.tun.sessionPhase = .stopping
                applyTunSnapshot(try await tunCoordinator.stopSession())
            }
            let envelope = try await bootstrapper.privilegedTunConfigurationEnvelope(
                selectedIP: selectedIP
            )
            state.proxyCorePhase = .starting
            state.tun.sessionPhase = .starting
            let snapshot = try await tunCoordinator.startSession(envelopePayload: envelope)
            applyTunSnapshot(snapshot)
            guard snapshot.sessionPhase == .running, snapshot.sessionOwnedByCaller else {
                throw AppModelError.virtualInterfaceStartNotConfirmed
            }
            state.proxyCorePhase = .running
            beginTunStatusMonitoring()
            syncTrafficMonitoring()
            appendLog(source: .proxy, level: .success, message: "虚拟网卡已应用最新配置")
            refreshExitIPAfterNetworkChangeIfNeeded()
        } catch {
            state.proxyCorePhase = .failed(error.localizedDescription)
            state.tun.sessionPhase = .failed(error.localizedDescription)
            stopTunStatusMonitoring()
            syncTrafficMonitoring()
            appendLog(
                source: .proxy,
                level: .error,
                message: "虚拟网卡重新启动失败：\(error.localizedDescription)"
            )
            throw error
        }
    }

    private func beginTunStatusMonitoring() {
        stopTunStatusMonitoring()
        let monitorID = UUID()
        activeTunMonitorID = monitorID
        tunMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                activeTunMonitorID == monitorID,
                effectiveNetworkAccessUsesTun,
                state.proxyCorePhase == .running
            {
                do {
                    try await Task.sleep(for: .seconds(2))
                    let snapshot = try await tunCoordinator.helperStatus()
                    guard !Task.isCancelled, activeTunMonitorID == monitorID else { return }
                    applyTunSnapshot(snapshot)
                    guard snapshot.sessionPhase == .running,
                        snapshot.sessionOwnedByCaller
                    else {
                        let detail = snapshot.lastError ?? "特权 TUN 会话已停止"
                        state.proxyCorePhase = .failed(detail)
                        syncTrafficMonitoring()
                        await restoreSystemProxyAfterProxyFailure()
                        appendLog(source: .proxy, level: .error, message: detail)
                        showNotice("虚拟网卡异常停止：\(detail)", style: .error)
                        activeTunMonitorID = nil
                        tunMonitorTask = nil
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, activeTunMonitorID == monitorID else { return }
                    state.tun.lastError = error.localizedDescription
                    appendLog(
                        source: .app,
                        level: .warning,
                        message: "刷新虚拟网卡状态失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func stopTunStatusMonitoring() {
        activeTunMonitorID = nil
        tunMonitorTask?.cancel()
        tunMonitorTask = nil
    }

    private func syncTrafficMonitoring() {
        if state.isProxyRunning {
            startTrafficMonitoring()
        } else {
            stopTrafficMonitoring()
        }
    }

    /// Restores proxy phase and traffic monitoring after a shutdown attempt that
    /// had to keep the runtime alive (for example system-proxy restore failure).
    private func reconcileProxyRuntimeAfterFailedShutdown() async {
        if let core = activeProxyCore, await core.isRunning {
            state.proxyCorePhase = .running
            syncTrafficMonitoring()
            return
        }

        if state.tun.sessionPhase == .running, state.tun.sessionOwnedByCurrentUser {
            state.proxyCorePhase = .running
            beginTunStatusMonitoring()
            syncTrafficMonitoring()
            return
        }

        if activeProxyCore != nil {
            // Reference without a live process — drop the stale handle so Start
            // is not blocked forever.
            activeProxyCore = nil
            activeProxyCoreID = nil
        }
        if state.proxyCorePhase == .running {
            state.proxyCorePhase = .stopped
        }
        syncTrafficMonitoring()
    }

    private func startTrafficMonitoring() {
        guard !isShuttingDown, state.isProxyRunning else { return }

        // Keep an existing consumer while the proxy stays up. Restarting on
        // every phase echo races with fire-and-forget stops and drops the UI
        // stream after node switches / restarts.
        if trafficMonitorTask != nil, state.traffic.isMonitoring {
            return
        }

        trafficMonitorGeneration += 1
        let generation = trafficMonitorGeneration
        state.traffic.isMonitoring = true
        trafficMonitorTask?.cancel()
        trafficMonitorTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if trafficMonitorGeneration == generation {
                    trafficMonitorTask = nil
                }
            }

            // Serialize against any in-flight stop so a late `stop()` cannot
            // tear down the session we are about to start.
            if let pendingStop = trafficMonitorStopTask {
                await pendingStop.value
                if trafficMonitorGeneration == generation {
                    trafficMonitorStopTask = nil
                }
            }

            guard trafficMonitorGeneration == generation,
                !Task.isCancelled,
                !isShuttingDown,
                state.isProxyRunning
            else { return }

            let apiConfiguration: MihomoAPIConfiguration
            do {
                apiConfiguration = try await bootstrapper.mihomoAPIConfiguration()
            } catch {
                guard trafficMonitorGeneration == generation,
                    !Task.isCancelled,
                    !isShuttingDown
                else { return }
                appendLog(
                    source: .app,
                    level: .warning,
                    message: "无法读取 Controller 配置，流量统计暂不可用：\(error.localizedDescription)"
                )
                state.traffic.isMonitoring = false
                state.traffic.monitorUnavailableReason = error.localizedDescription
                scheduleTrafficMonitoringRetry(after: generation)
                return
            }

            trafficMonitorConfigurationRetries = 0
            state.traffic.monitorUnavailableReason = nil

            guard trafficMonitorGeneration == generation,
                !Task.isCancelled,
                !isShuttingDown,
                state.isProxyRunning
            else { return }

            await trafficMonitor.start(configuration: apiConfiguration)
            guard trafficMonitorGeneration == generation, !Task.isCancelled else {
                await trafficMonitor.stop()
                return
            }

            let stream = trafficMonitor.snapshots()
            for await snapshot in stream {
                guard trafficMonitorGeneration == generation,
                    !Task.isCancelled,
                    !isShuttingDown
                else { break }
                state.traffic.snapshot = snapshot
                state.traffic.isMonitoring = true
            }

            if trafficMonitorGeneration == generation {
                await trafficMonitor.stop()
                if !state.isProxyRunning {
                    state.traffic.isMonitoring = false
                    state.traffic.snapshot = .empty
                }
            }
        }
    }

    /// Bounded retry after a controller-configuration read failure so a
    /// transient error does not leave traffic statistics dead until the next
    /// proxy restart.
    private static let trafficMonitorConfigurationRetryLimit = 3
    private static let trafficMonitorConfigurationRetryDelay = Duration.seconds(3)

    private func scheduleTrafficMonitoringRetry(after generation: Int) {
        guard trafficMonitorConfigurationRetries < Self.trafficMonitorConfigurationRetryLimit
        else { return }
        trafficMonitorConfigurationRetries += 1
        trafficMonitorRetryTask?.cancel()
        trafficMonitorRetryTask = Task { [weak self] in
            guard let self else { return }
            defer { trafficMonitorRetryTask = nil }
            do {
                try await Task.sleep(for: Self.trafficMonitorConfigurationRetryDelay)
            } catch {
                return
            }
            guard trafficMonitorGeneration == generation,
                !isShuttingDown,
                state.isProxyRunning
            else { return }
            startTrafficMonitoring()
        }
    }

    private func stopTrafficMonitoring() {
        trafficMonitorGeneration += 1
        trafficMonitorRetryTask?.cancel()
        trafficMonitorRetryTask = nil
        trafficMonitorConfigurationRetries = 0
        trafficMonitorTask?.cancel()
        trafficMonitorTask = nil
        state.traffic.isMonitoring = false
        state.traffic.snapshot = .empty
        state.traffic.monitorUnavailableReason = nil
        let stopTask = Task { [trafficMonitor] in
            await trafficMonitor.stop()
        }
        trafficMonitorStopTask = stopTask
    }

    private func receiveProxyCoreEvent(_ event: MihomoEvent, controllerID: UUID) {
        guard activeProxyCoreID == controllerID else { return }
        switch event {
        case .stateChanged(let proxyState):
            switch proxyState {
            case .stopped:
                if case .failed = state.proxyCorePhase { return }
                state.proxyCorePhase = .stopped
            case .validating:
                state.proxyCorePhase = .validating
            case .starting:
                state.proxyCorePhase = .starting
            case .running:
                state.proxyCorePhase = .running
            case .stopping:
                state.proxyCorePhase = .stopping
            }
            syncTrafficMonitoring()
        case .log(let line):
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                appendLog(source: .proxy, message: clean)
            }
        case .unexpectedExit(let status, let output):
            cancelExitIPDetection()
            let detail = output.isEmpty ? "状态码 \(status)" : output
            state.proxyCorePhase = .failed("本地代理意外退出：\(detail)")
            syncTrafficMonitoring()
            appendLog(source: .proxy, level: .error, message: "本地代理意外退出：\(detail)")
            showNotice("本地代理意外退出", style: .error)
            activeProxyCore = nil
            activeProxyCoreID = nil
            systemProxyCleanupTask?.cancel()
            systemProxyCleanupTask = Task { [weak self] in
                guard let self else { return }
                defer { systemProxyCleanupTask = nil }
                do {
                    try await restoreSystemProxyIfNeeded()
                } catch {
                    state.systemProxyPhase = .failed(error.localizedDescription)
                    appendLog(
                        source: .app,
                        level: .error,
                        message: "本地代理退出后恢复系统代理失败：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func applySystemProxyIfRequested(endpoint: ProxyEndpoint) async throws {
        guard state.localProxyConfiguration.systemProxyEnabled else {
            try await restoreSystemProxyIfNeeded()
            if case .failed(let message) = state.systemProxyPhase {
                throw AppModelError.systemProxyRecoveryRequired(message)
            }
            return
        }

        state.systemProxyPhase = .enabling
        do {
            _ = try await systemProxyManager.enable(endpoint: endpoint)
            try Task.checkCancellation()
            state.systemProxyPhase = .enabled
            appendLog(
                source: .app,
                level: .success,
                message: "系统代理已启用，使用 \(endpoint.displayAddress)"
            )
        } catch is CancellationError {
            await restoreSystemProxyAfterProxyFailure()
            throw CancellationError()
        } catch {
            state.systemProxyPhase = .failed(error.localizedDescription)
            throw error
        }
    }

    private func restoreSystemProxyIfNeeded() async throws {
        let hasSnapshot = await systemProxyManager.isEnabled()
        guard hasSnapshot else {
            switch state.systemProxyPhase {
            case .enabled, .enabling, .disabling:
                state.systemProxyPhase = .disabled
            case .disabled, .failed:
                break
            }
            return
        }

        state.systemProxyPhase = .disabling
        do {
            let report = try await systemProxyManager.disable()
            state.systemProxyPhase = .disabled
            if !report.skippedExternallyModifiedServiceIDs.isEmpty {
                appendLog(
                    source: .app,
                    level: .warning,
                    message:
                        "部分网络服务已被其他应用修改，ViaSix 未覆盖这些系统代理设置："
                        + report.skippedExternallyModifiedServiceIDs.joined(separator: "、")
                )
            }
            if !report.missingServiceIDs.isEmpty {
                appendLog(
                    source: .app,
                    level: .warning,
                    message:
                        "部分网络服务已不存在，无法恢复其系统代理设置："
                        + report.missingServiceIDs.joined(separator: "、")
                )
            }
        } catch {
            state.systemProxyPhase = .failed(error.localizedDescription)
            throw error
        }
    }

    private func restoreSystemProxyAfterProxyFailure() async {
        do {
            try await restoreSystemProxyIfNeeded()
        } catch {
            state.systemProxyPhase = .failed(error.localizedDescription)
            appendLog(
                source: .app,
                level: .error,
                message: "恢复系统代理失败：\(error.localizedDescription)"
            )
        }
    }

    private func receiveSpeedTestEvent(_ event: CfstOutputEvent, runID: UUID) {
        guard activeSpeedTestID == runID else { return }
        state.speedTest.lastActivityAt = Date()
        switch event {
        case .progress(let current, let total):
            state.speedTest.current = current
            state.speedTest.total = total
        case .heartbeat(let bytes):
            state.speedTest.outputBytes = bytes
        case .line(let line):
            appendLog(source: .speedTest, message: line)
        }
    }

    private func receiveConfigurationTestEvent(_ event: CfstOutputEvent, runID: UUID) {
        guard activeConfigurationTestID == runID else { return }
        if case .line(let line) = event {
            appendLog(source: .speedTest, message: line)
        }
    }

    private func finishSpeedTest(runID: UUID, phase: AppState.SpeedTestPhase) {
        guard activeSpeedTestID == runID else { return }
        state.speedTest.phase = phase
        activeRunner = nil
        activeSpeedTestID = nil
        speedTestTask = nil
    }

    private func finishConfigurationTest(runID: UUID, phase: AppState.SpeedTestPhase) {
        guard activeConfigurationTestID == runID else { return }
        state.configurationTest.phase = phase
        state.configurationTest.startedAt = nil
        activeRunner = nil
        activeConfigurationTestID = nil
        configurationTestTask = nil
    }

    private var currentExitIPDetectionContext: AppState.ExitState.DetectionContext {
        let mode = state.preferences.exitIPDetectionMode
        let endpoint = AppMetadata.exitIPEndpoint(
            for: mode,
            automaticEndpoint: state.preferences.exitIPEndpoint
        )
        let route: AppState.ExitState.DetectionContext.Route =
            if state.isProxyRunning {
                .proxy(
                    endpoint: state.proxyEndpoint,
                    selectedIP: state.preferences.selectedIP
                )
            } else {
                .direct
            }
        return .init(route: route, mode: mode, serviceEndpoint: endpoint)
    }

    private func cancelExitIPDetection() {
        activeExitDetectionID = nil
        detectTask?.cancel()
        exitIPEnrichmentTask?.cancel()
        detectTask = nil
        exitIPEnrichmentTask = nil
        state.exit.isDetecting = false
        state.exit.isEnriching = false
    }

    private func startExitIPEnrichment(
        for info: ExitIPInfo,
        proxy: ProxyEndpoint?,
        context: AppState.ExitState.DetectionContext,
        detectionID: UUID
    ) {
        exitIPEnrichmentTask?.cancel()
        state.exit.isEnriching = true
        exitIPEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if activeExitDetectionID == detectionID {
                    activeExitDetectionID = nil
                    exitIPEnrichmentTask = nil
                    state.exit.isEnriching = false
                }
            }

            do {
                let enrichedInfo = try await exitDetector.enrich(info, proxy: proxy)
                guard
                    activeExitDetectionID == detectionID,
                    !Task.isCancelled,
                    enrichedInfo.ip == info.ip,
                    state.exit.info?.ip == info.ip,
                    state.exit.context == context
                else { return }
                state.exit.info = enrichedInfo
            } catch is CancellationError {
                return
            } catch {
                // Geolocation is best-effort; the primary exit IP remains valid.
                return
            }
        }
    }

    private func refreshExitIPAfterNetworkChangeIfNeeded() {
        guard state.exit.info != nil, detectTask == nil, !isShuttingDown else { return }
        detectExitIP()
    }

    private func schedulePreferencesSave() {
        guard state.launchPhase == .ready, !isShuttingDown else { return }
        saveTask?.cancel()
        let snapshot = state.preferences
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                try await self?.preferencesStore.save(snapshot)
            } catch is CancellationError {
                return
            } catch {
                self?.showNotice("保存设置失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    private func savePreferencesNow() async throws {
        saveTask?.cancel()
        saveTask = nil
        try await preferencesStore.save(state.preferences)
    }

    private func appendLog(
        source: AppLogEntry.Source,
        level: AppLogEntry.Level = .info,
        message: String
    ) {
        state.logs.append(AppLogEntry(source: source, level: level, message: message))
        if state.logs.count > 500 {
            state.logs.removeFirst(state.logs.count - 500)
        }
    }

    private func showNotice(
        _ message: String,
        style: AppNotice.Style = .info,
        action: AppNotice.Action? = nil
    ) {
        guard !isShuttingDown else { return }
        noticeTask?.cancel()
        noticeTask = nil
        let notice = AppNotice(message: message, style: style, action: action)
        state.notice = notice

        // Errors stay visible until dismissed so failures from the menu bar or
        // a background task are not lost when the main window is closed.
        guard style != .error else { return }

        noticeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard self?.state.notice?.id == notice.id else { return }
                self?.state.notice = nil
            } catch {
                return
            }
        }
    }
}

enum AppModelError: LocalizedError, Equatable {
    case appNotReady
    case templateOperationInProgress
    case selectionInProgress
    case runtimeOperationInProgress
    case profileChangedExternally
    case proxyMustBeStopped
    case proxyNotActive
    case proxyExitedDuringStart
    case proxyExitedDuringRestart
    case nodeSelectionUnsupported
    case systemProxyRecoveryRequired(String)
    case virtualInterfaceUnavailable
    case virtualInterfaceOwnedByAnotherUser
    case virtualInterfaceStartNotConfirmed
    case configurationTestResultMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .appNotReady: "应用仍在准备，请稍后再试"
        case .templateOperationInProgress: "另一项代理配置操作尚未完成"
        case .selectionInProgress: "正在应用节点，请等待切换完成后再保存代理配置"
        case .runtimeOperationInProgress: "运行组件操作进行中，请完成后再保存代理配置"
        case .profileChangedExternally: "代理配置已被其他操作修改，请重新载入后再保存"
        case .proxyMustBeStopped: "请先停止本地代理再保存连接配置"
        case .proxyNotActive: "本地代理当前未运行"
        case .proxyExitedDuringStart: "本地代理在系统网络设置完成前已退出"
        case .proxyExitedDuringRestart: "本地代理在重新连接后立即退出"
        case .nodeSelectionUnsupported: "当前代理配置不支持直接应用测速节点"
        case .systemProxyRecoveryRequired(let message): "系统代理尚未安全恢复：\(message)"
        case .virtualInterfaceUnavailable: "虚拟网卡服务尚未就绪"
        case .virtualInterfaceOwnedByAnotherUser: "虚拟网卡会话正由其他登录用户使用"
        case .virtualInterfaceStartNotConfirmed: "虚拟网卡服务未确认 TUN 会话已运行"
        case .configurationTestResultMismatch(let expected, let actual):
            "CFST 返回的节点与当前配置不一致（期望 \(expected)，实际 \(actual)）"
        }
    }
}
