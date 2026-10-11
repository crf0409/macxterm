import AppKit
import MacXTermCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPublicKeys = false
    var body: some View {
        @Bindable var model = model
        Form {
            Section("终端") {
                Picker("配色", selection: $model.configuration.terminalTheme) {
                    Text("深色").tag("dark")
                    Text("浅色").tag("light")
                    Text("跟随系统").tag("system")
                }.onChange(of: model.configuration.terminalTheme) { _, _ in model.saveConfiguration() }
                Text("界面材质跟随 macOS；终端配色可独立设置。").font(.caption).foregroundStyle(.secondary)
            }
            Section("SSH 公钥") {
                Button {
                    showPublicKeys = true
                } label: {
                    Label("查看本机 SSH 公钥…", systemImage: "key.horizontal")
                }
            }
            Section("远程编辑") {
                LabeledContent("编辑器") {
                    Text(model.configuration.editorDisplayName ?? "按文件类型使用系统关联编辑器").foregroundStyle(.secondary)
                    Button("选择…") { model.chooseEditor() }
                }
                if model.configuration.editorBookmark != nil {
                    Button("恢复系统默认编辑器") {
                        model.configuration.editorBookmark = nil
                        model.configuration.editorDisplayName = nil
                        model.saveConfiguration()
                    }
                }
                LabeledContent("工作目录") {
                    Text(model.configuration.editDirectoryBookmark == nil ? "首次编辑时选择" : "已授权").foregroundStyle(
                        .secondary)
                    Button("更改…") {
                        do { try model.chooseEditFolder() } catch { model.errorMessage = error.localizedDescription }
                    }.disabled(!model.edits.isEmpty)
                }
                Text("支持不超过 20 MB 的 UTF-8 / UTF-16 文本。保存后自动回传；退出前请先保存编辑器中的修改。").font(.caption).foregroundStyle(
                    .secondary)
            }
            Section("关于") {
                LabeledContent("MacXTerm", value: "1.0.0")
                Text("SwiftTerm · libssh2 · OpenSSL").font(.caption).foregroundStyle(.secondary)
                Button("查看开源许可") {
                    if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }.formStyle(.grouped).frame(width: 540, height: 540)
            .sheet(isPresented: $showPublicKeys) { LocalPublicKeysView() }
    }
}
