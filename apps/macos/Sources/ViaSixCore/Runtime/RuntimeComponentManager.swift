import Foundation

public struct RuntimeDiscoveredFiles: Equatable, Sendable {
    public let files: [RuntimePayloadFile: URL]

    public init(files: [RuntimePayloadFile: URL] = [:]) {
        self.files = files
    }

    public subscript(file: RuntimePayloadFile) -> URL? {
        files[file]
    }

    public var cfstURL: URL? { self[.cfst] }
    public var mihomoURL: URL? { self[.mihomo] }

    public var installedFiles: Set<RuntimePayloadFile> {
        Set(files.keys)
    }

    public var missingFiles: Set<RuntimePayloadFile> {
        Set(RuntimePayloadFile.allCases).subtracting(installedFiles)
    }

    public var isComplete: Bool {
        missingFiles.isEmpty
    }
}

public struct RuntimeInstallationStatus: Equatable, Sendable {
    public let runtimeDirectory: URL
    public let discoveredFiles: RuntimeDiscoveredFiles
    public let executableFiles: Set<RuntimePayloadFile>
    /// Files that exist but failed a local integrity check.  Keeping these
    /// separate from `missingFiles` lets the UI explain that a component must
    /// be repaired rather than merely installed.
    public let invalidFiles: Set<RuntimePayloadFile>

    public init(
        runtimeDirectory: URL,
        discoveredFiles: RuntimeDiscoveredFiles,
        executableFiles: Set<RuntimePayloadFile>,
        invalidFiles: Set<RuntimePayloadFile> = []
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.discoveredFiles = discoveredFiles
        self.executableFiles = executableFiles
        self.invalidFiles = invalidFiles
    }

    public var cfstURL: URL? {
        invalidFiles.contains(.cfst) ? nil : discoveredFiles.cfstURL
    }
    public var mihomoURL: URL? {
        invalidFiles.contains(.mihomo) ? nil : discoveredFiles.mihomoURL
    }
    public var missingFiles: Set<RuntimePayloadFile> { discoveredFiles.missingFiles }
    public var isInstalled: Bool { discoveredFiles.isComplete }

    public var cfstIsReady: Bool {
        cfstURL != nil
            && executableFiles.contains(.cfst)
            && !invalidFiles.contains(.cfst)
    }

    public var mihomoIsReady: Bool {
        mihomoURL != nil
            && executableFiles.contains(.mihomo)
            && !invalidFiles.contains(.mihomo)
    }

    public var isReady: Bool {
        isInstalled && invalidFiles.isEmpty && cfstIsReady && mihomoIsReady
    }
}

public struct RuntimeDownloadedFile: Equatable, Sendable {
    public let fileURL: URL
    public let statusCode: Int

    public init(fileURL: URL, statusCode: Int) {
        self.fileURL = fileURL
        self.statusCode = statusCode
    }
}

public typealias RuntimeDownloadHandler = @Sendable (URL) async throws -> RuntimeDownloadedFile
public typealias RuntimeArchiveExtractor =
    @Sendable (RuntimeAsset, URL, URL) async throws -> Void
public typealias RuntimeInstallationStageHandler = @Sendable (RuntimeInstallationStage) async -> Void

public enum RuntimeInstallationStage: Equatable, Sendable {
    case preparingInstallation
    case downloading(RuntimeComponent)
    case verifying(RuntimeComponent)
    case extracting(RuntimeComponent)
    case committing
}

