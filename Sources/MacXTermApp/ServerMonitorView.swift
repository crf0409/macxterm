import Charts
import MacXTermCore
import SwiftUI

struct ServerMonitorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let tab: TerminalSession
    private var host: HostProfile { tab.host }
    private var monitor: ServerMonitorState { tab.monitor }
    private var metrics: ServerMetrics? { monitor.metrics }
    private var history: [ServerMetrics] { monitor.history }
    private var failure: String { monitor.error }
    private var paused: Bool { monitor.paused }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.50percent").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("服务器状态").font(.title2.bold())
                    Text(host.name + " · " + host.hostname).foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button(paused ? "继续刷新" : "暂停") { monitor.paused.toggle() }.disabled(!failure.isEmpty)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22).background(.bar)
            if let metrics {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Label(metrics.sample.kernel, systemImage: "server.rack")
                            Spacer()
                            Text("已运行 " + uptime(metrics.sample.uptime))
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 14) {
                            metricCard(
                                title: "CPU", symbol: "cpu",
                                value: metrics.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "采样中",
                                detail: "\(metrics.sample.cores) 个逻辑核心", fraction: (metrics.cpuPercent ?? 0) / 100,
                                color: .blue)
                            metricCard(
                                title: "内存", symbol: "memorychip",
                                value: String(format: "%.1f%%", metrics.sample.memoryPercent),
                                detail: "\(bytes(metrics.sample.memoryUsed)) / \(bytes(metrics.sample.memoryTotal))",
                                fraction: metrics.sample.memoryPercent / 100, color: .teal)
                            metricCard(
                                title: "交换空间", symbol: "arrow.left.arrow.right",
                                value: metrics.sample.swapTotal > 0
                                    ? bytes(max(0, metrics.sample.swapTotal - metrics.sample.swapFree)) : "未启用",
                                detail: metrics.sample.swapTotal > 0
                                    ? "共 " + bytes(metrics.sample.swapTotal) : "服务器未配置 Swap",
                                fraction: metrics.sample.swapTotal > 0
                                    ? max(0, 1 - metrics.sample.swapFree / metrics.sample.swapTotal) : 0, color: .purple
                            )
                        }
                        if !metrics.sample.cpuModel.isEmpty {
                            Text(metrics.sample.cpuModel).font(.caption).foregroundStyle(.secondary).textSelection(
                                .enabled)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("最近 5 分钟").font(.headline)
                                Spacer()
                                Label("CPU", systemImage: "circle.fill").foregroundStyle(.blue)
                                Label("内存", systemImage: "circle.fill").foregroundStyle(.teal)
                            }.font(.caption)
                            Chart {
                                ForEach(history) { point in
                                    if let cpu = point.cpuPercent {
                                        LineMark(
                                            x: .value("时间", point.sample.date), y: .value("使用率", cpu),
                                            series: .value("指标", "CPU-\(point.segment)")
                                        ).foregroundStyle(.blue)
                                    }
                                    LineMark(
                                        x: .value("时间", point.sample.date),
                                        y: .value("使用率", point.sample.memoryPercent),
                                        series: .value("指标", "内存-\(point.segment)")
                                    ).foregroundStyle(.teal)
                                }
                            }.chartYScale(domain: 0...100).chartYAxis {
                                AxisMarks(values: [0, 50, 100]) { value in
                                    AxisGridLine()
                                    AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
                                }
                            }.frame(height: 115)
                            HStack {
                                Text("系统负载（1 / 5 / 15 分钟）")
                                Spacer()
                                Text(metrics.sample.load.map { String(format: "%.2f", $0) }.joined(separator: "  /  "))
                                    .monospacedDigit()
                            }.font(.callout)
                        }.padding(16).background(.background, in: .rect(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 12) {
                            Label("磁盘空间", systemImage: "internaldrive").font(.headline)
                            if metrics.sample.disks.isEmpty { Text("未能读取磁盘信息").foregroundStyle(.secondary) }
                            ForEach(metrics.sample.disks) { disk in
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(disk.mount).font(.system(.callout, design: .monospaced)).textSelection(
                                            .enabled)
                                        Text(disk.device).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    ProgressView(value: min(1, max(0, disk.usedPercent / 100))).tint(
                                        disk.usedPercent >= 90 ? .orange : .accentColor
                                    ).frame(width: 120)
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(
                                            String(
                                                format: "%.0f%% · %@ / %@", disk.usedPercent, bytes(disk.used),
                                                bytes(disk.total)))
                                        Text("可用 " + bytes(disk.available)).foregroundStyle(.secondary)
                                    }.font(.caption).monospacedDigit().frame(width: 200, alignment: .trailing)
                                }
                            }
                        }.padding(16).background(.background, in: .rect(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 12) {
                            Label("网络速率", systemImage: "network").font(.headline)
                            ForEach(metrics.interfaces) { item in
                                HStack {
                                    Text(item.name).font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    Label(item.received.map { bytes($0) + "/s" } ?? "采样中", systemImage: "arrow.down")
                                        .frame(width: 160, alignment: .trailing)
                                    Label(item.sent.map { bytes($0) + "/s" } ?? "采样中", systemImage: "arrow.up").frame(
                                        width: 160, alignment: .trailing)
                                }.font(.callout).monospacedDigit()
                            }
                            Text("按网卡分别显示，不合计虚拟网卡以避免重复计数。").font(.caption).foregroundStyle(.secondary)
                        }.padding(16).background(.background, in: .rect(cornerRadius: 12))
                    }.padding(22)
                }
            } else if failure.isEmpty {
                Spacer()
                ProgressView("正在读取服务器状态…")
                Spacer()
            } else {
                Spacer()
                ContentUnavailableView(
                    "状态暂不可用", systemImage: "gauge.with.dots.needle.0percent", description: Text("服务器状态面板支持 Linux 主机。"))
                Spacer()
            }
            Divider()
            HStack {
                Circle().fill(!failure.isEmpty ? Color.orange : paused ? Color.secondary : Color.green).frame(
                    width: 6, height: 6)
                Text(!failure.isEmpty ? failure : paused ? "已暂停，显示最近一次采样" : "CPU / 内存 / 网络每秒刷新 · 磁盘每 30 秒 · 与底栏共享采样")
                    .lineLimit(3).textSelection(.enabled)
                Spacer()
                if !failure.isEmpty { Button("重试") { monitor.retry() } }
                if let date = metrics?.sample.date {
                    Text(date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                }
            }.font(.caption).padding(14).background(.bar)
        }.frame(width: 820, height: 760)
            .task(id: "\(tab.id)-\(scenePhase)") {
                if scenePhase == .active, let service = tab.service { await monitor.observe(using: service) }
            }
    }
    private func metricCard(
        title: String, symbol: String, value: String, detail: String, fraction: Double, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
            ProgressView(value: fraction).tint(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(
            .background, in: .rect(cornerRadius: 12))
    }
    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(
            fromByteCount: value.isFinite ? Int64(min(9e18, max(0, value))) : 0, countStyle: .binary)
    }
    private func uptime(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return "\(minutes/1440) 天 \(minutes/60%24) 小时 \(minutes%60) 分钟"
    }
}
