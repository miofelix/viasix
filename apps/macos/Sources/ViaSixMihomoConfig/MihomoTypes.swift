import Foundation

public enum MihomoRoutingMode: String, Codable, CaseIterable, Sendable {
    case rule
    case global
    case direct

    public var displayName: String {
        switch self {
        case .rule: "规则"
        case .global: "全局"
        case .direct: "直连"
        }
    }
}

public enum MihomoLogLevel: String, Codable, CaseIterable, Sendable {
    case silent
    case error
    case warning
    case info
    case debug

    public var displayName: String {
        switch self {
        case .silent: "关闭"
        case .error: "仅错误"
        case .warning: "警告"
        case .info: "信息"
        case .debug: "调试"
        }
    }
}

public enum MihomoProxyProtocol: String, Codable, CaseIterable, Sendable {
    case vless
    case vmess
    case trojan
    case shadowsocks = "ss"

    public var displayName: String {
        switch self {
        case .vless: "VLESS"
        case .vmess: "VMess"
        case .trojan: "Trojan"
        case .shadowsocks: "Shadowsocks"
        }
    }
}

public enum MihomoTransport: String, Codable, CaseIterable, Sendable {
    case websocket = "ws"
    case grpc
    case tcp
    case http
    case h2

    public var displayName: String {
        switch self {
        case .websocket: "WebSocket"
        case .grpc: "gRPC"
        case .tcp: "TCP"
        case .http: "HTTP"
        case .h2: "HTTP/2"
        }
    }
}

public enum MihomoTransportSecurity: String, Codable, CaseIterable, Sendable {
    case tls
    case reality
    case none

    public var displayName: String {
        switch self {
        case .tls: "TLS"
        case .reality: "REALITY"
        case .none: "无"
        }
    }
}

public enum MihomoTunStack: String, Codable, CaseIterable, Sendable {
    case mixed
    case system
    case gvisor

    public var displayName: String {
        switch self {
        case .mixed: "Mixed"
        case .system: "System"
        case .gvisor: "gVisor"
        }
    }
}

/// Selects the trust boundary used when projecting a stored server profile
/// into a runnable Mihomo document.
///
/// User-owned runtime homes must always use ``user``. Only the privileged
/// service may request ``privilegedTun`` and consume the returned document
/// without first writing it into a user-controlled location.
public enum MihomoRuntimeProjection: Equatable, Sendable {
    case user
    case privilegedTun
}

public struct MihomoTunConfiguration: Codable, Equatable, Sendable {
    public var stack: MihomoTunStack
    public var strictRoute: Bool
    public var mtu: Int
    public var routeExcludeAddresses: [String]

    public init(
        stack: MihomoTunStack = .mixed,
        strictRoute: Bool = true,
        mtu: Int = 1_500,
        routeExcludeAddresses: [String] = []
    ) {
        self.stack = stack
        self.strictRoute = strictRoute
        self.mtu = mtu
        self.routeExcludeAddresses = routeExcludeAddresses
    }
}

public struct MihomoRuntimeOptions: Codable, Equatable, Sendable {
    public var listenAddress: String
    public var mixedPort: Int
    public var routingMode: MihomoRoutingMode
    public var logLevel: MihomoLogLevel
    public var ipv6Enabled: Bool
    public var udpEnabled: Bool
    public var sniffingEnabled: Bool
    public var bypassPrivateNetworks: Bool
    public var externalController: MihomoExternalControllerConfiguration?
    public var tun: MihomoTunConfiguration?

    public init(
        listenAddress: String = "127.0.0.1",
        mixedPort: Int = 11_451,
        routingMode: MihomoRoutingMode = .rule,
        logLevel: MihomoLogLevel = .warning,
        ipv6Enabled: Bool = true,
        udpEnabled: Bool = true,
        sniffingEnabled: Bool = true,
        bypassPrivateNetworks: Bool = true,
        externalController: MihomoExternalControllerConfiguration? = nil,
        tun: MihomoTunConfiguration? = nil
    ) {
        self.listenAddress = listenAddress
        self.mixedPort = mixedPort
        self.routingMode = routingMode
        self.logLevel = logLevel
        self.ipv6Enabled = ipv6Enabled
        self.udpEnabled = udpEnabled
        self.sniffingEnabled = sniffingEnabled
        self.bypassPrivateNetworks = bypassPrivateNetworks
        self.externalController = externalController
        self.tun = tun
    }
}

public struct MihomoExternalControllerConfiguration: Codable, Equatable, Sendable {
    public static let maximumSecretUTF8Bytes = 512

    /// Characters accepted in a loopback controller bearer secret.
    ///
    /// Restricted to a token-safe alphabet so the value can be placed in an
    /// HTTP `Authorization` header and Mihomo YAML without control-character
    /// injection (for example CR/LF header splitting).
    private static let allowedSecretScalars = CharacterSet(
        charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/="
    )

    public var port: Int
    public var secret: String

    public init(port: Int, secret: String) {
        self.port = port
        self.secret = secret
    }

