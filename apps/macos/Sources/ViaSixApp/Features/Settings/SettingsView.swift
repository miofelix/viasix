import AppKit
import SwiftUI
import ViaSixCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsLocalProxyEditor = false
    @State private var exitIPEndpointDraft = ""
    @State private var exitIPEndpointError: String?

    var body: some View {
        VStack(spacing: 0) {
            AppPageHeader("设置", subtitle: "连接、网络接入与运行组件")

            ScrollView {
                VStack(alignment: .leading, spacing: VisualStyle.spacing12) {
                    runtimeCard
                    localProxyCard
                    tunServiceCard
                    dataCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VisualStyle.pageHorizontalPadding)
                .padding(.vertical, VisualStyle.pageVerticalPadding)
            }
            .scrollbarSafeContent()
        }
        .onAppear {
            if exitIPEndpointDraft.isEmpty {
                exitIPEndpointDraft = model.exitIPEndpoint
            }
        }
        .onChange(of: model.exitIPEndpoint) { _, endpoint in
            if endpoint != exitIPEndpointDraft {
                exitIPEndpointDraft = endpoint
                exitIPEndpointError = nil
            }
        }
    }

    private var tunServiceCard: some View {
        SurfaceCard {
            CardHeader(
                "虚拟网卡服务",
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                tone: tunServiceTone
            ) {
                StatusBadge(
                    tunServiceStatusTitle,
                    tone: tunServiceTone,
                    systemImage: tunServiceStatusSystemImage
                )
            }
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                SettingRow(
                    "系统服务",
                    detail: tunRegistrationDetail,
                    systemImage: "gearshape.2"
                ) {
                    tunRegistrationAction
                }

                Divider()
                    .padding(.leading, 52)

                SettingRow(
                    "特权 Mihomo",
                    detail: tunRuntimeDetail,
                    systemImage: "shield.lefthalf.filled"
                ) {
                    tunRuntimeAction
                }

                Divider()
                    .padding(.leading, 52)

                SettingRow(
                    "TUN 会话",
                    detail: tunSessionDetail,
                    systemImage: "network"
                ) {
                    tunSessionAction
                }

                if let error = model.state.tun.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, VisualStyle.spacing8)
                }

                Text("TUN 使用应用内固定签名的 Mihomo，由 macOS 后台服务以最小权限启动；不会使用自定义可执行文件。本地构建只在首次安装或特权服务升级时请求管理员授权，日常启停无需重复输入密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, VisualStyle.spacing8)
            }
            .padding(.horizontal, VisualStyle.spacing16)
            .padding(.bottom, VisualStyle.spacing8)
        }
    }

    @ViewBuilder
    private var tunRegistrationAction: some View {
        if model.state.tun.operationInProgress {
            ProgressView()
                .controlSize(.small)
        } else {
            switch model.state.tun.servicePhase {
            case .checking:
                Button("刷新", systemImage: "arrow.clockwise") {
                    model.refreshTunState()
                }
                .controlSize(.small)
            case .notInstalled:
                Button("安装服务", systemImage: "plus.circle") {
                    model.installTunService()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canMaintainTunInstallation)
            case .requiresApproval:
                Button("打开系统设置", systemImage: "gear") {
                    model.openTunApprovalSettings()
                }
                .controlSize(.small)
            case .ready:
                Button("刷新", systemImage: "arrow.clockwise") {
                    model.refreshTunState()
                }
                .controlSize(.small)
            case .unavailable:
                Button("修复服务", systemImage: "wrench.and.screwdriver") {
                    model.repairTunService()
                }
                .controlSize(.small)
                .disabled(!model.canMaintainTunInstallation)
            }
        }
    }

    @ViewBuilder
    private var tunRuntimeAction: some View {
        if model.state.tun.operationInProgress || model.state.tun.runtimePhase == .installing {
            ProgressView()
                .controlSize(.small)
        } else if model.state.tun.serviceIsReady {
            switch model.state.tun.runtimePhase {
            case .unknown:
                Button("检查", systemImage: "arrow.clockwise") {
                    model.refreshTunState()
                }
                .controlSize(.small)
            case .notInstalled:
                Button("安装", systemImage: "arrow.down.circle") {
                    model.installOrRepairTunRuntime()
                }
                .controlSize(.small)
                .disabled(!model.canMaintainTunInstallation)
            case .ready:
                Button("重新安装", systemImage: "arrow.clockwise.circle") {
                    model.installOrRepairTunRuntime()
                }
                .controlSize(.small)
                .disabled(!model.canMaintainTunInstallation)
            case .repairRequired, .failed:
                Button("修复", systemImage: "wrench.and.screwdriver") {
                    model.installOrRepairTunRuntime()
                }
                .controlSize(.small)
                .disabled(!model.canMaintainTunInstallation)
            case .installing:
                EmptyView()
            }
        } else {
            Text("等待服务")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tunSessionAction: some View {
        switch model.state.tun.sessionPhase {
        case .running:
            if model.canStopTunSession {
                Button("停止", systemImage: "stop.fill") {
                    model.stopProxy()
                }
                .controlSize(.small)
            } else {
                Text("其他用户运行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .recoveryRequired:
            if model.canRecoverTunSession {
                Button("恢复", systemImage: "arrow.counterclockwise") {
                    model.recoverTunSession()
                }
                .controlSize(.small)
                .disabled(model.state.tun.operationInProgress)
            } else {
                Text("等待会话所有者处理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Text("已停止，可检查后重试")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .starting, .stopping, .recovering:
            if model.hasForeignTunSession {
                Text("其他用户处理中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .inactive:
            Text("未运行")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var runtimeCard: some View {
        SurfaceCard {
            CardHeader("运行组件", systemImage: "shippingbox") {
                runtimeBadge
            }
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                runtimeComponentSection(.cfst)
                Divider()
                    .padding(.vertical, VisualStyle.spacing4)
                runtimeComponentSection(.mihomo)

                if model.state.runtimeOperation != nil {
                    Divider()
                        .padding(.top, VisualStyle.spacing8)

                    HStack(spacing: VisualStyle.spacing12) {
                        runtimeOperationStatus
                        Spacer()
                        if model.state.runtimeOperation?.canCancel == true {
                            Button("取消", systemImage: "xmark.circle") {
                                model.cancelRuntimeOperation()
                            }
                        }
                    }
                    .padding(.vertical, VisualStyle.spacing12)
                }

                if let issue = model.runtimeIntegrityIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, VisualStyle.spacing12)
                }

                if let message = model.state.runtimeOperationError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, VisualStyle.spacing12)
                }
            }
            .padding(.horizontal, VisualStyle.spacing16)
            .padding(.bottom, VisualStyle.spacing12)
        }
    }

    @ViewBuilder
    private var runtimeOperationStatus: some View {
        if let operation = model.state.runtimeOperation {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(operation.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(operation.description)
        }
    }

    private var localProxyCard: some View {
        SurfaceCard {
            CardHeader("本机代理", systemImage: "laptopcomputer", tone: .accent) {
                Button("编辑", systemImage: "slider.horizontal.3") {
                    showsLocalProxyEditor = true
                }
                .disabled(localProxyEditingDisabled)
            }
            Divider()

            VStack(spacing: 0) {
                SettingRow(
                    "传输策略",
                    detail: "规则与全局模式只使用所选 IPv6 代理入口",
                    systemImage: "6.circle.fill"
                ) {
                    StatusBadge(
                        "IPv6",
                        tone: .positive
                    )
                }

                Divider()
                    .padding(.leading, 52)

                SettingRow(
                    "网络接入",
                    detail: networkAccessConfigurationDetail,
                    systemImage: "network"
                ) {
                    StatusBadge(
                        networkAccessTitle,
                        tone: networkAccessTone,
                        systemImage: networkAccessSystemImage
                    )
                }

                Divider()
                    .padding(.leading, 52)

                SettingRow(
                    "监听端点",
                    detail: "HTTP 与 SOCKS 共用本地 mixed 入口",
                    systemImage: "dot.radiowaves.left.and.right"
                ) {
                    Text(model.state.proxyEndpoint.displayAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, VisualStyle.spacing16)
            .padding(.bottom, VisualStyle.spacing12)
        }
        .sheet(isPresented: $showsLocalProxyEditor) {
            LocalProxySettingsView()
                .environment(model)
        }
    }

    private var dataCard: some View {
        SurfaceCard {
            CardHeader("应用与数据", systemImage: "folder", tone: .neutral)
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                SettingRow(
                    "数据目录",
                    detail: model.paths.root.path,
                    systemImage: "folder"
                ) {
                    Button("打开", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(model.paths.root)
                    }
                }

                Divider()
                    .padding(.leading, 52)

                SettingRow(
                    "出口 IP 检测服务",
                    detail: exitIPEndpointError ?? "自动检测出口地址时使用",
                    systemImage: "location"
                ) {
                    HStack(spacing: VisualStyle.spacing8) {
                        TextField(
                            AppMetadata.defaultExitIPEndpoint,
                            text: $exitIPEndpointDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220, idealWidth: 320, maxWidth: 380)
                        .accessibilityLabel("出口 IP 检测服务地址")
                        .accessibilityHint("使用 HTTP 或 HTTPS 地址")
                        .onChange(of: exitIPEndpointDraft) { _, value in
                            validateAndSaveExitIPEndpoint(value)
                        }

                        Button {
                            exitIPEndpointDraft = AppMetadata.defaultExitIPEndpoint
                            validateAndSaveExitIPEndpoint(exitIPEndpointDraft)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .iconButtonHitTarget()
                        .help("恢复默认检测服务")
                        .accessibilityLabel("恢复默认检测服务")
                        .disabled(exitIPEndpointDraft == AppMetadata.defaultExitIPEndpoint)
                    }
                }

                Divider()

                HStack(spacing: VisualStyle.spacing8) {
                    Button("使用帮助", systemImage: "questionmark.circle") {
                        AppDocumentOpener.open(.userGuide)
                    }
                    Button("第三方许可", systemImage: "doc.plaintext") {
                        AppDocumentOpener.open(.thirdPartyNotices)
                    }
                    Spacer()
                }
                .padding(.vertical, VisualStyle.spacing12)
            }
            .padding(.horizontal, VisualStyle.spacing16)
            .padding(.bottom, VisualStyle.spacing12)
        }
    }

    private var tunServiceTone: AppTone {
        if model.state.tun.operationInProgress || model.isTunTransitioning { return .accent }
        if model.state.tun.isRunning { return .positive }
        if model.state.tun.lastError != nil { return .negative }
        if model.canUseTunMode { return .positive }
        return switch model.state.tun.servicePhase {
        case .checking: .neutral
        case .notInstalled, .requiresApproval: .warning
        case .ready:
            switch model.state.tun.runtimePhase {
            case .failed: .negative
            case .unknown, .notInstalled, .ready, .repairRequired, .installing: .warning
            }
        case .unavailable: .negative
        }
    }

    private var tunServiceStatusTitle: String {
        if model.state.tun.operationInProgress || model.isTunTransitioning { return "处理中" }
        if model.state.tun.isRunning { return "运行中" }
        if model.canUseTunMode { return "已就绪" }
        return switch model.state.tun.servicePhase {
        case .checking: "检查中"
        case .notInstalled: "未安装"
        case .requiresApproval: "待批准"
        case .unavailable: "不可用"
        case .ready:
            switch model.state.tun.runtimePhase {
            case .unknown: "检查中"
            case .notInstalled: "缺少内核"
            case .ready: "能力不完整"
            case .repairRequired: "需修复"
            case .installing: "安装中"
            case .failed: "安装失败"
            }
        }
    }

    private var tunServiceStatusSystemImage: String {
        switch tunServiceTone {
        case .accent: "arrow.triangle.2.circlepath"
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .negative: "xmark.circle.fill"
        case .neutral: "circle"
        }
    }

    private var tunRegistrationDetail: String {
        switch model.state.tun.servicePhase {
        case .checking:
            "正在检查 macOS 后台服务注册状态"
        case .notInstalled:
            "尚未安装用于管理 TUN 的 LaunchDaemon"
        case .requiresApproval:
            "已注册，等待在系统设置中允许后台运行"
        case .ready:
            "后台服务已注册并可建立受签名约束的 XPC 连接"
        case .unavailable(let detail):
            detail
        }
    }

    private var tunRuntimeDetail: String {
        let version = model.state.tun.runtimeVersion.map { " · \($0)" } ?? ""
        return switch model.state.tun.runtimePhase {
        case .unknown: "等待后台服务检查固定签名内核"
        case .notInstalled: "尚未安装应用内置的固定签名 Mihomo"
        case .ready: "签名与完整性校验通过\(version)"
        case .repairRequired: "已安装文件未通过签名或完整性校验"
        case .installing: "正在以 root-only 权限安装并验证"
        case .failed(let detail): detail
        }
    }

    private var tunSessionDetail: String {
        switch model.state.tun.sessionPhase {
        case .inactive:
            "当前没有特权 TUN 会话"
        case .starting:
            "正在创建虚拟网卡并应用路由与 DNS"
        case .running:
            model.state.tun.sessionOwnedByCurrentUser
                ? "正在接管流量，退出应用前会安全停止"
                : "已有其他用户的 TUN 会话正在运行"
        case .stopping:
            "正在撤销路由、DNS 与虚拟网卡"
        case .recovering:
            "正在核验并恢复上次会话状态"
        case .recoveryRequired:
            "检测到未完成清理的会话，需要恢复"
        case .failed(let detail):
            detail
        }
    }

    private var networkAccessConfigurationDetail: String {
        switch networkAccessFlags {
        case (true, true): "系统代理与 TUN 独立启用"
        case (true, false): "本地代理运行后接入 macOS 系统代理"
        case (false, true): "通过虚拟网卡接管应用流量"
        case (false, false): "仅提供本机 mixed 代理端口"
        }
    }

    private var networkAccessFlags: (systemProxy: Bool, tun: Bool) {
        (
            model.state.localProxyConfiguration.systemProxyEnabled,
            model.state.localProxyConfiguration.networkAccessMode == .virtualInterface
        )
    }

    private var networkAccessTitle: String {
        switch networkAccessFlags {
        case (true, true): "系统代理 + TUN"
        case (true, false): "系统代理"
        case (false, true): "TUN"
        case (false, false): "本地代理"
        }
    }

    private var systemProxyPresentation: SystemProxyStatusPresentation {
        SystemProxyStatusPresentation(
            phase: model.state.systemProxyPhase,
            isRequested: model.state.localProxyConfiguration.systemProxyEnabled
        )
    }

    private var networkAccessTone: AppTone {
        if case .failed = model.state.systemProxyPhase { return .negative }
        if case .failed = model.state.tun.sessionPhase { return .negative }
        if model.isSystemProxyTransitioning || model.isTunTransitioning { return .accent }
        return networkAccessFlags.systemProxy || networkAccessFlags.tun ? .positive : .neutral
    }

    private var networkAccessSystemImage: String {
        if networkAccessTone == .negative { return "exclamationmark.triangle.fill" }
        if model.isSystemProxyTransitioning || model.isTunTransitioning { return "hourglass" }
        if networkAccessFlags.tun { return "point.3.filled.connected.trianglepath.dotted" }
        if networkAccessFlags.systemProxy { return systemProxyStatusSystemImage }
        return "dot.radiowaves.left.and.right"
    }

    private var systemProxyStatusSystemImage: String {
        if systemProxyPresentation.isTransitioning {
            return "hourglass"
        }
        return switch systemProxyPresentation.tone {
        case .active: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .pending: "clock.fill"
        case .neutral: "circle"
        }
    }

    private var runtimeBadge: some View {
        let (label, tone, systemImage): (String, AppTone, String) =
            if model.state.runtimeOperation != nil {
                ("操作中", .accent, "arrow.triangle.2.circlepath")
            } else if model.state.runtimeOperationError != nil {
                ("操作失败", .negative, "xmark.circle.fill")
            } else if model.runtimeIntegrityIssue != nil {
                ("需修复", .warning, "exclamationmark.circle.fill")
            } else {
                switch model.state.runtimePhase {
                case .checking: ("检查中", .neutral, "arrow.triangle.2.circlepath")
                case .missing: ("未就绪", .warning, "exclamationmark.circle.fill")
                case .ready: ("已就绪", .positive, "checkmark.circle.fill")
                }
            }
        return StatusBadge(label, tone: tone, systemImage: systemImage)
    }

    private func runtimeComponentSection(_ component: RuntimeComponent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            componentRow(
                component: component,
                url: resolvedDisplayURL(for: component),
                ready: componentReady(component)
            )

            Divider()
                .padding(.leading, 52)

            customExecutableRow(component)
        }
    }

    private func componentRow(
        component: RuntimeComponent,
        url: URL?,
        ready: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Link(destination: component.repositoryURL) {
                    HStack(spacing: 6) {
                        Text(component.displayName)
                            .fontWeight(.medium)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("在 GitHub 打开 \(component.displayName)")
                Text(url?.path ?? "未找到")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()

            Button(
                componentInstallTitle(component),
                systemImage: componentOperationIsActive(component)
                    ? "arrow.triangle.2.circlepath"
                    : "arrow.down.circle"
            ) {
                model.installRuntime(component)
            }
            .buttonStyle(.bordered)
            .tint(VisualStyle.accent)
            .controlSize(.small)
            .disabled(componentInstallDisabled(component))
        }
        .frame(minHeight: VisualStyle.settingsRowHeight)
    }

    private func customExecutableRow(_ component: RuntimeComponent) -> some View {
        let value = customExecutablePath(component)
        let editingDisabled = componentPathEditingDisabled(component)
        return VStack(alignment: .leading, spacing: VisualStyle.spacing8) {
            HStack(spacing: VisualStyle.spacing12) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text("自定义可执行文件")
                        .font(.subheadline.weight(.medium))
                    Text(value.isEmpty ? "未指定；使用托管组件、Homebrew 或 PATH" : value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button(value.isEmpty ? "导入…" : "更换…", systemImage: "folder") {
                    chooseExecutable(component)
                }
                .controlSize(.small)
                .disabled(editingDisabled)

                if !value.isEmpty {
                    Button {
                        model.setCustomExecutable(component, url: nil)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .iconButtonHitTarget()
                    .help("清除 \(component.displayName) 自定义路径")
                    .accessibilityLabel("清除 \(component.displayName) 自定义可执行文件")
                    .disabled(editingDisabled)
                }
            }

            if editingDisabled {
                Text(componentPathEditingMessage(component))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
            }
        }
        .frame(minHeight: VisualStyle.settingsRowHeight)
    }

    private func customExecutablePath(_ component: RuntimeComponent) -> String {
        switch component {
        case .cfst:
            model.state.preferences.cfstPath
        case .mihomo:
            model.state.preferences.mihomoPath
        }
    }

    private func componentInstallTitle(_ component: RuntimeComponent) -> String {
        if componentOperationIsActive(component) { return "安装中" }
        if managedComponentInvalid(component) { return "修复" }
        return managedComponentReady(component) ? "重新安装" : "安装"
    }

    private func componentOperationIsActive(_ component: RuntimeComponent) -> Bool {
        model.state.runtimeOperation?.installingComponent == component
    }

    private func managedComponentReady(_ component: RuntimeComponent) -> Bool {
        switch component {
        case .cfst:
            model.state.runtimeStatus?.cfstIsReady == true
        case .mihomo:
            model.state.runtimeStatus?.mihomoIsReady == true
        }
    }

    private func managedComponentInvalid(_ component: RuntimeComponent) -> Bool {
        let payload: RuntimePayloadFile =
            switch component {
            case .cfst: .cfst
            case .mihomo: .mihomo
            }
        return model.state.runtimeStatus?.invalidFiles.contains(payload) == true
    }

    private func componentInstallDisabled(_ component: RuntimeComponent) -> Bool {
        guard model.state.launchPhase == .ready else { return true }
        guard model.state.runtimeOperation == nil else { return true }
        guard model.state.templateOperationPhase == .idle else { return true }
        guard model.switchingIP == nil else { return true }

        return switch component {
        case .cfst:
            model.isCfstBusy
        case .mihomo:
            switch model.state.proxyCorePhase {
            case .validating, .starting, .running, .stopping:
                true
            case .stopped, .failed:
                false
            }
        }
    }

    private func componentReady(_ component: RuntimeComponent) -> Bool {
        resolvedDisplayURL(for: component) != nil
    }

    private func componentPathEditingDisabled(_ component: RuntimeComponent) -> Bool {
        if model.state.runtimeOperation != nil { return true }
        return switch component {
        case .cfst:
            model.isCfstBusy
        case .mihomo:
            switch model.state.proxyCorePhase {
            case .validating, .starting, .running, .stopping:
                true
            case .stopped, .failed:
                false
            }
        }
    }

    private func componentPathEditingMessage(_ component: RuntimeComponent) -> String {
        if let operation = model.state.runtimeOperation {
            return "\(operation.description)，完成后才能修改路径。"
        }
        return switch component {
        case .cfst: "测速进行中，停止后才能修改路径。"
        case .mihomo: "本地代理运行中，停止后才能修改路径。"
        }
    }

    private func resolvedDisplayURL(for component: RuntimeComponent) -> URL? {
        let (preferredPath, managedURL, commandName): (String, URL?, String) =
            switch component {
            case .cfst:
                (model.state.preferences.cfstPath, model.state.runtimeStatus?.cfstURL, "cfst")
            case .mihomo:
                (
                    model.state.preferences.mihomoPath,
                    model.state.runtimeStatus?.mihomoIsReady == true
                        ? model.state.runtimeStatus?.mihomoURL
                        : nil,
                    "mihomo"
                )
            }

        var candidates: [URL] = []
        if !preferredPath.isEmpty {
            candidates.append(URL(fileURLWithPath: preferredPath))
        }
        if let managedURL {
            candidates.append(managedURL)
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(commandName)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(commandName)"))
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(
                contentsOf: path.split(separator: ":").map {
                    URL(fileURLWithPath: String($0)).appendingPathComponent(commandName)
                })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private var localProxyEditingDisabled: Bool {
        guard model.state.launchPhase == .ready else { return true }
        guard model.state.templateOperationPhase == .idle else { return true }
        guard model.switchingIP == nil else { return true }
        guard model.state.runtimeOperation == nil else { return true }
        return switch model.state.proxyCorePhase {
        case .validating, .starting, .running, .stopping:
            true
        case .stopped, .failed:
            false
        }
    }

    private func chooseExecutable(_ component: RuntimeComponent) {
        let panel = NSOpenPanel()
        panel.title = "导入 \(component.displayName) 自定义可执行文件"
        panel.message = "该文件只覆盖 \(component.displayName) 的自动查找路径，不会复制或修改另一个组件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此文件"
        if panel.runModal() == .OK {
            model.setCustomExecutable(component, url: panel.url)
        }
    }

    private func validateAndSaveExitIPEndpoint(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            exitIPEndpointError = "检测服务地址不能为空；可点击右侧按钮恢复默认地址。"
            return
        }
        guard
            let url = URL(string: normalized),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil
        else {
            exitIPEndpointError = "请输入有效的 HTTP 或 HTTPS 地址。"
            return
        }
        exitIPEndpointError = nil
        model.exitIPEndpoint = normalized
    }
}
