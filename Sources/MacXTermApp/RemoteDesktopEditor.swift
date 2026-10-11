import MacXTermCore
import SwiftUI

struct RemoteDesktopFields: View {
    @Binding var configuration: RemoteDesktopConfiguration
    var canTunnel: Bool
    var showOverrides: Bool
    var body: some View {
        Section("远程桌面") {
            if canTunnel {
                Toggle("通过 SSH 安全隧道连接", isOn: $configuration.useSSHTunnel)
            }
            if showOverrides {
                TextField(configuration.useSSHTunnel ? "服务器内的桌面地址" : "桌面地址", text: $configuration.hostname,
                    prompt: Text(configuration.useSSHTunnel ? "留空使用 127.0.0.1" : "留空使用 SSH 主机地址"))
                TextField("桌面用户名", text: $configuration.username, prompt: Text("留空使用 SSH 用户名"))
            }
            TextField("RDP 端口", value: $configuration.port, format: .number.grouping(.never))
            if canTunnel && configuration.useSSHTunnel {
                TextField("本机隧道端口", value: $configuration.localPort, format: .number.grouping(.never))
                Text("隧道仅监听本机 127.0.0.1，关闭桌面标签时自动停止。使用 SSH 主机中已配置的密码或私钥。").font(.caption).foregroundStyle(.secondary)
            }
            TextField("域（可选）", text: $configuration.domain)
            Picker("分辨率", selection: Binding(
                get: { "\(configuration.width)x\(configuration.height)" },
                set: { value in
                    let parts = value.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { configuration.width = parts[0]; configuration.height = parts[1] }
                })) {
                    ForEach(["1024x768", "1280x720", "1440x900", "1920x1080", "2560x1440", "3840x2160"], id: \.self) {
                        Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0)
                    }
                }
            Picker("安全协议", selection: $configuration.security) {
                ForEach(RDPSecurity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("XRDP 默认选择 TLS；需要 NLA 的 RDP 服务器选择自动协商。画面随窗口缩放，分辨率在重新连接后生效。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RemoteDesktopEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: HostProfile
    @State private var password = ""
    @State private var error = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("打开远程桌面").font(.title2.bold())
                    Text(host.name.isEmpty ? host.hostname : host.name).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Form {
                RemoteDesktopFields(configuration: $host.remoteDesktop, canTunnel: host.connectionType == .ssh, showOverrides: true)
                Section("桌面认证") {
                    SecureField("桌面密码", text: $password, prompt: Text("留空则连接时输入"))
                    Text("桌面密码与 SSH 私钥口令分别输入；桌面密码仅保留在当前标签页的内存中。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if !error.isEmpty { Text(error).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12) }
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并打开桌面") {
                    do {
                        host.remoteDesktop.hostname = host.remoteDesktop.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                        host.remoteDesktop.username = host.remoteDesktop.username.trimmingCharacters(in: .whitespacesAndNewlines)
                        try host.remoteDesktop.validate(for: host)
                        try model.saveHost(host, secret: nil)
                        let hostToConnect = host
                        let enteredPassword = password.isEmpty ? nil : password
                        dismiss()
                        Task { @MainActor in model.connectDesktop(hostToConnect, password: enteredPassword) }
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 550, height: 660)
    }
}