    /// Normalizes and validates a controller secret.
    ///
    /// Rejects empty values, oversized secrets, and any character outside the
    /// token-safe alphabet (including whitespace and control characters).
    public static func validatedSecret(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumSecretUTF8Bytes else {
            throw MihomoConfigurationError.invalidControllerSecret
        }
        guard value.unicodeScalars.allSatisfy({ allowedSecretScalars.contains($0) }) else {
            throw MihomoConfigurationError.invalidControllerSecret
        }
        return value
    }
}

public enum MihomoConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidUTF8
    case invalidYAML(String)
    case topLevelMustBeMapping
    case nonStringMappingKey
    case unsupportedValue(String)
    case missingProxySource
    case missingInlineProxy
    case missingSelectedNodeAddress
    case selectedNodeMustBeIPv6
    case ipv6ManagedProfileRequired
    case invalidProxy(String)
    case unsupportedProtocol(String)
    case invalidServerPort
    case missingCredential
    case missingServerName
    case missingRealityPublicKey
    case placeholderConfiguration
    case invalidListenAddress
    case invalidMixedPort
    case invalidControllerPort
    case invalidControllerSecret
    case missingTunConfiguration
    case invalidTunMTU
    case tooManyTunRouteExclusions
    case invalidTunRouteExclusion(String)
    case privilegedEnvelopeTooLarge(Int)
    case invalidPrivilegedEnvelope
    case unsupportedPrivilegedEnvelopeVersion(Int)
    case nonCanonicalPrivilegedEnvelope
    case legacyXrayConfiguration
    case configurationTooLarge(Int)
    case configurationTooDeep
    case configurationTooComplex
    case unsupportedProviderType(name: String, type: String)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            "Mihomo 配置必须使用 UTF-8 编码"
        case .invalidYAML(let detail):
            "Mihomo YAML 无法解析：\(detail)"
        case .topLevelMustBeMapping:
            "Mihomo 配置顶层必须是 YAML 映射"
        case .nonStringMappingKey:
            "Mihomo 配置只允许字符串键名"
        case .unsupportedValue(let description):
            "Mihomo 配置包含不支持的值：\(description)"
        case .missingProxySource:
            "配置至少需要 proxies 或 proxy-providers"
        case .missingInlineProxy:
            "配置没有可由 ViaSix 更新地址的内联代理节点"
        case .missingSelectedNodeAddress:
            "配置不包含节点地址，请先在 ViaSix 中测速并选择一个当前节点"
        case .selectedNodeMustBeIPv6:
            "IPv6 模式需要选择有效的 IPv6 节点"
        case .ipv6ManagedProfileRequired:
            "IPv6 模式需要包含可由 ViaSix 注入地址的内联节点"
        case .invalidProxy(let reason):
            "代理节点配置无效：\(reason)"
        case .unsupportedProtocol(let name):
            "可视化编辑器暂不支持 \(name) 协议，请使用高级 YAML 编辑器"
        case .invalidServerPort:
            "服务器端口必须在 1–65535 之间"
        case .missingCredential:
            "请输入服务器提供的 UUID 或密码"
        case .missingServerName:
            "TLS/REALITY 模式需要填写 Server Name"
        case .missingRealityPublicKey:
            "REALITY 模式需要填写公钥"
        case .placeholderConfiguration:
            "代理连接仍包含示例凭据，请先填写真实服务器配置"
        case .invalidListenAddress:
            "本地监听地址必须是回环地址"
        case .invalidMixedPort:
            "本地 mixed 端口必须在 1–65535 之间"
        case .invalidControllerPort:
            "Mihomo Controller 端口必须在 1–65535 之间，且不能与 mixed 端口相同"
        case .invalidControllerSecret:
            "Mihomo Controller 密钥无效"
        case .missingTunConfiguration:
            "特权 TUN 投影需要明确的 TUN 配置"
        case .invalidTunMTU:
            "TUN MTU 必须在 1280–9000 之间"
        case .tooManyTunRouteExclusions:
            "TUN 路由排除项最多允许 32 条"
        case .invalidTunRouteExclusion(let value):
            "TUN 路由排除项无效或不安全：\(value)"
        case .privilegedEnvelopeTooLarge(let size):
            "特权 TUN 配置 envelope 过大：\(size) 字节"
        case .invalidPrivilegedEnvelope:
            "特权 TUN 配置 envelope 无效"
        case .unsupportedPrivilegedEnvelopeVersion(let version):
            "特权 TUN 配置 envelope 版本不受支持：\(version)"
        case .nonCanonicalPrivilegedEnvelope:
            "特权 TUN 配置 envelope 未通过安全重建"
        case .legacyXrayConfiguration:
            "检测到旧版 Xray JSON，需要先迁移为 Mihomo YAML"
        case .configurationTooLarge(let size):
            "Mihomo 配置过大：\(size) 字节"
        case .configurationTooDeep:
            "Mihomo 配置嵌套层级过深"
        case .configurationTooComplex:
            "Mihomo 配置包含过多节点"
        case .unsupportedProviderType(let name, let type):
            "Provider \(name) 使用了不安全或不支持的类型：\(type)"
        }
    }
}
