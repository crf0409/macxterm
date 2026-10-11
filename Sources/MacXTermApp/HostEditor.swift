import AppKit
import MacXTermCore
import SwiftUI

struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: HostProfile
    @State private var secret = ""
    @State private var error = ""
    @State private var originalCredentialID: String?
    @State private var connectAfterSave = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("新建 / 编辑连接").font(.title2.bold())
                    Text("保存主机，随时回来继续工作。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Form {
                Picker("连接类型", selection: $host.connectionType) {
                    Text("SSH 终端").tag(HostConnectionType.ssh)
                    Text("XRDP / RDP 桌面").tag(HostConnectionType.rdp)
                }.pickerStyle(.segmented)
                Section("主机") {
                    TextField("名称", text: $host.name, prompt: Text("例如：生产服务器"))
                    TextField("分组", text: $host.group)
                    TextField("主机地址", text: $host.hostname, prompt: Text("example.com 或 IP 地址"))
                    if host.connectionType == .ssh {
                        TextField("SSH 端口", value: $host.port, format: .number.grouping(.never))
                    }
                    TextField("用户名", text: $host.username, prompt: Text("例如：ubuntu"))
                }
                if host.connectionType == .rdp {
                    RemoteDesktopFields(configuration: $host.remoteDesktop, canTunnel: false, showOverrides: false)
                    Section("桌面认证") {
                        SecureField("桌面密码", text: $secret, prompt: Text("留空则连接时输入"))
                        Text("桌面密码仅保留在当前标签页的内存中。服务器需已启用 XRDP / RDP 服务。").font(.caption).foregroundStyle(.secondary)
                    }
                } else { Section("认证") {
                    Picker("方式", selection: $host.authentication) {
                        Text("密码").tag(AuthenticationMethod.password)
                        Text("私钥").tag(AuthenticationMethod.privateKey)
                    }.pickerStyle(.segmented)
                    if host.authentication == .privateKey {
                        LabeledContent("私钥文件") {
                            Text(host.keyDisplayName ?? "尚未选择").foregroundStyle(.secondary).lineLimit(1)
                            Button("选择…", action: chooseKey)
                        }
                        SecureField("私钥口令", text: $secret, prompt: Text("未加密私钥可留空"))
                        Text("支持 OpenSSH RSA / Ed25519 与 RSA PEM 格式。").font(.caption).foregroundStyle(.secondary)
                        Toggle("保存在系统钥匙串", isOn: $host.rememberCredential)
                    } else {
                        SecureField("密码", text: $secret, prompt: Text("留空则使用已保存的密码或连接时输入"))
                        Text("首次连接成功后，密码会自动保存在系统钥匙串。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                }
            }.formStyle(.grouped)
            if !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 10)
            }
            Divider()
            HStack {
                Toggle("保存后连接", isOn: $connectAfterSave).font(.callout)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(connectAfterSave ? "保存并连接" : "保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(
                    .defaultAction)
            }.padding(20)
        }.frame(width: 520, height: 650)
            .onChange(of: host.authentication) { _, _ in secret = "" }
            .onChange(of: host.connectionType) { _, _ in secret = ""; host.remoteDesktop.useSSHTunnel = false }
            .onAppear {
                if model.configuration.hosts.contains(where: { $0.id == host.id }) {
                    connectAfterSave = false
                    originalCredentialID = host.credentialID
                    if host.connectionType == .ssh && host.authentication == .privateKey && host.rememberCredential {
                        do { secret = try CredentialStore.read(host.credentialID) ?? "" } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
    }
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "选择私钥"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try BookmarkStore.create(url, readOnly: true)
            if host.keyBookmark != bookmark { secret = "" }
            host.keyBookmark = bookmark
            host.keyDisplayName = url.lastPathComponent
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            host.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host.name = host.hostname }
            let enteredSecret =
                secret.isEmpty && (host.authentication == .password || originalCredentialID == host.credentialID)
                ? nil : secret
            try model.saveHost(host, secret: enteredSecret)
            if connectAfterSave { model.connect(host) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
