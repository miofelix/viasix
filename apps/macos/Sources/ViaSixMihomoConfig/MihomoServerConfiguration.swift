import Darwin
import Foundation

public struct MihomoServerConfiguration: Equatable, Sendable {
    public static let placeholderCredential = "00000000-0000-0000-0000-000000000000"
    public static let placeholderServerName = "example.com"

    private static let runtimeServerKeys = [
        "proxies",
        "proxy-providers",
        "proxy-groups",
        "rules",
        "rule-providers",
        "sub-rules",
    ]
    private let canonicalData: Data

    public init(data: Data) throws {
        let input = try MihomoYAML.mapping(from: data)
        if input["outbounds"] != nil || input["inbounds"] != nil {
            throw MihomoConfigurationError.legacyXrayConfiguration
        }
        let server = try Self.serverMapping(from: input)
        try Self.validateServerMapping(server)
        canonicalData = try MihomoYAML.data(from: server)
    }

    public init(profile: MihomoProxyProfile) throws {
        let proxy = try profile.mapping()
        let server: [String: Any] = ["proxies": [proxy]]
        try Self.validateServerMapping(server)
        canonicalData = try MihomoYAML.data(from: server)
    }

    public var data: Data { canonicalData }

    public var summary: MihomoProfileSummary {
        let root = rawMapping()
        let proxies = root.mappings("proxies") ?? []
        return MihomoProfileSummary(
            inlineProxyCount: proxies.count,
            providerCount: root.mapping("proxy-providers")?.count ?? 0,
            groupCount: root.mappings("proxy-groups")?.count ?? 0,
            ruleCount: (root["rules"] as? [String])?.count ?? 0,
            primaryProxyName: proxies.first?.string("name")
        )
    }

    /// Whether ViaSix can safely apply a speed-test result by replacing the
    /// first inline proxy's `server` value. Provider-only profiles remain
    /// launchable, but their remote contents are intentionally not rewritten.
    public var hasReplaceablePrimaryServer: Bool {
        Self.primaryServerIndex(in: rawMapping()) != nil
    }

    /// Whether this ViaSix-specific profile intentionally omits its node
    /// address and requires the app's current speed-test selection at runtime.
    public var requiresSelectedPrimaryServer: Bool {
        viaSixOptions?.primaryServer == .selectedIP
    }

    /// Declarative, low-risk ViaSix preferences imported alongside the proxy
    /// profile. Local listeners, controller credentials, system proxy and TUN
    /// settings are deliberately outside this schema.
    public var viaSixOptions: MihomoViaSixProfileOptions? {
        try? Self.viaSixOptions(in: rawMapping())
    }

    /// Distinguishes provider-backed profiles without exposing their raw YAML
    /// representation to callers.
    public var isProviderOnly: Bool {
        let root = rawMapping()
        return !hasReplaceablePrimaryServer && !(root.mapping("proxy-providers") ?? [:]).isEmpty
    }

    public func formattedData() throws -> Data {
        try MihomoYAML.data(from: rawMapping())
    }

    public func primaryProfile() throws -> MihomoProxyProfile {
        guard
            let proxy = rawMapping().mappings("proxies")?.first(where: {
                $0.string("server")?.isEmpty == false
            })
        else {
            throw MihomoConfigurationError.missingInlineProxy
        }
        return try MihomoProxyProfile(mapping: proxy).validated()
    }

