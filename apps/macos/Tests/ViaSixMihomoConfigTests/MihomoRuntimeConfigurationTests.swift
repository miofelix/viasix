import Foundation
import XCTest

@testable import ViaSixMihomoConfig

final class MihomoRuntimeConfigurationTests: XCTestCase {
    func testIPv6RuntimeRejectsIPv4SelectionAndProviderOnlyProfile() throws {
        XCTAssertThrowsError(
            try sampleServer().runtimeConfiguration(
                options: MihomoRuntimeOptions(),
                replacingPrimaryServerWith: "203.0.113.8"
            )
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .selectedNodeMustBeIPv6)
        }

        let providerOnly = try MihomoServerConfiguration(
            data: Data(
                """
                proxy-providers:
                  remote:
                    type: http
                    url: https://subscription.example/profile.yaml
                    path: remote.yaml
                proxy-groups:
                  - name: PROXY
                    type: select
                    use: [remote]
                rules:
                  - MATCH,PROXY
                """.utf8
            )
        )
        XCTAssertThrowsError(
            try providerOnly.runtimeConfiguration(
                options: MihomoRuntimeOptions(),
                replacingPrimaryServerWith: "2606:4700::8"
            )
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .ipv6ManagedProfileRequired)
        }
    }

    func testIPv6RuntimeKeepsOnlyPrimaryProxyAndManagedRules() throws {
        let server = try MihomoServerConfiguration(
            data: Data(
                """
                proxies:
                  - name: primary-edge
                    type: vless
                    server: origin.example
                    port: 443
                    uuid: 11111111-1111-4111-8111-111111111111
                  - name: unused-edge
                    type: ss
                    server: unused.example
                    port: 8388
                    cipher: aes-128-gcm
                    password: secret
                proxy-providers:
                  remote:
                    type: inline
                    payload:
                      - name: provider-edge
                        type: ss
                        server: provider.example
                        port: 8388
                        cipher: aes-128-gcm
                        password: secret
                proxy-groups:
                  - name: IMPORTED
                    type: select
                    proxies: [primary-edge, unused-edge]
                rule-providers:
                  domains:
                    type: inline
                    behavior: domain
                    payload: [example.com]
                sub-rules:
                  imported:
                    - DOMAIN,example.com,DIRECT
                rules:
                  - DOMAIN-SUFFIX,example.com,DIRECT
                  - MATCH,IMPORTED
                """.utf8
            )
        )

        let root = try MihomoYAML.mapping(
            from: server.runtimeConfiguration(
                options: MihomoRuntimeOptions(
                    routingMode: .global
                ),
                replacingPrimaryServerWith: "2606:4700::8"
            )
        )

        let proxies = try XCTUnwrap(root.mappings("proxies"))
        XCTAssertEqual(proxies.count, 1)
        XCTAssertEqual(proxies.first?.string("name"), "primary-edge")
        XCTAssertEqual(proxies.first?.string("server"), "2606:4700::8")
        XCTAssertEqual(root.string("mode"), "global")
        XCTAssertNil(root["proxy-providers"])
        XCTAssertNil(root["proxy-groups"])
        XCTAssertNil(root["rule-providers"])
        XCTAssertNil(root["sub-rules"])
        XCTAssertNil(root["rules"])
    }

    func testIPv6PrivilegedEnvelopeRoundTripsProjection() throws {
        let options = MihomoRuntimeOptions(
            routingMode: .direct,
            tun: MihomoTunConfiguration()
        )
        let envelope = try MihomoPrivilegedEnvelope.encode(
            server: supportedProtocolsServer(),
            options: options,
            replacingPrimaryServerWith: "2606:4700::9"
        )

        let plan = try MihomoPrivilegedEnvelope.decodeRuntimePlan(from: envelope)
        let root = try MihomoYAML.mapping(from: plan.configuration)

        XCTAssertEqual(root.string("mode"), "direct")
        XCTAssertNil(root["proxies"])
        XCTAssertEqual(root["rules"] as? [String], ["MATCH,DIRECT"])
        XCTAssertEqual(root.mapping("tun")?.bool("enable"), true)
    }

    func testUserAndPrivilegedProjectionsKeepAuthenticatedLoopbackController() throws {
        let controller = MihomoExternalControllerConfiguration(port: 9_090, secret: "local-secret")
        let user = try MihomoYAML.mapping(
            from: sampleServer().runtimeConfiguration(
                options: MihomoRuntimeOptions(externalController: controller),
                replacingPrimaryServerWith: "2606:4700::20"
            )
        )
        XCTAssertEqual(user.string("external-controller"), "127.0.0.1:9090")
        XCTAssertEqual(user.string("secret"), "local-secret")

        let privileged = try MihomoYAML.mapping(
            from: sampleServer().runtimeConfiguration(
                options: MihomoRuntimeOptions(
                    externalController: controller,
                    tun: MihomoTunConfiguration()
                ),
                projection: .privilegedTun,
                replacingPrimaryServerWith: "2606:4700::20"
            )
        )
        XCTAssertEqual(privileged.string("external-controller"), "127.0.0.1:9090")
        XCTAssertEqual(privileged.string("secret"), "local-secret")
    }

    func testControllerSecretRejectsControlCharactersAndWhitespace() throws {
        XCTAssertEqual(
            try MihomoExternalControllerConfiguration.validatedSecret("  token-safe_value./+=  "),
            "token-safe_value./+="
        )
        for raw in [
            "has space",
            "tab\there",
            "crlf\r\ninject",
            "quote\"break",
            "newline\ninject",
            "",
            "   ",
            String(repeating: "a", count: 513),
        ] {
            XCTAssertThrowsError(
                try MihomoExternalControllerConfiguration.validatedSecret(raw),
                "Expected rejection for \(raw.debugDescription)"
            ) { error in
                XCTAssertEqual(error as? MihomoConfigurationError, .invalidControllerSecret)
            }
        }

        let server = try sampleServer()
        XCTAssertThrowsError(
            try server.runtimeConfiguration(
                options: MihomoRuntimeOptions(
                    externalController: MihomoExternalControllerConfiguration(
                        port: 9_090,
                        secret: "evil\r\nX-Injected: 1"
                    )
                ),
                replacingPrimaryServerWith: "2606:4700::20"
            )
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .invalidControllerSecret)
        }
    }

    func testDefaultRuntimeOptionsUseContractMixedPort() throws {
        // contracts/schemas/local-proxy.schema.json declares default 11451;
        // Rust ProjectOptions and Android ProjectOptions already match.
        XCTAssertEqual(MihomoRuntimeOptions().mixedPort, 11_451)

        let output = try sampleServer().runtimeConfiguration(
            options: MihomoRuntimeOptions(),
            replacingPrimaryServerWith: "2606:4700::21"
        )
        let root = try MihomoYAML.mapping(from: output)
        XCTAssertEqual(root.int("mixed-port"), 11_451)
    }

    func testRuleModeBuildsManagedGroupAndPrivateBypassRules() throws {
        let output = try sampleServer().runtimeConfiguration(
            options: MihomoRuntimeOptions(
                listenAddress: "127.0.0.1",
                mixedPort: 20_280,
                routingMode: .rule,
                logLevel: .info,
                ipv6Enabled: true,
                udpEnabled: true,
                sniffingEnabled: true,
                bypassPrivateNetworks: true
            ),
            replacingPrimaryServerWith: "2606:4700::21"
        )
        let root = try MihomoYAML.mapping(from: output)

        XCTAssertEqual(root.int("mixed-port"), 20_280)
        XCTAssertEqual(root.string("bind-address"), "127.0.0.1")
        XCTAssertEqual(root.string("mode"), "rule")
        XCTAssertEqual(root.string("log-level"), "info")
        XCTAssertEqual(root.bool("allow-lan"), false)
        XCTAssertEqual(root.mappings("proxies")?.first?.string("server"), "2606:4700::21")
        XCTAssertEqual(root.mappings("proxies")?.first?.bool("udp"), true)
        XCTAssertNil(root["proxy-groups"])
        let rules = try XCTUnwrap(root["rules"] as? [String])
        XCTAssertTrue(rules.contains("IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"))
        XCTAssertEqual(rules.last, "MATCH,edge")
        XCTAssertEqual(root.mapping("tun")?.bool("enable"), false)
        XCTAssertEqual(root.mapping("sniffer")?.bool("enable"), true)
    }

    func testGlobalAndDirectModesUseMihomoNativeModeValues() throws {
        let server = try sampleServer()
        let global = try MihomoYAML.mapping(
            from: server.runtimeConfiguration(
                options: MihomoRuntimeOptions(routingMode: .global),
                replacingPrimaryServerWith: "2606:4700::22"
            )
        )
        XCTAssertEqual(global.string("mode"), "global")

        let direct = try MihomoYAML.mapping(
            from: MihomoServerConfiguration.runtimeConfiguration(
                server: server,
                options: MihomoRuntimeOptions(routingMode: .direct)
            )
        )
        XCTAssertEqual(direct.string("mode"), "direct")
        XCTAssertEqual(direct["rules"] as? [String], ["MATCH,DIRECT"])
        XCTAssertEqual(direct.mapping("tun")?.bool("enable"), false)
        XCTAssertNil(direct["proxies"])
        XCTAssertNil(direct["proxy-providers"])
        XCTAssertNil(direct["proxy-groups"])
    }

    func testUserProjectionNeverEnablesTunOrValidatesPrivilegedTunInput() throws {
        let output = try sampleServer().runtimeConfiguration(
            options: MihomoRuntimeOptions(
                tun: MihomoTunConfiguration(
                    mtu: 1,
                    routeExcludeAddresses: ["not-a-cidr"]
                )
            ),
            replacingPrimaryServerWith: "2606:4700::23"
        )
        let root = try MihomoYAML.mapping(from: output)

        XCTAssertEqual(root.mapping("tun")?.bool("enable"), false)
        XCTAssertNil(root["dns"])
        XCTAssertEqual(root.mapping("profile")?.bool("store-fake-ip"), false)
    }

    func testPrivilegedTunUsesFixedRoutingAndFakeIPDNSWithoutDevice() throws {
        let output = try sampleServer().runtimeConfiguration(
            options: MihomoRuntimeOptions(
                routingMode: .rule,
                tun: MihomoTunConfiguration(
                    stack: .mixed,
                    strictRoute: true,
                    mtu: 1_500,
                    routeExcludeAddresses: ["1.1.1.1/32"]
                )
            ),
            projection: .privilegedTun,
            replacingPrimaryServerWith: "2606:4700::24"
        )
        let root = try MihomoYAML.mapping(from: output)
        let tun: [String: Any] = try XCTUnwrap(root.mapping("tun"))
        let dns: [String: Any] = try XCTUnwrap(root.mapping("dns"))

        XCTAssertEqual(tun.bool("enable"), true)
        XCTAssertEqual(tun.string("stack"), "mixed")
        XCTAssertNil(tun["device"])
        XCTAssertEqual(tun.bool("auto-route"), true)
        XCTAssertEqual(tun.bool("strict-route"), true)
        XCTAssertEqual(tun.bool("auto-detect-interface"), true)
        XCTAssertEqual(tun["dns-hijack"] as? [String], ["any:53", "tcp://any:53"])
        XCTAssertEqual(tun["route-exclude-address"] as? [String], ["1.1.1.1/32"])
        XCTAssertEqual(dns.bool("enable"), true)
        XCTAssertEqual(dns.string("enhanced-mode"), "fake-ip")
        XCTAssertEqual(dns.string("fake-ip-range"), "198.18.0.1/16")
        XCTAssertEqual(dns.string("fake-ip-range6"), "fdfe:dcba:9876::1/64")
        XCTAssertEqual(dns.bool("respect-rules"), true)
        XCTAssertEqual(dns["default-nameserver"] as? [String], ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(
            dns["nameserver"] as? [String],
            ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
        )
        XCTAssertEqual(
            dns["proxy-server-nameserver"] as? [String],
            ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
        )
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("system"))
        XCTAssertEqual(root.mapping("profile")?.bool("store-fake-ip"), true)
    }

    func testPrivilegedTunRequiresExplicitTunConfiguration() throws {
        XCTAssertThrowsError(
            try sampleServer().runtimeConfiguration(
                options: MihomoRuntimeOptions(),
                projection: .privilegedTun
            )
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .missingTunConfiguration)
        }
    }

    func testPrivilegedProjectionKeepsOnlySelectedInlineProxy() throws {
        let output = try supportedProtocolsServer().runtimeConfiguration(
            options: privilegedOptions(),
            projection: .privilegedTun,
            replacingPrimaryServerWith: "2606:4700::25"
        )
        let root = try MihomoYAML.mapping(from: output)

        XCTAssertEqual(
            root.mappings("proxies")?.compactMap { $0.string("type") },
            ["vless"]
        )
        XCTAssertNil(root["proxy-groups"])
        XCTAssertEqual((root["rules"] as? [String])?.last, "MATCH,vless-edge")
        XCTAssertEqual(root.mapping("tun")?.bool("enable"), true)
        XCTAssertNotNil(root["dns"])
    }

    func testProviderOnlyProfilesAreRejectedForEveryRuntimeProjection() throws {
        let server = try MihomoServerConfiguration(
            data: Data(
                """
                proxy-providers:
                  remote:
                    type: http
                    url: https://subscription.example/profile.yaml
                    path: ../../outside.yaml
                    interval: 3600
                proxy-groups:
                  - name: PROXY
                    type: select
                    use: [remote]
                rules:
                  - MATCH,PROXY
                """.utf8
            )
        )

        for (options, projection) in [
            (MihomoRuntimeOptions(), MihomoRuntimeProjection.user),
            (privilegedOptions(), MihomoRuntimeProjection.privilegedTun),
        ] {
            XCTAssertThrowsError(
                try server.runtimeConfiguration(
                    options: options,
                    projection: projection,
                    replacingPrimaryServerWith: "2606:4700::30"
                )
            ) { error in
                XCTAssertEqual(
                    error as? MihomoConfigurationError,
                    .ipv6ManagedProfileRequired
                )
            }
        }
    }

    func testInlineProviderOnlyProfileIsRejected() throws {
        let server = try MihomoServerConfiguration(
            data: Data(
                """
                proxy-providers:
                  embedded:
                    type: inline
                    payload:
                      - name: provider-edge
                        type: ss
                        server: provider.example
                        port: 8388
                        cipher: aes-128-gcm
                        password: secret
                rule-providers:
                  local-domains:
                    type: inline
                    behavior: domain
                    payload:
                      - example.com
                proxy-groups:
                  - name: PROXY
                    type: select
                    use: [embedded]
                rules:
                  - RULE-SET,local-domains,PROXY
                  - MATCH,PROXY
                """.utf8
            )
        )

        XCTAssertThrowsError(
            try server.runtimeConfiguration(
                options: privilegedOptions(),
                projection: .privilegedTun,
                replacingPrimaryServerWith: "2606:4700::31"
            )
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .ipv6ManagedProfileRequired)
        }
    }

    func testPrivilegedProjectionRejectsUnknownProtocolsAndDangerousProxyFields() throws {
        for profile in [
            """
            proxies:
              - name: unsupported
                type: socks5
                server: origin.example
                port: 1080
            """,
            """
            proxies:
              - name: plugin
                type: ss
                server: origin.example
                port: 8388
                cipher: aes-128-gcm
                password: secret
                plugin: obfs
                plugin-opts: {mode: tls}
            """,
            """
            proxies:
              - name: key-file
                type: vless
                server: origin.example
                port: 443
                uuid: 11111111-1111-4111-8111-111111111111
                network: ws
                tls: true
                servername: origin.example
                private-key: /tmp/key.pem
            """,
            """
            proxies:
              - name: nested-file
                type: vless
                server: origin.example
                port: 443
                uuid: 11111111-1111-4111-8111-111111111111
                network: ws
                tls: true
                servername: origin.example
                ws-opts:
                  path: /safe-request-path
                  certificate: /tmp/certificate.pem
            """,
        ] {
            let server = try MihomoServerConfiguration(data: Data(profile.utf8))
            XCTAssertThrowsError(
                try server.runtimeConfiguration(
                    options: privilegedOptions(),
                    projection: .privilegedTun,
                    replacingPrimaryServerWith: "2606:4700::40"
                ),
                profile
            )
        }
    }

    func testManagedProjectionDropsImportedRuleProvidersAndGeodataRules() throws {
        let remoteProvider = try MihomoServerConfiguration(
            data: Data(
                """
                proxies:
                  - name: edge
                    type: ss
                    server: origin.example
                    port: 8388
                    cipher: aes-128-gcm
                    password: secret
                rule-providers:
                  remote:
                    type: http
                    behavior: domain
                    url: https://rules.example/rules.yaml
                    path: ../../rules.yaml
                rules:
                  - RULE-SET,remote,edge
                  - MATCH,edge
                """.utf8
            )
        )
        let geodata = try MihomoServerConfiguration(
            data: Data(
                """
                proxies:
                  - name: edge
                    type: ss
                    server: origin.example
                    port: 8388
                    cipher: aes-128-gcm
                    password: secret
                rules:
                  - GEOIP,CN,DIRECT
                  - MATCH,edge
                """.utf8
            )
        )
        for server in [remoteProvider, geodata] {
            let root = try MihomoYAML.mapping(
                from: server.runtimeConfiguration(
                    options: privilegedOptions(),
                    projection: .privilegedTun,
                    replacingPrimaryServerWith: "2606:4700::41"
                )
            )
            XCTAssertNil(root["rule-providers"])
            let rules = try XCTUnwrap(root["rules"] as? [String])
            XCTAssertEqual(rules.count, 10)
            XCTAssertEqual(rules.last, "MATCH,edge")
            XCTAssertFalse(rules.contains { $0.contains("GEOIP") || $0.contains("RULE-SET") })
        }
    }

    func testPrivilegedProjectionRejectsInvalidPrimaryProxyFields() throws {
        let profile = """
            proxies:
              - name: vmess-edge
                type: vmess
                server: origin.example
                port: 443
                uuid: 22222222-2222-4222-8222-222222222222
                alterId: -1
                cipher: auto
            """
        let server = try MihomoServerConfiguration(data: Data(profile.utf8))
        XCTAssertThrowsError(
            try server.runtimeConfiguration(
                options: privilegedOptions(),
                projection: .privilegedTun,
                replacingPrimaryServerWith: "2606:4700::42"
            )
        )
    }

    func testImportedRulesAreReplacedByManagedRuleSet() throws {
        let rules =
            (0..<1_025).map { "DOMAIN-SUFFIX,host-\($0).example,edge" }
            + ["MATCH,edge"]
        let profile = """
            proxies:
              - name: edge
                type: ss
                server: origin.example
                port: 8388
                cipher: aes-128-gcm
                password: secret
            rules:
            \(rules.map { "  - \($0)" }.joined(separator: "\n"))
            """
        let server = try MihomoServerConfiguration(data: Data(profile.utf8))

        let root = try MihomoYAML.mapping(
            from: server.runtimeConfiguration(
                options: privilegedOptions(),
                projection: .privilegedTun,
                replacingPrimaryServerWith: "2606:4700::43"
            )
        )
        XCTAssertEqual((root["rules"] as? [String])?.count, 10)
    }

    func testPrivilegedTunValidatesMTUAndRouteExclusions() throws {
        for mtu in [1_279, 9_001] {
            XCTAssertThrowsError(
                try sampleServer().runtimeConfiguration(
                    options: privilegedOptions(tun: MihomoTunConfiguration(mtu: mtu)),
                    projection: .privilegedTun,
                    replacingPrimaryServerWith: "2606:4700::50"
                )
            ) { error in
                XCTAssertEqual(error as? MihomoConfigurationError, .invalidTunMTU)
            }
        }

        for mtu in [1_280, 9_000] {
            XCTAssertNoThrow(
                try sampleServer().runtimeConfiguration(
                    options: privilegedOptions(
                        tun: MihomoTunConfiguration(
                            mtu: mtu,
                            routeExcludeAddresses: ["1.1.1.1/32", "2001:db8::/32"]
                        )
                    ),
                    projection: .privilegedTun,
                    replacingPrimaryServerWith: "2606:4700::50"
                )
            )
        }

        for route in [
            "not-a-cidr",
            "127.0.0.1/32",
            "0.0.0.0/0",
            "198.18.0.0/15",
            "::1/128",
            "fdfe:dcba:9876::1/128",
        ] {
            XCTAssertThrowsError(
                try sampleServer().runtimeConfiguration(
                    options: privilegedOptions(
                        tun: MihomoTunConfiguration(routeExcludeAddresses: [route])
                    ),
                    projection: .privilegedTun,
                    replacingPrimaryServerWith: "2606:4700::50"
                ),
                route
            ) { error in
                XCTAssertEqual(
                    error as? MihomoConfigurationError,
                    .invalidTunRouteExclusion(route)
                )
            }
        }

        XCTAssertThrowsError(
            try sampleServer().runtimeConfiguration(
                options: privilegedOptions(
                    tun: MihomoTunConfiguration(
                        routeExcludeAddresses: (0..<33).map { "203.0.113.\($0)/32" }
                    )
                ),
                projection: .privilegedTun,
                replacingPrimaryServerWith: "2606:4700::50"
            )
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .tooManyTunRouteExclusions)
        }
    }

    func testRuntimeRejectsUnsafeLocalValuesAndAppliesUDPPreference() throws {
        XCTAssertThrowsError(
            try sampleServer().runtimeConfiguration(
                options: MihomoRuntimeOptions(listenAddress: "0.0.0.0")
            )
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .invalidListenAddress)
        }

        let udpDisabled = try MihomoYAML.mapping(
            from: sampleServer().runtimeConfiguration(
                options: MihomoRuntimeOptions(udpEnabled: false),
                replacingPrimaryServerWith: "2606:4700::51"
            )
        )
        XCTAssertEqual(udpDisabled.mappings("proxies")?.first?.bool("udp"), false)
    }

    func testLocalUDPPreferenceCannotEnableUDPDisabledByTheProxy() throws {
        let server = try MihomoServerConfiguration(
            data: Data(
                """
                proxies:
                  - name: tcp-only-edge
                    type: vless
                    server: origin.example
                    port: 443
                    uuid: 11111111-1111-4111-8111-111111111111
                    encryption: none
                    udp: false
                    tls: true
                    servername: origin.example
                """.utf8
            )
        )

        let runtime = try MihomoYAML.mapping(
            from: server.runtimeConfiguration(
                options: MihomoRuntimeOptions(udpEnabled: true),
                replacingPrimaryServerWith: "2606:4700::53"
            )
        )

        XCTAssertEqual(runtime.mappings("proxies")?.first?.bool("udp"), false)
    }

    func testPrivilegedConfigurationPassesPinnedMihomoValidationWhenAvailable() throws {
        guard
            let binary = ProcessInfo.processInfo.environment["VIASIX_MIHOMO_TEST_BINARY"],
            FileManager.default.isExecutableFile(atPath: binary)
        else {
            throw XCTSkip("Set VIASIX_MIHOMO_TEST_BINARY to run the real-core validation")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ViaSixMihomoRuntimeTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let config = root.appendingPathComponent("config.yaml")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try supportedProtocolsServer().runtimeConfiguration(
            options: privilegedOptions(),
            projection: .privilegedTun,
            replacingPrimaryServerWith: "2606:4700::52"
        ).write(to: config)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-t", "-d", home.path, "-f", config.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
    }

    func testPrivilegedEnvelopeRoundTripsThroughFreshAllowlistProjection() throws {
        let server = try supportedProtocolsServer()
        let options = privilegedOptions()
        let expected = try server.runtimeConfiguration(
            options: options,
            projection: .privilegedTun,
            replacingPrimaryServerWith: "2606:4700::53"
        )

        let envelope = try MihomoPrivilegedEnvelope.encode(
            server: server,
            options: options,
            replacingPrimaryServerWith: "2606:4700::53"
        )
        let decoded = try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(
            from: envelope
        )

        XCTAssertTrue(envelope.starts(with: Data("bplist00".utf8)))
        XCTAssertEqual(
            try MihomoYAML.mapping(from: decoded) as NSDictionary,
            try MihomoYAML.mapping(from: expected) as NSDictionary
        )

        let replaced = try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(
            from: MihomoPrivilegedEnvelope.encode(
                server: server,
                options: options,
                replacingPrimaryServerWith: "2606:4700::54"
            )
        )
        XCTAssertEqual(
            try MihomoYAML.mapping(from: replaced).mappings("proxies")?.first?
                .string("server"),
            "2606:4700::54"
        )
    }

    func testPrivilegedEnvelopeRoundTripsSelectedIPVLESSWebSocketProfile() throws {
        let server = try MihomoServerConfiguration(
            data: Data(
                """
                x-viasix:
                  version: 1
                  primary-server: selected-ip
                proxies:
                  - name: ViaSix Cloudflare Pages
                    type: vless
                    port: 443
                    uuid: 11111111-1111-4111-8111-111111111111
                    encryption: none
                    udp: false
                    tls: true
                    servername: origin.example
                    client-fingerprint: chrome
                    skip-cert-verify: false
                    network: ws
                    ws-opts:
                      path: /?ed=2560
                      headers:
                        Host: origin.example
                """.utf8
            )
        )
        let options = MihomoRuntimeOptions(
            listenAddress: "127.0.0.1",
            mixedPort: 11_451,
            routingMode: .rule,
            logLevel: .warning,
            ipv6Enabled: true,
            udpEnabled: true,
            sniffingEnabled: true,
            bypassPrivateNetworks: true,
            externalController: MihomoExternalControllerConfiguration(
                port: 9_090,
                secret: "controller-secret"
            ),
            tun: MihomoTunConfiguration()
        )

        let envelope = try MihomoPrivilegedEnvelope.encode(
            server: server,
            options: options,
            replacingPrimaryServerWith: "2606:4700::53"
        )

        XCTAssertNoThrow(try MihomoPrivilegedEnvelope.decodeRuntimePlan(from: envelope))
    }

    func testPrivilegedEnvelopeRejectsRawYAMLBadSchemaAndNonCanonicalPayload() throws {
        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(
                from: try supportedProtocolsServer().runtimeConfiguration(
                    options: privilegedOptions(),
                    projection: .privilegedTun,
                    replacingPrimaryServerWith: "2606:4700::55"
                )
            )
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .invalidPrivilegedEnvelope)
        }

        let envelope = try MihomoPrivilegedEnvelope.encode(
            server: try supportedProtocolsServer(),
            options: privilegedOptions(),
            replacingPrimaryServerWith: "2606:4700::55"
        )
        var root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: envelope, format: nil)
                as? [String: Any]
        )
        root["schemaVersion"] = 99
        let unsupported = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(from: unsupported)
        ) { error in
            XCTAssertEqual(
                error as? MihomoConfigurationError,
                .unsupportedPrivilegedEnvelopeVersion(99)
            )
        }

        root["schemaVersion"] = MihomoPrivilegedEnvelope.schemaVersion
        var server = try XCTUnwrap(root["server"] as? [String: Any])
        server["certificate"] = "/tmp/root-readable.pem"
        root["server"] = server
        let nonCanonical = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(from: nonCanonical)
        ) { error in
            XCTAssertEqual(
                error as? MihomoConfigurationError,
                .nonCanonicalPrivilegedEnvelope
            )
        }

        func assertRejectedUnknownField(
            _ mutatedRoot: [String: Any],
            line: UInt = #line
        ) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: mutatedRoot,
                format: .binary,
                options: 0
            )
            XCTAssertThrowsError(
                try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(from: data),
                line: line
            ) { error in
                XCTAssertEqual(
                    error as? MihomoConfigurationError,
                    .nonCanonicalPrivilegedEnvelope,
                    line: line
                )
            }
        }

        let canonicalRoot = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: envelope, format: nil)
                as? [String: Any]
        )
        var unknownTopLevel = canonicalRoot
        unknownTopLevel["rawYAML"] = "mode: direct"
        try assertRejectedUnknownField(unknownTopLevel)

        var unknownOption = canonicalRoot
        var options = try XCTUnwrap(unknownOption["options"] as? [String: Any])
        options["executablePath"] = "/tmp/mihomo"
        unknownOption["options"] = options
        try assertRejectedUnknownField(unknownOption)

        var unknownTunOption = canonicalRoot
        options = try XCTUnwrap(unknownTunOption["options"] as? [String: Any])
        var tun = try XCTUnwrap(options["tun"] as? [String: Any])
        tun["device"] = "utun99"
        options["tun"] = tun
        unknownTunOption["options"] = options
        try assertRejectedUnknownField(unknownTunOption)
    }

    func testPrivilegedEnvelopeRejectsPreviousCanonicalRebuildVersion() throws {
        let envelope = try MihomoPrivilegedEnvelope.encode(
            server: try supportedProtocolsServer(),
            options: privilegedOptions(),
            replacingPrimaryServerWith: "2606:4700::55"
        )
        var root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: envelope, format: nil)
                as? [String: Any]
        )
        root["schemaVersion"] = 1
        let previousVersion = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )

        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(from: previousVersion)
        ) { error in
            XCTAssertEqual(
                error as? MihomoConfigurationError,
                .unsupportedPrivilegedEnvelopeVersion(1)
            )
        }
    }

    func testPrivilegedEnvelopeRejectsOversizedInputBeforeDecoding() {
        let data = Data(
            repeating: 0,
            count: MihomoPrivilegedEnvelope.maximumBytes + 1
        )

        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(from: data)
        ) { error in
            XCTAssertEqual(
                error as? MihomoConfigurationError,
                .privilegedEnvelopeTooLarge(data.count)
            )
        }
    }

    func testPrivilegedEnvelopeEncoderRejectsNonCanonicalOptions() throws {
        var options = privilegedOptions()
        options.listenAddress = "LOCALHOST"
        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.encode(
                server: try supportedProtocolsServer(),
                options: options
            )
        ) { error in
            XCTAssertEqual(
                error as? MihomoConfigurationError,
                .nonCanonicalPrivilegedEnvelope
            )
        }

        options = privilegedOptions(
            tun: MihomoTunConfiguration(
                routeExcludeAddresses: [" 203.0.113.0/24"]
            )
        )
        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.encode(
                server: try supportedProtocolsServer(),
                options: options
            )
        ) { error in
            XCTAssertEqual(
                error as? MihomoConfigurationError,
                .nonCanonicalPrivilegedEnvelope
            )
        }
    }

    func testPrivilegedEnvelopeRejectsDeepOrOverlyComplexPlistBeforeTypedDecode() throws {
        let envelope = try MihomoPrivilegedEnvelope.encode(
            server: try supportedProtocolsServer(),
            options: privilegedOptions(),
            replacingPrimaryServerWith: "2606:4700::56"
        )
        let canonicalRoot = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: envelope, format: nil)
                as? [String: Any]
        )

        var deepValue: Any = "leaf"
        for _ in 0...64 {
            deepValue = [deepValue]
        }
        var deepRoot = canonicalRoot
        deepRoot["unknown"] = deepValue
        let deepEnvelope = try PropertyListSerialization.data(
            fromPropertyList: deepRoot,
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(from: deepEnvelope)
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .configurationTooDeep)
        }

        var complexRoot = canonicalRoot
        complexRoot["unknown"] = [Bool](repeating: false, count: 200_000)
        let complexEnvelope = try PropertyListSerialization.data(
            fromPropertyList: complexRoot,
            format: .binary,
            options: 0
        )
        XCTAssertLessThanOrEqual(
            complexEnvelope.count,
            MihomoPrivilegedEnvelope.maximumBytes
        )
        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(from: complexEnvelope)
        ) { error in
            XCTAssertEqual(error as? MihomoConfigurationError, .configurationTooComplex)
        }
    }

    func testPrivilegedDirectProjectionDropsUnsafeRemoteSourcesBeforeValidation() throws {
        let server = try MihomoServerConfiguration(
            data: Data(
                """
                proxy-providers:
                  remote:
                    type: http
                    url: https://subscription.example/profile.yaml
                    path: ../../outside.yaml
                proxy-groups:
                  - name: PROXY
                    type: select
                    use: [remote]
                rules:
                  - GEOIP,CN,DIRECT
                  - MATCH,PROXY
                """.utf8
            )
        )
        let options = MihomoRuntimeOptions(
            routingMode: .direct,
            tun: MihomoTunConfiguration()
        )

        let runtime = try server.runtimeConfiguration(
            options: options,
            projection: .privilegedTun
        )
        let envelope = try MihomoPrivilegedEnvelope.encode(server: server, options: options)
        let decodedEnvelope = try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(
            from: envelope
        )

        for data in [runtime, decodedEnvelope] {
            let root = try MihomoYAML.mapping(from: data)
            XCTAssertEqual(root.string("mode"), "direct")
            XCTAssertEqual(root["rules"] as? [String], ["MATCH,DIRECT"])
            XCTAssertNil(root["proxies"])
            XCTAssertNil(root["proxy-providers"])
            XCTAssertNil(root["proxy-groups"])
            XCTAssertEqual(root.mapping("tun")?.bool("enable"), true)
        }

        var injectedRoot = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: envelope, format: nil)
                as? [String: Any]
        )
        var injectedServer = try XCTUnwrap(injectedRoot["server"] as? [String: Any])
        injectedServer["proxy-providers"] = [
            "remote": [
                "type": "http",
                "url": "https://subscription.example/profile.yaml",
            ]
        ]
        injectedRoot["server"] = injectedServer
        let injectedEnvelope = try PropertyListSerialization.data(
            fromPropertyList: injectedRoot,
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(
            try MihomoPrivilegedEnvelope.decodeRuntimeConfiguration(from: injectedEnvelope)
        ) { error in
            XCTAssertEqual(
                error as? MihomoConfigurationError,
                .nonCanonicalPrivilegedEnvelope
            )
        }
    }

    private func privilegedOptions(
        tun: MihomoTunConfiguration = MihomoTunConfiguration()
    ) -> MihomoRuntimeOptions {
        MihomoRuntimeOptions(
            routingMode: .rule,
            ipv6Enabled: true,
            udpEnabled: true,
            sniffingEnabled: true,
            bypassPrivateNetworks: true,
            tun: tun
        )
    }

    private func sampleServer() throws -> MihomoServerConfiguration {
        try MihomoServerConfiguration(
            profile: MihomoProxyProfile(
                name: "edge",
                protocolName: .vless,
                serverAddress: "origin.example.com",
                serverPort: 443,
                credential: "11111111-1111-4111-8111-111111111111",
                transport: .websocket,
                security: .tls,
                serverName: "origin.example.com",
                host: "origin.example.com"
            )
        )
    }

    private func supportedProtocolsServer() throws -> MihomoServerConfiguration {
        try MihomoServerConfiguration(
            data: Data(
                """
                proxies:
                  - name: vless-edge
                    type: vless
                    server: vless.example
                    port: 443
                    uuid: 11111111-1111-4111-8111-111111111111
                    encryption: none
                    network: ws
                    tls: true
                    servername: vless.example
                    ws-opts:
                      path: /proxy
                      headers:
                        Host: vless.example
                  - name: vmess-edge
                    type: vmess
                    server: vmess.example
                    port: 443
                    uuid: 22222222-2222-4222-8222-222222222222
                    alterId: 0
                    cipher: auto
                    network: grpc
                    tls: true
                    servername: vmess.example
                    grpc-opts:
                      grpc-service-name: viasix
                  - name: trojan-edge
                    type: trojan
                    server: trojan.example
                    port: 443
                    password: trojan-secret
                    network: tcp
                    sni: trojan.example
                  - name: ss-edge
                    type: ss
                    server: ss.example
                    port: 8388
                    cipher: aes-128-gcm
                    password: ss-secret
                proxy-groups:
                  - name: PROXY
                    type: select
                    proxies: [vless-edge, vmess-edge, trojan-edge, ss-edge]
                rules:
                  - DOMAIN-SUFFIX,example.com,PROXY
                  - MATCH,PROXY
                """.utf8
            )
        )
    }
}
