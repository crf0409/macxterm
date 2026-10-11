import MacXTermCore
import SwiftUI

/// Fixed slots keep neighbouring metrics still as values and units change.
struct ServerStatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let tab: TerminalSession
    private var monitor: ServerMonitorState { tab.monitor }
    private var metrics: ServerMetrics? { monitor.metrics }
    private var disk: DiskUsage? {
        metrics?.sample.disks.first(where: { $0.mount == "/" }) ?? metrics?.sample.disks.first
    }
    private var network: NetworkRate? {
        metrics?.interfaces.first(where: { $0.name == metrics?.sample.defaultInterface }) ?? metrics?.interfaces.first
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(indicatorColor).frame(width: 5, height: 5)
                Text(monitor.paused && tab.state == .connected ? "已暂停" : tab.state.rawValue)
            }
            .frame(width: 56, alignment: .leading)
            .foregroundStyle(.secondary)
            .help(monitor.error.isEmpty ? tab.host.endpoint : "显示上次采样：" + monitor.error)

            if tab.state == .connected {
                Button {
                    model.monitoringHost = tab.host
                } label: {
                    HStack(spacing: 0) {
                        metric("CPU", value: metrics?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—", width: 92)
                            .help(metrics.map { "\($0.sample.cores) 个逻辑核心 · \($0.sample.cpuModel)" } ?? "正在读取 CPU")
                        boundary
                        metric(
                            "内存", value: metrics.map { String(format: "%.0f%%", $0.sample.memoryPercent) } ?? "—",
                            width: 84
                        )
                        .help(
                            metrics.map { "\(bytes($0.sample.memoryUsed)) / \(bytes($0.sample.memoryTotal))" }
                                ?? "正在读取内存")
                        boundary
                        metric("磁盘", value: disk.map { String(format: "%.0f%%", $0.usedPercent) } ?? "—", width: 84)
                            .foregroundStyle((disk?.usedPercent ?? 0) >= 90 ? Color.orange : Color.secondary)
                            .help(
                                disk.map { "\($0.mount) · 可用 \(bytes($0.available)) / \(bytes($0.total))" } ?? "暂无磁盘信息")
                        boundary
                        rate(network?.received, symbol: "arrow.down", label: "接收")
                        boundary
                        rate(network?.sent, symbol: "arrow.up", label: "发送")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("点击查看服务器状态详情")
                Spacer(minLength: 0)
                Button {
                    if monitor.error.isEmpty { model.monitoringHost = tab.host } else { monitor.retry() }
                } label: {
                    Image(systemName: monitor.error.isEmpty ? "chart.xyaxis.line" : "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(monitor.error.isEmpty ? "服务器状态详情" : "重新读取服务器状态：" + monitor.error)
            } else {
                Text(tab.host.endpoint).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
        .transaction { $0.animation = nil }
        .task(id: "\(tab.id)-\(tab.state.rawValue)-\(scenePhase)") {
            if tab.state == .connected, scenePhase == .active, let service = tab.service {
                await monitor.observe(using: service)
            }
        }
    }

    private var indicatorColor: Color {
        if tab.state != .connected || monitor.paused { return .secondary }
        return monitor.error.isEmpty ? .green : .orange
    }
    private var boundary: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 12)
    }
    private func metric(_ title: LocalizedStringKey, value: String, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(title).fixedSize()
            Spacer(minLength: 0)
            Text(value).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(width: width)
        .accessibilityElement(children: .combine)
    }
    private func rate(_ value: Double?, symbol: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 10)
            Spacer(minLength: 0)
            Text(value.map { bytes($0) + "/s" } ?? "—").lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 8)
        .frame(width: 110)
        .help("\(network?.name ?? "网卡") · \(label)；点击查看全部网卡")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value.map { bytes($0) + "/s" } ?? "暂无数据")")
    }
    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(
            fromByteCount: value.isFinite ? Int64(min(9e18, max(0, value))) : 0, countStyle: .binary)
    }
}
