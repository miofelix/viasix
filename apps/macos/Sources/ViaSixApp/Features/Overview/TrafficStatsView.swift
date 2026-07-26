import Charts
import SwiftUI
import ViaSixCore

struct TrafficStatsView: View {
    let snapshot: TrafficSnapshot
    let isProxyRunning: Bool
    var monitorUnavailableReason: String?

    private static let graphHeight: CGFloat = 128
    private static let metricHeight: CGFloat = 56
    private static let footerHeight: CGFloat = 16

    var body: some View {
        SurfaceCard {
            CardHeader("流量统计", systemImage: "chart.xyaxis.line", tone: headerTone) {
                StatusBadge(
                    statusTitle,
                    tone: statusTone,
                    systemImage: statusIcon
                )
                .frame(minWidth: 72, alignment: .trailing)
            }
            Divider()

            VStack(alignment: .leading, spacing: VisualStyle.spacing12) {
                trafficGraph
                    .frame(height: Self.graphHeight)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: VisualStyle.radiusMedium, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: VisualStyle.radiusMedium, style: .continuous)
                            .fill(VisualStyle.subtleFill)
                    )

                // Fixed 2×3 grid keeps metric tiles aligned regardless of value length.
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: VisualStyle.spacing12),
                        GridItem(.flexible(), spacing: VisualStyle.spacing12),
                        GridItem(.flexible(), spacing: VisualStyle.spacing12),
                    ],
                    spacing: VisualStyle.spacing12
                ) {
                    metricTile(
                        title: "上传",
                        value: ByteRateFormatter.formatRate(snapshot.up),
                        systemImage: "arrow.up.circle.fill",
                        tone: .accent
                    )
                    metricTile(
                        title: "下载",
                        value: ByteRateFormatter.formatRate(snapshot.down),
                        systemImage: "arrow.down.circle.fill",
                        tone: .positive
                    )
                    metricTile(
                        title: "内存",
                        value: ByteRateFormatter.formatBytes(snapshot.memoryInUse),
                        systemImage: "memorychip",
                        tone: .warning
                    )
                    metricTile(
                        title: "总上传",
                        value: ByteRateFormatter.formatBytes(snapshot.uploadTotal),
                        systemImage: "arrow.up.to.line.circle.fill",
                        tone: .accent
                    )
                    metricTile(
                        title: "总下载",
                        value: ByteRateFormatter.formatBytes(snapshot.downloadTotal),
                        systemImage: "arrow.down.to.line.circle.fill",
                        tone: .positive
                    )
                    metricTile(
                        title: "状态",
                        value: statusMetricValue,
                        systemImage: isProxyRunning ? "waveform.path.ecg" : "pause.circle",
                        tone: monitorIsUnavailable ? .warning : (isProxyRunning ? .positive : .neutral)
                    )
                }

                Text(footerText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: Self.footerHeight, alignment: .leading)
                    .opacity(0.85)
            }
            .padding(VisualStyle.spacing16)
        }
    }

    private var monitorIsUnavailable: Bool {
        isProxyRunning && monitorUnavailableReason != nil
    }

    private var statusMetricValue: String {
        if !isProxyRunning { return "未连接" }
        if monitorIsUnavailable { return "统计不可用" }
        return snapshot.isLive ? "实时采集" : "连接中"
    }

    private var graphPlaceholderText: String {
        if monitorIsUnavailable { return "流量统计不可用" }
        return isProxyRunning ? "等待流量数据…" : "暂无流量数据"
    }

    private var headerTone: AppTone {
        if !isProxyRunning { return .neutral }
        if monitorIsUnavailable { return .warning }
        return snapshot.isLive ? .positive : .accent
    }

    private var statusTitle: String {
        if !isProxyRunning { return "未连接" }
        if monitorIsUnavailable { return "不可用" }
        return snapshot.isLive ? "实时" : "连接中"
    }

    private var statusTone: AppTone {
        if !isProxyRunning { return .neutral }
        if monitorIsUnavailable { return .warning }
        return snapshot.isLive ? .positive : .warning
    }

    private var statusIcon: String {
        if !isProxyRunning { return "circle" }
        if monitorIsUnavailable { return "exclamationmark.triangle.fill" }
        return snapshot.isLive ? "antenna.radiowaves.left.and.right" : "hourglass"
    }

    private var footerText: String {
        if monitorIsUnavailable, let monitorUnavailableReason {
            return "流量统计不可用：\(monitorUnavailableReason)"
        }
        if isProxyRunning {
            return "速率来自 /traffic，累计来自 /connections，内存来自 /memory"
        }
        return "启动连接后显示实时上下行速率、累计流量、流量曲线与内存占用"
    }

    @ViewBuilder
    private var trafficGraph: some View {
        let points = displayPoints
        if points.isEmpty {
            ZStack {
                TrafficGraphGrid()
                Text(graphPlaceholderText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Chart {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("时间", point.date),
                        y: .value("速率", point.down)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                VisualStyle.positive.opacity(0.28),
                                VisualStyle.positive.opacity(0.02),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("下载", point.down)
                    )
                    .foregroundStyle(VisualStyle.positive)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("上传", point.up)
                    )
                    .foregroundStyle(VisualStyle.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel {
                        if let rate = value.as(Double.self) {
                            Text(axisRateLabel(rate))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .padding(.horizontal, VisualStyle.spacing8)
            .padding(.vertical, VisualStyle.spacing8)
        }
    }

    private var displayPoints: [TrafficGraphPoint] {
        snapshot.points.map {
            TrafficGraphPoint(
                id: $0.timestamp.timeIntervalSinceReferenceDate,
                date: $0.timestamp,
                up: Double($0.up),
                down: Double($0.down)
            )
        }
    }

    private func metricTile(
        title: String,
        value: String,
        systemImage: String,
        tone: AppTone
    ) -> some View {
        HStack(spacing: VisualStyle.spacing8) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tone.color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .help(value)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VisualStyle.spacing12)
        .frame(maxWidth: .infinity, minHeight: Self.metricHeight, maxHeight: Self.metricHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VisualStyle.radiusMedium, style: .continuous)
                .fill(tone.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VisualStyle.radiusMedium, style: .continuous)
                .strokeBorder(tone.color.opacity(0.14), lineWidth: 1)
        )
    }

    private func axisRateLabel(_ rate: Double) -> String {
        let clamped = max(0, rate)
        if clamped < 1_024 {
            return "\(Int(clamped)) B"
        }
        return ByteRateFormatter.formatCompactRate(UInt64(clamped))
            .replacingOccurrences(of: "/s", with: "")
    }
}

private struct TrafficGraphPoint: Identifiable {
    let id: TimeInterval
    let date: Date
    let up: Double
    let down: Double
}

private struct TrafficGraphGrid: View {
    var body: some View {
        Canvas { context, size in
            let rows = 3
            let columns = 6
            var path = Path()
            for row in 0...rows {
                let y = size.height * CGFloat(row) / CGFloat(rows)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            for column in 0...columns {
                let x = size.width * CGFloat(column) / CGFloat(columns)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(
                path,
                with: .color(Color.secondary.opacity(0.18)),
                style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
            )
        }
    }
}
