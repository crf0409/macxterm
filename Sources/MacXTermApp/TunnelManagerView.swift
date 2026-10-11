import MacXTermCore
import SwiftUI

struct TunnelManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: TunnelRule?
    @State private var showEditor = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("端口转发").font(.title2.bold())
                    Text("隧道独立于终端标签运行，退出应用后停止。").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button {
                    editing = nil
                    showEditor = true
                } label: {
                    Label("新建规则", systemImage: "plus")
                }.disabled(model.configuration.hosts.isEmpty)
            }.padding(24)
            if model.configuration.tunnels.isEmpty {
                ContentUnavailableView(
                    "尚无转发规则", systemImage: "arrow.triangle.branch",
                    description: Text(model.configuration.hosts.isEmpty ? "请先添加 SSH 主机。" : "将远端服务带到本机，或通过服务器访问本地服务。")
                ).frame(maxHeight: .infinity)
            } else {
                List(model.configuration.tunnels) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: rule.kind == .socks5 ? "network" : "arrow.triangle.branch")
                                .foregroundStyle(.tint)
                            Text(rule.name.isEmpty ? rule.kind.title : rule.name).fontWeight(.semibold)
                            Text(rule.kind.title).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(model.tunnelStates[rule.id] ?? "未启动").font(.caption).foregroundStyle(
                                model.tunnelRunning(rule.id) ? Color.green : Color.secondary)
                            Button(model.tunnelRunning(rule.id) ? "停止" : "启动") {
                                if model.tunnelRunning(rule.id) {
                                    model.stopTunnel(rule.id)
                                } else {
                                    model.startTunnel(rule)
                                }
                            }
                            Menu {
                                Button("编辑") {
                                    editing = rule
                                    showEditor = true
                                }.disabled(model.tunnelRunning(rule.id))
                                Button("删除", role: .destructive) { model.deleteTunnel(rule) }
                            } label: {
                                Image(systemName: "ellipsis")
                            }.menuStyle(.borderlessButton).frame(width: 20)
                        }
                        Text(rule.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        if let host = model.configuration.hosts.first(where: { $0.id == rule.hostID }) {
                            Text("经由 \(host.name) · \(host.endpoint)").font(.caption).foregroundStyle(.tertiary)
                        }
                        if let error = model.tunnelErrors[rule.id] {
                            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }.padding(.vertical, 10)
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
        }.frame(width: 760, height: 520)
            .sheet(isPresented: $showEditor) {
                if let host = model.configuration.hosts.first {
                    TunnelEditor(rule: editing ?? TunnelRule(hostID: host.id))
                }
            }
    }
}
private struct TunnelEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var rule: TunnelRule
    @State private var error = ""
    var body: some View {
        VStack(spacing: 0) {
            Text("转发规则").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Form {
                TextField("名称", text: $rule.name)
                Picker("SSH 主机", selection: $rule.hostID) {
                    ForEach(model.configuration.hosts) { Text($0.name).tag($0.id) }
                }
                Picker("转发类型", selection: $rule.kind) {
                    ForEach(TunnelKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Section(rule.kind == .remote ? "服务器监听" : "本机监听") {
                    TextField("监听地址", text: $rule.bindHost).disabled(rule.kind == .socks5)
                    TextField("监听端口", value: $rule.bindPort, format: .number.grouping(.never))
                }
                if rule.kind != .socks5 {
                    Section(rule.kind == .remote ? "从 Mac 访问的目标" : "从 SSH 服务器访问的目标") {
                        TextField("目标主机", text: $rule.targetHost)
                        TextField("目标端口", value: $rule.targetPort, format: .number.grouping(.never))
                    }
                } else {
                    Text("SOCKS5 仅供本机使用，支持 TCP CONNECT 与远端域名解析。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption).padding(12) }
            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    do {
                        try model.saveTunnel(rule)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(18)
        }.frame(width: 530, height: 590)
            .onChange(of: rule.kind) { _, kind in if kind == .socks5 { rule.bindHost = "127.0.0.1" } }
    }
}
