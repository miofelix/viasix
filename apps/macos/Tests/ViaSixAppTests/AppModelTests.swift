import Foundation
import ViaSixMihomoConfig
import ViaSixPrivilegedProtocol
import XCTest

@testable import ViaSixApp
@testable import ViaSixCore

@MainActor
final class AppModelTests: XCTestCase {
    func testIPv6RuntimeBlocksStartupWithoutIPv6SelectionOrTunReadiness() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await bootstrapper.replaceProfile(
            with: validProfile(),
            selectedIP: "2606:4700::10"
        )
        try await store.save(
            UserPreferences(parameters: .defaults(ipv6File: paths.ipv6List))
        )
        let tunCoordinator = ControlledTunModeCoordinator(registration: .notRegistered)
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            tunCoordinator: tunCoordinator
        )

        model.start()
        try await waitUntilReady(model)
        XCTAssertEqual(model.ipv6TransportReadinessIssue, "IPv6 模式需要先选择有效的 IPv6 节点")

        model.startProxy()
        try await Task.sleep(for: .milliseconds(40))
        let startCountWithoutNode = await tunCoordinator.startCount
        XCTAssertEqual(startCountWithoutNode, 0)

        model.selectIP("2606:4700::10")
        try await waitUntil { model.switchingIP == nil }
        XCTAssertEqual(model.state.preferences.selectedIP, "2606:4700::10")
        XCTAssertEqual(model.ipv6TransportReadinessIssue, "虚拟网卡模式需要先准备 TUN 服务")

        model.startProxy()
        try await Task.sleep(for: .milliseconds(40))
        let startCountWithoutTun = await tunCoordinator.startCount
        XCTAssertEqual(startCountWithoutTun, 0)
        await model.shutdown()
    }

    func testIPv6RuntimeBlocksProviderOnlyProfile() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try providerOnlyProfile().write(to: paths.profileConfig, options: .atomic)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606:4700::11"
            )
        )
        let tunCoordinator = ControlledTunModeCoordinator()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            tunCoordinator: tunCoordinator
        )

        model.start()
        try await waitUntilReady(model)

        XCTAssertFalse(model.state.proxySupportsNodeSelection)
        XCTAssertEqual(
            model.proxyConfigurationIssue,
            MihomoConfigurationError.ipv6ManagedProfileRequired.localizedDescription
        )
        model.startProxy()
        try await Task.sleep(for: .milliseconds(40))
        let startCount = await tunCoordinator.startCount
        XCTAssertEqual(startCount, 0)
        await model.shutdown()
    }

    func testSystemProxyCanToggleWhileTunKeepsRunning() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await bootstrapper.replaceProfile(with: validProfile(), selectedIP: "2606::1")
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(networkAccessMode: .virtualInterface),
            selectedIP: "2606::1"
        )
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::1"
            )
        )
        let systemProxy = ControlledSystemProxyManager()
        let tunCoordinator = ControlledTunModeCoordinator()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            tunCoordinator: tunCoordinator
        )

        model.start()
        try await waitUntilReady(model)
        model.startProxy()
        try await waitUntilAsync {
            let tunStartCount = await tunCoordinator.startCount
            return tunStartCount == 1
                && model.state.proxyCorePhase == .running
                && model.state.tun.isRunning
                && model.state.systemProxyPhase == .disabled
        }

        model.setSystemProxyEnabled(true)
        try await waitUntilAsync {
            let tunStartCount = await tunCoordinator.startCount
            let enableCount = await systemProxy.enableCount
            return tunStartCount == 1
                && enableCount == 1
                && model.state.tun.isRunning
                && model.state.localProxyConfiguration.systemProxyEnabled
                && model.state.systemProxyPhase == .enabled
        }

        model.setSystemProxyEnabled(false)
        try await waitUntilAsync {
            let tunStartCount = await tunCoordinator.startCount
            let tunStopCount = await tunCoordinator.stopCount
            let disableCount = await systemProxy.disableCount
            return tunStartCount == 1
                && tunStopCount == 0
                && disableCount == 1
                && model.state.tun.isRunning
                && !model.state.localProxyConfiguration.systemProxyEnabled
                && model.state.systemProxyPhase == .disabled
        }

        model.stopProxy()
        try await waitUntil {
            model.state.proxyCorePhase == .stopped
                && model.state.tun.sessionPhase == .inactive
        }
        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
    }

    func testSystemProxyAndTunCanRunTogetherAndStopCleanly() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await bootstrapper.replaceProfile(with: validProfile(), selectedIP: "2606::1")
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                networkAccessMode: .virtualInterface,
                systemProxyEnabled: true
            ),
            selectedIP: "2606::1"
        )
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::1"
            )
        )
        let systemProxy = ControlledSystemProxyManager()
        let tunCoordinator = ControlledTunModeCoordinator()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            tunCoordinator: tunCoordinator
        )

        model.start()
        try await waitUntilReady(model)
        XCTAssertTrue(model.state.localProxyConfiguration.systemProxyEnabled)
        XCTAssertEqual(
            model.state.localProxyConfiguration.networkAccessMode,
            .virtualInterface
        )

        model.startProxy()
        try await waitUntilAsync {
            let enableCount = await systemProxy.enableCount
            return model.state.proxyCorePhase == .running
                && model.state.tun.isRunning
                && model.state.systemProxyPhase == .enabled
                && enableCount == 1
        }

        model.stopProxy()
        try await waitUntilAsync {
            let disableCount = await systemProxy.disableCount
            return model.state.proxyCorePhase == .stopped
                && model.state.tun.sessionPhase == .inactive
                && model.state.systemProxyPhase == .disabled
                && disableCount == 1
        }

        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
    }

    func testTunToggleRestartsRuntimeWithoutChangingSystemProxyPreference() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await bootstrapper.replaceProfile(with: validProfile(), selectedIP: "2606::1")
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                networkAccessMode: .localProxy,
                systemProxyEnabled: true
            ),
            selectedIP: "2606::1"
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::1",
                mihomoPath: executableURL.path
            )
        )
        let systemProxy = ControlledSystemProxyManager()
        let proxyCore = ControlledMihomoController()
        let tunCoordinator = ControlledTunModeCoordinator()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            tunCoordinator: tunCoordinator,
            proxyCoreControllerFactory: { _ in proxyCore }
        )

        model.start()
        try await waitUntilReady(model)
        model.startProxy()
        try await waitUntilAsync {
            let startCount = await proxyCore.startCount
            return startCount == 1
                && model.state.proxyCorePhase == .running
                && model.state.systemProxyPhase == .enabled
        }

        model.setNetworkAccessMode(.virtualInterface)
        try await waitUntilAsync {
            let stopCount = await proxyCore.stopCount
            let tunStartCount = await tunCoordinator.startCount
            return stopCount == 1
                && tunStartCount == 1
                && model.state.localProxyConfiguration.networkAccessMode == .virtualInterface
                && model.state.localProxyConfiguration.systemProxyEnabled
                && model.state.tun.isRunning
                && model.state.systemProxyPhase == .enabled
        }

        model.setNetworkAccessMode(.localProxy)
        try await waitUntilAsync {
            let tunStopCount = await tunCoordinator.stopCount
            let startCount = await proxyCore.startCount
            return tunStopCount == 1
                && startCount == 2
                && model.state.localProxyConfiguration.networkAccessMode == .localProxy
                && model.state.localProxyConfiguration.systemProxyEnabled
                && model.state.tun.sessionPhase == .inactive
                && model.state.systemProxyPhase == .enabled
        }

        model.stopProxy()
        try await waitUntil { model.state.proxyCorePhase == .stopped }
        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
    }

    func testTunModeStartsWithPrivilegedRuntimeWithoutUserMihomoAndStopsCleanly()
        async throws
    {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await bootstrapper.replaceProfile(with: validProfile(), selectedIP: "2606::1")
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                networkAccessMode: .virtualInterface,
                tunStack: .gvisor,
                tunMTU: 1_400,
                tunStrictRoute: true
            ),
            selectedIP: "2606::1"
        )
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::1"
            )
        )
        let tunCoordinator = ControlledTunModeCoordinator()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            tunCoordinator: tunCoordinator
        )

        model.start()
        try await waitUntilReady(model)
        XCTAssertTrue(model.canUseTunMode)
        XCTAssertTrue(model.activeProxyRuntimeIsAvailable)
        XCTAssertFalse(model.hasProxyCoreExecutable)

        model.startProxy()
        try await waitUntil {
            model.state.proxyCorePhase == .running && model.state.tun.isRunning
        }

        let startCount = await tunCoordinator.startCount
        let startedPlanValue = await tunCoordinator.startedPlan
        XCTAssertEqual(startCount, 1)
        let startedPlan = try XCTUnwrap(startedPlanValue)
        XCTAssertEqual(startedPlan.options.tun?.stack, .gvisor)
        XCTAssertEqual(startedPlan.options.tun?.mtu, 1_400)
        XCTAssertEqual(startedPlan.options.tun?.strictRoute, true)

        model.setNetworkAccessMode(.localProxy)
        XCTAssertEqual(
            model.state.localProxyConfiguration.networkAccessMode,
            .virtualInterface
        )
        XCTAssertTrue(model.state.notice?.message.contains("安装 Mihomo") == true)

        model.stopProxy()
        try await waitUntil {
            model.state.proxyCorePhase == .stopped
                && model.state.tun.sessionPhase == .inactive
        }
        let stopCount = await tunCoordinator.stopCount
        XCTAssertEqual(stopCount, 1)
        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
    }

    func testBootstrapAdoptsOwnedTunSessionAndShutdownStopsIt() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .virtualInterface
            )
        )
        let tunCoordinator = ControlledTunModeCoordinator(sessionIsRunning: true)
        let model = makeModel(
            paths: paths,
            bootstrapper: bootstrapper,
            tunCoordinator: tunCoordinator
        )

        model.start()
        try await waitUntilReady(model)
        XCTAssertEqual(model.state.proxyCorePhase, .running)
        XCTAssertTrue(model.state.tun.isRunning)

        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
        let stopCount = await tunCoordinator.stopCount
        let phase = await tunCoordinator.sessionPhase
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(phase, .inactive)
    }

    func testForeignTunSessionCannotBeStoppedStartedOrUsedForMaintenance() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .virtualInterface
            )
        )
        let tunCoordinator = ControlledTunModeCoordinator(
            sessionPhase: .running,
            sessionOwnedByCaller: false
        )
        let model = makeModel(
            paths: paths,
            bootstrapper: bootstrapper,
            tunCoordinator: tunCoordinator
        )

        model.start()
        try await waitUntilReady(model)

        XCTAssertTrue(model.hasForeignTunSession)
        XCTAssertFalse(model.canStopTunSession)
        XCTAssertFalse(model.canMaintainTunInstallation)
        XCTAssertEqual(model.state.proxyCorePhase, .stopped)

        model.stopProxy()
        model.installTunService()
        model.repairTunService()
        model.installOrRepairTunRuntime()
        model.startProxy()
        try await Task.sleep(for: .milliseconds(50))

        let stopCountBeforeShutdown = await tunCoordinator.stopCount
        let startCount = await tunCoordinator.startCount
        let registerCount = await tunCoordinator.registerCount
        let repairCount = await tunCoordinator.repairCount
        let runtimeInstallCount = await tunCoordinator.runtimeInstallCount
        XCTAssertEqual(stopCountBeforeShutdown, 0)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(registerCount, 0)
        XCTAssertEqual(repairCount, 0)
        XCTAssertEqual(runtimeInstallCount, 0)
        XCTAssertTrue(model.state.notice?.message.contains("其他登录用户") == true)

        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
        let stopCountAfterShutdown = await tunCoordinator.stopCount
        XCTAssertEqual(stopCountAfterShutdown, 0)
    }

    func testBootstrapDoesNotRecoverAnotherUsersTunJournal() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let tunCoordinator = ControlledTunModeCoordinator(
            sessionPhase: .recoveryRequired,
            sessionOwnedByCaller: false
        )
        let model = makeModel(paths: paths, tunCoordinator: tunCoordinator)

        model.start()
        try await waitUntilReady(model)

        XCTAssertEqual(model.state.tun.sessionPhase, .recoveryRequired)
        XCTAssertTrue(model.hasForeignTunSession)
        XCTAssertFalse(model.canRecoverTunSession)
        var recoverCount = await tunCoordinator.recoverCount
        XCTAssertEqual(recoverCount, 0)

        model.recoverTunSession()
        try await Task.sleep(for: .milliseconds(50))
        recoverCount = await tunCoordinator.recoverCount
        XCTAssertEqual(recoverCount, 0)

        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
    }

    func testRecoverTunSessionRestoresRunningProxyPhase() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .virtualInterface
            ),
            selectedIP: nil
        )
        // Bootstrap starts clean so it does not auto-recover during launch.
        let tunCoordinator = ControlledTunModeCoordinator(
            sessionPhase: .inactive,
            sessionOwnedByCaller: false
        )
        let model = makeModel(
            paths: paths,
            bootstrapper: bootstrapper,
            tunCoordinator: tunCoordinator
        )

        model.start()
        try await waitUntilReady(model)
        XCTAssertEqual(model.state.proxyCorePhase, .stopped)

        await tunCoordinator.seedRecoveryRequiredSession()
        await tunCoordinator.setRecoverRestoresRunningSession(true)
        model.refreshTunState()
        try await waitUntil {
            model.state.tun.sessionPhase == .recoveryRequired
                && model.canRecoverTunSession
        }

        model.recoverTunSession()
        try await waitUntil {
            model.state.tun.sessionPhase == .running
                && model.state.proxyCorePhase == .running
        }

        let recoverCount = await tunCoordinator.recoverCount
        XCTAssertEqual(recoverCount, 1)
        XCTAssertTrue(model.state.traffic.isMonitoring)
        XCTAssertTrue(model.state.notice?.message.contains("恢复运行") == true)

        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
    }

    func testFailedTunSessionWithCompletedCleanupAllowsMaintenance() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let tunCoordinator = ControlledTunModeCoordinator(
            sessionPhase: .failed,
            sessionOwnedByCaller: true
        )
        let model = makeModel(paths: paths, tunCoordinator: tunCoordinator)

        model.start()
        try await waitUntilReady(model)

        XCTAssertTrue(model.canMaintainTunInstallation)
        XCTAssertFalse(model.canRecoverTunSession)

        model.installOrRepairTunRuntime()
        try await waitUntilAsync {
            await tunCoordinator.runtimeInstallCount == 1
        }

        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
    }

    func testBecomingActiveRefreshesTunApprovalState() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let tunCoordinator = ControlledTunModeCoordinator(
            registration: .requiresApproval
        )
        let model = makeModel(paths: paths, tunCoordinator: tunCoordinator)

        model.start()
        try await waitUntilReady(model)
        XCTAssertEqual(model.state.tun.servicePhase, .requiresApproval)

        await tunCoordinator.setRegistration(.enabled)
        model.applicationDidBecomeActive()
        try await waitUntil {
            model.state.tun.servicePhase == .ready
                && model.state.tun.runtimePhase == .ready
        }

        let statusCount = await tunCoordinator.statusCount
        XCTAssertGreaterThan(statusCount, 0)
        let didShutdown = await model.shutdown()
        XCTAssertTrue(didShutdown)
    }

    func testBootstrapUsesPersistedSelectionInsteadOfInferringItFromGeneratedProfile()
        async throws
    {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await bootstrapper.replaceProfile(
            with: validProfile(),
            selectedIP: "2606::2"
        )
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::1"
            ))

        let model = AppModel(
            paths: paths,
            preferencesStore: store,
            bootstrapper: bootstrapper,
            runtimeManager: RuntimeComponentManager(paths: paths),
            exitDetector: ExitIPDetector()
        )
        model.start()
        try await waitUntilReady(model)

        XCTAssertEqual(model.state.preferences.selectedIP, "2606::1")
        let currentIP = try await bootstrapper.currentConfigIP()
        XCTAssertEqual(currentIP, "2606::1")
        await model.shutdown()
    }

    func testBootstrapRegeneratesMissingConfigFromPersistedSelection() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try await bootstrapper.replaceProfile(with: validProfile())
        try FileManager.default.removeItem(at: paths.generatedConfig)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::3"
            ))

        let model = AppModel(
            paths: paths,
            preferencesStore: store,
            bootstrapper: bootstrapper,
            runtimeManager: RuntimeComponentManager(paths: paths),
            exitDetector: ExitIPDetector()
        )
        model.start()
        try await waitUntilReady(model)

        let currentIP = try await bootstrapper.currentConfigIP()
        XCTAssertEqual(currentIP, "2606::3")
        await model.shutdown()
    }

    func testBootstrapIgnoresCorruptCachedResults() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try Data("IP,Sent,Recv\n\"unterminated".utf8).write(to: paths.resultCSV)

        let model = makeModel(paths: paths, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)

        XCTAssertTrue(model.state.results.isEmpty)
        XCTAssertTrue(model.state.logs.contains { $0.message.contains("损坏的历史测速结果") })
        await model.shutdown()
    }

    func testBootstrapBacksUpCorruptPreferencesAndRecordsWarning() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.prepare()
        let corruptData = Data("not valid preferences json".utf8)
        try corruptData.write(to: paths.preferences, options: .atomic)
        let model = makeModel(paths: paths)

        model.start()
        try await waitUntilReady(model)

        XCTAssertEqual(model.state.preferences.selectedIP, "")
        XCTAssertTrue(
            model.state.logs.contains {
                $0.level == .warning
                    && $0.message.contains("偏好文件无法解析")
                    && $0.message.contains("preferences.corrupt-")
                    && $0.message.contains("本次使用默认设置")
            }
        )
        let backups = try corruptPreferenceBackups(in: paths)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corruptData)
        await model.shutdown()
    }

    func testBootstrapFailsOnPreferencesReadErrorWithoutOverwritingOriginal() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.prepare()
        try FileManager.default.createDirectory(
            at: paths.preferences,
            withIntermediateDirectories: false
        )
        let model = makeModel(paths: paths)

        model.start()
        try await waitUntil {
            if case .failed = model.state.launchPhase { return true }
            return false
        }

        guard case .failed(let message) = model.state.launchPhase else {
            return XCTFail("Expected bootstrap to fail")
        }
        XCTAssertTrue(message.contains("无法读取偏好文件"))
        await model.shutdown()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.preferences.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(try corruptPreferenceBackups(in: paths).isEmpty)
    }

    func testBootstrapAllowsRepairingCorruptProxyProfile() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try Data("proxies: [".utf8).write(to: paths.profileConfig, options: .atomic)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::4"
            ))

        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)

        XCTAssertEqual(model.state.preferences.selectedIP, "2606::4")
        XCTAssertTrue(model.state.logs.contains { $0.message.contains("代理配置需要修复") })
        await model.shutdown()
    }

    func testBootstrapUsesProxyEndpointFromLocalConfiguration() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try await bootstrapper.replaceProfile(with: validProfile())
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                listenAddress: "127.0.0.2",
                port: 18_080,
                networkAccessMode: .localProxy
            ),
            selectedIP: "2606:4700::100"
        )
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606:4700::100"
            )
        )

        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)

        XCTAssertEqual(model.state.proxyEndpoint, ProxyEndpoint(host: "127.0.0.2", port: 18_080))
        XCTAssertTrue(model.isProxyConfigurationReady)
        XCTAssertNil(model.proxyConfigurationIssue)
        await model.shutdown()
    }

    func testBootstrapRebuildsGeneratedConfigWhenProfileDetailsChange() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        let firstProfile = validProfile(
            address: "first.example.net",
            userID: "f4edc501-056c-4572-9da8-ad63a264a698",
            serverName: "first.example.net",
            path: "/first"
        )
        try await bootstrapper.replaceProfile(with: firstProfile, selectedIP: "2606::5")
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                listenAddress: "127.0.0.3",
                port: 18_081
            ),
            selectedIP: "2606::5"
        )
        let secondProfile = validProfile(
            address: "second-origin.example.net",
            userID: "22de5d8d-17f7-40e8-a83f-567ae87c865a",
            serverName: "second.example.net",
            path: "/second"
        )
        try secondProfile.write(to: paths.profileConfig, options: .atomic)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::5"
            )
        )

        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)

        let generatedData = try Data(contentsOf: paths.generatedConfig)
        let generated = String(decoding: generatedData, as: UTF8.self)
        XCTAssertEqual(model.state.proxyEndpoint, ProxyEndpoint(host: "127.0.0.3", port: 18_081))
        XCTAssertEqual(
            MihomoServerConfiguration.proxyServerAddress(in: generatedData),
            "2606::5"
        )
        XCTAssertTrue(generated.contains("22de5d8d-17f7-40e8-a83f-567ae87c865a"))
        XCTAssertTrue(generated.contains("second.example.net"))
        XCTAssertTrue(generated.contains("/second"))
        XCTAssertFalse(generated.contains("f4edc501-056c-4572-9da8-ad63a264a698"))
        await model.shutdown()
    }

    func testMissingProxyProfileBlocksStartAndOffersProfilesRecovery() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)

        let executableURL = paths.root.appendingPathComponent("mihomo-test")
        let invocationMarkerURL = paths.root.appendingPathComponent("mihomo-invoked.txt")
        try #"""
        #!/bin/sh
        touch mihomo-invoked.txt
        exit 0
        """#.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::6",
                mihomoPath: executableURL.path
            ))

        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)
        XCTAssertTrue(model.hasProxyCoreExecutable)
        XCTAssertEqual(
            model.proxyConfigurationIssue,
            MihomoConfigurationError.missingProxySource.localizedDescription
        )
        XCTAssertFalse(model.isProxyConfigurationReady)

        model.startProxy()
        XCTAssertEqual(model.state.proxyCorePhase, .stopped)
        XCTAssertEqual(model.state.notice?.action, .openProfiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationMarkerURL.path))
        XCTAssertTrue(
            model.state.notice?.message.contains(
                MihomoConfigurationError.missingProxySource.localizedDescription
            ) == true
        )
        await model.shutdown()
    }

    func testLegacyXrayPathIsNeverUsedAsMihomoExecutable() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy
            )
        )

        let legacyExecutable = paths.root.appendingPathComponent("xray-test")
        let invocationMarker = paths.root.appendingPathComponent("xray-invoked.txt")
        try #"""
        #!/bin/sh
        touch xray-invoked.txt
        exit 0
        """#.write(to: legacyExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: legacyExecutable.path
        )
        try writeLegacyPreferences(
            xrayPath: legacyExecutable.path,
            to: paths.preferences,
            ipv6File: paths.ipv6List
        )
        let recorder = ProxyCoreConfigurationRecorder()
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            bootstrapper: bootstrapper,
            proxyCoreControllerFactory: { configuration in
                recorder.record(configuration)
                return proxyCore
            }
        )

        model.start()
        try await waitUntilReady(model)
        XCTAssertEqual(model.state.preferences.mihomoPath, "")

        model.startProxy()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(FileManager.default.fileExists(atPath: invocationMarker.path))
        XCTAssertNotEqual(recorder.configuration?.executableURL, legacyExecutable)
        await model.shutdown()
    }

    func testRoutingModeCanSwitchToDirectWithoutServerOrSelectedNode() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        let model = makeModel(paths: paths, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)
        XCTAssertFalse(model.isProxyConfigurationReady)

        model.setRoutingMode(.direct)
        try await waitUntil {
            !model.isRoutingModeChanging
                && model.state.localProxyConfiguration.routingMode == .direct
        }

        XCTAssertTrue(model.isProxyConfigurationReady)
        let stored = try await bootstrapper.loadLocalProxyConfiguration()
        XCTAssertEqual(stored.routingMode, .direct)
        let generated = String(
            decoding: try Data(contentsOf: paths.generatedConfig),
            as: UTF8.self
        )
        XCTAssertTrue(generated.contains("mode: direct"))
        XCTAssertFalse(generated.contains("proxies:"))
        XCTAssertFalse(generated.contains("proxy-providers:"))
        await model.shutdown()
    }

    func testDirectModeStartsWithoutSelectedNodeAndSystemProxyFollowsLifecycle() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "",
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager()
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)

        model.setSystemProxyEnabled(true)
        try await waitUntil {
            model.state.localProxyConfiguration.systemProxyEnabled
        }
        let activeBeforeStart = await systemProxy.isActive
        let storedBeforeStart = try await bootstrapper.loadLocalProxyConfiguration()
        XCTAssertFalse(activeBeforeStart)
        XCTAssertEqual(storedBeforeStart.networkAccessMode, .localProxy)
        XCTAssertTrue(storedBeforeStart.systemProxyEnabled)

        model.startProxy()
        try await waitUntilAsync {
            let enableCount = await systemProxy.enableCount
            return model.state.proxyCorePhase == .running
                && model.state.systemProxyPhase == .enabled
                && enableCount == 1
        }

        XCTAssertEqual(model.state.preferences.selectedIP, "")
        let generated = String(
            decoding: try Data(contentsOf: paths.generatedConfig),
            as: UTF8.self
        )
        XCTAssertTrue(generated.contains("mode: direct"))
        XCTAssertFalse(generated.contains("proxies:"))
        XCTAssertFalse(generated.contains("proxy-providers:"))
        let lastEndpoint = await systemProxy.lastEndpoint
        XCTAssertEqual(lastEndpoint, model.state.proxyEndpoint)

        model.stopProxy()
        try await waitUntilAsync {
            let disableCount = await systemProxy.disableCount
            return model.state.proxyCorePhase == .stopped
                && model.state.systemProxyPhase == .disabled
                && disableCount == 1
        }
        let activeAfterStop = await systemProxy.isActive
        XCTAssertFalse(activeAfterStop)
        await model.shutdown()
    }

    func testProviderOnlyProfileIsBlocked() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try providerOnlyProfile().write(to: paths.profileConfig, options: .atomic)
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::30",
                mihomoPath: executableURL.path
            ))
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            proxyCoreControllerFactory: { _ in proxyCore }
        )

        model.start()
        try await waitUntilReady(model)
        XCTAssertFalse(model.isProxyConfigurationReady)
        XCTAssertEqual(
            model.proxyConfigurationIssue,
            MihomoConfigurationError.ipv6ManagedProfileRequired.localizedDescription
        )

        model.startProxy()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.state.proxyCorePhase, .stopped)
        let startCount = await proxyCore.startCount
        XCTAssertEqual(startCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.generatedConfig.path))
        await model.shutdown()
    }

    func testInlineHostnameProfileWithoutSelectedIPv6IsBlocked()
        async throws
    {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try validProfile(address: "origin.example").write(
            to: paths.profileConfig,
            options: .atomic
        )
        let local = LocalProxyConfiguration(
            listenAddress: "127.0.0.4",
            port: 19_090,
            routingMode: .rule,
            networkAccessMode: .localProxy
        )
        try JSONEncoder.pretty.encode(local).write(to: paths.localProxyConfig, options: .atomic)
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "",
                mihomoPath: executableURL.path
            ))
        let recorder = ProxyCoreConfigurationRecorder()
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            proxyCoreControllerFactory: { configuration in
                recorder.record(configuration)
                return proxyCore
            }
        )

        model.start()
        try await waitUntilReady(model)
        XCTAssertFalse(model.isProxyConfigurationReady)
        XCTAssertEqual(
            model.proxyConfigurationIssue,
            MihomoConfigurationError.selectedNodeMustBeIPv6.localizedDescription
        )
        model.startProxy()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.state.preferences.selectedIP, "")
        XCTAssertTrue(model.state.proxySupportsNodeSelection)
        XCTAssertEqual(model.state.proxyCorePhase, .stopped)
        XCTAssertNil(recorder.configuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.generatedConfig.path))
        await model.shutdown()
    }

    func testPersistedSelectedIPOverridesOnlyFirstInlineProxy() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try await bootstrapper.replaceProfile(
            with: twoProxyProfile(),
            selectedIP: "2606::20"
        )
        try FileManager.default.removeItem(at: paths.generatedConfig)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::20"
            ))
        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)

        model.start()
        try await waitUntilReady(model)

        let generated = String(
            decoding: try Data(contentsOf: paths.generatedConfig),
            as: UTF8.self
        )
        XCTAssertEqual(
            MihomoServerConfiguration.proxyServerAddress(
                in: try Data(contentsOf: paths.generatedConfig)
            ),
            "2606::20"
        )
        XCTAssertTrue(generated.contains("2606::20"))
        XCTAssertFalse(generated.contains("second-origin.example"))
        XCTAssertFalse(generated.contains("server: first-origin.example"))
        await model.shutdown()
    }

    func testSystemProxyEnableFailureStopsTheStartedProxy() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy,
                systemProxyEnabled: true
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(enableFailure: .permissionDenied)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)

        model.startProxy()
        try await waitUntil {
            if case .failed = model.state.proxyCorePhase { return true }
            return false
        }

        let enableCount = await systemProxy.enableCount
        let stopCount = await proxyCore.stopCount
        let proxyCoreIsRunning = await proxyCore.isRunning
        XCTAssertEqual(enableCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(proxyCoreIsRunning)
        guard case .failed(let message) = model.state.systemProxyPhase else {
            return XCTFail("Expected the system proxy failure to remain visible")
        }
        XCTAssertTrue(message.contains("权限"))
        await model.shutdown()
    }

    func testSystemProxyPreferenceFailureRollsBackPersistedPreference() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy
            )
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(enableFailure: .permissionDenied)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)
        model.startProxy()
        try await waitUntil { model.state.proxyCorePhase == .running }

        model.setSystemProxyEnabled(true)
        try await waitUntilAsync {
            let enableCount = await systemProxy.enableCount
            guard enableCount == 1 else { return false }
            guard !model.state.localProxyConfiguration.systemProxyEnabled else {
                return false
            }
            if case .failed = model.state.systemProxyPhase { return true }
            return false
        }

        let stored = try await bootstrapper.loadLocalProxyConfiguration()
        XCTAssertEqual(stored.networkAccessMode, .localProxy)
        XCTAssertFalse(stored.systemProxyEnabled)
        XCTAssertEqual(model.state.proxyCorePhase, .running)
        await model.shutdown()
    }

    func testUnexpectedProxyExitRestoresSystemProxy() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy,
                systemProxyEnabled: true
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager()
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)
        model.startProxy()
        try await waitUntilAsync {
            let enableCount = await systemProxy.enableCount
            return model.state.systemProxyPhase == .enabled
                && enableCount == 1
        }

        await proxyCore.exitUnexpectedly()
        try await waitUntilAsync {
            let disableCount = await systemProxy.disableCount
            if case .failed = model.state.proxyCorePhase {
                return model.state.systemProxyPhase == .disabled
                    && disableCount == 1
            }
            return false
        }

        let activeAfterExit = await systemProxy.isActive
        XCTAssertFalse(activeAfterExit)
        await model.shutdown()
    }

    func testUnexpectedProxyExitBlocksRestartUntilSystemProxyCleanupCompletes() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy,
                systemProxyEnabled: true
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(suspendNextDisable: true)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)
        model.startProxy()
        try await waitUntilAsync {
            let enableCount = await systemProxy.enableCount
            return enableCount == 1
                && model.state.proxyCorePhase == .running
                && model.state.systemProxyPhase == .enabled
        }

        await proxyCore.exitUnexpectedly()
        try await waitUntilAsync {
            let disableCount = await systemProxy.disableCount
            return disableCount == 1
                && model.state.systemProxyPhase == .disabling
        }

        model.startProxy()
        try await Task.sleep(for: .milliseconds(50))

        let blockedStartCount = await proxyCore.startCount
        XCTAssertEqual(blockedStartCount, 1)
        XCTAssertEqual(model.state.notice?.message, "正在恢复系统代理，请稍候")

        await systemProxy.resumeDisable()
        try await waitUntil { model.state.systemProxyPhase == .disabled }

        model.startProxy()
        try await waitUntilAsync {
            let startCount = await proxyCore.startCount
            let enableCount = await systemProxy.enableCount
            return startCount == 2
                && enableCount == 2
                && model.state.proxyCorePhase == .running
                && model.state.systemProxyPhase == .enabled
        }

        let isSystemProxyActive = await systemProxy.isActive
        XCTAssertTrue(isSystemProxyActive)
        await model.shutdown()
    }

    func testProxyExitDuringSystemProxyEnableNeverReportsSuccessfulStart() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy,
                systemProxyEnabled: true
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(suspendNextEnable: true)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)

        model.startProxy()
        try await waitUntilAsync {
            let enableCount = await systemProxy.enableCount
            let isActive = await systemProxy.isActive
            return enableCount == 1
                && isActive
                && model.state.systemProxyPhase == .enabling
        }

        await proxyCore.exitUnexpectedly()
        try await waitUntilAsync {
            let disableCount = await systemProxy.disableCount
            let isActive = await systemProxy.isActive
            return disableCount == 1 && !isActive
        }
        await systemProxy.resumeEnable()
        try await waitUntilAsync {
            guard await proxyCore.stopCount == 1 else { return false }
            if case .failed = model.state.proxyCorePhase { return true }
            return false
        }

        let isProxyCoreRunning = await proxyCore.isRunning
        let isSystemProxyActive = await systemProxy.isActive
        XCTAssertFalse(isProxyCoreRunning)
        XCTAssertFalse(isSystemProxyActive)
        XCTAssertFalse(
            model.state.logs.contains {
                $0.level == .success && $0.message.contains("本地代理已启动，监听")
            }
        )
        XCTAssertNotEqual(model.state.notice?.message, "本地代理已启动")
        await model.shutdown()
    }

    func testShutdownWaitsForConcurrentSystemProxyEnableAndLeavesNoStaleProxy() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(suspendNextEnable: true)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)
        model.startProxy()
        try await waitUntil { model.state.proxyCorePhase == .running }

        model.setSystemProxyEnabled(true)
        try await waitUntilAsync {
            let enableCount = await systemProxy.enableCount
            let isActive = await systemProxy.isActive
            return enableCount == 1
                && isActive
                && model.state.systemProxyPhase == .enabling
        }

        let shutdownTask = Task { await model.shutdown() }
        await Task.yield()
        await systemProxy.resumeEnable()

        let didShutdown = await shutdownTask.value
        let isSystemProxyActive = await systemProxy.isActive
        let isProxyCoreRunning = await proxyCore.isRunning
        let disableCount = await systemProxy.disableCount
        XCTAssertTrue(didShutdown)
        XCTAssertFalse(isSystemProxyActive)
        XCTAssertFalse(isProxyCoreRunning)
        XCTAssertGreaterThanOrEqual(disableCount, 1)
        let stored = try await bootstrapper.loadLocalProxyConfiguration()
        XCTAssertEqual(stored.networkAccessMode, .localProxy)
    }

    func testShutdownReturnsFalseAndKeepsProxyAliveWhenSystemProxyRestoreFails() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy,
                systemProxyEnabled: true
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(disableFailure: .restoreFailed)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)
        model.startProxy()
        try await waitUntilAsync {
            let isActive = await systemProxy.isActive
            return isActive
                && model.state.proxyCorePhase == .running
                && model.state.systemProxyPhase == .enabled
        }

        let firstShutdownResult = await model.shutdown()
        let isSystemProxyActiveAfterFailure = await systemProxy.isActive
        let isProxyCoreRunningAfterFailure = await proxyCore.isRunning
        let stopCountAfterFailure = await proxyCore.stopCount
        XCTAssertFalse(firstShutdownResult)
        XCTAssertTrue(isSystemProxyActiveAfterFailure)
        XCTAssertTrue(isProxyCoreRunningAfterFailure)
        XCTAssertEqual(stopCountAfterFailure, 0)
        XCTAssertEqual(model.state.proxyCorePhase, .running)
        XCTAssertTrue(model.state.traffic.isMonitoring)
        XCTAssertTrue(model.state.notice?.message.contains("无法安全退出") == true)

        await systemProxy.setDisableFailure(nil)
        let secondShutdownResult = await model.shutdown()
        let isSystemProxyActiveAfterRetry = await systemProxy.isActive
        let isProxyCoreRunningAfterRetry = await proxyCore.isRunning
        XCTAssertTrue(secondShutdownResult)
        XCTAssertFalse(isSystemProxyActiveAfterRetry)
        XCTAssertFalse(isProxyCoreRunningAfterRetry)
    }

    func testStopDuringLocalProxyStartDoesNotLeaveZombieController() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy,
                systemProxyEnabled: true
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(suspendNextEnable: true)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)

        model.startProxy()
        try await waitUntilAsync {
            let isActive = await systemProxy.isActive
            let isRunning = await proxyCore.isRunning
            return isActive
                && isRunning
                && model.state.systemProxyPhase == .enabling
        }

        model.stopProxy()
        await systemProxy.resumeEnable()
        try await waitUntil {
            model.state.proxyCorePhase == .stopped
                && model.state.systemProxyPhase != .enabling
                && model.state.systemProxyPhase != .disabling
        }

        let isRunning = await proxyCore.isRunning
        let stopCount = await proxyCore.stopCount
        XCTAssertFalse(isRunning)
        XCTAssertGreaterThanOrEqual(stopCount, 1)

        // Start must be available again after the cancelled start.
        model.startProxy()
        try await waitUntil { model.state.proxyCorePhase == .running }
        let startCount = await proxyCore.startCount
        XCTAssertGreaterThanOrEqual(startCount, 2)

        await model.shutdown()
    }

    func testLocalProxyStartPreservesBootstrapSystemProxyRecoveryFailure() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy
            ),
            selectedIP: nil
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(recoveryFailure: .recoveryFailed)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)

        guard case .failed(let recoveryMessage) = model.state.systemProxyPhase else {
            return XCTFail("Expected bootstrap system proxy recovery to fail")
        }
        XCTAssertTrue(recoveryMessage.contains("恢复"))

        model.startProxy()
        try await waitUntilAsync {
            guard await proxyCore.stopCount == 1 else { return false }
            if case .failed(let message) = model.state.proxyCorePhase {
                return message.contains("系统代理尚未安全恢复")
            }
            return false
        }

        let isProxyCoreRunning = await proxyCore.isRunning
        let disableCount = await systemProxy.disableCount
        XCTAssertFalse(isProxyCoreRunning)
        XCTAssertEqual(disableCount, 0)
        XCTAssertTrue(model.state.notice?.message.contains("系统代理尚未安全恢复") == true)
        XCTAssertFalse(
            model.state.logs.contains {
                $0.level == .success && $0.message.contains("本地代理已启动，监听")
            }
        )
        await model.shutdown()
    }

    func testSystemProxyRollbackWriteFailureKeepsMemoryAndDiskOnPersistedMode() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let setupBootstrapper = AppBootstrapper(paths: paths)
        try await setupBootstrapper.prepareDefaults()
        _ = try await setupBootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                routingMode: .direct,
                networkAccessMode: .localProxy
            ),
            selectedIP: nil
        )
        let writer = ControlledConfigurationWriter()
        let bootstrapper = AppBootstrapper(
            paths: paths,
            configurationFileWriter: { data, url in
                try writer.write(data, to: url)
            }
        )
        let executableURL = try makeExecutable(in: paths)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                mihomoPath: executableURL.path
            ))
        let systemProxy = ControlledSystemProxyManager(enableFailure: .permissionDenied)
        let proxyCore = ControlledMihomoController()
        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            systemProxyManager: systemProxy,
            proxyCoreControllerFactory: { _ in proxyCore }
        )
        model.start()
        try await waitUntilReady(model)
        model.startProxy()
        try await waitUntil { model.state.proxyCorePhase == .running }
        writer.fail(afterSuccessfulWrites: 2)

        model.setSystemProxyEnabled(true)
        try await waitUntilAsync {
            guard await systemProxy.enableCount == 1 else { return false }
            guard
                model.state.localProxyConfiguration.systemProxyEnabled,
                case .failed(let message) = model.state.systemProxyPhase
            else { return false }
            return message.contains("恢复系统代理偏好失败")
        }

        let stored = try await bootstrapper.loadLocalProxyConfiguration()
        XCTAssertEqual(stored.networkAccessMode, .localProxy)
        XCTAssertTrue(stored.systemProxyEnabled)
        XCTAssertEqual(model.state.localProxyConfiguration, stored)
        XCTAssertTrue(model.state.notice?.message.contains("恢复原设置失败") == true)
        let isProxyCoreRunning = await proxyCore.isRunning
        XCTAssertTrue(isProxyCoreRunning)
        await model.shutdown()
    }

    func testRoutingModeChangesRefreshNodeSelectionCapability() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try await bootstrapper.replaceProfile(with: validProfile(), selectedIP: "2606::40")
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::40"
            ))
        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)

        XCTAssertTrue(model.state.proxySupportsNodeSelection)
        XCTAssertEqual(model.state.preferences.selectedIP, "2606::40")

        model.setRoutingMode(.direct)
        try await waitUntil {
            !model.isRoutingModeChanging
                && model.state.localProxyConfiguration.routingMode == .direct
        }
        XCTAssertFalse(model.state.proxySupportsNodeSelection)
        XCTAssertEqual(model.state.preferences.selectedIP, "2606::40")
        XCTAssertNotNil(model.currentConfigurationTestUnavailableReason)

        model.selectIP("2606::41")
        XCTAssertEqual(
            model.state.notice?.message,
            AppModelError.nodeSelectionUnsupported.localizedDescription
        )
        XCTAssertNil(model.switchingIP)
        XCTAssertEqual(model.state.preferences.selectedIP, "2606::40")

        let firstShutdownResult = await model.shutdown()
        XCTAssertTrue(firstShutdownResult)

        let relaunchedModel = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        relaunchedModel.start()
        try await waitUntilReady(relaunchedModel)
        XCTAssertEqual(relaunchedModel.state.localProxyConfiguration.routingMode, .direct)
        XCTAssertFalse(relaunchedModel.state.proxySupportsNodeSelection)
        XCTAssertEqual(relaunchedModel.state.preferences.selectedIP, "2606::40")
        XCTAssertNotNil(relaunchedModel.currentConfigurationTestUnavailableReason)

        relaunchedModel.setRoutingMode(.rule)
        try await waitUntil {
            !relaunchedModel.isRoutingModeChanging
                && relaunchedModel.state.localProxyConfiguration.routingMode == .rule
        }
        XCTAssertTrue(relaunchedModel.state.proxySupportsNodeSelection)
        XCTAssertEqual(relaunchedModel.state.preferences.selectedIP, "2606::40")
        let currentConfigIP = try await bootstrapper.currentConfigIP()
        XCTAssertEqual(currentConfigIP, "2606::40")
        await relaunchedModel.shutdown()
    }

    func testSaveProxyProfileWaitsForSuccessfulWrite() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try await bootstrapper.replaceProfile(with: validProfile(address: "2606:4700::201"))
        _ = try await bootstrapper.replaceLocalProxyConfiguration(
            with: LocalProxyConfiguration(
                listenAddress: "127.0.0.2",
                port: 18_081,
                networkAccessMode: .localProxy
            ),
            selectedIP: "2606:4700::201"
        )
        let model = makeModel(paths: paths, bootstrapper: bootstrapper)
        let openedProfile = try Data(contentsOf: paths.profileConfig)
        let profile = validProfile(address: "2606:4700::202")

        try await model.saveProfileConfiguration(
            profile,
            expectedProfileData: openedProfile
        )

        XCTAssertEqual(
            try Data(contentsOf: paths.profileConfig),
            try MihomoServerConfiguration(data: profile).data
        )
        XCTAssertEqual(model.state.proxyEndpoint, ProxyEndpoint(host: "127.0.0.2", port: 18_081))
        XCTAssertEqual(model.state.templateOperationPhase, .idle)
        XCTAssertTrue(model.state.logs.contains { $0.message == "代理配置已保存" })
        await model.shutdown()
    }

    func testSaveProxyProfileRejectsExternalChangeWithoutOverwritingIt() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try await bootstrapper.replaceProfile(with: validProfile(address: "2606:4700::211"))
        let openedProfile = try Data(contentsOf: paths.profileConfig)
        let externalProfile = validProfile(address: "2606:4700::212")
        try externalProfile.write(to: paths.profileConfig, options: .atomic)
        let model = makeModel(paths: paths, bootstrapper: bootstrapper)

        do {
            try await model.saveProfileConfiguration(
                validProfile(address: "2606:4700::213"),
                expectedProfileData: openedProfile
            )
            XCTFail("Expected the externally changed profile to be preserved")
        } catch {
            XCTAssertEqual(error as? AppModelError, .profileChangedExternally)
        }

        XCTAssertEqual(try Data(contentsOf: paths.profileConfig), externalProfile)
        XCTAssertEqual(model.state.templateOperationPhase, .idle)
        XCTAssertTrue(model.state.logs.contains { $0.message.contains("已阻止覆盖外部修改") })
        await model.shutdown()
    }

    func testProfileImportPublishesBusyStateAndBlocksConcurrentSave() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        let importedProfile = validProfile(address: "2606:4700::221")
        let importURL = paths.root.appendingPathComponent("imported-profile.yaml")
        try importedProfile.write(to: importURL, options: .atomic)
        let model = makeModel(paths: paths, bootstrapper: bootstrapper)

        model.importProxyProfile(from: importURL)
        XCTAssertEqual(model.state.templateOperationPhase, .importing)

        do {
            try await model.saveProfileConfiguration(validProfile(address: "2606:4700::222"))
            XCTFail("Expected saving to be rejected while a profile import is running")
        } catch {
            XCTAssertEqual(error as? AppModelError, .templateOperationInProgress)
        }

        try await waitUntil { model.state.templateOperationPhase == .idle }
        XCTAssertEqual(
            try Data(contentsOf: paths.profileConfig),
            try MihomoServerConfiguration(data: importedProfile).data
        )
        XCTAssertEqual(model.state.proxyEndpoint, ProxyEndpoint())
        XCTAssertFalse(model.isProxyConfigurationReady)
        XCTAssertTrue(model.state.proxySupportsNodeSelection)
        XCTAssertNil(model.state.templateOperationError)
        await model.shutdown()
    }

    func testFailedProfileImportPublishesSettingsVisibleError() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try await bootstrapper.replaceProfile(with: validProfile(address: "2606:4700::231"))
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606:4700::231"
            )
        )
        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)
        let originalProfile = try Data(contentsOf: paths.profileConfig)
        let importURL = paths.root.appendingPathComponent("invalid-profile.yaml")
        try Data("proxies: [".utf8).write(to: importURL, options: .atomic)

        model.importProxyProfile(from: importURL)
        try await waitUntil { model.state.templateOperationPhase == .idle }

        XCTAssertTrue(
            model.state.templateOperationError?.contains("Mihomo YAML 无法解析") == true
        )
        XCTAssertEqual(try Data(contentsOf: paths.profileConfig), originalProfile)
        XCTAssertTrue(model.isProxyConfigurationReady)
        await model.shutdown()
    }

    func testImportRepairsIncompatibleLocalAndProfileConfiguration() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()

        try Data(
            """
            {
              "listenAddress": "127.0.0.1",
              "port": 11451,
              "networkAccessMode": "virtualInterface"
            }
            """.utf8
        ).write(to: paths.localProxyConfig, options: .atomic)
        try Data(
            """
            x-viasix:
              version: 1
              primary-server: selected-ip
              routing-mode: rule
              udp-enabled: false
              log-level: info
              sniffing-enabled: true
              bypass-private-networks: true
            proxies:
              - name: old-edge
                type: vless
                port: 443
                uuid: 11111111-1111-4111-8111-111111111111
                tls: true
                servername: old.example
            """.utf8
        ).write(to: paths.profileConfig, options: .atomic)
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606:4700::61"
            )
        )

        let model = makeModel(
            paths: paths,
            store: store,
            bootstrapper: bootstrapper,
            tunCoordinator: ControlledTunModeCoordinator()
        )
        model.start()
        try await waitUntilReady(model)
        XCTAssertFalse(model.isProxyConfigurationReady)

        let importURL = paths.root.appendingPathComponent("viasix-mihomo.yaml")
        try selectedIPProfile().write(to: importURL, options: .atomic)
        model.importProxyProfile(from: importURL)
        try await waitUntil { model.state.templateOperationPhase == .idle }

        XCTAssertNil(model.state.templateOperationError)
        XCTAssertTrue(model.isProxyConfigurationReady)
        XCTAssertEqual(model.state.localProxyConfiguration, .default)
        let stored = String(decoding: try Data(contentsOf: paths.profileConfig), as: UTF8.self)
        XCTAssertFalse(stored.contains("bypass-private-networks"))

        model.setSystemProxyEnabled(true)
        try await waitUntil { model.state.localProxyConfiguration.systemProxyEnabled }
        XCTAssertNil(model.state.templateOperationError)
        await model.shutdown()
    }

    func testProfileImportRejectsNonYAMLFiles() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = makeModel(paths: paths)
        let importURL = paths.root.appendingPathComponent("profile.txt")

        model.importProxyProfile(from: importURL)

        XCTAssertEqual(model.state.templateOperationPhase, .idle)
        XCTAssertEqual(model.state.templateOperationError, "仅支持导入 .yaml 或 .yml 配置文件")
        await model.shutdown()
    }

    func testProfileOperationsAreRejectedWhileApplyingSelection() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await useLocalProxyMode(bootstrapper)
        try await bootstrapper.replaceProfile(with: validProfile())
        let model = makeModel(paths: paths, bootstrapper: bootstrapper)
        let importURL = paths.root.appendingPathComponent("imported-profile.yaml")
        try validProfile(address: "imported.example").write(to: importURL, options: .atomic)
        model.start()
        try await waitUntilReady(model)

        model.selectIP("2606::12")
        model.importProxyProfile(from: importURL)
        XCTAssertEqual(model.state.templateOperationPhase, .idle)

        do {
            try await model.saveProfileConfiguration(validProfile(address: "saved.example"))
            XCTFail("Expected saving to be rejected while a selection is being applied")
        } catch {
            XCTAssertEqual(error as? AppModelError, .selectionInProgress)
        }

        try await waitUntil { model.switchingIP == nil }
        await model.shutdown()
    }

    func testSaveProxyProfilePropagatesWriteFailure() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = makeModel(paths: paths)

        do {
            try await model.saveProfileConfiguration(validProfile())
            XCTFail("Expected the missing application data directory to make the save fail")
        } catch {
            XCTAssertTrue(model.state.logs.contains { $0.message.contains("保存代理配置失败") })
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.profileConfig.path))
        await model.shutdown()
    }

    func testSaveProxyProfileRejectsOverlapAndShutdownCancelsPendingSave() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let replacer = SuspendedProfileReplacer()
        let model = makeModel(paths: paths, profileReplacer: replacer)
        let pendingSave = Task {
            try await model.saveProfileConfiguration(validProfile())
        }
        try await waitForProfileRequest(replacer)
        XCTAssertEqual(model.state.templateOperationPhase, .saving)

        do {
            try await model.saveProfileConfiguration(validProfile(address: "overlap.example"))
            XCTFail("Expected a second profile operation to be rejected")
        } catch {
            XCTAssertEqual(error.localizedDescription, "另一项代理配置操作尚未完成")
        }

        await model.shutdown()
        do {
            try await pendingSave.value
            XCTFail("Expected shutdown to cancel the pending template save")
        } catch is CancellationError {
            // Expected: shutdown owns and cancels the underlying save task.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let requestCount = await replacer.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(model.state.templateOperationPhase, .idle)
        XCTAssertFalse(model.state.logs.contains { $0.message.contains("保存代理配置失败") })
    }

    func testCurrentConfigurationTestUsesSelectedIPAndExpiresAfterSelectionChanges() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        try await bootstrapper.replaceProfile(
            with: validProfile(),
            selectedIP: "2606::7"
        )

        let executableURL = paths.root.appendingPathComponent("cfst-test")
        try #"""
        #!/bin/sh
        output=""
        selected_ip=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o) output="$2"; shift 2 ;;
            -ip) selected_ip="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n%s,4,4,0.00,18.5,12.3,SJC\n' "$selected_ip" > "$output"
        """#.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: "2606::7",
                cfstPath: executableURL.path
            ))

        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)

        var configuredParameters = model.parameters
        configuredParameters.httping = false
        configuredParameters.port = 8443
        configuredParameters.url = "https://speed.example.test/file"
        configuredParameters.latencyLowerBound = 900
        configuredParameters.latencyUpperBound = 901
        configuredParameters.lossRateUpperBound = 0
        configuredParameters.speedLowerBound = 999
        configuredParameters.colo = "NRT"
        model.parameters = configuredParameters

        model.startCurrentConfigurationTest()
        try await waitUntil { model.state.configurationTest.result != nil }
        XCTAssertEqual(model.state.configurationTest.result?.ip, "2606::7")
        XCTAssertEqual(model.state.configurationTest.result?.latency, "18.5")
        XCTAssertEqual(model.state.configurationTest.parameters?.httping, model.parameters.httping)
        XCTAssertEqual(model.state.configurationTest.parameters?.port, 8443)
        XCTAssertEqual(model.state.configurationTest.parameters?.url, "https://speed.example.test/file")
        XCTAssertEqual(model.state.configurationTest.parameters?.latencyLowerBound, 0)
        XCTAssertEqual(model.state.configurationTest.parameters?.latencyUpperBound, 999_999)
        XCTAssertEqual(model.state.configurationTest.parameters?.lossRateUpperBound, 1)
        XCTAssertEqual(model.state.configurationTest.parameters?.speedLowerBound, 0)
        XCTAssertEqual(model.state.configurationTest.parameters?.colo, "")
        XCTAssertTrue(model.state.configurationTest.parameters?.debug == true)
        XCTAssertNotNil(model.state.configurationTest.completedAt)

        model.selectIP("2606::8")
        try await waitUntil {
            model.switchingIP == nil && model.state.preferences.selectedIP == "2606::8"
        }
        XCTAssertNil(model.state.configurationTest.result)
        await model.shutdown()
    }

    func testCurrentConfigurationNoResultsDoesNotReportInternalCSVPath() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: "2606::16",
            script: #"""
                #!/bin/sh
                printf '[信息] 延迟测速结果 IP 数量为 0，跳过下载测速。\n'
                exit 0
                """#
        )

        model.startCurrentConfigurationTest()
        try await waitUntil {
            if case .failed = model.state.configurationTest.phase { return true }
            return false
        }

        XCTAssertEqual(model.state.notice?.message, "当前节点测速失败：没有任何 IP 通过测速")
        XCTAssertFalse(model.state.notice?.message.contains(".current-test-") == true)
        XCTAssertTrue(
            model.state.logs.contains {
                $0.message.contains("延迟测速结果 IP 数量为 0")
            }
        )
        await model.shutdown()
    }

    func testCurrentConfigurationTestRejectsResultForAnotherIPAndClearsPreviousState() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: "2606::12",
            script: #"""
                #!/bin/sh
                output=""
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    -o) output="$2"; shift 2 ;;
                    *) shift ;;
                  esac
                done
                printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n2606::12,4,4,0,18.5,12.3,SJC\n' > "$output"
                """#
        )

        model.startCurrentConfigurationTest()
        try await waitUntil { model.state.configurationTest.result != nil }
        XCTAssertNotNil(model.state.configurationTest.completedAt)

        let executableURL = URL(fileURLWithPath: model.state.preferences.cfstPath)
        try #"""
        #!/bin/sh
        output=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o) output="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n2606::99,4,4,0,18.5,12.3,SJC\n' > "$output"
        """#.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        model.startCurrentConfigurationTest()
        XCTAssertEqual(model.state.configurationTest.phase, .running)
        XCTAssertNil(model.state.configurationTest.result)
        XCTAssertNil(model.state.configurationTest.completedAt)
        try await waitUntil {
            if case .failed = model.state.configurationTest.phase { return true }
            return false
        }

        XCTAssertNil(model.state.configurationTest.result)
        XCTAssertNil(model.state.configurationTest.completedAt)
        XCTAssertTrue(model.state.notice?.message.contains("与当前配置不一致") == true)
        XCTAssertTrue(model.state.logs.contains { $0.message.contains("当前节点测速失败") })
        await model.shutdown()
    }

    func testCurrentConfigurationTestAcceptsEquivalentIPv6AndPreservesSelectedSpelling() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let selectedIP = "2606:0000:0000:0000:0000:0000:0000:0007"
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: selectedIP,
            script: #"""
                #!/bin/sh
                output=""
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
                done
                printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n2606::7,4,4,0,18.5,12.3,SJC\n' > "$output"
                """#
        )

        model.startCurrentConfigurationTest()
        try await waitUntil { model.state.configurationTest.result != nil }

        XCTAssertEqual(model.state.configurationTest.result?.ip, selectedIP)
        XCTAssertEqual(model.state.configurationTest.result?.latency, "18.5")
        await model.shutdown()
    }

    func testConfigurationTestPresentationOmitsMissingUnits() {
        let result = SpeedTestResult(ip: "2606::13", latency: "", speed: "")
        XCTAssertNil(result.latencyDisplayValue)
        XCTAssertNil(result.speedDisplayValue)
        XCTAssertEqual(result.performanceSummary, "暂无有效测速指标")

        let partial = SpeedTestResult(ip: "2606::13", latency: " 18.5 ", speed: "")
        XCTAssertEqual(partial.latencyDisplayValue, "18.5 ms")
        XCTAssertEqual(partial.performanceSummary, "18.5 ms")
    }

    func testStopCurrentConfigurationTestReturnsToCleanIdleState() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: "2606::14",
            script: #"""
                #!/bin/sh
                output=""
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
                done
                printf 'started\n' > current-test-cancel-started.txt
                sleep 30
                printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n2606::14,4,4,0,12.5,24.0,SJC\n' > "$output"
                """#
        )

        model.startCurrentConfigurationTest()
        let markerURL = paths.root.appendingPathComponent("current-test-cancel-started.txt")
        try await waitUntil { FileManager.default.fileExists(atPath: markerURL.path) }

        model.stopCurrentConfigurationTest()
        XCTAssertEqual(model.state.configurationTest.phase, .stopping)
        try await waitUntil { model.state.configurationTest.phase == .idle }

        XCTAssertFalse(model.isCfstBusy)
        XCTAssertNil(model.state.configurationTest.result)
        XCTAssertNil(model.state.configurationTest.startedAt)
        XCTAssertNil(model.state.configurationTest.completedAt)
        await model.shutdown()
    }

    func testChangingParametersCancelsCurrentConfigurationTestWithoutLateResult() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: "2606::15",
            script: #"""
                #!/bin/sh
                output=""
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
                done
                printf 'started\n' > current-test-parameter-change-started.txt
                sleep 30
                printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n2606::15,4,4,0,12.5,24.0,SJC\n' > "$output"
                """#
        )

        model.startCurrentConfigurationTest()
        let markerURL = paths.root.appendingPathComponent(
            "current-test-parameter-change-started.txt"
        )
        try await waitUntil { FileManager.default.fileExists(atPath: markerURL.path) }

        var parameters = model.parameters
        parameters.threads += 1
        model.parameters = parameters

        try await waitUntil { model.state.configurationTest.phase == .idle }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.isCfstBusy)
        XCTAssertNil(model.state.configurationTest.result)
        XCTAssertNil(model.state.configurationTest.parameters)
        XCTAssertNil(model.state.configurationTest.completedAt)
        await model.shutdown()
    }

    func testBlankExitIPEndpointRestoresDefaultAndTrimsValidValues() async {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = makeModel(paths: paths)

        model.exitIPEndpoint = "  https://status.example.test/ip  "
        XCTAssertEqual(model.exitIPEndpoint, "https://status.example.test/ip")

        model.exitIPEndpoint = "   "
        XCTAssertEqual(model.exitIPEndpoint, AppMetadata.defaultExitIPEndpoint)
        await model.shutdown()
    }

    func testShutdownRejectsNewBackgroundWork() async {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let detector = ControlledExitDetector()
        let model = makeModel(paths: paths, exitDetector: detector)

        await model.shutdown()
        model.installRuntime(.cfst)
        model.startSpeedTest()
        model.startCurrentConfigurationTest()
        model.detectExitIP()

        XCTAssertFalse(model.isCfstBusy)
        XCTAssertFalse(model.state.exit.isDetecting)
        XCTAssertEqual(model.state.runtimePhase, .checking)
        let requestCount = await detector.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testSpeedTestEntryPointsRejectRequestsBeforeBootstrapIsReady() async {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = makeModel(paths: paths)
        model.start()

        model.startSpeedTest()
        XCTAssertEqual(model.state.notice?.message, "应用仍在准备，请稍后再试")
        XCTAssertFalse(model.isCfstBusy)
        XCTAssertEqual(model.state.speedTest.phase, .idle)

        model.startCurrentConfigurationTest()
        XCTAssertEqual(model.state.notice?.message, "应用仍在准备，请稍后再试")
        XCTAssertFalse(model.isCfstBusy)
        XCTAssertEqual(model.state.configurationTest.phase, .idle)

        model.importProxyProfile(
            from: paths.root.appendingPathComponent("not-ready-profile.yaml")
        )
        XCTAssertEqual(model.state.notice?.message, "应用仍在准备，请稍后再试")

        model.selectIP("2606::9")
        XCTAssertEqual(model.state.notice?.message, "应用仍在准备，请稍后再试")

        do {
            try await model.saveProfileConfiguration(Data("{}".utf8))
            XCTFail("Expected profile save to be rejected before bootstrap")
        } catch let error as AppModelError {
            XCTAssertEqual(error, .appNotReady)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await model.shutdown()
    }

    func testInvalidSpeedTestSourceIsReportedBeforeLaunchingCFST() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: "",
            script: "#!/bin/sh\nexit 0\n"
        )
        var parameters = model.parameters
        parameters.ipFile = ""
        parameters.ipRange = "not-an-ip"
        model.parameters = parameters

        model.startSpeedTest()

        XCTAssertEqual(model.state.notice?.message, "IP 段格式无效：not-an-ip")
        XCTAssertFalse(model.isCfstBusy)
        XCTAssertEqual(model.state.speedTest.phase, .idle)
        await model.shutdown()
    }

    func testStopSpeedTestDoesNotCancelCurrentConfigurationTest() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: "2606::9",
            script: #"""
                #!/bin/sh
                output=""
                selected_ip=""
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    -o) output="$2"; shift 2 ;;
                    -ip) selected_ip="$2"; shift 2 ;;
                    *) shift ;;
                  esac
                done
                printf 'started\n' > current-test-started.txt
                sleep 0.3
                printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n%s,4,4,0,12.5,24.0,SJC\n' "$selected_ip" > "$output"
                """#
        )

        model.startCurrentConfigurationTest()
        let markerURL = paths.root.appendingPathComponent("current-test-started.txt")
        try await waitUntil { FileManager.default.fileExists(atPath: markerURL.path) }

        model.stopSpeedTest()

        XCTAssertEqual(model.state.speedTest.phase, .idle)
        XCTAssertEqual(model.state.configurationTest.phase, .running)
        try await waitUntil { model.state.configurationTest.result != nil }
        XCTAssertEqual(model.state.configurationTest.result?.ip, "2606::9")
        XCTAssertEqual(model.state.configurationTest.result?.latency, "12.5")
        XCTAssertFalse(model.isCfstBusy)
        await model.shutdown()
    }

    func testStopSpeedTestStillCancelsFullSpeedTest() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: "2606::10",
            script: #"""
                #!/bin/sh
                output=""
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
                done
                printf 'started\n' > full-test-started.txt
                sleep 30
                printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n2606::10,4,4,0,12.5,24.0,SJC\n' > "$output"
                """#
        )

        model.startSpeedTest()
        let markerURL = paths.root.appendingPathComponent("full-test-started.txt")
        try await waitUntil { FileManager.default.fileExists(atPath: markerURL.path) }

        model.stopSpeedTest()

        XCTAssertEqual(model.state.speedTest.phase, .stopping)
        try await waitUntil { model.state.speedTest.phase == .idle }
        XCTAssertFalse(model.isCfstBusy)
        XCTAssertEqual(model.state.configurationTest.phase, .idle)
        await model.shutdown()
    }

    func testSpeedTestRequiresExplicitSelectionAndTracksParameterSnapshot() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let model = try await makeSpeedTestModel(
            paths: paths,
            selectedIP: "",
            script: #"""
                #!/bin/sh
                output=""
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi
                done
                printf 'IP,Sent,Recv,Loss,Latency,Speed,Region\n2606::11,4,4,0,10.5,28.0,SJC\n' > "$output"
                """#
        )
        let testedParameters = model.parameters

        model.startSpeedTest()
        try await waitUntil {
            model.state.results.count == 1 && model.state.speedTest.phase == .idle
        }

        XCTAssertEqual(model.state.preferences.selectedIP, "")
        let generatedIP = try await AppBootstrapper(paths: paths).currentConfigIP()
        XCTAssertNil(generatedIP)
        XCTAssertEqual(
            model.state.preferences.lastSuccessfulSpeedTestParameters,
            testedParameters
        )
        XCTAssertTrue(model.state.speedTestResultsAreCurrent)

        var changedParameters = model.parameters
        changedParameters.httping.toggle()
        model.parameters = changedParameters

        XCTAssertEqual(model.state.results.map(\.ip), ["2606::11"])
        XCTAssertFalse(model.state.speedTestResultsAreCurrent)
        XCTAssertNil(model.state.selectedResult)
        await model.shutdown()
    }

    func testExitIPDetectionStoresDirectContextAndPreservesResultWhenModeChanges() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let detector = ControlledExitDetector()
        let model = makeModel(paths: paths, exitDetector: detector)

        model.detectExitIP()
        try await waitForRequestCount(detector, 1)
        let pendingRequestID = await detector.requestID(at: 0)
        let requestID = try XCTUnwrap(pendingRequestID)
        await detector.resolve(
            requestID,
            with: .success(ExitIPInfo(ip: "203.0.113.10", location: "东京 日本", details: "Example ISP · AS64500"))
        )
        try await waitUntil {
            model.state.exit.info?.ip == "203.0.113.10" && !model.state.exit.isDetecting
        }

        XCTAssertEqual(model.exitIPRouteDescription, "直连")
        XCTAssertFalse(model.exitIPResultIsStale)
        XCTAssertEqual(model.state.exit.context?.mode, .automatic)
        XCTAssertNotNil(model.state.exit.detectedAt)

        model.exitIPDetectionMode = .ipv4
        XCTAssertEqual(model.state.exit.info?.ip, "203.0.113.10")
        XCTAssertTrue(model.exitIPResultIsStale)
        await model.shutdown()
    }

    func testExitIPDetectionDropsCancelledGeneration() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let detector = ControlledExitDetector()
        let model = makeModel(paths: paths, exitDetector: detector)

        model.detectExitIP()
        try await waitForRequestCount(detector, 1)
        let pendingFirstID = await detector.requestID(at: 0)
        let firstID = try XCTUnwrap(pendingFirstID)

        model.exitIPDetectionMode = .ipv4
        model.detectExitIP()
        try await waitForRequestCount(detector, 2)
        let pendingSecondID = await detector.requestID(at: 1)
        let secondID = try XCTUnwrap(pendingSecondID)
        await detector.resolve(
            secondID,
            with: .success(ExitIPInfo(ip: "198.51.100.20", location: "新加坡", details: "Example ISP"))
        )
        try await waitUntil {
            model.state.exit.info?.ip == "198.51.100.20" && !model.state.exit.isDetecting
        }

        // The first detector intentionally ignores cancellation. Its late
        // response must not replace the result from the current generation.
        await detector.resolve(
            firstID,
            with: .success(ExitIPInfo(ip: "198.51.100.30", location: "旧结果"))
        )
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.state.exit.info?.ip, "198.51.100.20")
        XCTAssertEqual(model.state.exit.context?.mode, .ipv4)
        await model.shutdown()
    }

    func testExitIPDetectionFailureKeepsLastSuccessfulSnapshot() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let detector = ControlledExitDetector()
        let model = makeModel(paths: paths, exitDetector: detector)

        model.detectExitIP()
        try await waitForRequestCount(detector, 1)
        let pendingFirstID = await detector.requestID(at: 0)
        let firstID = try XCTUnwrap(pendingFirstID)
        await detector.resolve(
            firstID,
            with: .success(ExitIPInfo(ip: "192.0.2.40", location: "大阪 日本", details: "Example ISP"))
        )
        try await waitUntil {
            model.state.exit.info?.ip == "192.0.2.40" && !model.state.exit.isDetecting
        }
        let detectedAt = try XCTUnwrap(model.state.exit.detectedAt)

        model.detectExitIP()
        try await waitForRequestCount(detector, 2)
        let pendingSecondID = await detector.requestID(at: 1)
        let secondID = try XCTUnwrap(pendingSecondID)
        await detector.resolve(secondID, with: .failure(.unavailable))
        try await waitUntil {
            model.state.exit.errorMessage != nil && !model.state.exit.isDetecting
        }

        XCTAssertEqual(model.state.exit.info?.ip, "192.0.2.40")
        XCTAssertEqual(model.state.exit.detectedAt, detectedAt)
        await model.shutdown()
    }

    func testExitIPDetectionPublishesPrimaryResultBeforeEnrichment() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let primaryInfo = ExitIPInfo(ip: "203.0.113.50")
        let enrichedInfo = ExitIPInfo(
            ip: primaryInfo.ip,
            location: "东京 日本",
            details: "Example ISP · AS64500"
        )
        let detector = ControlledTwoPhaseExitDetector(primaryResults: [primaryInfo])
        let model = makeModel(paths: paths, exitDetector: detector)

        model.detectExitIP()
        try await waitForEnrichmentRequestCount(detector, 1)

        XCTAssertEqual(model.state.exit.info, primaryInfo)
        XCTAssertFalse(model.state.exit.isDetecting)
        XCTAssertTrue(model.state.exit.isEnriching)
        XCTAssertNil(model.state.exit.errorMessage)
        let detectedAt = try XCTUnwrap(model.state.exit.detectedAt)

        let pendingRequestID = await detector.enrichmentRequestID(at: 0)
        let requestID = try XCTUnwrap(pendingRequestID)
        await detector.resolveEnrichment(requestID, with: .success(enrichedInfo))
        try await waitUntil { model.state.exit.info == enrichedInfo }

        XCTAssertEqual(model.state.exit.detectedAt, detectedAt)
        XCTAssertFalse(model.state.exit.isEnriching)
        await model.shutdown()
    }

    func testExitIPEnrichmentFailurePreservesPrimaryResult() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let primaryInfo = ExitIPInfo(ip: "198.51.100.60")
        let detector = ControlledTwoPhaseExitDetector(primaryResults: [primaryInfo])
        let model = makeModel(paths: paths, exitDetector: detector)

        model.detectExitIP()
        try await waitForEnrichmentRequestCount(detector, 1)
        let detectedAt = try XCTUnwrap(model.state.exit.detectedAt)
        let pendingRequestID = await detector.enrichmentRequestID(at: 0)
        let requestID = try XCTUnwrap(pendingRequestID)
        await detector.resolveEnrichment(requestID, with: .failure(.unavailable))
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.state.exit.info, primaryInfo)
        XCTAssertFalse(model.state.exit.isEnriching)
        XCTAssertEqual(model.state.exit.detectedAt, detectedAt)
        XCTAssertNil(model.state.exit.errorMessage)
        await model.shutdown()
    }

    func testExitIPDetectionDropsEnrichmentFromPreviousGeneration() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let firstPrimaryInfo = ExitIPInfo(ip: "192.0.2.70")
        let secondPrimaryInfo = ExitIPInfo(ip: "198.51.100.71")
        let secondEnrichedInfo = ExitIPInfo(
            ip: secondPrimaryInfo.ip,
            location: "新加坡",
            details: "Current ISP"
        )
        let detector = ControlledTwoPhaseExitDetector(
            primaryResults: [firstPrimaryInfo, secondPrimaryInfo]
        )
        let model = makeModel(paths: paths, exitDetector: detector)

        model.detectExitIP()
        try await waitForEnrichmentRequestCount(detector, 1)
        let pendingFirstRequestID = await detector.enrichmentRequestID(at: 0)
        let firstRequestID = try XCTUnwrap(pendingFirstRequestID)

        model.exitIPDetectionMode = .ipv4
        model.detectExitIP()
        try await waitForEnrichmentRequestCount(detector, 2)
        XCTAssertEqual(model.state.exit.info, secondPrimaryInfo)
        XCTAssertEqual(model.state.exit.context?.mode, .ipv4)

        let pendingSecondRequestID = await detector.enrichmentRequestID(at: 1)
        let secondRequestID = try XCTUnwrap(pendingSecondRequestID)
        await detector.resolveEnrichment(secondRequestID, with: .success(secondEnrichedInfo))
        try await waitUntil { model.state.exit.info == secondEnrichedInfo }

        await detector.resolveEnrichment(
            firstRequestID,
            with: .success(
                ExitIPInfo(
                    ip: firstPrimaryInfo.ip,
                    location: "旧位置",
                    details: "Stale ISP"
                )
            )
        )
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.state.exit.info, secondEnrichedInfo)
        XCTAssertEqual(model.state.exit.context?.mode, .ipv4)
        await model.shutdown()
    }

    func testShutdownCancelsAndWaitsForExitIPEnrichment() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let detector = CancellationObservingExitDetector(
            primaryInfo: ExitIPInfo(ip: "203.0.113.80")
        )
        let model = makeModel(paths: paths, exitDetector: detector)

        model.detectExitIP()
        try await waitForEnrichmentStart(detector)

        await model.shutdown()

        let enrichmentWasCancelled = await detector.enrichmentWasCancelled
        XCTAssertTrue(enrichmentWasCancelled)
    }

    private func waitUntilReady(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if model.state.launchPhase == .ready { return }
            if case .failed(let message) = model.state.launchPhase {
                XCTFail("Bootstrap failed: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for bootstrap")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for condition")
    }

    private func waitUntilAsync(
        _ predicate: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }

    private func waitForRequestCount(
        _ detector: ControlledExitDetector,
        _ count: Int
    ) async throws {
        for _ in 0..<100 {
            if await detector.requestCount >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(count) exit IP requests")
    }

    private func waitForEnrichmentRequestCount(
        _ detector: ControlledTwoPhaseExitDetector,
        _ count: Int
    ) async throws {
        for _ in 0..<100 {
            if await detector.enrichmentRequestCount >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(count) exit IP enrichment requests")
    }

    private func waitForEnrichmentStart(
        _ detector: CancellationObservingExitDetector
    ) async throws {
        for _ in 0..<100 {
            if await detector.enrichmentStarted { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for exit IP enrichment to start")
    }

    private func waitForProfileRequest(_ replacer: SuspendedProfileReplacer) async throws {
        for _ in 0..<100 {
            if await replacer.requestCount > 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the profile save to start")
    }

    private func makeModel(
        paths: AppPaths,
        store: PreferencesStore? = nil,
        bootstrapper: AppBootstrapper? = nil,
        exitDetector: (any ExitIPDetecting)? = nil,
        profileReplacer: (any ProxyProfileReplacing)? = nil,
        systemProxyManager: (any SystemProxyManaging)? = nil,
        tunCoordinator: (any TunModeCoordinating)? = nil,
        proxyCoreControllerFactory: ProxyCoreControllerFactory? = nil
    ) -> AppModel {
        AppModel(
            paths: paths,
            preferencesStore: store ?? PreferencesStore(fileURL: paths.preferences),
            bootstrapper: bootstrapper ?? AppBootstrapper(paths: paths),
            runtimeManager: RuntimeComponentManager(paths: paths),
            exitDetector: exitDetector ?? ExitIPDetector(),
            profileReplacer: profileReplacer,
            systemProxyManager: systemProxyManager,
            tunCoordinator: tunCoordinator,
            proxyCoreControllerFactory: proxyCoreControllerFactory
        )
    }

    private func makeExecutable(in paths: AppPaths) throws -> URL {
        let executableURL = paths.root.appendingPathComponent("mihomo-test")
        try "#!/bin/sh\nexit 0\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return executableURL
    }

    private func makeSpeedTestModel(
        paths: AppPaths,
        selectedIP: String,
        script: String
    ) async throws -> AppModel {
        let store = PreferencesStore(fileURL: paths.preferences)
        let bootstrapper = AppBootstrapper(paths: paths)
        try await bootstrapper.prepareDefaults()
        if !selectedIP.isEmpty {
            try await bootstrapper.replaceProfile(
                with: validProfile(),
                selectedIP: selectedIP
            )
        }

        let executableURL = paths.root.appendingPathComponent("cfst-test")
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try await store.save(
            UserPreferences(
                parameters: .defaults(ipv6File: paths.ipv6List),
                selectedIP: selectedIP,
                cfstPath: executableURL.path
            ))

        let model = makeModel(paths: paths, store: store, bootstrapper: bootstrapper)
        model.start()
        try await waitUntilReady(model)
        return model
    }

    private func makePaths() -> AppPaths {
        AppPaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("AppModelTests-\(UUID().uuidString)", isDirectory: true)
        )
    }

    private func useLocalProxyMode(_ bootstrapper: AppBootstrapper) async throws {
        let local = LocalProxyConfiguration(networkAccessMode: .localProxy)
        let paths = await bootstrapper.paths
        try JSONEncoder.pretty.encode(local).write(
            to: paths.localProxyConfig,
            options: .atomic
        )
    }

    private func corruptPreferenceBackups(in paths: AppPaths) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: paths.preferences.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("preferences.corrupt-")
                && $0.pathExtension == "json"
        }
    }

    private func validProfile(
        address: String = "2606:4700::100",
        userID: String = "7b602ceb-cc3f-4274-a79d-c1a38f0fb0da",
        serverName: String = "proxy.example.net",
        path: String = "/viasix"
    ) -> Data {
        Data(
            """
            proxies:
              - name: edge
                type: vless
                server: \(address)
                port: 443
                uuid: \(userID)
                network: ws
                tls: true
                servername: \(serverName)
                ws-opts:
                  path: \(path)
                  headers:
                    Host: \(serverName)
            """.utf8
        )
    }

    private func providerOnlyProfile() -> Data {
        Data(
            """
            proxy-providers:
              remote:
                type: http
                url: https://subscription.example/profile.yaml
                path: providers/remote.yaml
                interval: 3600
            proxy-groups:
              - name: PROXY
                type: select
                use: [remote]
            rules:
              - MATCH,PROXY
            """.utf8
        )
    }

    private func selectedIPProfile() -> Data {
        Data(
            """
            x-viasix:
              version: 1
              primary-server: selected-ip
            proxies:
              - name: edge
                type: vless
                port: 443
                uuid: 11111111-1111-4111-8111-111111111111
                encryption: none
                udp: false
                tls: true
                servername: origin.example
                network: ws
                ws-opts:
                  path: /viasix
                  headers:
                    Host: origin.example
            """.utf8
        )
    }

    private func twoProxyProfile() -> Data {
        Data(
            """
            proxies:
              - name: first
                type: vless
                server: first-origin.example
                port: 443
                uuid: 11111111-1111-4111-8111-111111111111
                tls: true
                servername: first-origin.example
              - name: second
                type: vless
                server: second-origin.example
                port: 443
                uuid: 22222222-2222-4222-8222-222222222222
                tls: true
                servername: second-origin.example
            """.utf8
        )
    }

    private func writeLegacyPreferences(
        xrayPath: String,
        to destination: URL,
        ipv6File: URL
    ) throws {
        let current = UserPreferences(parameters: .defaults(ipv6File: ipv6File))
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "mihomoPath")
        object["xrayPath"] = xrayPath
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
            to: destination,
            options: .atomic
        )
    }
}

private actor ControlledTunModeCoordinator: TunModeCoordinating {
    private(set) var registration: TunHelperRegistrationState
    private(set) var runtimeState: TunPrivilegedRuntimeState = .ready
    private(set) var sessionPhase: TunHelperSessionPhase
    private(set) var sessionIdentifier: UUID?
    private(set) var sessionOwnedByCaller: Bool
    private(set) var recoveryRequired: Bool
    private(set) var statusCount = 0
    private(set) var registerCount = 0
    private(set) var repairCount = 0
    private(set) var runtimeInstallCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var recoverCount = 0
    private(set) var startedPlan: MihomoPrivilegedRuntimePlan?

    private let features: TunHelperFeature = [
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

    init(
        sessionIsRunning: Bool = false,
        registration: TunHelperRegistrationState = .enabled
    ) {
        self.registration = registration
        sessionPhase = sessionIsRunning ? .running : .inactive
        sessionIdentifier = sessionIsRunning ? UUID() : nil
        sessionOwnedByCaller = sessionIsRunning
        recoveryRequired = false
    }

    init(
        sessionPhase: TunHelperSessionPhase,
        sessionOwnedByCaller: Bool,
        registration: TunHelperRegistrationState = .enabled
    ) {
        self.registration = registration
        self.sessionPhase = sessionPhase
        self.sessionOwnedByCaller = sessionOwnedByCaller
        sessionIdentifier =
            sessionPhase != .inactive && sessionOwnedByCaller ? UUID() : nil
        recoveryRequired = sessionPhase == .recoveryRequired
    }

    func registrationState() -> TunHelperRegistrationState { registration }

    func registerService() throws -> TunHelperRegistrationState {
        registerCount += 1
        registration = .enabled
        return registration
    }

    func repairService() throws -> TunHelperRegistrationState {
        repairCount += 1
        registration = .enabled
        return registration
    }

    func setRegistration(_ registration: TunHelperRegistrationState) {
        self.registration = registration
    }

    func openApprovalSettings() {}

    func helperStatus() throws -> TunHelperStatusSnapshot {
        statusCount += 1
        return try snapshot()
    }

    func installOrRepairRuntime() throws -> TunHelperStatusSnapshot {
        runtimeInstallCount += 1
        runtimeState = .ready
        return try snapshot()
    }

    func startSession(envelopePayload: Data) throws -> TunHelperStatusSnapshot {
        startedPlan = try MihomoPrivilegedEnvelope.decodeRuntimePlan(from: envelopePayload)
        startCount += 1
        sessionPhase = .running
        sessionIdentifier = UUID()
        sessionOwnedByCaller = true
        recoveryRequired = false
        return try snapshot()
    }

    func stopSession() throws -> TunHelperStatusSnapshot {
        stopCount += 1
        sessionPhase = .inactive
        sessionIdentifier = nil
        sessionOwnedByCaller = false
        recoveryRequired = false
        return try snapshot()
    }

    private var recoverRestoresRunningSession = false

    func setRecoverRestoresRunningSession(_ value: Bool) {
        recoverRestoresRunningSession = value
    }

    func seedRecoveryRequiredSession() {
        sessionPhase = .recoveryRequired
        sessionIdentifier = UUID()
        sessionOwnedByCaller = true
        recoveryRequired = true
    }

    func recover() throws -> TunHelperStatusSnapshot {
        recoverCount += 1
        if recoverRestoresRunningSession {
            sessionPhase = .running
            sessionIdentifier = sessionIdentifier ?? UUID()
            sessionOwnedByCaller = true
            recoveryRequired = false
        } else {
            sessionPhase = .inactive
            sessionIdentifier = nil
            sessionOwnedByCaller = false
            recoveryRequired = false
        }
        return try snapshot()
    }

    func invalidate() {}

    private func snapshot() throws -> TunHelperStatusSnapshot {
        try TunHelperStatusSnapshot(
            supportedFeatures: features.rawValue,
            runtimeState: runtimeState,
            runtimeVersion: runtimeState == .ready ? "1.19.29" : nil,
            sessionPhase: sessionPhase,
            sessionIdentifier: sessionOwnedByCaller ? sessionIdentifier : nil,
            sessionOwnedByCaller: sessionOwnedByCaller,
            recoveryRequired: recoveryRequired,
            routingMode: sessionOwnedByCaller && sessionPhase != .inactive ? .rule : nil,
            observedAt: Date(),
            lastError: nil
        )
    }
}

private final class ControlledConfigurationWriter: @unchecked Sendable {
    enum Failure: Error, LocalizedError, Sendable {
        case injected

        var errorDescription: String? {
            "测试注入的配置写入失败"
        }
    }

    private let lock = NSLock()
    private var remainingSuccessfulWritesBeforeFailure: Int?

    func fail(afterSuccessfulWrites count: Int) {
        lock.withLock {
            remainingSuccessfulWritesBeforeFailure = count
        }
    }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            guard let remaining = remainingSuccessfulWritesBeforeFailure else { return false }
            guard remaining > 0 else { return true }
            remainingSuccessfulWritesBeforeFailure = remaining - 1
            return false
        }
        if shouldFail { throw Failure.injected }
        try data.write(to: url, options: .atomic)
    }
}

private actor ControlledSystemProxyManager: SystemProxyManaging {
    enum Failure: Error, LocalizedError, Sendable {
        case permissionDenied
        case recoveryFailed
        case restoreFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "没有修改系统代理所需的权限"
            case .recoveryFailed:
                "恢复遗留系统代理失败"
            case .restoreFailed:
                "恢复系统代理失败"
            }
        }
    }

    private let enableFailure: Failure?
    private var disableFailure: Failure?
    private let recoveryFailure: Failure?
    private var shouldSuspendNextEnable: Bool
    private var shouldSuspendNextDisable: Bool
    private var enableContinuation: CheckedContinuation<Void, Never>?
    private var disableContinuation: CheckedContinuation<Void, Never>?
    private(set) var enableCount = 0
    private(set) var disableCount = 0
    private(set) var recoveryCount = 0
    private(set) var lastEndpoint: ProxyEndpoint?
    private(set) var isActive: Bool

    init(
        enableFailure: Failure? = nil,
        disableFailure: Failure? = nil,
        recoveryFailure: Failure? = nil,
        initiallyActive: Bool = false,
        suspendNextEnable: Bool = false,
        suspendNextDisable: Bool = false
    ) {
        self.enableFailure = enableFailure
        self.disableFailure = disableFailure
        self.recoveryFailure = recoveryFailure
        isActive = initiallyActive
        shouldSuspendNextEnable = suspendNextEnable
        shouldSuspendNextDisable = suspendNextDisable
    }

    func enable(endpoint: ProxyEndpoint) async throws -> SystemProxySnapshot {
        enableCount += 1
        lastEndpoint = endpoint
        if let enableFailure { throw enableFailure }
        isActive = true
        if shouldSuspendNextEnable {
            shouldSuspendNextEnable = false
            await withCheckedContinuation { continuation in
                enableContinuation = continuation
            }
        }
        return SystemProxySnapshot(endpoint: endpoint, services: [])
    }

    func disable() async throws -> SystemProxyRestoreReport {
        disableCount += 1
        if shouldSuspendNextDisable {
            shouldSuspendNextDisable = false
            await withCheckedContinuation { continuation in
                disableContinuation = continuation
            }
        }
        if let disableFailure { throw disableFailure }
        isActive = false
        return SystemProxyRestoreReport(restoredServiceIDs: ["test-service"])
    }

    func recoverIfNeeded() async throws -> SystemProxyRestoreReport {
        recoveryCount += 1
        if let recoveryFailure { throw recoveryFailure }
        isActive = false
        return SystemProxyRestoreReport()
    }

    func isEnabled() async -> Bool {
        isActive
    }

    func resumeEnable() {
        enableContinuation?.resume()
        enableContinuation = nil
    }

    func resumeDisable() {
        disableContinuation?.resume()
        disableContinuation = nil
    }

    func setDisableFailure(_ failure: Failure?) {
        disableFailure = failure
    }
}

private final class ProxyCoreConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConfiguration: ProxyCoreControllerConfiguration?

    var configuration: ProxyCoreControllerConfiguration? {
        lock.withLock { storedConfiguration }
    }

    func record(_ configuration: ProxyCoreControllerConfiguration) {
        lock.withLock {
            storedConfiguration = configuration
        }
    }
}

private actor ControlledMihomoController: ProxyCoreControlling {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var restartCount = 0
    private(set) var isRunning = false
    private var eventHandler: MihomoEventHandler?
    private let restartDelay: Duration

    init(restartDelay: Duration = .zero) {
        self.restartDelay = restartDelay
    }

    func start(onEvent: @escaping MihomoEventHandler) async throws {
        startCount += 1
        eventHandler = onEvent
        await onEvent(.stateChanged(.validating))
        await onEvent(.stateChanged(.starting))
        isRunning = true
        await onEvent(.stateChanged(.running(pid: 42)))
    }

    func stop() async {
        stopCount += 1
        guard isRunning || eventHandler != nil else { return }
        isRunning = false
        if let eventHandler {
            await eventHandler(.stateChanged(.stopping))
            await eventHandler(.stateChanged(.stopped))
        }
        self.eventHandler = nil
    }

    func restart(onEvent: @escaping MihomoEventHandler) async throws {
        restartCount += 1
        await stop()
        try await Task.sleep(for: restartDelay)
        try await start(onEvent: onEvent)
    }

    func exitUnexpectedly() async {
        guard let eventHandler else { return }
        isRunning = false
        self.eventHandler = nil
        await eventHandler(.unexpectedExit(status: 9, output: "test exit"))
    }
}

private actor SuspendedProfileReplacer: ProxyProfileReplacing {
    private(set) var requestCount = 0

    func replaceProfile(
        with _: Data,
        selectedIP _: String?,
        expectedProfileData _: Data?
    ) async throws -> ProxyEndpoint {
        requestCount += 1
        try await Task.sleep(for: .seconds(30))
        return ProxyEndpoint()
    }
}

private actor ControlledExitDetector: ExitIPDetecting {
    enum Resolution: Sendable {
        case success(ExitIPInfo)
        case failure(StubError)
    }

    enum StubError: Error, LocalizedError, Sendable {
        case unavailable

        var errorDescription: String? {
            "检测服务暂不可用"
        }
    }

    private struct Request: Sendable {
        let id: UUID
    }

    private var requests: [Request] = []
    private var continuations: [UUID: CheckedContinuation<ExitIPInfo, any Error>] = [:]

    var requestCount: Int { requests.count }

    func requestID(at index: Int) -> UUID? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].id
    }

    func detect(
        proxy: ProxyEndpoint?,
        endpoint: URL?,
        expectedFamily: IPAddressFamily?
    ) async throws -> ExitIPInfo {
        let id = UUID()
        requests.append(Request(id: id))
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func resolve(_ id: UUID, with resolution: Resolution) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        switch resolution {
        case .success(let info):
            continuation.resume(returning: info)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private actor ControlledTwoPhaseExitDetector: ExitIPDetecting {
    enum Resolution: Sendable {
        case success(ExitIPInfo)
        case failure(StubError)
    }

    enum StubError: Error, LocalizedError, Sendable {
        case unavailable

        var errorDescription: String? {
            "位置服务暂不可用"
        }
    }

    private struct EnrichmentRequest: Sendable {
        let id: UUID
        let info: ExitIPInfo
    }

    private var primaryResults: [ExitIPInfo]
    private var enrichmentRequests: [EnrichmentRequest] = []
    private var enrichmentContinuations: [UUID: CheckedContinuation<ExitIPInfo, any Error>] = [:]

    init(primaryResults: [ExitIPInfo]) {
        self.primaryResults = primaryResults
    }

    var enrichmentRequestCount: Int { enrichmentRequests.count }

    func enrichmentRequestID(at index: Int) -> UUID? {
        guard enrichmentRequests.indices.contains(index) else { return nil }
        return enrichmentRequests[index].id
    }

    func detect(
        proxy _: ProxyEndpoint?,
        endpoint _: URL?,
        expectedFamily _: IPAddressFamily?
    ) async throws -> ExitIPInfo {
        guard !primaryResults.isEmpty else { throw StubError.unavailable }
        return primaryResults.removeFirst()
    }

    func enrich(
        _ info: ExitIPInfo,
        proxy _: ProxyEndpoint?
    ) async throws -> ExitIPInfo {
        let id = UUID()
        enrichmentRequests.append(EnrichmentRequest(id: id, info: info))
        return try await withCheckedThrowingContinuation { continuation in
            enrichmentContinuations[id] = continuation
        }
    }

    func resolveEnrichment(_ id: UUID, with resolution: Resolution) {
        guard let continuation = enrichmentContinuations.removeValue(forKey: id) else { return }
        switch resolution {
        case .success(let info):
            continuation.resume(returning: info)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private actor CancellationObservingExitDetector: ExitIPDetecting {
    private let primaryInfo: ExitIPInfo
    private(set) var enrichmentStarted = false
    private(set) var enrichmentWasCancelled = false

    init(primaryInfo: ExitIPInfo) {
        self.primaryInfo = primaryInfo
    }

    func detect(
        proxy _: ProxyEndpoint?,
        endpoint _: URL?,
        expectedFamily _: IPAddressFamily?
    ) async throws -> ExitIPInfo {
        primaryInfo
    }

    func enrich(
        _ info: ExitIPInfo,
        proxy _: ProxyEndpoint?
    ) async throws -> ExitIPInfo {
        enrichmentStarted = true
        do {
            try await Task.sleep(for: .seconds(30))
            return info
        } catch is CancellationError {
            enrichmentWasCancelled = true
            throw CancellationError()
        }
    }
}
