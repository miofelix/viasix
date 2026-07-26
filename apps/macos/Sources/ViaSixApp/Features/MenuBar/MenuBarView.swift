import AppKit
import SwiftUI
import ViaSixCore

/// A compact status-and-control surface for ViaSix's IPv6-first workflow.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 ViaSix", systemImage: "macwindow") {
            openMainWindow(.overview)
        }
        .keyboardShortcut("o")

        Divider()

        Label(transportTitle, systemImage: transportIcon)
        Label(proxyStatusTitle, systemImage: proxyStatusIcon)

        if let failureMessage = proxyFailureMessage {
            Text(failureMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }

        if let trafficSummary = MenuBarTrafficPresentation.menuSummary(
            isProxyRunning: model.state.isProxyRunning,
            snapshot: model.state.traffic.snapshot
        ) {
            Text(trafficSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }

        if !selectedNode.isEmpty {
            Text("IPv6 节点：\(selectedNode)")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }

        if let issue = model.proxyConfigurationIssue, !model.state.isProxyRunning {
            Text(issue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }

        Divider()

        proxyAction

        Button("重新连接", systemImage: "arrow.clockwise") {
            model.restartProxy()
        }
        .disabled(!model.state.isProxyRunning || proxyOperationBusy)

        Divider()

        Button("IPv6 优选", systemImage: "6.circle") {
            openMainWindow(.nodes)
        }
        Button("日志", systemImage: "text.alignleft") {
            openMainWindow(.logs)
        }
        Button("设置", systemImage: "gearshape") {
            openMainWindow(.settings)
        }

        Divider()

        Button("退出 ViaSix", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var proxyAction: some View {
        switch model.state.proxyCorePhase {
        case .stopped, .failed:
            Button("启动 IPv6 连接", systemImage: "play.fill") {
                model.startProxy()
            }
            .disabled(proxyStartDisabled)
        case .validating, .starting:
            Button("停止连接", systemImage: "stop.fill") {
                model.stopProxy()
            }
        case .running:
            Button("停止连接", systemImage: "stop.fill") {
                model.stopProxy()
            }
        case .stopping:
            Button("正在停止…", systemImage: "hourglass") {}
                .disabled(true)
        }
    }

    private var transportTitle: String {
        let route = model.state.localProxyConfiguration.routingMode.displayName
        let access =
            model.state.localProxyConfiguration.networkAccessMode == .virtualInterface
            ? "TUN" : "本地代理"
        return "\(route) · \(access)"
    }

    private var transportIcon: String {
        "6.circle.fill"
    }

    private var selectedNode: String {
        model.state.preferences.selectedIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var proxyStatusTitle: String {
        switch model.state.proxyCorePhase {
        case .stopped: "连接未启动"
        case .validating: "正在校验配置"
        case .starting: "正在建立连接"
        case .running: "连接运行中"
        case .stopping: "正在停止连接"
        case .failed: "连接异常"
        }
    }

    private var proxyStatusIcon: String {
        switch model.state.proxyCorePhase {
        case .running: "checkmark.circle.fill"
        case .validating, .starting, .stopping: "hourglass"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "circle"
        }
    }

    private var proxyFailureMessage: String? {
        guard case .failed(let message) = model.state.proxyCorePhase, !message.isEmpty else {
            return nil
        }
        return message
    }

    private var proxyOperationBusy: Bool {
        model.switchingIP != nil
            || model.isTemplateOperationBusy
            || model.state.runtimeOperation != nil
    }

    private var proxyStartDisabled: Bool {
        guard model.state.launchPhase == .ready else { return true }
        return proxyOperationBusy
            || model.hasForeignTunSession
            || !model.activeProxyRuntimeIsAvailable
            || !model.isProxyConfigurationReady
    }

    private func openMainWindow(_ section: AppSection) {
        router.select(section)
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