    /// Returns the primary profile for guided editing. A ViaSix selected-IP
    /// template does not persist a server address, so the current selection is
    /// injected only into the in-memory editor model.
    public func primaryProfile(replacingSelectedServerWith address: String) throws
        -> MihomoProxyProfile
    {
        guard requiresSelectedPrimaryServer else { return try primaryProfile() }

        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw MihomoConfigurationError.missingSelectedNodeAddress
        }
        let root = rawMapping()
        guard var proxies = root.mappings("proxies"),
            let index = Self.primaryServerIndex(in: root)
        else {
            throw MihomoConfigurationError.missingInlineProxy
        }
        proxies[index]["server"] = normalized
        if proxies[index]["udp"] == nil {
            proxies[index]["udp"] = true
        }
        return try MihomoProxyProfile(mapping: proxies[index]).validated()
    }

    /// Rebuilds the server-only YAML represented by the guided editor while
    /// preserving ViaSix import options. Selected-IP templates intentionally
    /// discard the editor's temporary server address before persistence.
    public func guidedConfiguration(replacingPrimaryProfile profile: MihomoProxyProfile) throws
        -> Self
    {
        var proxy = try profile.mapping()
        if requiresSelectedPrimaryServer {
            proxy.removeValue(forKey: "server")
        }
        var root: [String: Any] = ["proxies": [proxy]]
        if let options = viaSixOptions {
            root["x-viasix"] = options.canonicalMapping
        }
        return try Self(data: MihomoYAML.data(from: root))
    }

    /// Checks whether guided editing can round-trip the complete stored
    /// configuration. Older selected-IP templates omitted `udp`; treat that as
    /// the value declared by x-viasix (or Mihomo's default) during comparison.
    public func isRepresentedByGuidedConfiguration(_ guided: Self) -> Bool {
        var sourceRoot = rawMapping()
        if requiresSelectedPrimaryServer,
            var proxies = sourceRoot.mappings("proxies"),
            let index = Self.primaryServerIndex(in: sourceRoot),
            proxies[index]["udp"] == nil
        {
            proxies[index]["udp"] = true
            sourceRoot["proxies"] = proxies
        }
        return NSDictionary(dictionary: sourceRoot).isEqual(to: guided.rawMapping())
    }

    public func replacingPrimaryServer(with address: String) throws -> Self {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw MihomoConfigurationError.invalidProxy("服务器地址为空")
        }
        var root = rawMapping()
        guard var proxies = root.mappings("proxies"),
            let index = Self.primaryServerIndex(in: root)
        else {
            throw MihomoConfigurationError.missingInlineProxy
        }
        proxies[index]["server"] = normalized
        root["proxies"] = proxies
        return try Self(data: MihomoYAML.data(from: root))
    }

    public func runtimeConfiguration(
        options: MihomoRuntimeOptions,
        projection: MihomoRuntimeProjection = .user,
        replacingPrimaryServerWith address: String? = nil
    ) throws -> Data {
        try Self.runtimeConfiguration(
            server: self,
            options: options,
            projection: projection,
            replacingPrimaryServerWith: address
        )
    }

    public static func runtimeConfiguration(
        server: Self?,
        options: MihomoRuntimeOptions,
        projection: MihomoRuntimeProjection = .user,
        replacingPrimaryServerWith address: String? = nil
    ) throws -> Data {
        try validate(options: options, projection: projection)

        var serverRoot: [String: Any] = [:]
        if options.routingMode != .direct {
            guard let server, server.hasReplaceablePrimaryServer else {
                throw MihomoConfigurationError.ipv6ManagedProfileRequired
            }
            let selectedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines)
            let storedAddress = server.rawMapping().mappings("proxies")?
                .first(where: { $0.string("server")?.isEmpty == false })?
                .string("server")
            let managedAddress: String
            if let selectedAddress, !selectedAddress.isEmpty {
                guard isIPv6Address(selectedAddress) else {
                    throw MihomoConfigurationError.selectedNodeMustBeIPv6
                }
                managedAddress = selectedAddress
            } else if let storedAddress, isIPv6Address(storedAddress) {
                managedAddress = storedAddress
            } else {
                throw MihomoConfigurationError.selectedNodeMustBeIPv6
            }
            serverRoot = try ipv6ManagedServerMapping(
                from: server,
                replacingPrimaryServerWith: managedAddress
            )
            try validateServerMapping(serverRoot)
        }
        if projection == .privilegedTun {
            serverRoot = try privilegedServerMapping(from: serverRoot)
        }
        return try composeRuntime(
            server: serverRoot,
            options: options,
            projection: projection
        )
    }

    public static func proxyServerAddress(in data: Data) -> String? {
        guard let configuration = try? Self(data: data) else { return nil }
        return configuration.rawMapping().mappings("proxies")?
            .first(where: { $0.string("server")?.isEmpty == false })?
            .string("server")
    }

    private func rawMapping() -> [String: Any] {
        // `canonicalData` was produced by this module and failure here would
        // indicate a programmer error rather than malformed user input.
        (try? MihomoYAML.mapping(from: canonicalData)) ?? [:]
    }

    private static func ipv6ManagedServerMapping(
        from server: Self,
        replacingPrimaryServerWith address: String
    ) throws -> [String: Any] {
        let root = server.rawMapping()
        guard let proxies = root.mappings("proxies"),
            let index = primaryServerIndex(in: root)
        else {
            throw MihomoConfigurationError.ipv6ManagedProfileRequired
        }
        var primary = proxies[index]
        primary["server"] = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["proxies": [primary]]
    }

    private static func isIPv6Address(_ value: String) -> Bool {
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) == 1 }) else {
            return false
        }
        // Reject IPv4-mapped IPv6 (::ffff:a.b.c.d): the first 10 bytes are zero
        // followed by 0xff 0xff. These embed an IPv4 endpoint rather than a real
        // IPv6 exit, so the contract rejects them on every platform.
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let isV4Mapped =
            bytes.count == 16
            && bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
        return !isV4Mapped
    }

    private static func serverMapping(from input: [String: Any]) throws -> [String: Any] {
        if input["name"] != nil,
            input["type"] != nil,
            runtimeServerKeys.allSatisfy({ input[$0] == nil }),
            input["x-viasix"] == nil
        {
            return ["proxies": [input]]
        }

        var server: [String: Any] = [:]
        for key in runtimeServerKeys {
            if let value = input[key] {
                server[key] = value
            }
        }
        if let providers = input.mapping("proxy-providers") {
            server["proxy-providers"] = try sanitizedProviders(
                providers,
                directory: "providers"
            )
        }
        if let providers = input.mapping("rule-providers") {
            server["rule-providers"] = try sanitizedProviders(
                providers,
                directory: "rules"
            )
        }
        if let options = try viaSixOptions(in: input) {
            server["x-viasix"] = options.canonicalMapping
        }
        guard !server.isEmpty else {
            throw MihomoConfigurationError.missingProxySource
        }
        return server
    }

    private static func validateServerMapping(_ root: [String: Any]) throws {
        let options = try viaSixOptions(in: root)
        if let rawRules = root["rules"], !(rawRules is [String]) {
            throw MihomoConfigurationError.unsupportedValue("rules 必须是字符串列表")
        }

        let proxies = root.mappings("proxies") ?? []
        let providers = root.mapping("proxy-providers") ?? [:]
        guard !proxies.isEmpty || !providers.isEmpty else {
            throw MihomoConfigurationError.missingProxySource
        }

        var names = Set<String>()
        let primaryServerIndex = primaryServerIndex(in: root)
        if options?.primaryServer == .selectedIP, primaryServerIndex == nil {
            throw MihomoConfigurationError.invalidProxy(
                "x-viasix.primary-server 需要一个可注入地址的内联节点"
            )
        }

        for (index, proxy) in proxies.enumerated() {
            guard let name = proxy.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty,
                let type = proxy.string("type")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !type.isEmpty
            else {
                throw MihomoConfigurationError.invalidProxy("节点必须包含非空 name 和 type")
            }
            guard names.insert(name).inserted else {
                throw MihomoConfigurationError.invalidProxy("节点名称重复：\(name)")
            }

            let hasServer = proxy["server"] != nil
            let hasPort = proxy["port"] != nil
            if options?.primaryServer == .selectedIP,
                index == primaryServerIndex,
                !hasServer
            {
                guard let port = proxy.int("port"), (1...65_535).contains(port) else {
                    throw MihomoConfigurationError.invalidProxy(
                        "由 ViaSix 注入地址的节点必须包含有效 port"
                    )
                }
                if proxyContainsPlaceholder(proxy) {
                    throw MihomoConfigurationError.placeholderConfiguration
                }
                continue
            }
            if hasServer || hasPort {
                guard
                    let server = proxy.string("server")?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    !server.isEmpty,
                    let port = proxy.int("port"),
                    (1...65_535).contains(port)
                else {
                    throw MihomoConfigurationError.invalidProxy(
                        "节点必须包含 server 和有效 port"
                    )
                }
            }
            if proxyContainsPlaceholder(proxy) {
                throw MihomoConfigurationError.placeholderConfiguration
            }
        }
    }

    private static func composeRuntime(
        server: [String: Any],
        options: MihomoRuntimeOptions,
        projection: MihomoRuntimeProjection
    ) throws -> Data {
        var runtime: [String: Any] = [
            "mixed-port": options.mixedPort,
            "allow-lan": false,
            "bind-address": options.listenAddress,
            "mode": options.routingMode.rawValue,
            "log-level": options.logLevel.rawValue,
            "ipv6": options.ipv6Enabled,
            "unified-delay": true,
            "tcp-concurrent": true,
            "profile": [
                "store-selected": false,
                "store-fake-ip": projection == .privilegedTun,
            ],
        ]

        if let controller = options.externalController {
            runtime["external-controller"] = "127.0.0.1:\(controller.port)"
            runtime["secret"] = try MihomoExternalControllerConfiguration.validatedSecret(
                controller.secret
            )
        }

        if options.routingMode != .direct {
            // The IPv6 projection above retains only the selected inline proxy.
            for key in runtimeServerKeys where server[key] != nil {
                runtime[key] = server[key]
            }
        }

        if var proxies = runtime.mappings("proxies") {
            for index in proxies.indices {
                let proxyAllowsUDP = proxies[index].bool("udp") ?? true
                proxies[index]["udp"] = options.udpEnabled && proxyAllowsUDP
            }
            runtime["proxies"] = proxies
        }

        if options.sniffingEnabled {
            runtime["sniffer"] = [
                "enable": true,
                "force-dns-mapping": true,
                "parse-pure-ip": true,
                "override-destination": true,
                "sniff": [
                    "HTTP": [
                        "ports": ["80", "8080-8880"],
                        "override-destination": true,
                    ],
                    "TLS": ["ports": ["443", "8443"]],
                    "QUIC": ["ports": ["443", "8443"]],
                ],
            ]
        }

        try installIPv6ManagedPolicy(in: &runtime, routingMode: options.routingMode)

        if projection == .privilegedTun {
            guard let tun = options.tun else {
                throw MihomoConfigurationError.missingTunConfiguration
            }
            var tunMapping: [String: Any] = [
                "enable": true,
                "stack": tun.stack.rawValue,
                "auto-route": true,
                "strict-route": tun.strictRoute,
                "auto-detect-interface": true,
                "dns-hijack": ["any:53", "tcp://any:53"],
                "mtu": tun.mtu,
            ]
            if !tun.routeExcludeAddresses.isEmpty {
                tunMapping["route-exclude-address"] = tun.routeExcludeAddresses
            }
            runtime["tun"] = tunMapping
            runtime["dns"] = [
                "enable": true,
                "ipv6": options.ipv6Enabled,
                "enhanced-mode": "fake-ip",
                "fake-ip-range": "198.18.0.1/16",
                "fake-ip-range6": "fdfe:dcba:9876::1/64",
                "respect-rules": true,
                "default-nameserver": ["1.1.1.1", "8.8.8.8"],
                "nameserver": [
                    "https://1.1.1.1/dns-query",
                    "https://8.8.8.8/dns-query",
                ],
                "proxy-server-nameserver": [
                    "https://1.1.1.1/dns-query",
                    "https://8.8.8.8/dns-query",
                ],
            ]
        } else {
            runtime["tun"] = ["enable": false]
        }

        return try MihomoYAML.data(from: runtime, header: "Generated by ViaSix for Mihomo")
    }

    private static func installIPv6ManagedPolicy(
        in runtime: inout [String: Any],
        routingMode: MihomoRoutingMode
    ) throws {
        runtime.removeValue(forKey: "proxy-providers")
        runtime.removeValue(forKey: "proxy-groups")
        runtime.removeValue(forKey: "rule-providers")
        runtime.removeValue(forKey: "sub-rules")

        if routingMode == .direct {
            runtime.removeValue(forKey: "proxies")
            runtime["rules"] = ["MATCH,DIRECT"]
            return
        }

        guard let target = runtime.mappings("proxies")?.first?.string("name"),
            !target.isEmpty
        else {
            throw MihomoConfigurationError.ipv6ManagedProfileRequired
        }

        if routingMode == .global {
            runtime.removeValue(forKey: "rules")
            return
        }

        runtime["rules"] = [
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR6,::1/128,DIRECT,no-resolve",
            "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
            "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
            "MATCH,\(target)",
        ]
    }

    private static func validate(
        options: MihomoRuntimeOptions,
        projection: MihomoRuntimeProjection
    ) throws {
        guard isLoopbackHost(options.listenAddress) else {
            throw MihomoConfigurationError.invalidListenAddress
        }
        guard (1...65_535).contains(options.mixedPort) else {
            throw MihomoConfigurationError.invalidMixedPort
        }
        if let controller = options.externalController {
            guard (1...65_535).contains(controller.port), controller.port != options.mixedPort else {
                throw MihomoConfigurationError.invalidControllerPort
            }
            _ = try MihomoExternalControllerConfiguration.validatedSecret(controller.secret)
        }
        if projection == .privilegedTun {
            guard let tun = options.tun else {
                throw MihomoConfigurationError.missingTunConfiguration
            }
            guard (1_280...9_000).contains(tun.mtu) else {
                throw MihomoConfigurationError.invalidTunMTU
            }
            guard tun.routeExcludeAddresses.count <= 32 else {
                throw MihomoConfigurationError.tooManyTunRouteExclusions
            }
            for route in tun.routeExcludeAddresses {
                guard isSafeTunRouteExclusion(route) else {
                    throw MihomoConfigurationError.invalidTunRouteExclusion(route)
                }
            }
        }
    }

    private static func isLoopbackHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host == "localhost" || host == "::1" { return true }

        var address = in_addr()
        let isIPv4 = host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
        guard isIPv4 else { return false }
        return (UInt32(bigEndian: address.s_addr) >> 24) == 127
    }

    private static func proxyContainsPlaceholder(_ proxy: [String: Any]) -> Bool {
        for key in ["uuid", "password"] {
            if proxy.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == placeholderCredential
            {
                return true
            }
        }
        for key in ["servername", "sni"] {
            if proxy.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == placeholderServerName
            {
                return true
            }
        }
        return false
    }

    private static func primaryServerIndex(in root: [String: Any]) -> Int? {
        guard let proxies = root.mappings("proxies") else { return nil }
        if let index = proxies.firstIndex(where: {
            $0.string("server")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                == false
        }) {
            return index
        }
        guard (try? viaSixOptions(in: root))?.primaryServer == .selectedIP else {
            return nil
        }
        let serverlessTypes: Set<String> = ["direct", "reject", "dns"]
        return proxies.firstIndex { proxy in
            guard let type = proxy.string("type")?.lowercased() else { return false }
            return !serverlessTypes.contains(type)
        }
    }

    private static func viaSixOptions(
        in root: [String: Any]
    ) throws -> MihomoViaSixProfileOptions? {
        guard let raw = root["x-viasix"] else { return nil }
        guard let mapping = raw as? [String: Any] else {
            throw MihomoConfigurationError.unsupportedValue("x-viasix 必须是映射")
        }
        return try MihomoViaSixProfileOptions(mapping: mapping)
    }

    private static func sanitizedProviders(
        _ providers: [String: Any],
        directory: String
    ) throws -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for name in providers.keys.sorted() {
            guard var provider = providers[name] as? [String: Any] else {
                throw MihomoConfigurationError.invalidProxy("Provider \(name) 不是映射")
            }
            let type = provider.string("type")?.lowercased() ?? "http"
            switch type {
            case "http":
                provider["path"] = "\(directory)/\(safeProviderFileName(name)).yaml"
            case "inline":
                provider.removeValue(forKey: "path")
            default:
                throw MihomoConfigurationError.unsupportedProviderType(
                    name: name,
                    type: type
                )
            }
            sanitized[name] = provider
        }
        return sanitized
    }

    private static func safeProviderFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let stem = String(
            name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        ).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let prefix = stem.isEmpty ? "provider" : String(stem.prefix(64))
        return "\(prefix)-\(String(hash, radix: 16))"
    }
}

