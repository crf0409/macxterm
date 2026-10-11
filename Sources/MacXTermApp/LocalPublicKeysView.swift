import AppKit
import MacXTermCore
import SwiftUI

struct LocalPublicKeysView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
    private var state: LocalPublicKeysModel { model.publicKeys }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("本机 SSH 公钥").font(.title2.bold())
                    Text("查看并复制公钥，方便添加到其他服务器。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22).background(.bar)
            HStack {
                Button("选择 ~/.ssh 文件夹…") { state.chooseFolder() }
                    .disabled(!state.canSaveAuthorization)
                Button("选择 .pub 文件…") { state.chooseFiles() }
                    .disabled(!state.canSaveAuthorization)
                Spacer()
                Button {
                    state.refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!state.hasSources || state.loading)
            }.padding(.horizontal, 22).padding(.top, 18)
            HStack {
                Text(state.sourceDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle).help(state.sourceDescription)
                Spacer(minLength: 8)
                if state.hasSources { Button("清除授权") { state.clearLocations() }.font(.caption).buttonStyle(.link) }
            }.padding(.horizontal, 22).padding(.vertical, 10)
            if state.loading {
                Spacer()
                ProgressView("正在读取公钥…")
                Spacer()
            } else if let key = state.selected {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("公钥文件", selection: $state.selectedID) {
                        ForEach(state.keys) { item in
                            Text(
                                state.keys.filter { $0.filename == item.filename }.count > 1
                                    ? item.file.path : item.filename
                            )
                            .tag(Optional(item.id))
                        }
                    }.help(key.file.path)
                    HStack {
                        Text(key.algorithm).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        if !key.comment.isEmpty {
                            Text(key.comment).font(.callout).lineLimit(1).truncationMode(.middle).help(key.comment)
                        }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Text("指纹").foregroundStyle(.secondary)
                        Text(key.fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.font(.caption)
                    ScrollView {
                        Text(key.line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(minHeight: 110, maxHeight: 160).background(.background, in: .rect(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5) }
                    HStack {
                        Text("将完整的一行公钥追加到目标用户的 ~/.ssh/authorized_keys。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(key.clipboardText, forType: .string)
                            copyReset?.cancel()
                            copyReset = Task {
                                do {
                                    try await Task.sleep(for: .seconds(2))
                                    copied = false
                                } catch {}
                            }
                        } label: {
                            Label(copied ? "已复制" : "复制公钥", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent).keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                }.padding(.horizontal, 22).padding(.vertical, 8)
                Spacer(minLength: 8)
            } else {
                ContentUnavailableView(
                    state.hasSources ? "未发现可用的公钥" : "选择本机公钥", systemImage: "key.horizontal",
                    description: Text(
                        state.hasSources
                            ? "所选位置中没有可读取的 OpenSSH 公钥。可以选择其他 .pub 文件。" : "首次使用请选择 ~/.ssh 文件夹，或选取已有的 .pub 公钥文件。")
                )
                .frame(maxHeight: .infinity)
            }
            if !state.error.isEmpty || !state.issues.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if !state.error.isEmpty { Text(state.error) }
                        ForEach(Array(state.issues.enumerated()), id: \.offset) { _, issue in Text(issue) }
                    }.font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(maxHeight: 72).padding(.horizontal, 22).padding(.bottom, 10)
            }
            Divider()
            Label("只读 .pub 公钥文件 · 文件授权保存在本机", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).background(.bar)
        }.frame(width: 680, height: 540)
            .task { state.refresh() }
            .onChange(of: state.selectedID) { _, _ in
                copied = false
                copyReset?.cancel()
            }
            .onDisappear { copyReset?.cancel() }
    }
}
