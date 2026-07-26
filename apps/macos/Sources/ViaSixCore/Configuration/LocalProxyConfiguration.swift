import Darwin
import Foundation

/// Log verbosity shared by the application's proxy-core integrations.
public enum ProxyLogLevel: String, Codable, CaseIterable, Sendable {
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

/// Determines how traffic entering the local mixed proxy is routed.
public enum ProxyRoutingMode: String, Codable, CaseIterable, Sendable {
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

public enum LocalProxyConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidListenAddress
    case invalidPort
    case invalidControllerPort
    case conflictingControllerPort
    case invalidTunMTU

    public var errorDescription: String? {
        switch self {
        case .invalidListenAddress:
            "本地监听地址必须是 127.0.0.0/8、::1 或 localhost"
        case .invalidPort:
            "本地监听端口必须在 1–65535 之间"
        case .invalidControllerPort:
            "内核控制端口必须在 1–65535 之间"
        case .conflictingControllerPort:
            "内核控制端口不能与本地代理端口相同"
        case .invalidTunMTU:
            "TUN MTU 必须在 1280–9000 之间"
        }
    }
}

public struct LocalProxyConfiguration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public var listenAddress: String
    public var port: Int
    public var controllerPort: Int
    public var udpEnabled: Bool
    public var sniffingEnabled: Bool
    public var bypassPrivateNetworks: Bool
    public var logLevel: ProxyLogLevel
    public var routingMode: ProxyRoutingMode
    public var networkAccessMode: NetworkAccessMode
    public var systemProxyEnabled: Bool
    public var tunStack: VirtualInterfaceStack
    public var tunMTU: Int
    public var tunStrictRoute: Bool

    public init(
        listenAddress: String = AppMetadata.proxyHost,
        port: Int = AppMetadata.proxyPort,
        controllerPort: Int = AppMetadata.controllerPort,
        udpEnabled: Bool = true,
        sniffingEnabled: Bool = true,
        bypassPrivateNetworks: Bool = true,
        logLevel: ProxyLogLevel = .warning,
        routingMode: ProxyRoutingMode = .rule,
        networkAccessMode: NetworkAccessMode = .virtualInterface,
        systemProxyEnabled: Bool = false,
        tunStack: VirtualInterfaceStack = .mixed,
        tunMTU: Int = 1_500,
        tunStrictRoute: Bool = true
    ) {
        version = Self.schemaVersion
        self.listenAddress = listenAddress
        self.port = port
        self.controllerPort = controllerPort
        self.udpEnabled = udpEnabled
        self.sniffingEnabled = sniffingEnabled
        self.bypassPrivateNetworks = bypassPrivateNetworks
        self.logLevel = logLevel
        self.routingMode = routingMode
        self.networkAccessMode = networkAccessMode
        self.systemProxyEnabled = systemProxyEnabled
        self.tunStack = tunStack
        self.tunMTU = tunMTU
        self.tunStrictRoute = tunStrictRoute
    }

    public static let `default` = Self()

    private enum CodingKeys: String, CodingKey {
        case version
        case listenAddress
        case port
        case controllerPort
        case udpEnabled
        case sniffingEnabled
        case bypassPrivateNetworks
        case logLevel
        case routingMode
        case networkAccessMode
        case systemProxyEnabled
        case tunStack
        case tunMTU
        case tunStrictRoute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported local proxy configuration version: \(version)"
            )
        }
        listenAddress = try container.decode(String.self, forKey: .listenAddress)
        port = try container.decode(Int.self, forKey: .port)
        controllerPort = try container.decode(Int.self, forKey: .controllerPort)
        udpEnabled = try container.decode(Bool.self, forKey: .udpEnabled)
        sniffingEnabled = try container.decode(Bool.self, forKey: .sniffingEnabled)
        bypassPrivateNetworks = try container.decode(Bool.self, forKey: .bypassPrivateNetworks)
        logLevel = try container.decode(ProxyLogLevel.self, forKey: .logLevel)
        routingMode = try container.decode(ProxyRoutingMode.self, forKey: .routingMode)
        networkAccessMode = try container.decode(NetworkAccessMode.self, forKey: .networkAccessMode)
        systemProxyEnabled = try container.decode(Bool.self, forKey: .systemProxyEnabled)
        tunStack = try container.decode(VirtualInterfaceStack.self, forKey: .tunStack)
        tunMTU = try container.decode(Int.self, forKey: .tunMTU)
        tunStrictRoute = try container.decode(Bool.self, forKey: .tunStrictRoute)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(listenAddress, forKey: .listenAddress)
        try container.encode(port, forKey: .port)
        try container.encode(controllerPort, forKey: .controllerPort)
        try container.encode(udpEnabled, forKey: .udpEnabled)
        try container.encode(sniffingEnabled, forKey: .sniffingEnabled)
        try container.encode(bypassPrivateNetworks, forKey: .bypassPrivateNetworks)
        try container.encode(logLevel, forKey: .logLevel)
        try container.encode(routingMode, forKey: .routingMode)
        try container.encode(networkAccessMode, forKey: .networkAccessMode)
        try container.encode(systemProxyEnabled, forKey: .systemProxyEnabled)
        try container.encode(tunStack, forKey: .tunStack)
        try container.encode(tunMTU, forKey: .tunMTU)
        try container.encode(tunStrictRoute, forKey: .tunStrictRoute)
    }

    public func validated() throws -> LocalProxyConfiguration {
        var copy = self
        copy.listenAddress = copy.listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard Self.isLoopbackHost(copy.listenAddress) else {
            throw LocalProxyConfigurationError.invalidListenAddress
        }
        guard (1...65_535).contains(copy.port) else {
            throw LocalProxyConfigurationError.invalidPort
        }
        guard (1...65_535).contains(copy.controllerPort) else {
            throw LocalProxyConfigurationError.invalidControllerPort
        }
        guard copy.controllerPort != copy.port else {
            throw LocalProxyConfigurationError.conflictingControllerPort
        }
        guard (1_280...9_000).contains(copy.tunMTU) else {
            throw LocalProxyConfigurationError.invalidTunMTU
        }
        return copy
    }

    public var endpoint: ProxyEndpoint {
        ProxyEndpoint(host: listenAddress, port: port)
    }

    static func isLoopbackHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host == "localhost" || host == "::1" { return true }

        var address = in_addr()
        let isIPv4 = host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
        guard isIPv4 else { return false }
        return (UInt32(bigEndian: address.s_addr) >> 24) == 127
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
