import Foundation
import Network
import ViaSixCore

struct AppState: Equatable, Sendable {
    enum LaunchPhase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    enum RuntimePhase: Equatable, Sendable {
        case checking
        case missing
        case ready
    }

    enum ProxyConfigurationPhase: Equatable, Sendable {
        case checking
        case needsSetup(String)
        case ready
    }

    enum RuntimeOperation: Equatable, Sendable {
        case installing(RuntimeComponent, RuntimeInstallationStage)
        case cancelling

        var description: String {
            switch self {
            case .installing(let component, .preparingInstallation):
                "正在准备安装 \(component.displayName)"
            case .installing(_, .downloading(let component)):
                "正在下载 \(component.displayName)"
            case .installing(_, .verifying(let component)):
                "正在校验 \(component.displayName) 的 SHA-256"
            case .installing(_, .extracting(let component)):
                "正在解压 \(component.displayName)"
            case .installing(let component, .committing):
                "正在安装 \(component.displayName)，现有组件会保留到成功"
            case .cancelling:
                "正在取消，现有组件不会被修改"
            }
        }

        var installingComponent: RuntimeComponent? {
            guard case .installing(let component, _) = self else { return nil }
            return component
        }

        var canCancel: Bool {
            switch self {
            case .installing(_, .committing), .cancelling:
                false
            case .installing:
                true
            }
        }
    }

    enum SpeedTestPhase: Equatable, Sendable {
        case idle
        case running
        case stopping
        case failed(String)
    }

    enum ProxyCorePhase: Equatable, Sendable {
        case stopped
        case validating
        case starting
        case running
        case stopping
        case failed(String)
    }

    enum SystemProxyPhase: Equatable, Sendable {
        case disabled
        case enabling
        case enabled
        case disabling
        case failed(String)

        var isTransitioning: Bool {
            switch self {
            case .enabling, .disabling: true
            case .disabled, .enabled, .failed: false
            }
        }
    }

    struct TunState: Equatable, Sendable {
        enum ServicePhase: Equatable, Sendable {
            case checking
            case notInstalled
            case requiresApproval
            case ready
            case unavailable(String)
        }

        enum RuntimePhase: Equatable, Sendable {
            case unknown
            case notInstalled
            case ready
            case repairRequired
            case installing
            case failed(String)
        }

        enum SessionPhase: Equatable, Sendable {
            case inactive
            case starting
            case running
            case stopping
            case recovering
            case recoveryRequired
            case failed(String)

            var isTransitioning: Bool {
                switch self {
                case .starting, .stopping, .recovering: true
                case .inactive, .running, .recoveryRequired, .failed: false
                }
            }

            var isFailed: Bool {
                if case .failed = self { return true }
                return false
            }
        }

        var servicePhase: ServicePhase = .checking
        var runtimePhase: RuntimePhase = .unknown
        var sessionPhase: SessionPhase = .inactive
        var runtimeVersion: String?
        var supportedFeatures: UInt64 = 0
        var sessionIdentifier: UUID?
        var sessionOwnedByCurrentUser = false
        var lastError: String?
        var operationInProgress = false

        var serviceIsReady: Bool {
            servicePhase == .ready
        }

        var runtimeIsReady: Bool {
            runtimePhase == .ready
        }

        var isAvailable: Bool {
            serviceIsReady && runtimeIsReady
        }

        var isRunning: Bool {
            sessionPhase == .running
        }
    }

    enum TemplateOperationPhase: Equatable, Sendable {
        case idle
        case importing
        case saving
    }

    struct SpeedTestState: Equatable, Sendable {
        var phase: SpeedTestPhase = .idle
        var current = 0
        var total = 0
        var outputBytes: Int64 = 0
        var startedAt: Date?
        var lastActivityAt: Date?

