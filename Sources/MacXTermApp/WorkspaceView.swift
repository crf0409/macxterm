import AppKit
import MacXTermCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var editingHost: HostProfile?
    @State private var showHostSheet = false
    @State private var selectedHost: UUID?
    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar.navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if model.layout.tabCount > 0 {
                    SessionWorkspaceView()
                } else {
                    welcome.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.showTransfers {
                    Divider()
                    TransferPanel().frame(minHeight: 170, idealHeight: 220, maxHeight: 280)
                }
                if let tab = model.active { ServerStatusBar(tab: tab) } else { statusBar }
            }
            .frame(minWidth: 620)
            .navigationTitle(model.activeHost?.name ?? "MacXTerm")
            .navigationSubtitle(model.activeDesktop?.displayEndpoint ?? model.activeHost?.endpoint ?? "终端 · 远程桌面 · 文件 · 端口转发")
        }
        .frame(minWidth: 980, minHeight: 640)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingHost = nil
                    showHostSheet = true
                } label: {
                    Label("新建连接", systemImage: "plus")
                }.help("新建连接 ⌘N")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let desktop = model.activeDesktop {
                    Button {
                        if desktop.state == .connected || desktop.state == .connecting { desktop.disconnect() }
                        else { desktop.connect() }
                    } label: {
                        Label(desktop.state == .connected ? "断开桌面" : "连接桌面",
                              systemImage: desktop.state == .connected ? "bolt.slash" : "bolt")
                    }
                }
                if let tab = model.active {
                    Button {
                        if tab.state == .connected || tab.state == .connecting {
                            tab.disconnect()
                        } else {
                            model.reconnect(tab)
                        }
                    } label: {
                        Label(
                            tab.state == .connected ? "断开" : "连接",
                            systemImage: tab.state == .connected ? "bolt.slash" : "bolt")
                    }
                }
                Button {
                    if let host = model.activeHost ?? model.configuration.hosts.first(where: { $0.id == selectedHost }) {
                        model.configureDesktop(host)
                    } else {
                        var host = HostProfile(); host.connectionType = .rdp
                        editingHost = host; showHostSheet = true
                    }
                } label: { Label("远程桌面", systemImage: "desktopcomputer") }.help("打开 XRDP / RDP 远程桌面")
                Menu {
                    Button("左右分屏") { model.splitWorkspace(.horizontal) }
                    Button("上下分屏") { model.splitWorkspace(.vertical) }
                    if model.layout.panes.count == 2 {
                        Divider()
                        Button("合并分屏") { model.layout.merge() }
                    }
                } label: { Label("分屏", systemImage: "rectangle.split.2x1") }
                    .disabled(model.layout.tabCount < 2)
                    .help("拖动标签到工作区边缘也可分屏")
                Button {
                    model.showTunnels = true
                } label: {
                    Label("端口转发", systemImage: "arrow.triangle.branch")
                }
                Button {
                    model.showPublicKeys = true
                } label: {
                    Label("本机 SSH 公钥", systemImage: "key.horizontal")
                }.help("查看并复制本机 SSH 公钥 ⌘⇧K")
                Button {
                    model.showTransfers.toggle()
                } label: {
                    Label("传输与编辑", systemImage: "arrow.up.arrow.down")
                }.tint(model.showTransfers ? .accentColor : nil)
            }
        }
        .sheet(isPresented: $showHostSheet) { HostEditor(host: editingHost ?? HostProfile()) }
        .sheet(isPresented: $model.showTunnels) { TunnelManagerView() }
        .sheet(isPresented: $model.showPublicKeys) { LocalPublicKeysView() }
        .sheet(item: $model.editingDesktopHost) { host in RemoteDesktopEditor(host: host) }
        .sheet(item: $model.monitoringHost) { host in
            if let tab = model.active?.host.id == host.id
                ? model.active : model.sessions.first(where: { $0.host.id == host.id && $0.state == .connected })
            {
                ServerMonitorView(tab: tab)
            } else {
                VStack {
                    ContentUnavailableView("请先连接主机", systemImage: "network", description: Text("连接后即可在底栏和详情中查看服务器性能。"))
                    Button("完成") { model.monitoringHost = nil }.keyboardShortcut(.cancelAction).padding(.bottom)
                }.frame(width: 520, height: 300)
            }
        }
        .alert(
            "操作未完成",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newHost)) { _ in
            editingHost = nil
            showHostSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDesktopHost)) { _ in
            var host = HostProfile(); host.connectionType = .rdp
            editingHost = host; showHostSheet = true
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("侧栏", selection: Binding(get: { model.sidebarMode }, set: { model.sidebarMode = $0 })) {
                Label("主机", systemImage: "server.rack").tag("hosts")
                Label("文件", systemImage: "folder").tag("files")
            }.pickerStyle(.segmented).labelsHidden().padding(12)
            if model.sidebarMode == "hosts" {
                hostList
            } else if let tab = model.active {
                FileBrowserView(tab: tab)
            } else {
                ContentUnavailableView("尚未连接", systemImage: "folder", description: Text("连接主机后浏览远程文件。"))
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("SSH · XRDP / RDP").font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("设置 ⌘,")
            }.padding(12)
        }
    }
    private var hostList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("搜索主机", text: Binding(get: { model.search }, set: { model.search = $0 })).textFieldStyle(
                    .plain)
            }.padding(8).background(.quaternary, in: .rect(cornerRadius: 8)).padding(.horizontal, 12).padding(
                .bottom, 8)
            if model.configuration.hosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("添加第一台主机").font(.headline)
                    Text("保存常用连接，在这里快速访问。").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("新建连接") {
                        editingHost = nil
                        showHostSheet = true
                    }
                }.padding(22).frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedHost) {
                    ForEach(Array(Set(model.filteredHosts.map(\.group))).sorted(), id: \.self) { group in
                        Section(group.isEmpty ? "未分组" : group) {
                            ForEach(model.filteredHosts.filter { $0.group == group }) { host in
                                HStack(spacing: 10) {
                                    Image(systemName: host.connectionType == .rdp ? "desktopcomputer" : "server.rack").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(host.name.isEmpty ? host.hostname : host.name).fontWeight(.medium)
                                        Text("\(host.username)@\(host.hostname)").font(.caption).foregroundStyle(
                                            .secondary
                                        ).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Button {
                                        model.connect(host)
                                    } label: {
                                        Image(systemName: "play.fill").font(.caption)
                                    }.buttonStyle(.borderless).help("连接")
                                }.padding(.vertical, 4).tag(host.id).contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.connect(host) }
                                    .contextMenu {
                                        if host.connectionType == .ssh {
                                            Button("打开终端") { model.connect(host) }
                                            Button("打开远程桌面…") { model.configureDesktop(host) }
                                            Button("服务器状态") { model.monitoringHost = host }
                                        } else {
                                            Button("打开远程桌面") { model.connect(host) }
                                        }
                                        Button("编辑主机") {
                                            editingHost = host
                                            showHostSheet = true
                                        }
                                        Button("清除保存的凭据") { model.clearCredential(host) }
                                        Button("重置服务器指纹") { model.forgetHostKey(host) }
                                        Divider()
                                        Button("删除主机", role: .destructive) { model.deleteHost(host) }
                                    }
                            }
                        }
                    }
                }.listStyle(.sidebar)
            }
        }
    }
    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("连接你的下一台主机").font(.system(size: 26, weight: .medium))
            Text("终端、XRDP 远程桌面、文件与端口转发，尽在一个工作区。").foregroundStyle(.secondary)
            Button {
                editingHost = nil
                showHostSheet = true
            } label: {
                Label("新建 SSH 连接", systemImage: "plus").padding(.horizontal, 10).padding(.vertical, 4)
            }.buttonStyle(.glassProminent).padding(.top, 6)
            HStack(spacing: 24) {
                Label("密码与私钥", systemImage: "key")
                Label("拖拽传输", systemImage: "arrow.up.arrow.down")
                Label("保存即回传", systemImage: "square.and.pencil")
            }.font(.caption).foregroundStyle(.tertiary).padding(.top, 18)
        }.padding(36)
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            if let tab = model.active {
                Circle().fill(tab.state == .connected ? .green : .secondary).frame(width: 5, height: 5)
                Text(tab.state.rawValue)
                Text(tab.host.endpoint).foregroundStyle(.tertiary)
            } else {
                Text("准备就绪")
            }
            Spacer()
            let running = model.transfers.filter { $0.state == .running }.count
            if running > 0 { Text("\(running) 个传输任务") }
            if !model.edits.isEmpty { Text("\(model.edits.count) 个编辑文件") }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 26).background(
            .bar)
    }
}
extension Notification.Name {
    static let newHost = Notification.Name("MacXTerm.newHost")
    static let newDesktopHost = Notification.Name("MacXTerm.newDesktopHost")
}
