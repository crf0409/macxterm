import AppKit
import MacXTermCore
import SwiftUI
import UniformTypeIdentifiers

struct ByPyDriveView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var drive: ByPyDriveModel
    @State private var dropTarget = false
    @State private var pathInput = "/"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.icloud").font(.system(size: 26)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("百度网盘 · 大文件传输").font(.title2).fontWeight(.semibold)
                    Text("拖拽上传、直接下载、一键复制文件名").foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismissWindow(id: "bypy") }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack {
                Picker("执行位置", selection: $drive.target) {
                    Text("Mac 本机").tag("local")
                    ForEach(drive.hosts) { host in Text(host.name.isEmpty ? host.hostname : host.name).tag(host.id.uuidString) }
                }.frame(width: 240).disabled(drive.busy).onChange(of: drive.target) { _, _ in drive.changeTarget() }
                Text(drive.target == "local" ? "本机 ↔ 百度网盘" : "SSH 服务器 ↔ 百度网盘").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if drive.busy { ProgressView().controlSize(.small) }
                Text(drive.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("授权设置") { drive.showAuthorization() }.disabled(drive.busy)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if drive.needsAuthorization { authorization }
            if !drive.error.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(drive.error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("关闭提示") { drive.error = "" }.buttonStyle(.borderless)
                }.padding(12).background(.orange.opacity(0.08)).padding(.horizontal, 20).padding(.bottom, 10)
            }
            HStack {
                Button { drive.refresh(path: RemotePath.parent(drive.path)) } label: { Image(systemName: "arrow.up") }.help("上级网盘目录")
                Text("/apps/bypy").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                TextField("网盘路径", text: $pathInput).font(.system(.body, design: .monospaced)).onSubmit { drive.refresh(path: pathInput) }
                Button { drive.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }.disabled(drive.busy).padding(.horizontal, 20).padding(.bottom, 12)
            dropZone
            HStack {
                if drive.target != "local" {
                    TextField("服务器要上传的文件或文件夹路径", text: $drive.serverPath)
                        .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity)
                }
                Button { drive.chooseUpload() } label: { Label("上传", systemImage: "arrow.up.doc") }.disabled(!drive.authorized || drive.busy)
                Button { drive.download() } label: { Label("下载所选", systemImage: "arrow.down.doc") }
                    .disabled(drive.selectedEntry == nil || !drive.authorized || drive.busy)
                Spacer()
                Button("复制文件名") { drive.copyName() }.disabled(drive.selectedEntry == nil)
                Menu {
                    Button("复制文件名") { drive.copyName() }
                    Button("复制网盘相对路径") { drive.copyPath() }
                    Button("复制 bypy download 命令") { drive.copyCommand() }
                } label: { Label("复制命令", systemImage: "doc.on.doc") }.disabled(drive.selectedEntry == nil)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if drive.target != "local" {
                HStack {
                    Text("服务器下载目录").font(.caption).foregroundStyle(.secondary)
                    TextField("例如 ~/Downloads", text: $drive.serverDownloadDirectory).font(.system(.caption, design: .monospaced))
                }.padding(.horizontal, 20).padding(.bottom, 10)
            }
            fileTable
            if !drive.jobs.isEmpty { transfers }
            Divider()
            HStack {
                Text("访问范围 /apps/bypy · 大文件分块传输 · 本机与各服务器分别授权").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("bypy 开源项目", destination: URL(string: "https://github.com/houtianze/bypy")!).font(.caption)
            }.padding(14)
        }.frame(minWidth: 950, idealWidth: 1040, minHeight: 700, idealHeight: 760)
            .task { if !drive.busy { drive.refresh() } }
            .onChange(of: drive.path) { _, value in pathInput = value }
    }
    private var fileTable: some View {
        Table(drive.entries, selection: $drive.selection) {
            TableColumn("文件名") { entry in
                HStack {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                }.contentShape(Rectangle()).onTapGesture(count: 2) { if entry.isDirectory { drive.refresh(path: entry.path) } }
            }
            TableColumn("大小") { entry in
                Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
            }.width(100)
            TableColumn("修改时间") { entry in
                Text(Date(timeIntervalSince1970: entry.modified), format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
            }.width(150)
        }.contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first {
                Button("复制文件名") { drive.selection = id; drive.copyName() }
                Button("复制 bypy download 命令") { drive.selection = id; drive.copyCommand() }
                Button("下载") { drive.selection = id; drive.download() }.disabled(!drive.authorized || drive.busy)
            }
        }.overlay {
            if drive.entries.isEmpty && !drive.controlling {
                ContentUnavailableView(drive.needsAuthorization ? "连接百度网盘" : "这个目录还没有文件", systemImage: "cloud",
                    description: Text(drive.needsAuthorization ? "完成授权后自动列出网盘文件。" : "拖入文件上传，或输入其他网盘目录。"))
            }
        }
    }
    private var authorization: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("授权 \(drive.targetName)").font(.headline)
                Spacer()
                Button("打开百度授权页面") { drive.openAuthorization() }
                if drive.target == "local" { Button("导入已有 bypy.json") { drive.importAuthorization() }.disabled(drive.busy) }
            }
            HStack {
                SecureField("粘贴百度页面给出的授权码", text: $drive.authorizationCode)
                Button("完成授权") { drive.authorize() }.disabled(drive.busy || drive.authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
            }
            Text("使用 bypy 的百度 OAuth 授权流程兑换授权码。本机令牌保存到系统钥匙串；服务器令牌保存在所选服务器的私有目录。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.blue.opacity(0.06), in: .rect(cornerRadius: 10)).padding(.horizontal, 20).padding(.bottom, 12)
    }
    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.doc.on.clipboard").font(.system(size: 28)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(dropTarget ? "松开即可上传到当前网盘目录" : "把大文件或文件夹拖到这里").font(.headline)
                Text(drive.target == "local" ? "本机文件直接上传到 /apps/bypy\(drive.path == "/" ? "" : drive.path)" : "从服务器文件侧栏拖入，或填写服务器路径后点击上传")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(18).frame(maxWidth: .infinity).background(dropTarget ? Color.accentColor.opacity(0.14) : Color.accentColor.opacity(0.05), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
            .padding(.horizontal, 20)
            .onDrop(of: [UTType.fileURL.identifier, RemoteFileDrag.type], isTargeted: $dropTarget) { providers in
                guard drive.authorized, !drive.busy else { return false }
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(RemoteFileDrag.type) {
                        _ = provider.loadDataRepresentation(forTypeIdentifier: RemoteFileDrag.type) { data, _ in
                            guard let data, let item = try? JSONDecoder().decode(RemoteFileDrag.self, from: data) else { return }
                            Task { @MainActor in drive.uploadRemote(item) }
                        }
                    } else {
                        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                            Task { @MainActor in drive.uploadLocal([url]) }
                        }
                    }
                }
                return true
            }
    }
    private var transfers: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text("网盘传输任务").font(.headline).padding(.horizontal, 20).padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(drive.jobs.reversed()) { job in
                        HStack(spacing: 12) {
                            Image(systemName: job.task.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.task.name).lineLimit(1)
                                Text(job.task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if job.task.state == .running {
                                VStack(alignment: .trailing, spacing: 4) {
                                    ProgressView(value: job.task.fraction).frame(width: 140)
                                    Text("\(ByteCountFormatter.string(fromByteCount: job.task.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: job.task.totalBytes, countStyle: .file))").font(.caption2)
                                }
                                Button("取消") { drive.cancel(job.id) }
                            } else if job.task.state == .queued { Button("取消") { drive.cancel(job.id) } }
                            else if job.task.state == .failed || job.task.state == .cancelled {
                                Button("重试") { drive.retry(job.id) }.disabled(drive.busy)
                                Menu("更多") { Button("替换同名项目并重试") { drive.retry(job.id, replace: true) } }.disabled(drive.busy)
                            } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }.frame(maxHeight: 140)
        }
    }
}
