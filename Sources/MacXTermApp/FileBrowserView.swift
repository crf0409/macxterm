import AppKit
import MacXTermCore
import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Environment(AppModel.self) private var model
    @Bindable var tab: TerminalSession
    @State private var pathInput = ""
    @State private var dropTarget = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.loadDirectory(tab, path: RemotePath.parent(tab.directory))
                } label: {
                    Image(systemName: "arrow.up")
                }.help("上级目录")
                TextField("远程路径", text: $pathInput).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.loadDirectory(tab, path: pathInput) }
                Button {
                    model.loadDirectory(tab)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("刷新")
            }.buttonStyle(.borderless).padding(10).background(.quaternary.opacity(0.45))
            HStack(spacing: 14) {
                Button {
                    model.chooseUpload(tab: tab)
                } label: {
                    Label("上传", systemImage: "arrow.up.doc")
                }
                Button {
                    if let entry = tab.selectedEntry { model.download(entry, host: tab.host) }
                } label: {
                    Label("下载", systemImage: "arrow.down.doc")
                }.disabled(tab.selectedEntry == nil)
                Spacer()
                Toggle(isOn: $tab.showHidden) { Image(systemName: tab.showHidden ? "eye" : "eye.slash") }.toggleStyle(
                    .button
                ).help("显示隐藏文件")
            }.font(.caption).buttonStyle(.borderless).padding(10)
            if tab.loadingFiles { ProgressView().controlSize(.small).padding(10) }
            if !tab.fileError.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("无法浏览文件", systemImage: "exclamationmark.triangle")
                    Text(tab.fileError).font(.caption).textSelection(.enabled)
                    Button("重试") { model.loadDirectory(tab) }
                }.padding(12).foregroundStyle(.secondary)
            }
            List(selection: $tab.selectedFile) {
                ForEach(tab.entries.filter { tab.showHidden || !$0.name.hasPrefix(".") }) { entry in
                    HStack(spacing: 9) {
                        Image(
                            systemName: entry.attributes.isSymbolicLink
                                ? "link" : entry.attributes.isDirectory ? "folder.fill" : "doc.text"
                        ).foregroundStyle(entry.attributes.isDirectory ? Color.accentColor : Color.secondary).frame(
                            width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 5) {
                                if !entry.attributes.isDirectory {
                                    Text(
                                        ByteCountFormatter.string(
                                            fromByteCount: Int64(clamping: entry.attributes.size), countStyle: .file))
                                }
                                Text(
                                    Date(timeIntervalSince1970: Double(entry.attributes.modified)),
                                    format: .dateTime.month().day().hour().minute())
                            }.font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        if model.isOpeningFile(entry, host: tab.host) {
                            ProgressView().controlSize(.mini).help("正在打开编辑器…")
                        }
                    }.padding(.vertical, 3).tag(entry.path).contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.activateFile(entry, tab: tab) }
                        .contextMenu {
                            if entry.attributes.isDirectory {
                                Button("打开目录") { model.loadDirectory(tab, path: entry.path) }
                            } else {
                                Button("用关联编辑器打开") { model.editFile(entry, host: tab.host) }
                            }
                            Button("下载") { model.download(entry, host: tab.host) }.disabled(
                                entry.attributes.isSymbolicLink)
                            Button("复制路径") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.path, forType: .string)
                            }
                        }
                }
            }.listStyle(.sidebar)
            Text(dropTarget ? "松开以上传到当前目录" : "拖入文件上传 · 双击打开关联编辑器").font(.system(size: 10)).foregroundStyle(
                dropTarget ? Color.accentColor : Color.secondary
            ).padding(10).frame(maxWidth: .infinity)
        }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).padding(4).allowsHitTesting(
                    false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            guard tab.fileService != nil else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    guard let url else { return }
                    Task { @MainActor in model.upload([url], tab: tab) }
                }
            }
            return true
        }
        .onAppear { pathInput = tab.directory }
        .onChange(of: tab.directory) { _, path in pathInput = path }
    }
}
