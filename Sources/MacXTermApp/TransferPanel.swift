import MacXTermCore
import SwiftUI

struct TransferPanel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Picker("任务类型", selection: $model.taskSection) {
                    Text("传输 \(model.transfers.count)").tag("transfers")
                    Text("远程编辑 \(model.edits.count)").tag("edits")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Spacer()
                Button {
                    model.showTransfers = false
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).help("收起任务区域")
            }.padding(.horizontal, 14).padding(.vertical, 9).background(.bar)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.taskSection == "transfers" {
                        if model.transfers.isEmpty {
                            Text("传输任务会显示在这里").font(.callout).foregroundStyle(.tertiary).padding(24)
                        }
                        ForEach(model.transfers.reversed()) { job in
                            HStack(spacing: 12) {
                                Image(systemName: job.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.name).font(.callout)
                                    Text(job.detail).font(.caption).foregroundStyle(
                                        job.state == .failed ? Color.orange : Color.secondary
                                    ).lineLimit(2).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if job.state == .running {
                                    VStack(spacing: 4) {
                                        ProgressView(value: job.fraction).frame(width: 110)
                                        Text(
                                            ByteCountFormatter.string(
                                                fromByteCount: job.completedBytes, countStyle: .file)
                                        ).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Button("取消") { model.cancelTransfer(job.id) }
                                } else if job.state == .failed || job.state == .cancelled || job.state == .paused {
                                    Button(job.state == .paused ? "恢复" : "重试") { model.retryTransfer(job.id) }
                                } else if job.state == .queued {
                                    Text("排队中").font(.caption).foregroundStyle(.secondary)
                                    Button("取消") { model.cancelTransfer(job.id) }
                                } else {
                                    Image(systemName: job.state == .completed ? "checkmark.circle.fill" : "clock")
                                        .foregroundStyle(job.state == .completed ? Color.green : Color.secondary)
                                }
                            }.padding(.horizontal, 16).padding(.vertical, 9)
                                .contextMenu {
                                    if job.state != .completed {
                                        Button("重新授权本地文件或文件夹") { model.reauthorizeTransfer(job.id) }.disabled(
                                            job.state == .running || job.state == .queued)
                                    }
                                    Button("移除任务记录") { model.removeTransfer(job.id) }.disabled(
                                        job.state == .running || job.state == .queued)
                                }
                            Divider().padding(.leading, 44)
                        }
                    } else {
                        if model.edits.isEmpty {
                            Text("双击远程文本文件，开始在外部编辑器中编辑").font(.callout).foregroundStyle(.tertiary).padding(24)
                        }
                        ForEach(model.edits) { record in
                            HStack(spacing: 12) {
                                Image(
                                    systemName: record.state == .conflict
                                        ? "exclamationmark.triangle" : "square.and.pencil"
                                ).foregroundStyle(record.state == .conflict ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.remotePath).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(record.detail).font(.caption).foregroundStyle(
                                        record.state == .conflict || record.state == .failed
                                            ? Color.orange : Color.secondary
                                    ).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if record.state == .running { ProgressView().controlSize(.small) }
                                if record.state == .paused || record.state == .failed {
                                    Button("恢复") { model.editAction(record, action: "resume") }
                                }
                                Menu {
                                    Button("在 Finder 中查看本地副本") { model.editAction(record, action: "reveal") }
                                    if record.state == .conflict {
                                        Button("用本地修改覆盖远端") { model.editAction(record, action: "overwrite") }
                                        Button("备份本地并重新下载") { model.editAction(record, action: "redownload") }
                                    }
                                    Divider()
                                    Button("结束编辑并保留本地副本") { model.editAction(record, action: "stop") }.disabled(
                                        record.state == .running)
                                } label: {
                                    Text(record.state == .conflict ? "处理冲突" : "更多")
                                }
                            }.padding(.horizontal, 16).padding(.vertical, 9)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }
}