        var fractionCompleted: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(current) / Double(total))
        }
    }

    struct ExitState: Equatable, Sendable {
        struct DetectionContext: Equatable, Sendable {
            enum Route: Equatable, Sendable {
                case direct
                case proxy(endpoint: ProxyEndpoint, selectedIP: String)
            }

            let route: Route
            let mode: ExitIPDetectionMode
            let serviceEndpoint: String
        }

        var info: ExitIPInfo?
        var isDetecting = false
        var isEnriching = false
        var errorMessage: String?
        var detectedAt: Date?
        var context: DetectionContext?
    }

    struct ConfigurationTestState: Equatable, Sendable {
        var phase: SpeedTestPhase = .idle
        var result: SpeedTestResult?
        var parameters: SpeedTestParameters?
        var startedAt: Date?
        var completedAt: Date?
    }

    struct TrafficState: Equatable, Sendable {
        var snapshot = TrafficSnapshot.empty
        var isMonitoring = false
        /// Set when the monitor cannot connect (for example the controller
        /// configuration is unreadable) so the UI can explain instead of
        /// showing a perpetual "连接中".
        var monitorUnavailableReason: String?
    }

    var launchPhase: LaunchPhase = .idle
    var preferences: UserPreferences
    var results: [SpeedTestResult] = []
    var runtimePhase: RuntimePhase = .checking
    var runtimeStatus: RuntimeInstallationStatus?
    var runtimeOperation: RuntimeOperation?
    var runtimeOperationError: String?
    var proxyConfigurationPhase: ProxyConfigurationPhase = .checking
    var proxySupportsNodeSelection = false
    var speedTest = SpeedTestState()
    var configurationTest = ConfigurationTestState()
    var proxyCorePhase: ProxyCorePhase = .stopped
    /// Actual macOS proxy state, kept separate from the user's independent
    /// preference (`localProxyConfiguration.systemProxyEnabled`).
    var systemProxyPhase: SystemProxyPhase = .disabled
    var tun = TunState()
    var templateOperationPhase: TemplateOperationPhase = .idle
    var templateOperationError: String?
    var proxyEndpoint = ProxyEndpoint()
    var localProxyConfiguration = LocalProxyConfiguration()
    var exit = ExitState()
    var traffic = TrafficState()
    var logs: [AppLogEntry] = []
    var notice: AppNotice?

    var speedTestResultsAreCurrent: Bool {
        guard !results.isEmpty, let snapshot = preferences.lastSuccessfulSpeedTestParameters else {
            return false
        }
        return snapshot == preferences.parameters
    }

    var selectedResult: SpeedTestResult? {
        guard speedTestResultsAreCurrent else { return nil }
        let selected = preferences.selectedIP
        return results.first { Self.ipAddressesAreEquivalent($0.ip, selected) }
    }

    /// Matches AppModel configuration-test comparison so compressed and expanded
    /// IPv6 spellings of the same address resolve to the same result row.
    private static func ipAddressesAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
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

    var isProxyRunning: Bool {
        proxyCorePhase == .running
    }
}

extension SpeedTestResult {
    var latencyDisplayValue: String? {
        metricDisplayValue(latency, unit: "ms")
    }

    var speedDisplayValue: String? {
        metricDisplayValue(speed, unit: "MB/s")
    }

    var performanceSummary: String {
        [latencyDisplayValue, speedDisplayValue]
            .compactMap { $0 }
            .joined(separator: " · ")
            .ifEmpty("暂无有效测速指标")
    }

    private func metricDisplayValue(_ value: String, unit: String) -> String? {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalizedValue.isEmpty,
            let numericValue = Double(normalizedValue),
            numericValue.isFinite
        else { return nil }
        return "\(normalizedValue) \(unit)"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

struct AppLogEntry: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable {
        case app = "应用"
        case speedTest = "测速"
        case proxy = "代理"
    }

    enum Level: Sendable {
        case info
        case success
        case warning
        case error
    }

    let id: UUID
    let date: Date
    let source: Source
    let level: Level
    let message: String

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        source: Source,
        level: Level = .info,
        message: String
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.level = level
        self.message = message
    }
}

struct AppNotice: Identifiable, Equatable, Sendable {
    enum Style: Sendable {
        case info
        case success
        case error
    }

    enum Action: Equatable, Sendable {
        case openSettings
        case openProfiles
    }

    let id: UUID
    let message: String
    let style: Style
    let action: Action?

    init(
        id: UUID = UUID(),
        message: String,
        style: Style = .info,
        action: Action? = nil
    ) {
        self.id = id
        self.message = message
        self.style = style
        self.action = action
    }
}