public enum MihomoPrimaryServerSource: String, Equatable, Sendable {
    case selectedIP = "selected-ip"
}

public struct MihomoViaSixProfileOptions: Equatable, Sendable {
    public let version: Int
    public let primaryServer: MihomoPrimaryServerSource?

    fileprivate init(mapping: [String: Any]) throws {
        let supportedKeys: Set<String> = [
            "version",
            "primary-server",
        ]
        if let unsupported = mapping.keys.sorted().first(where: { !supportedKeys.contains($0) }) {
            throw MihomoConfigurationError.unsupportedValue(
                "x-viasix.\(unsupported) 不允许覆盖本机安全设置"
            )
        }
        guard mapping.int("version") == 1 else {
            throw MihomoConfigurationError.unsupportedValue("x-viasix.version 必须为 1")
        }
        version = 1

        if let value = mapping["primary-server"] {
            guard let raw = value as? String,
                let source = MihomoPrimaryServerSource(rawValue: raw.lowercased())
            else {
                throw MihomoConfigurationError.unsupportedValue(
                    "x-viasix.primary-server 仅支持 selected-ip"
                )
            }
            primaryServer = source
        } else {
            primaryServer = nil
        }

    }

    fileprivate var canonicalMapping: [String: Any] {
        var mapping: [String: Any] = ["version": version]
        if let primaryServer { mapping["primary-server"] = primaryServer.rawValue }
        return mapping
    }
}

public struct MihomoProfileSummary: Equatable, Sendable {
    public let inlineProxyCount: Int
    public let providerCount: Int
    public let groupCount: Int
    public let ruleCount: Int
    public let primaryProxyName: String?

    public init(
        inlineProxyCount: Int,
        providerCount: Int,
        groupCount: Int,
        ruleCount: Int,
        primaryProxyName: String?
    ) {
        self.inlineProxyCount = inlineProxyCount
        self.providerCount = providerCount
        self.groupCount = groupCount
        self.ruleCount = ruleCount
        self.primaryProxyName = primaryProxyName
    }
}