public enum RuntimeComponentError: LocalizedError, Equatable, Sendable {
    case missingManifestAsset(RuntimeComponent, RuntimeArchitecture)
    case invalidPayloadExpectations(
        RuntimeComponent,
        expected: [RuntimePayloadFile],
        actual: [RuntimePayloadFile]
    )
    case sourceNotFound(URL)
    case sourceIsNotFileOrDirectory(URL)
    case noPayloadFiles([URL])
    case missingArchivePayload(RuntimeComponent, Set<RuntimePayloadFile>)
    case invalidPayload(RuntimePayloadFile)
    case emptyPayload(RuntimePayloadFile)
    case invalidExecutable(RuntimePayloadFile)
    case incompatibleExecutableArchitecture(
        RuntimePayloadFile,
        expected: RuntimeArchitecture,
        available: [RuntimeArchitecture]
    )
    case unsupportedInstallationArchitecture(
        requested: RuntimeArchitecture,
        current: RuntimeArchitecture
    )
    case invalidDownloadResponse(URL)
    case httpStatus(Int, URL)
    case checksumMismatch(archiveName: String, expected: String, actual: String)
    case payloadByteCountMismatch(RuntimePayloadFile, expected: Int64, actual: Int64)
    case payloadChecksumMismatch(RuntimePayloadFile, expected: String, actual: String)
    case extractionFailed(archiveName: String, status: Int32, output: String)
    case extractionTimedOut(archiveName: String)
    case invalidRuntimeDirectory(URL)
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .missingManifestAsset(let component, let architecture):
            return "缺少 \(component.rawValue) 的 \(architecture.rawValue) 运行组件清单。"
        case .invalidPayloadExpectations(let component, let expected, let actual):
            let expectedNames = expected.map(\.rawValue).joined(separator: ", ")
            let actualNames = actual.map(\.rawValue).joined(separator: ", ")
            return "\(component.rawValue) 的运行组件文件声明无效，必须且只能包含 \(expectedNames)（实际：\(actualNames)）。"
        case .sourceNotFound(let url):
            return "本地路径不存在：\(url.path)"
        case .sourceIsNotFileOrDirectory(let url):
            return "本地路径不是可读取的文件或目录：\(url.path)"
        case .noPayloadFiles(let urls):
            return "未在本地路径中找到 cfst 或 mihomo：\(urls.map(\.path).joined(separator: ", "))"
        case .missingArchivePayload(let component, let files):
            let names = files.map(\.rawValue).sorted().joined(separator: ", ")
            return "\(component.rawValue) 压缩包缺少必要文件：\(names)"
        case .invalidPayload(let payload):
            return "运行组件文件 \(payload.rawValue) 不是可读取的普通文件。"
        case .emptyPayload(let payload):
            return "运行组件文件 \(payload.rawValue) 为空，无法使用。"
        case .invalidExecutable(let payload):
            return "运行组件文件 \(payload.rawValue) 不是可识别的 macOS 可执行文件。"
        case .incompatibleExecutableArchitecture(let payload, let expected, let available):
            let names = available.map(\.rawValue).joined(separator: ", ")
            return "运行组件文件 \(payload.rawValue) 不支持当前 Mac 架构 \(expected.rawValue)（文件架构：\(names)）。"
        case .unsupportedInstallationArchitecture(let requested, let current):
            return "当前安装仅支持本机架构 \(current.rawValue)，不能安装 \(requested.rawValue) 运行组件。"
        case .invalidDownloadResponse(let url):
            return "下载响应不是有效的 HTTP 响应：\(url.absoluteString)"
        case .httpStatus(let status, let url):
            return "下载失败（HTTP \(status)）：\(url.absoluteString)"
        case .checksumMismatch(let archiveName, let expected, let actual):
            return "\(archiveName) 的 SHA256 校验失败，预期 \(expected)，实际 \(actual)。"
        case .payloadByteCountMismatch(let payload, let expected, let actual):
            return "运行组件文件 \(payload.rawValue) 大小校验失败，预期 \(expected) 字节，实际 \(actual) 字节。"
        case .payloadChecksumMismatch(let payload, let expected, let actual):
            return "运行组件文件 \(payload.rawValue) 的 SHA256 校验失败，预期 \(expected)，实际 \(actual)。"
        case .extractionFailed(let archiveName, let status, let output):
            return "解压 \(archiveName) 失败（退出码 \(status)）：\(output)"
        case .extractionTimedOut(let archiveName):
            return "解压 \(archiveName) 超时，已停止解压进程。"
        case .invalidRuntimeDirectory(let url):
            return "Runtime 路径已存在，但不是目录：\(url.path)"
        case .operationInProgress:
            return "另一项运行组件操作尚未完成。"
        }
    }
}

