import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }

        isTerminating = true
        Task { @MainActor [weak self] in
            let canTerminate = await model.shutdown()
            sender.reply(toApplicationShouldTerminate: canTerminate)
            self?.isTerminating = false
            if !canTerminate {
                self?.presentQuitRefusalAlertIfNeeded(model: model)
            }
        }
        return .terminateLater
    }

    /// In-app notices render only inside the main window; a quit from the menu
    /// bar with the window closed would otherwise be refused silently.
    private func presentQuitRefusalAlertIfNeeded(model: AppModel) {
        guard !mainWindowIsVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法安全退出"
        alert.informativeText =
            model.state.notice?.message ?? "退出前的清理未完成，请打开主窗口查看详情后重试。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private var mainWindowIsVisible: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.identifier?.rawValue.hasPrefix("main") == true
        }
    }
}
