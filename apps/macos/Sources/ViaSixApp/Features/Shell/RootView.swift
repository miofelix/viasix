import AppKit
import SwiftUI
import ViaSixCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(VisualStyle.surfaceBorder)
                .frame(width: 1)
            detail
        }
        .background(VisualStyle.pageBackgroundColor)
        .tint(VisualStyle.accent)
        .frame(minWidth: 860, minHeight: 620)
        .comfortableInterface()
        .animation(VisualStyle.standardAnimation, value: model.state.notice?.id)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                Text(AppMetadata.name)
                    .font(.system(size: 19, weight: .bold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 19)
            .padding(.bottom, 18)

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { section in
                    navigationButton(section)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: VisualStyle.spacing16)

            VStack(alignment: .leading, spacing: 7) {
                Divider()
                Label(
                    "IPv6 代理入口",
                    systemImage: "6.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(VisualStyle.positive)

                if !model.state.preferences.selectedIP.isEmpty {
                    Text(model.state.preferences.selectedIP)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(width: VisualStyle.sidebarWidth)
        .background(VisualStyle.sidebarBackgroundColor)
    }

    private func navigationButton(_ section: AppSection) -> some View {
        let selected = router.selectedSection == section
        return Button {
            router.select(section)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 17, weight: selected ? .semibold : .medium))
                    .frame(width: 22)
                Text(section.title)
                    .font(.system(size: 15, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .frame(height: VisualStyle.navigationRowHeight)
            .background(
                selected ? VisualStyle.accent.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: VisualStyle.radiusSmall)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "当前页面" : "")
    }

    private var detail: some View {
        ZStack(alignment: .bottomTrailing) {
            VisualStyle.pageBackground.ignoresSafeArea()
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let notice = model.state.notice {
                NoticeView(
                    notice: notice,
                    selectSection: { router.select($0) },
                    dismiss: model.clearNotice
                )
                .padding(14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.state.launchPhase {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在准备 ViaSix…").font(.headline)
                Text("正在检查 IPv6 资源、配置与虚拟网卡服务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("初始化失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试", action: model.retryBootstrap)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            page(router.selectedSection)
        }
    }

    @ViewBuilder
    private func page(_ section: AppSection) -> some View {
        switch section {
        case .overview:
            OverviewView(
                onSelectNodes: { router.select(.nodes) },
                onManageRuntime: { router.select(.settings) }
            )
        case .nodes:
            NodesView()
        case .profiles:
            ProfilesView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }
}

private struct NoticeView: View {
    let notice: AppNotice
    let selectSection: (AppSection) -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(notice.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let (title, section) = actionPresentation {
                Button(title) { selectSection(section) }
                    .buttonStyle(.borderless)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(VisualStyle.surfaceBorder)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: 520)
    }

    private var actionPresentation: (String, AppSection)? {
        switch notice.action {
        case .openSettings: ("打开设置", .settings)
        case .openProfiles: ("打开连接配置", .profiles)
        case nil: nil
        }
    }

    private var color: Color {
        switch notice.style {
        case .info: VisualStyle.accent
        case .success: VisualStyle.positive
        case .error: VisualStyle.negative
        }
    }

    private var icon: String {
        switch notice.style {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }
}
