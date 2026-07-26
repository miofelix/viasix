import Foundation
import XCTest

@testable import ViaSixMihomoConfig

/// Loads monorepo `contracts/fixtures/mihomo-config/cases/*` and asserts semantic expectations.
/// Other platforms should implement the same cases against their projection engines.
final class ContractFixtureTests: XCTestCase {
    func testAllContractProjectionCases() throws {
        let cases = try ContractFixtureLoader.loadAll()
        XCTAssertFalse(cases.isEmpty, "Expected at least one contract fixture case")

        for fixture in cases {
            let expectation = fixture.caseFile.expect
            do {
                let server: MihomoServerConfiguration?
                if fixture.caseFile.requireProfile == false {
                    server = nil
                } else {
                    server = try MihomoServerConfiguration(data: fixture.inputYAML)
                }

                let routingMode = try XCTUnwrap(
                    MihomoRoutingMode(contractValue: fixture.caseFile.routingMode),
                    "Unknown routingMode \(fixture.caseFile.routingMode) in \(fixture.id)"
                )
                let projection = try XCTUnwrap(
                    MihomoRuntimeProjection(contractValue: fixture.caseFile.projection),
                    "Unknown projection \(fixture.caseFile.projection) in \(fixture.id)"
                )

                let output = try MihomoServerConfiguration.runtimeConfiguration(
                    server: server,
                    options: MihomoRuntimeOptions(routingMode: routingMode),
                    projection: projection,
                    replacingPrimaryServerWith: fixture.caseFile.selectedAddress
                )

                if expectation.success == false {
                    XCTFail("Case \(fixture.id) expected failure but projection succeeded")
                    continue
                }

                let root = try MihomoYAML.mapping(from: output)
                try assertSuccessfulProjection(root, expect: expectation, caseID: fixture.id)
            } catch let error as MihomoConfigurationError {
                guard expectation.success == false else {
                    XCTFail("Case \(fixture.id) unexpected error: \(error)")
                    continue
                }
                let code = error.contractErrorCode
                XCTAssertEqual(
                    code,
                    expectation.errorCode,
                    "Case \(fixture.id) error code mismatch"
                )
            } catch {
                XCTFail("Case \(fixture.id) unexpected non-config error: \(error)")
            }
        }
    }

    private func assertSuccessfulProjection(
        _ root: [String: Any],
        expect: ContractExpectation,
        caseID: String
    ) throws {
        if let mode = expect.mode {
            XCTAssertEqual(root.string("mode"), mode, "\(caseID): mode")
        }

        let proxies = root.mappings("proxies") ?? []
        if let count = expect.proxyCount {
            XCTAssertEqual(proxies.count, count, "\(caseID): proxyCount")
        }
        if let name = expect.primaryProxyName {
            XCTAssertEqual(proxies.first?.string("name"), name, "\(caseID): primaryProxyName")
        }
        if let server = expect.primaryProxyServer {
            XCTAssertEqual(proxies.first?.string("server"), server, "\(caseID): primaryProxyServer")
        }

        for key in expect.absentKeys ?? [] {
            XCTAssertNil(root[key], "\(caseID): expected absent key \(key)")
        }

        let rules = root["rules"] as? [String]
        if let last = expect.lastRule {
            XCTAssertEqual(rules?.last, last, "\(caseID): lastRule")
        }
        if let mustContain = expect.rulesMustContain {
            let present = rules ?? []
            for rule in mustContain {
                XCTAssertTrue(
                    present.contains(rule),
                    "\(caseID): missing rule \(rule) in \(present)"
                )
            }
        }
        if let exact = expect.rulesExact {
            XCTAssertEqual(rules, exact, "\(caseID): rulesExact")
        }

        if let tunEnable = expect.tunEnable {
            XCTAssertEqual(root.mapping("tun")?.bool("enable"), tunEnable, "\(caseID): tunEnable")
        }
    }
}

// MARK: - Loader

private enum ContractFixtureLoader {
    static func loadAll(file: StaticString = #filePath) throws -> [ContractFixture] {
        let casesRoot = try monorepoRoot(from: file)
            .appendingPathComponent("contracts/fixtures/mihomo-config/cases", isDirectory: true)

        let directoryNames = try FileManager.default.contentsOfDirectory(atPath: casesRoot.path)
            .sorted()
        return try directoryNames.compactMap { name -> ContractFixture? in
            let caseDir = casesRoot.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: caseDir.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue
            else {
                return nil
            }

            let caseURL = caseDir.appendingPathComponent("case.json")
            let inputURL = caseDir.appendingPathComponent("input.yaml")
            let caseData = try Data(contentsOf: caseURL)
            let decoded = try JSONDecoder().decode(ContractCaseFile.self, from: caseData)
            let inputYAML = try Data(contentsOf: inputURL)
            return ContractFixture(id: decoded.id, caseFile: decoded, inputYAML: inputYAML)
        }
    }

    private static func monorepoRoot(from file: StaticString) throws -> URL {
        var url = URL(fileURLWithPath: String(describing: file))
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            let marker = url.appendingPathComponent("contracts/VERSION")
            if FileManager.default.isReadableFile(atPath: marker.path) {
                return url
            }
        }
        throw NSError(
            domain: "ContractFixtureLoader",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not locate monorepo root (contracts/VERSION) from \(file)"
            ]
        )
    }
}

private struct ContractFixture {
    let id: String
    let caseFile: ContractCaseFile
    let inputYAML: Data
}

private struct ContractCaseFile: Decodable {
    let id: String
    let description: String?
    let selectedAddress: String?
    let routingMode: String
    let projection: String
    let requireProfile: Bool?
    let expect: ContractExpectation
}

private struct ContractExpectation: Decodable {
    let success: Bool
    let errorCode: String?
    let mode: String?
    let proxyCount: Int?
    let primaryProxyName: String?
    let primaryProxyServer: String?
    let absentKeys: [String]?
    let lastRule: String?
    let rulesMustContain: [String]?
    let rulesExact: [String]?
    let tunEnable: Bool?
}

// MARK: - Contract mappings

extension MihomoRoutingMode {
    init?(contractValue: String) {
        switch contractValue {
        case "rule": self = .rule
        case "global": self = .global
        case "direct": self = .direct
        default: return nil
        }
    }
}

extension MihomoRuntimeProjection {
    init?(contractValue: String) {
        switch contractValue {
        case "user": self = .user
        case "privilegedTun": self = .privilegedTun
        default: return nil
        }
    }
}

extension MihomoConfigurationError {
    /// Stable cross-platform error identifiers for contracts/fixtures.
    var contractErrorCode: String {
        switch self {
        case .selectedNodeMustBeIPv6:
            "selectedNodeMustBeIPv6"
        case .ipv6ManagedProfileRequired:
            "ipv6ManagedProfileRequired"
        case .missingTunConfiguration:
            "missingTunConfiguration"
        case .missingSelectedNodeAddress:
            "missingSelectedNodeAddress"
        case .missingInlineProxy:
            "missingInlineProxy"
        case .unsupportedValue(let detail) where detail.hasPrefix("x-viasix"):
            "unsupportedProfileExtension"
        default:
            String(describing: self)
        }
    }
}
