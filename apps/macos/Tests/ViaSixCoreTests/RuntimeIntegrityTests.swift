import Foundation
import XCTest

@testable import ViaSixCore

final class RuntimeIntegrityTests: XCTestCase {
    func testInspectorRecognizesThinAndUniversalMachOArchitectures() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let thinURL = root.appendingPathComponent("thin")
        try thinMachO(for: .arm64).write(to: thinURL)
        XCTAssertEqual(
            RuntimeBinaryInspector.inspect(fileAt: thinURL),
            .machO([.arm64])
        )

        let universalURL = root.appendingPathComponent("universal")
        try universalMachO(for: [.arm64, .x8664]).write(to: universalURL)
        XCTAssertEqual(
            RuntimeBinaryInspector.inspect(fileAt: universalURL),
            .machO([.arm64, .x8664])
        )
    }

    func testInspectorRejectsTruncatedUniversalMachO() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var data = universalMachO(for: [.arm64, .x8664])
        data.removeLast()
        let url = root.appendingPathComponent("truncated-universal")
        try data.write(to: url)

        XCTAssertEqual(RuntimeBinaryInspector.inspect(fileAt: url), .invalid)
    }

    func testInstalledStatusRejectsWrongArchitectureExecutable() async throws {
        let root = makeRoot()
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)

        let wrongArchitecture =
            RuntimeArchitecture.current == .arm64
            ? RuntimeArchitecture.x8664
            : .arm64
        let cfstURL = runtimeURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue)
        try thinMachO(for: wrongArchitecture).write(to: cfstURL)
        try makeExecutable(cfstURL)

        let status = await RuntimeComponentManager(runtimeDirectory: runtimeURL).installedStatus()

        XCTAssertEqual(status.discoveredFiles.installedFiles, [.cfst])
        XCTAssertEqual(status.invalidFiles, [.cfst])
        XCTAssertNil(status.cfstURL)
        XCTAssertFalse(status.cfstIsReady)
        XCTAssertFalse(status.isReady)
    }

    func testInstalledStatusRejectsEmptyMihomoExecutable() async throws {
        let root = makeRoot()
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)

        let cfstURL = runtimeURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue)
        try executableScript(marker: RuntimePayloadFile.cfst.rawValue).write(to: cfstURL)
        try makeExecutable(cfstURL)
        let mihomoURL = runtimeURL.appendingPathComponent(RuntimePayloadFile.mihomo.rawValue)
        try Data().write(to: mihomoURL)
        try makeExecutable(mihomoURL)

        let status = await RuntimeComponentManager(runtimeDirectory: runtimeURL).installedStatus()

        XCTAssertEqual(status.invalidFiles, [.mihomo])
        XCTAssertTrue(status.cfstIsReady)
        XCTAssertNil(status.mihomoURL)
        XCTAssertFalse(status.mihomoIsReady)
        XCTAssertFalse(status.isReady)
    }

    func testRejectedArchitecturePreservesExistingRuntime() async throws {
        let root = makeRoot()
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        let sourceURL = root.appendingPathComponent("Source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        for payload in RuntimePayloadFile.allCases {
            let url = runtimeURL.appendingPathComponent(payload.rawValue)
            let data =
                payload.requiresExecutablePermission
                ? executableScript(marker: "existing-\(payload.rawValue)")
                : Data("existing-\(payload.rawValue)".utf8)
            try data.write(to: url)
            if payload.requiresExecutablePermission {
                try makeExecutable(url)
            }
        }
        let existingCFST = try Data(
            contentsOf: runtimeURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue)
        )

        let wrongArchitecture =
            RuntimeArchitecture.current == .arm64
            ? RuntimeArchitecture.x8664
            : .arm64
        try thinMachO(for: wrongArchitecture)
            .write(to: sourceURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue))

        let manager = RuntimeComponentManager(runtimeDirectory: runtimeURL)
        do {
            _ = try await manager.install(from: sourceURL)
            XCTFail("Expected the incompatible executable to be rejected")
        } catch let error as RuntimeComponentError {
            XCTAssertEqual(
                error,
                .incompatibleExecutableArchitecture(
                    .cfst,
                    expected: .current,
                    available: [wrongArchitecture]
                )
            )
        }

        XCTAssertEqual(
            try Data(
                contentsOf: runtimeURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue)
            ),
            existingCFST
        )
        let status = await manager.installedStatus()
        XCTAssertTrue(status.isReady)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".Runtime-install-") }
        XCTAssertTrue(leftovers.isEmpty, "Unexpected transaction leftovers: \(leftovers)")
    }

    func testInstallingMihomoRemovesLegacyPayloadsAtCommit() async throws {
        let root = makeRoot()
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        let sourceURL = root.appendingPathComponent("Source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let cfstURL = runtimeURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue)
        try executableScript(marker: "existing-cfst").write(to: cfstURL)
        try makeExecutable(cfstURL)
        for legacyName in ["xray", "geoip.dat", "geosite.dat"] {
            try Data("legacy-\(legacyName)".utf8)
                .write(to: runtimeURL.appendingPathComponent(legacyName))
        }

        let replacementMihomo = executableScript(marker: "replacement-mihomo")
        try replacementMihomo.write(
            to: sourceURL.appendingPathComponent(RuntimePayloadFile.mihomo.rawValue)
        )

        let manager = RuntimeComponentManager(runtimeDirectory: runtimeURL)
        let status = try await manager.install(from: sourceURL)

        XCTAssertTrue(status.isReady)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(status.mihomoURL)), replacementMihomo)
        for legacyName in ["xray", "geoip.dat", "geosite.dat"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: runtimeURL.appendingPathComponent(legacyName).path
                )
            )
        }
    }

    func testFailedMihomoMigrationPreservesLegacyRuntime() async throws {
        let root = makeRoot()
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        let sourceURL = root.appendingPathComponent("Source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let cfstURL = runtimeURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue)
        let existingCFST = executableScript(marker: "existing-cfst")
        try existingCFST.write(to: cfstURL)
        try makeExecutable(cfstURL)
        let legacyPayloads = Dictionary(
            uniqueKeysWithValues: ["xray", "geoip.dat", "geosite.dat"].map {
                ($0, Data("legacy-\($0)".utf8))
            }
        )
        for (legacyName, data) in legacyPayloads {
            try data.write(to: runtimeURL.appendingPathComponent(legacyName))
        }

        let wrongArchitecture =
            RuntimeArchitecture.current == .arm64
            ? RuntimeArchitecture.x8664
            : .arm64
        try thinMachO(for: wrongArchitecture).write(
            to: sourceURL.appendingPathComponent(RuntimePayloadFile.mihomo.rawValue)
        )

        let manager = RuntimeComponentManager(runtimeDirectory: runtimeURL)
        do {
            _ = try await manager.install(from: sourceURL)
            XCTFail("Expected the incompatible Mihomo executable to be rejected")
        } catch let error as RuntimeComponentError {
            XCTAssertEqual(
                error,
                .incompatibleExecutableArchitecture(
                    .mihomo,
                    expected: .current,
                    available: [wrongArchitecture]
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: cfstURL), existingCFST)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeURL.appendingPathComponent(RuntimePayloadFile.mihomo.rawValue).path
            )
        )
        for (legacyName, expectedData) in legacyPayloads {
            XCTAssertEqual(
                try Data(contentsOf: runtimeURL.appendingPathComponent(legacyName)),
                expectedData
            )
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".Runtime-install-") }
        XCTAssertTrue(leftovers.isEmpty, "Unexpected transaction leftovers: \(leftovers)")
    }

    func testArchiveMustContainTheMihomoPayload() async throws {
        let root = makeRoot()
        let archiveURL = root.appendingPathComponent("archive")
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveData = Data("archive fixture".utf8)
        try archiveData.write(to: archiveURL)
        let digest = RuntimeSHA256.hexDigest(of: archiveData)
        let manifest = RuntimeManifest(assets: [
            RuntimeAsset(
                component: .cfst,
                version: "test",
                architecture: .current,
                archiveName: "cfst.zip",
                archiveFormat: .zip,
                downloadURL: URL(string: "https://example.invalid/cfst.zip")!,
                sha256: digest,
                payloadExpectations: [RuntimePayloadExpectation(file: .cfst)]
            ),
            RuntimeAsset(
                component: .mihomo,
                version: "test",
                architecture: .current,
                archiveName: "mihomo.gz",
                archiveFormat: .gzip(output: .mihomo),
                downloadURL: URL(string: "https://example.invalid/mihomo.gz")!,
                sha256: digest,
                payloadExpectations: [RuntimePayloadExpectation(file: .mihomo)]
            ),
        ])
        let manager = RuntimeComponentManager(
            runtimeDirectory: runtimeURL,
            manifest: manifest,
            downloadHandler: { _ in
                RuntimeDownloadedFile(fileURL: archiveURL, statusCode: 200)
            },
            archiveExtractor: { _, _, destinationURL in
                guard destinationURL.lastPathComponent == RuntimeComponent.cfst.rawValue else {
                    return
                }
                try Data("#!/bin/sh\nexit 0\n".utf8).write(
                    to: destinationURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue)
                )
            }
        )

        do {
            _ = try await manager.downloadAndInstall(architecture: .current)
            XCTFail("Expected the missing Mihomo payload to be rejected")
        } catch let error as RuntimeComponentError {
            XCTAssertEqual(
                error,
                .missingArchivePayload(.mihomo, [.mihomo])
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeURL.path))
    }

    func testManifestRequiresExactlyOneExpectationForEveryComponentPayload() async throws {
        let root = makeRoot()
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "0", count: 64)
        let manifest = RuntimeManifest(assets: [
            RuntimeAsset(
                component: .cfst,
                version: "test",
                architecture: .current,
                archiveName: "cfst.zip",
                archiveFormat: .zip,
                downloadURL: URL(string: "https://example.invalid/cfst.zip")!,
                sha256: digest,
                payloadExpectations: [RuntimePayloadExpectation(file: .cfst)]
            ),
            RuntimeAsset(
                component: .mihomo,
                version: "test",
                architecture: .current,
                archiveName: "mihomo.gz",
                archiveFormat: .gzip(output: .mihomo),
                downloadURL: URL(string: "https://example.invalid/mihomo.gz")!,
                sha256: digest,
                payloadExpectations: []
            ),
        ])
        let manager = RuntimeComponentManager(
            runtimeDirectory: runtimeURL,
            manifest: manifest,
            downloadHandler: { _ in
                XCTFail("Invalid manifest must be rejected before any download")
                throw CancellationError()
            },
            archiveExtractor: { _, _, _ in
                XCTFail("Invalid manifest must be rejected before extraction")
            }
        )

        do {
            _ = try await manager.downloadAndInstall(architecture: .current)
            XCTFail("Expected incomplete payload expectations to be rejected")
        } catch let error as RuntimeComponentError {
            XCTAssertEqual(
                error,
                .invalidPayloadExpectations(
                    .mihomo,
                    expected: RuntimeComponent.mihomo.payloadFiles.sorted {
                        $0.rawValue < $1.rawValue
                    },
                    actual: []
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeURL.path))
    }

    func testPayloadByteCountMismatchPreservesExistingRuntime() async throws {
        let root = makeRoot()
        let archiveURL = root.appendingPathComponent("archive")
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeReadyRuntime(at: runtimeURL, marker: "existing")

        let archiveData = Data("archive fixture".utf8)
        let cfstData = executableScript(marker: "replacement-cfst")
        try archiveData.write(to: archiveURL)
        let expectedByteCount = Int64(cfstData.count + 1)
        let manager = RuntimeComponentManager(
            runtimeDirectory: runtimeURL,
            manifest: makeDownloadManifest(
                archiveData: archiveData,
                cfstExpectation: RuntimePayloadExpectation(
                    file: .cfst,
                    byteCount: expectedByteCount,
                    sha256: RuntimeSHA256.hexDigest(of: cfstData)
                )
            ),
            downloadHandler: { _ in
                RuntimeDownloadedFile(fileURL: archiveURL, statusCode: 200)
            },
            archiveExtractor: { asset, _, destinationURL in
                try writeIntegrityPayloads(
                    for: asset.component,
                    cfstData: cfstData,
                    to: destinationURL
                )
            }
        )

        do {
            _ = try await manager.downloadAndInstall(architecture: .current)
            XCTFail("Expected payload byte-count mismatch")
        } catch let error as RuntimeComponentError {
            XCTAssertEqual(
                error,
                .payloadByteCountMismatch(
                    .cfst,
                    expected: expectedByteCount,
                    actual: Int64(cfstData.count)
                )
            )
        }

        let status = await manager.installedStatus()
        XCTAssertTrue(status.isReady)
        for payload in RuntimePayloadFile.allCases {
            XCTAssertEqual(
                try Data(contentsOf: runtimeURL.appendingPathComponent(payload.rawValue)),
                integrityRuntimeFixtureData(for: payload, marker: "existing")
            )
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".Runtime-download-") || $0.hasPrefix(".Runtime-install-") }
        XCTAssertTrue(leftovers.isEmpty, "Unexpected transaction leftovers: \(leftovers)")
    }

    func testPayloadSHA256MismatchRejectsInstallation() async throws {
        let root = makeRoot()
        let archiveURL = root.appendingPathComponent("archive")
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archiveData = Data("archive fixture".utf8)
        let cfstData = executableScript(marker: "replacement-cfst")
        let expectedSHA256 = String(repeating: "0", count: 64)
        try archiveData.write(to: archiveURL)
        let manager = RuntimeComponentManager(
            runtimeDirectory: runtimeURL,
            manifest: makeDownloadManifest(
                archiveData: archiveData,
                cfstExpectation: RuntimePayloadExpectation(
                    file: .cfst,
                    byteCount: Int64(cfstData.count),
                    sha256: expectedSHA256
                )
            ),
            downloadHandler: { _ in
                RuntimeDownloadedFile(fileURL: archiveURL, statusCode: 200)
            },
            archiveExtractor: { asset, _, destinationURL in
                try writeIntegrityPayloads(
                    for: asset.component,
                    cfstData: cfstData,
                    to: destinationURL
                )
            }
        )

        do {
            _ = try await manager.downloadAndInstall(architecture: .current)
            XCTFail("Expected payload SHA-256 mismatch")
        } catch let error as RuntimeComponentError {
            XCTAssertEqual(
                error,
                .payloadChecksumMismatch(
                    .cfst,
                    expected: expectedSHA256,
                    actual: RuntimeSHA256.hexDigest(of: cfstData)
                )
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeURL.path))
    }

    func testMatchingPayloadIntegrityUsesOnlyPinnedManifestAssetURLs() async throws {
        let root = makeRoot()
        let archiveURL = root.appendingPathComponent("archive")
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archiveData = Data("archive fixture".utf8)
        let cfstData = executableScript(marker: "verified-cfst")
        try archiveData.write(to: archiveURL)
        let manifest = makeDownloadManifest(
            archiveData: archiveData,
            cfstExpectation: RuntimePayloadExpectation(
                file: .cfst,
                byteCount: Int64(cfstData.count),
                sha256: RuntimeSHA256.hexDigest(of: cfstData)
            )
        )
        let recorder = RuntimeDownloadURLRecorder()
        let manager = RuntimeComponentManager(
            runtimeDirectory: runtimeURL,
            manifest: manifest,
            downloadHandler: { url in
                await recorder.append(url)
                return RuntimeDownloadedFile(fileURL: archiveURL, statusCode: 200)
            },
            archiveExtractor: { asset, _, destinationURL in
                try writeIntegrityPayloads(
                    for: asset.component,
                    cfstData: cfstData,
                    to: destinationURL
                )
            }
        )

        let status = try await manager.downloadAndInstall(architecture: .current)

        XCTAssertTrue(status.isReady)
        let requestedURLs = await recorder.urls
        XCTAssertEqual(requestedURLs, manifest.assets(for: .current).map(\.downloadURL))
        XCTAssertEqual(
            try Data(contentsOf: runtimeURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue)),
            cfstData
        )
    }

    func testInstallationRejectsNonCurrentArchitectureBeforeResolvingAssets() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let requestedArchitecture: RuntimeArchitecture =
            RuntimeArchitecture.current == .arm64 ? .x8664 : .arm64
        let manager = RuntimeComponentManager(runtimeDirectory: root)

        do {
            _ = try await manager.downloadAndInstall(architecture: requestedArchitecture)
            XCTFail("Expected a non-native installation request to be rejected")
        } catch let error as RuntimeComponentError {
            XCTAssertEqual(
                error,
                .unsupportedInstallationArchitecture(
                    requested: requestedArchitecture,
                    current: .current
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testNewOperationRemovesOnlyStaleTransactionDirectories() async throws {
        let root = makeRoot()
        let runtimeURL = root.appendingPathComponent("Runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let stale = root.appendingPathComponent(".Runtime-download-stale", isDirectory: true)
        let fresh = root.appendingPathComponent(".Runtime-install-fresh", isDirectory: true)
        let unrelated = root.appendingPathComponent(".Other-download-stale", isDirectory: true)
        for directory in [stale, fresh, unrelated] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }
        let oldDate = Date().addingTimeInterval(-48 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: unrelated.path
        )

        let manager = RuntimeComponentManager(runtimeDirectory: runtimeURL)
        do {
            _ = try await manager.install(from: root.appendingPathComponent("Missing"))
            XCTFail("Expected missing source")
        } catch let error as RuntimeComponentError {
            XCTAssertEqual(error, .sourceNotFound(root.appendingPathComponent("Missing")))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ViaSix-RuntimeIntegrity-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDownloadManifest(
        archiveData: Data,
        cfstExpectation: RuntimePayloadExpectation
    ) -> RuntimeManifest {
        let digest = RuntimeSHA256.hexDigest(of: archiveData)
        return RuntimeManifest(assets: [
            RuntimeAsset(
                component: .cfst,
                version: "pinned-cfst",
                architecture: .current,
                archiveName: "cfst.zip",
                archiveFormat: .zip,
                downloadURL: URL(string: "https://downloads.example.invalid/pinned/cfst.zip")!,
                sha256: digest,
                payloadExpectations: [cfstExpectation]
            ),
            RuntimeAsset(
                component: .mihomo,
                version: "pinned-mihomo",
                architecture: .current,
                archiveName: "mihomo.gz",
                archiveFormat: .gzip(output: .mihomo),
                downloadURL: URL(string: "https://downloads.example.invalid/pinned/mihomo.gz")!,
                sha256: digest,
                payloadExpectations: [RuntimePayloadExpectation(file: .mihomo)]
            ),
        ])
    }

    private func makeReadyRuntime(at runtimeURL: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        for payload in RuntimePayloadFile.allCases {
            let fileURL = runtimeURL.appendingPathComponent(payload.rawValue)
            try integrityRuntimeFixtureData(for: payload, marker: marker).write(to: fileURL)
            if payload.requiresExecutablePermission {
                try makeExecutable(fileURL)
            }
        }
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
    }

    private func executableScript(marker: String) -> Data {
        Data("#!/bin/sh\n# \(marker)\nexit 0\n".utf8)
    }

    private func thinMachO(for architecture: RuntimeArchitecture) -> Data {
        var data = Data([0xcf, 0xfa, 0xed, 0xfe])
        appendUInt32LittleEndian(cpuType(for: architecture), to: &data)
        data.append(Data(repeating: 0, count: 24))
        return data
    }

    private func universalMachO(for architectures: [RuntimeArchitecture]) -> Data {
        let slices = architectures.map { thinMachO(for: $0) }
        let entriesEnd = 8 + architectures.count * 20
        var offsets: [Int] = []
        var nextOffset = entriesEnd
        for slice in slices {
            offsets.append(nextOffset)
            nextOffset += slice.count
        }

        var data = Data([0xca, 0xfe, 0xba, 0xbe])
        appendUInt32BigEndian(UInt32(architectures.count), to: &data)
        for (index, architecture) in architectures.enumerated() {
            appendUInt32BigEndian(cpuType(for: architecture), to: &data)
            appendUInt32BigEndian(0, to: &data)
            appendUInt32BigEndian(UInt32(offsets[index]), to: &data)
            appendUInt32BigEndian(UInt32(slices[index].count), to: &data)
            appendUInt32BigEndian(0, to: &data)
        }
        for slice in slices {
            data.append(slice)
        }
        return data
    }

    private func cpuType(for architecture: RuntimeArchitecture) -> UInt32 {
        switch architecture {
        case .arm64: 0x0100_000c
        case .x8664: 0x0100_0007
        }
    }

    private func appendUInt32LittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func appendUInt32BigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}

private actor RuntimeDownloadURLRecorder {
    private(set) var urls: [URL] = []

    func append(_ url: URL) {
        urls.append(url)
    }
}

private func writeIntegrityPayloads(
    for component: RuntimeComponent,
    cfstData: Data,
    to destinationURL: URL
) throws {
    switch component {
    case .cfst:
        try cfstData.write(to: destinationURL.appendingPathComponent(RuntimePayloadFile.cfst.rawValue))
    case .mihomo:
        try integrityRuntimeFixtureData(for: .mihomo, marker: "replacement")
            .write(to: destinationURL.appendingPathComponent(RuntimePayloadFile.mihomo.rawValue))
    }
}

private func integrityRuntimeFixtureData(
    for payload: RuntimePayloadFile,
    marker: String
) -> Data {
    if payload.requiresExecutablePermission {
        return Data("#!/bin/sh\n# \(marker)-\(payload.rawValue)\nexit 0\n".utf8)
    }
    return Data("\(marker)-\(payload.rawValue)".utf8)
}