public actor RuntimeComponentManager {
    private static let extractionTimeout: Duration = .seconds(120)
    private static let staleTransactionAge: TimeInterval = 24 * 60 * 60
    private static let legacyPayloadNames = ["xray", "geoip.dat", "geosite.dat"]
    private static let gzipExtractionScript = #"""
        umask 077
        set -C
        exec /usr/bin/gzip -dc -- "$1" > "$2"
        """#
    private static let downloadSession = RuntimeNetworkPolicy.makeSession(
        requestTimeout: RuntimeNetworkPolicy.downloadRequestTimeout,
        resourceTimeout: RuntimeNetworkPolicy.downloadResourceTimeout
    )

    public let runtimeDirectory: URL
    public let manifest: RuntimeManifest

    private let downloadHandler: RuntimeDownloadHandler
    private let archiveExtractor: RuntimeArchiveExtractor
    private var operationInProgress = false

    public init(
        runtimeDirectory: URL,
        manifest: RuntimeManifest = .current
    ) {
        self.runtimeDirectory = runtimeDirectory.standardizedFileURL
        self.manifest = manifest
        self.downloadHandler = Self.downloadUsingURLSession
        self.archiveExtractor = Self.extractArchive
    }

    public init(
        paths: AppPaths,
        manifest: RuntimeManifest = .current
    ) {
        self.init(runtimeDirectory: paths.runtime, manifest: manifest)
    }

    public init(
        runtimeDirectory: URL,
        manifest: RuntimeManifest = .current,
        downloadHandler: @escaping RuntimeDownloadHandler,
        archiveExtractor: @escaping RuntimeArchiveExtractor
    ) {
        self.runtimeDirectory = runtimeDirectory.standardizedFileURL
        self.manifest = manifest
        self.downloadHandler = downloadHandler
        self.archiveExtractor = archiveExtractor
    }

    public func installedStatus() -> RuntimeInstallationStatus {
        let fileManager = FileManager.default
        var files: [RuntimePayloadFile: URL] = [:]
        var executableFiles = Set<RuntimePayloadFile>()
        var invalidFiles = Set<RuntimePayloadFile>()

        for payload in RuntimePayloadFile.allCases {
            let fileURL = runtimeDirectory.appendingPathComponent(payload.rawValue)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                continue
            }
            files[payload] = fileURL
            if Self.isInvalidInstalledPayload(
                payload,
                fileURL: fileURL,
                fileManager: fileManager,
                expectedArchitecture: .current
            ) {
                invalidFiles.insert(payload)
                continue
            }
            if payload.requiresExecutablePermission {
                executableFiles.insert(payload)
            }
        }

        return RuntimeInstallationStatus(
            runtimeDirectory: runtimeDirectory,
            discoveredFiles: RuntimeDiscoveredFiles(files: files),
            executableFiles: executableFiles,
            invalidFiles: invalidFiles
        )
    }

    public func discover(in sourcePath: URL) throws -> RuntimeDiscoveredFiles {
        try discover(in: [sourcePath])
    }

    public func discover(in sourcePaths: [URL]) throws -> RuntimeDiscoveredFiles {
        let files = try Self.discoverFiles(
            in: sourcePaths.map(\.standardizedFileURL),
            using: FileManager.default
        )
        return RuntimeDiscoveredFiles(files: files)
    }

    @discardableResult
    public func install(from sourcePath: URL) throws -> RuntimeInstallationStatus {
        try install(from: [sourcePath])
    }

    @discardableResult
    public func install(from sourcePaths: [URL]) throws -> RuntimeInstallationStatus {
        try beginRuntimeOperation()
        defer { finishRuntimeOperation() }
        try Task.checkCancellation()
        let normalizedPaths = sourcePaths.map(\.standardizedFileURL)
        let files = try Self.discoverFiles(in: normalizedPaths, using: FileManager.default)
        try Task.checkCancellation()
        guard !files.isEmpty else {
            throw RuntimeComponentError.noPayloadFiles(normalizedPaths)
        }
        return try atomicallyInstall(files, expectedArchitecture: .current)
    }

    @discardableResult
    public func downloadAndInstall(
        architecture: RuntimeArchitecture = .current,
        onStage: @escaping RuntimeInstallationStageHandler = { _ in }
    ) async throws -> RuntimeInstallationStatus {
        try await downloadAndInstall(
            components: RuntimeComponent.allCases,
            architecture: architecture,
            onStage: onStage
        )
    }

    @discardableResult
    public func downloadAndInstall(
        component: RuntimeComponent,
        architecture: RuntimeArchitecture = .current,
        onStage: @escaping RuntimeInstallationStageHandler = { _ in }
    ) async throws -> RuntimeInstallationStatus {
        try await downloadAndInstall(
            components: [component],
            architecture: architecture,
            onStage: onStage
        )
    }

    private func downloadAndInstall(
        components: [RuntimeComponent],
        architecture: RuntimeArchitecture,
        onStage: @escaping RuntimeInstallationStageHandler
    ) async throws -> RuntimeInstallationStatus {
        try beginRuntimeOperation()
        defer { finishRuntimeOperation() }
        try Task.checkCancellation()
        guard architecture == .current else {
            throw RuntimeComponentError.unsupportedInstallationArchitecture(
                requested: architecture,
                current: .current
            )
        }
        await onStage(.preparingInstallation)
        try Task.checkCancellation()
        let assets = try assetsForInstallation(
            components: components,
            architecture: architecture
        )
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let workspace = transactionDirectory(prefix: "download")
        let downloadsDirectory = workspace.appendingPathComponent("Downloads", isDirectory: true)
        let extractedDirectory = workspace.appendingPathComponent("Extracted", isDirectory: true)

        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        var payloadFiles: [RuntimePayloadFile: URL] = [:]
        for asset in assets {
            try Task.checkCancellation()
            await onStage(.downloading(asset.component))
            let archiveURL = try await download(
                asset,
                to: downloadsDirectory,
                onVerification: {
                    await onStage(.verifying(asset.component))
                }
            )
            try Task.checkCancellation()
            let componentDirectory =
                extractedDirectory
                .appendingPathComponent(asset.component.rawValue, isDirectory: true)
            try fileManager.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
            await onStage(.extracting(asset.component))
            try Task.checkCancellation()
            try await archiveExtractor(asset, archiveURL, componentDirectory)
            try Task.checkCancellation()

            let discovered = try Self.discoverFiles(
                in: [componentDirectory],
                using: fileManager
            )
            // The component definition is authoritative. A malformed custom
            // manifest must not be able to omit a required component payload.
            let requiredFiles = Set(asset.component.payloadFiles)
            let missingFiles = requiredFiles.subtracting(discovered.keys)
            guard missingFiles.isEmpty else {
                throw RuntimeComponentError.missingArchivePayload(asset.component, missingFiles)
            }
            try Self.validatePayloadExpectations(
                asset.payloadExpectations,
                for: asset.component,
                discoveredFiles: discovered
            )
            for payload in asset.component.payloadFiles {
                payloadFiles[payload] = discovered[payload]
            }
        }

        try Task.checkCancellation()
        await onStage(.committing)
        try Task.checkCancellation()
        return try atomicallyInstall(payloadFiles, expectedArchitecture: architecture)
    }

    public func download(_ asset: RuntimeAsset, to destinationDirectory: URL) async throws -> URL {
        try await download(asset, to: destinationDirectory, onVerification: {})
    }

    private func download(
        _ asset: RuntimeAsset,
        to destinationDirectory: URL,
        onVerification: @escaping @Sendable () async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let downloaded = try await downloadHandler(asset.downloadURL)
        try Task.checkCancellation()
        guard (200...299).contains(downloaded.statusCode) else {
            throw RuntimeComponentError.httpStatus(downloaded.statusCode, asset.downloadURL)
        }

        let archiveURL = destinationDirectory.appendingPathComponent(asset.archiveName)
        var shouldRemoveArchive = true
        defer {
            if shouldRemoveArchive {
                try? fileManager.removeItem(at: archiveURL)
            }
        }
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        try fileManager.copyItem(at: downloaded.fileURL, to: archiveURL)
        try Task.checkCancellation()

        await onVerification()
        try Task.checkCancellation()
        let digest = try RuntimeSHA256.hexDigest(ofFileAt: archiveURL)
        try Task.checkCancellation()
        guard digest == asset.sha256.lowercased() else {
            throw RuntimeComponentError.checksumMismatch(
                archiveName: asset.archiveName,
                expected: asset.sha256.lowercased(),
                actual: digest
            )
        }
        shouldRemoveArchive = false
        return archiveURL
    }

    private func assetsForInstallation(
        components: [RuntimeComponent],
        architecture: RuntimeArchitecture
    ) throws -> [RuntimeAsset] {
        try components.map { component in
            guard let asset = manifest.asset(for: component, architecture: architecture) else {
                throw RuntimeComponentError.missingManifestAsset(component, architecture)
            }
            let expectedPayloads = component.payloadFiles.sorted { $0.rawValue < $1.rawValue }
            let actualPayloads = asset.payloadExpectations.map(\.file)
                .sorted { $0.rawValue < $1.rawValue }
            guard actualPayloads == expectedPayloads else {
                throw RuntimeComponentError.invalidPayloadExpectations(
                    component,
                    expected: expectedPayloads,
                    actual: actualPayloads
                )
            }
            return asset
        }
    }

    private static func validatePayloadExpectations(
        _ expectations: [RuntimePayloadExpectation],
        for component: RuntimeComponent,
        discoveredFiles: [RuntimePayloadFile: URL]
    ) throws {
        let requiredFiles = Set(component.payloadFiles)
        for expectation in expectations where requiredFiles.contains(expectation.file) {
            try Task.checkCancellation()
            guard let fileURL = discoveredFiles[expectation.file] else {
                throw RuntimeComponentError.missingArchivePayload(component, [expectation.file])
            }
            let values = try fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RuntimeComponentError.invalidPayload(expectation.file)
            }

            let actualByteCount = Int64(values.fileSize ?? 0)
            if let expectedByteCount = expectation.byteCount,
                actualByteCount != expectedByteCount
            {
                throw RuntimeComponentError.payloadByteCountMismatch(
                    expectation.file,
                    expected: expectedByteCount,
                    actual: actualByteCount
                )
            }

            if let expectedSHA256 = expectation.sha256 {
                let actualSHA256 = try RuntimeSHA256.hexDigest(ofFileAt: fileURL)
                guard actualSHA256 == expectedSHA256 else {
                    throw RuntimeComponentError.payloadChecksumMismatch(
                        expectation.file,
                        expected: expectedSHA256,
                        actual: actualSHA256
                    )
                }
            }
        }
    }

    private func beginRuntimeOperation() throws {
        guard !operationInProgress else {
            throw RuntimeComponentError.operationInProgress
        }
        removeStaleTransactionDirectories()
        operationInProgress = true
    }

    private func finishRuntimeOperation() {
        operationInProgress = false
    }

    private func atomicallyInstall(
        _ sourceFiles: [RuntimePayloadFile: URL],
        expectedArchitecture: RuntimeArchitecture
    ) throws -> RuntimeInstallationStatus {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let parentDirectory = runtimeDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        let runtimeExists = fileManager.fileExists(
            atPath: runtimeDirectory.path,
            isDirectory: &isDirectory
        )
        if runtimeExists && !isDirectory.boolValue {
            throw RuntimeComponentError.invalidRuntimeDirectory(runtimeDirectory)
        }

        let workspace = transactionDirectory(prefix: "install")
        let candidateDirectory = workspace.appendingPathComponent("Runtime", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        if runtimeExists {
            try fileManager.copyItem(at: runtimeDirectory, to: candidateDirectory)
        } else {
            try fileManager.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
        }

        for (payload, sourceURL) in sourceFiles {
            try Task.checkCancellation()
            let destinationURL = candidateDirectory.appendingPathComponent(payload.rawValue)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }

        // Legacy payloads are removed only from the transaction candidate and
        // only after Mihomo is present. If validation fails, the live Runtime
        // directory remains untouched and the candidate is discarded.
        let candidateMihomoURL = candidateDirectory.appendingPathComponent(
            RuntimePayloadFile.mihomo.rawValue
        )
        if fileManager.fileExists(atPath: candidateMihomoURL.path) {
            for legacyName in Self.legacyPayloadNames {
                try Task.checkCancellation()
                let legacyURL = candidateDirectory.appendingPathComponent(legacyName)
                if fileManager.fileExists(atPath: legacyURL.path) {
                    try fileManager.removeItem(at: legacyURL)
                }
            }
        }

        for payload in RuntimePayloadFile.allCases where payload.requiresExecutablePermission {
            try Task.checkCancellation()
            let executableURL = candidateDirectory.appendingPathComponent(payload.rawValue)
            guard fileManager.fileExists(atPath: executableURL.path) else { continue }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: executableURL.path
            )
        }

        try validateCandidate(
            at: candidateDirectory,
            payloads: Set(sourceFiles.keys),
            expectedArchitecture: expectedArchitecture,
            fileManager: fileManager
        )

        // This is the commit point. Cancellation is honored before the atomic
        // replacement; once replacement starts it must run to completion so a
        // partially installed Runtime directory is never exposed.
        try Task.checkCancellation()
        if runtimeExists {
            let backupName = ".\(runtimeDirectory.lastPathComponent)-backup-\(UUID().uuidString)"
            _ = try fileManager.replaceItemAt(
                runtimeDirectory,
                withItemAt: candidateDirectory,
                backupItemName: backupName,
                options: []
            )
            let backupURL = parentDirectory.appendingPathComponent(backupName)
            try? fileManager.removeItem(at: backupURL)
        } else {
            try fileManager.moveItem(at: candidateDirectory, to: runtimeDirectory)
        }

        return installedStatus()
    }

    private func validateCandidate(
        at directoryURL: URL,
        payloads: Set<RuntimePayloadFile>,
        expectedArchitecture: RuntimeArchitecture,
        fileManager: FileManager
    ) throws {
        for payload in payloads.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            let fileURL = directoryURL.appendingPathComponent(payload.rawValue)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                continue
            }

            if let error = Self.validationError(
                payload,
                fileURL: fileURL,
                fileManager: fileManager,
                expectedArchitecture: expectedArchitecture
            ) {
                throw error
            }
        }
    }

    private static func isInvalidInstalledPayload(
        _ payload: RuntimePayloadFile,
        fileURL: URL,
        fileManager: FileManager,
        expectedArchitecture: RuntimeArchitecture
    ) -> Bool {
        validationError(
            payload,
            fileURL: fileURL,
            fileManager: fileManager,
            expectedArchitecture: expectedArchitecture
        ) != nil
    }

    private static func validationError(
        _ payload: RuntimePayloadFile,
        fileURL: URL,
        fileManager: FileManager,
        expectedArchitecture: RuntimeArchitecture
    ) -> RuntimeComponentError? {
        guard
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            return .invalidPayload(payload)
        }

        guard (values.fileSize ?? 0) > 0 else {
            return .emptyPayload(payload)
        }

        guard payload.requiresExecutablePermission else { return nil }
        guard fileManager.isExecutableFile(atPath: fileURL.path) else {
            return .invalidExecutable(payload)
        }

        let inspection = RuntimeBinaryInspector.inspect(fileAt: fileURL)
        switch inspection {
        case .script:
            return nil
        case .invalid:
            return .invalidExecutable(payload)
        case .machO(let architectures):
            guard architectures.contains(expectedArchitecture) else {
                return .incompatibleExecutableArchitecture(
                    payload,
                    expected: expectedArchitecture,
                    available: architectures.sorted { $0.rawValue < $1.rawValue }
                )
            }
            return nil
        }
    }

    private func transactionDirectory(prefix: String) -> URL {
        runtimeDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(runtimeDirectory.lastPathComponent)-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func removeStaleTransactionDirectories(now: Date = Date()) {
        let fileManager = FileManager.default
        let parent = runtimeDirectory.deletingLastPathComponent()
        let prefixes = ["download", "install"].map {
            ".\(runtimeDirectory.lastPathComponent)-\($0)-"
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants]
            )
        else { return }

        let cutoff = now.addingTimeInterval(-Self.staleTransactionAge)
        for entry in entries where prefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
            guard
                let values = try? entry.resourceValues(forKeys: keys),
                values.isDirectory == true,
                values.isSymbolicLink != true,
                let modifiedAt = values.contentModificationDate,
                modifiedAt <= cutoff
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func discoverFiles(
        in sourcePaths: [URL],
        using fileManager: FileManager
    ) throws -> [RuntimePayloadFile: URL] {
        var candidates: [RuntimePayloadFile: [URL]] = [:]
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]

        for sourcePath in sourcePaths {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourcePath.path, isDirectory: &isDirectory) else {
                throw RuntimeComponentError.sourceNotFound(sourcePath)
            }

            if isDirectory.boolValue {
                guard
                    let enumerator = fileManager.enumerator(
                        at: sourcePath,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                else {
                    throw RuntimeComponentError.sourceIsNotFileOrDirectory(sourcePath)
                }
                for case let fileURL as URL in enumerator {
                    try Task.checkCancellation()
                    try addCandidate(
                        fileURL,
                        resourceKeys: resourceKeys,
                        to: &candidates
                    )
                }
            } else {
                try addCandidate(
                    sourcePath,
                    resourceKeys: resourceKeys,
                    to: &candidates
                )
            }
        }

        return candidates.mapValues { urls in
            urls.min { lhs, rhs in
                let lhsDepth = lhs.pathComponents.count
                let rhsDepth = rhs.pathComponents.count
                if lhsDepth == rhsDepth {
                    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
                return lhsDepth < rhsDepth
            }!
        }
    }

    private static func addCandidate(
        _ fileURL: URL,
        resourceKeys: Set<URLResourceKey>,
        to candidates: inout [RuntimePayloadFile: [URL]]
    ) throws {
        guard let payload = RuntimePayloadFile(rawValue: fileURL.lastPathComponent) else {
            return
        }
        let values = try fileURL.resourceValues(forKeys: resourceKeys)
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            return
        }
        candidates[payload, default: []].append(fileURL.standardizedFileURL)
    }

    private static func downloadUsingURLSession(_ url: URL) async throws -> RuntimeDownloadedFile {
        try await downloadUsingURLSession(url, using: downloadSession)
    }

    static func downloadUsingURLSession(
        _ url: URL,
        using session: URLSession
    ) async throws -> RuntimeDownloadedFile {
        try Task.checkCancellation()
        let (fileURL, response) = try await session.download(from: url)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw RuntimeComponentError.invalidDownloadResponse(url)
        }
        return RuntimeDownloadedFile(fileURL: fileURL, statusCode: response.statusCode)
    }

    static func extractArchive(
        _ asset: RuntimeAsset,
        _ archiveURL: URL,
        _ destinationURL: URL
    ) async throws {
        switch asset.archiveFormat {
        case .zip:
            try await extractZip(archiveURL, to: destinationURL)
        case .gzip(let output):
            try await extractGzip(
                archiveURL,
                to: destinationURL.appendingPathComponent(output.rawValue)
            )
        }
    }

    private static func extractZip(_ archiveURL: URL, to destinationURL: URL) async throws {
        let result: SupervisedCommandResult
        do {
            result = try await SupervisedCommand.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archiveURL.path, destinationURL.path],
                workingDirectoryURL: destinationURL,
                timeout: extractionTimeout
            )
        } catch SupervisedCommandError.timedOut {
            throw RuntimeComponentError.extractionTimedOut(archiveName: archiveURL.lastPathComponent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RuntimeComponentError.extractionFailed(
                archiveName: archiveURL.lastPathComponent,
                status: -1,
                output: error.localizedDescription
            )
        }

        if let readError = result.outputReadError {
            throw RuntimeComponentError.extractionFailed(
                archiveName: archiveURL.lastPathComponent,
                status: result.status,
                output: "读取解压输出失败：\(readError)"
            )
        }
        guard result.status == 0 else {
            throw RuntimeComponentError.extractionFailed(
                archiveName: archiveURL.lastPathComponent,
                status: result.status,
                output: result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func extractGzip(_ archiveURL: URL, to outputURL: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        var extractionSucceeded = false
        defer {
            if !extractionSucceeded {
                try? fileManager.removeItem(at: outputURL)
            }
        }

        let result: SupervisedCommandResult
        do {
            // The fixed script receives paths only as quoted positional
            // parameters. Decompressed stdout streams directly to the
            // canonical payload path, so binary data never enters the
            // command's bounded diagnostic String capture. `-c` also avoids
            // trusting any filename stored in the gzip header.
            result = try await SupervisedCommand.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    gzipExtractionScript,
                    "viasix-gzip-extractor",
                    archiveURL.path,
                    outputURL.path,
                ],
                workingDirectoryURL: outputURL.deletingLastPathComponent(),
                timeout: extractionTimeout
            )
        } catch SupervisedCommandError.timedOut {
            throw RuntimeComponentError.extractionTimedOut(archiveName: archiveURL.lastPathComponent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RuntimeComponentError.extractionFailed(
                archiveName: archiveURL.lastPathComponent,
                status: -1,
                output: error.localizedDescription
            )
        }

        if let readError = result.outputReadError {
            throw RuntimeComponentError.extractionFailed(
                archiveName: archiveURL.lastPathComponent,
                status: result.status,
                output: "读取解压错误输出失败：\(readError)"
            )
        }
        guard result.status == 0 else {
            throw RuntimeComponentError.extractionFailed(
                archiveName: archiveURL.lastPathComponent,
                status: result.status,
                output: result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        extractionSucceeded = true
    }
}
