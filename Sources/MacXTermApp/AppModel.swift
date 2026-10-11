import AppKit
import CoreServices
import Foundation
import MacXTermCore
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class AppModel {
    var configuration = AppConfiguration()
    var sessions = [TerminalSession]()
    var layout = WorkspaceLayout()
    var draggedSessionID: UUID?
    var desktopSessions = [RemoteDesktopSession]()
    var editingDesktopHost: HostProfile?
    var sidebarMode = "hosts"
    var search = ""
    var showTransfers = false
    var taskSection = "transfers"
    var showTunnels = false
    var showPublicKeys = false
    let publicKeys = LocalPublicKeysModel()
    var monitoringHost: HostProfile?
    var errorMessage: String?
    var transfers = [TransferTask]()
    var edits = [RemoteEditSession]()
    private var openingFiles = Set<String>()
    var tunnelStates: [UUID: String] = [:]
    var tunnelErrors: [UUID: String] = [:]
    @ObservationIgnored private var configurationStore: JSONStore<AppConfiguration>?
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var credentials: [String: String] = [:]
    @ObservationIgnored private var transferTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var transferJournal = TransferJournal()
    @ObservationIgnored private var transferStore: JSONStore<TransferJournal>?
    @ObservationIgnored private var transfersWritable = true
    @ObservationIgnored private var tunnelTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tunnelServices: [UUID: SSHSessionService] = [:]
    @ObservationIgnored private var editCoordinator: RemoteEditCoordinator?
    @ObservationIgnored private var editWorkspace: SecurityScopedResource?
    @ObservationIgnored var isShuttingDown = false
    init() {
        do {
            let store = JSONStore<AppConfiguration>(
                url: try JSONStore<AppConfiguration>.applicationURL("configuration.json"))
            configurationStore = store
            configuration = try store.load(default: AppConfiguration())
            guard configuration.version == 1 else { throw MacXError.message("配置来自更新版本的 MacXTerm，请升级后打开。") }
        } catch {
            writable = false
            errorMessage = "配置未载入，原文件已保留：\(error.localizedDescription)"
        }
        do {
            let store = JSONStore<TransferJournal>(url: try JSONStore<TransferJournal>.applicationURL("transfers.json"))
            transferStore = store
            transferJournal = try store.load(default: TransferJournal())
            try transferJournal.prepareForRecovery()
            transfers = transferJournal.records.map(\.task)
            showTransfers = !transfers.isEmpty
        } catch {
            transfersWritable = false
            errorMessage = "传输记录未载入，已保留原文件：\(error.localizedDescription)"
        }
        Task {
            if configuration.editDirectoryBookmark != nil {
                do { _ = try await ensureEditCoordinator() } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    var activeID: UUID? { sessions.first { $0.id == layout.selected }?.id }
    var activeDesktopID: UUID? { desktopSessions.first { $0.id == layout.selected }?.id }
    var active: TerminalSession? { sessions.first { $0.id == layout.selected } }
    var activeDesktop: RemoteDesktopSession? { desktopSessions.first { $0.id == activeDesktopID } }
    var activeHost: HostProfile? { activeDesktop?.host ?? active?.host }
    var filteredHosts: [HostProfile] {
        configuration.hosts.filter {
            search.isEmpty
                || "\($0.name) \($0.hostname) \($0.username) \($0.group)".localizedCaseInsensitiveContains(search)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var busy: Bool {
        sessions.contains { $0.state == .connected || $0.state == .connecting }
            || desktopSessions.contains { $0.state == .connected || $0.state == .connecting }
            || transfers.contains { $0.state == .running || $0.state == .queued } || !tunnelTasks.isEmpty
            || !edits.isEmpty
    }
    func saveConfiguration() {
        guard writable else {
            errorMessage = "配置文件无法安全写入，请先修复原配置。"
            return
        }
        do { try configurationStore?.save(configuration) } catch { errorMessage = error.localizedDescription }
    }
    func saveHost(_ host: HostProfile, secret: String?) throws {
        guard writable else { throw MacXError.message("原配置未成功载入，已禁止覆盖。") }
        try host.validate()
        let connectionChanged =
            configuration.hosts.first(where: { $0.id == host.id }).map { previous in
                previous.hostname != host.hostname || previous.port != host.port || previous.username != host.username
                    || previous.authentication != host.authentication || previous.keyBookmark != host.keyBookmark
                    || previous.connectionType != host.connectionType
            } ?? false
        if connectionChanged, let previous = configuration.hosts.first(where: { $0.id == host.id }) {
            try CredentialStore.save(nil, id: previous.credentialID)
            credentials[previous.credentialID] = nil
            credentials["desktop.\(previous.id)"] = nil
        }
        if host.connectionType == .ssh && host.authentication == .privateKey && !host.rememberCredential {
            try CredentialStore.save(nil, id: host.credentialID)
        }
        if let secret {
            if host.connectionType == .rdp { setDesktopPassword(secret, hostID: host.id) }
            else { credentials[host.credentialID] = secret }
        }
        if let i = configuration.hosts.firstIndex(where: { $0.id == host.id }) {
            configuration.hosts[i] = host
        } else {
            configuration.hosts.append(host)
        }
        saveConfiguration()
        for tab in desktopSessions where tab.host.id == host.id && tab.host != host {
            tab.disconnect(); tab.discardPassword(); tab.host = host
            tab.status = "桌面连接参数已更新，请重新连接"
        }
        if connectionChanged {
            for tab in sessions where tab.host.id == host.id {
                tab.disconnect()
                tab.host = host
                tab.status = "主机连接参数已更新，请重新连接"
            }
        }
    }
    func deleteHost(_ host: HostProfile) {
        guard !edits.contains(where: { $0.hostID == host.id }) else {
            errorMessage = "请先结束此主机的远程编辑，保留本地副本后再删除主机。"
            return
        }
        guard !transferJournal.records.contains(where: { $0.hostID == host.id }) else {
            errorMessage = "此主机仍有传输记录，请先完成或移除这些任务。"
            return
        }
        guard confirm("删除主机“\(host.name)”？", detail: "相关转发规则也会移除。已经打开的终端会关闭。", button: "删除") else { return }
        for rule in configuration.tunnels where rule.hostID == host.id { stopTunnel(rule.id) }
        for tab in sessions where tab.host.id == host.id { closeTab(tab.id) }
        for tab in desktopSessions where tab.host.id == host.id { closeDesktop(tab.id) }
        configuration.hosts.removeAll { $0.id == host.id }
        configuration.tunnels.removeAll { $0.hostID == host.id }
        do { try CredentialStore.save(nil, id: host.credentialID) } catch { errorMessage = error.localizedDescription }
        credentials[host.credentialID] = nil
        credentials["desktop.\(host.id)"] = nil
        saveConfiguration()
    }
    func forgetHostKey(_ host: HostProfile) {
        guard confirm("移除保存的服务器指纹？", detail: "请先通过可信渠道核对服务器的新指纹。下次连接会重新询问信任。", button: "移除指纹") else { return }
        configuration.knownHosts["[\(host.hostname.lowercased())]:\(host.port)"] = nil
        saveConfiguration()
    }
    func connect(_ host: HostProfile) {
        if host.connectionType == .rdp {
            let password = credentials.removeValue(forKey: "desktop.\(host.id)")
            connectDesktop(host, password: password)
            return
        }
        let tab = TerminalSession(host: host)
        sessions.append(tab)
        layout.insert(tab.id)
        sidebarMode = "files"
        reconnect(tab)
    }
    func reconnect(_ tab: TerminalSession) {
        tab.prepareForConnection()
        tab.status = "正在连接 \(tab.host.endpoint)…"
        let generation = tab.connectionGeneration
        let service = SSHSessionService()
        tab.service = service
        tab.connectionTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                _ = try await authenticated(tab.host, service: service)
                try Task.checkCancellation()
                try await service.openTerminal(columns: tab.columns, rows: tab.rows)
                try Task.checkCancellation()
                guard tab.connectionGeneration == generation else { throw CancellationError() }
                tab.state = .connected
                tab.synchronizeTerminalSize()
                tab.status = tab.host.endpoint
                tab.startWriter(service)
                loadDirectory(tab)
                var lastKeepalive = Date()
                while !Task.isCancelled {
                    let (data, eof) = try await service.readTerminal()
                    try Task.checkCancellation()
                    guard tab.connectionGeneration == generation else { throw CancellationError() }
                    if !data.isEmpty { tab.feed(data, from: generation) }
                    if eof {
                        tab.state = .disconnected
                        tab.status = "远端会话已结束，可重新连接"
                        break
                    }
                    if Date().timeIntervalSince(lastKeepalive) > 20 {
                        try await service.keepalive()
                        lastKeepalive = Date()
                    }
                    try await Task.sleep(for: .milliseconds(data.isEmpty ? 20 : 2))
                }
            } catch {
                if !Task.isCancelled && !isShuttingDown && tab.connectionGeneration == generation {
                    tab.state = .failed
                    tab.status = error.localizedDescription
                }
            }
            if tab.connectionGeneration == generation {
                tab.stopWriter()
            }
            service.cancel()
        }
    }
    func closeTab(_ id: UUID) {
        sessions.first { $0.id == id }?.disconnect()
        sessions.removeAll { $0.id == id }
        layout.close(id)
        if sessions.isEmpty && desktopSessions.isEmpty { sidebarMode = "hosts" }
    }
    func connectDesktop(_ host: HostProfile, password: String? = nil) {
        let tab = RemoteDesktopSession(host: host, authenticateSSH: { [weak self] host, connection in
            guard let self else { throw MacXError.cancelled }
            _ = try await authenticated(host, service: connection)
        })
        desktopSessions.append(tab)
        layout.insert(tab.id)
        sidebarMode = "hosts"
        tab.connect(password: password)
    }
    func configureDesktop(_ host: HostProfile) {
        var profile = host
        if profile.connectionType == .ssh && profile.remoteDesktop == RemoteDesktopConfiguration() {
            profile.remoteDesktop.useSSHTunnel = true
        }
        editingDesktopHost = profile
    }
    func closeDesktop(_ id: UUID) {
        desktopSessions.first { $0.id == id }?.disconnect()
        desktopSessions.first { $0.id == id }?.discardPassword()
        desktopSessions.removeAll { $0.id == id }
        layout.close(id)
        if sessions.isEmpty && desktopSessions.isEmpty { sidebarMode = "hosts" }
    }
    func selectSession(_ id: UUID, focusInput: Bool = false) {
        layout.select(id)
        if focusInput {
            DispatchQueue.main.async { [weak self] in
                self?.sessions.first { $0.id == id }?.focusInput()
                self?.desktopSessions.first { $0.id == id }?.focusInput?()
            }
        }
    }
    func closeSession(_ id: UUID) {
        if sessions.contains(where: { $0.id == id }) { closeTab(id) } else { closeDesktop(id) }
    }
    func splitWorkspace(_ axis: WorkspaceSplitAxis) {
        if layout.panes.count == 2 { layout.setAxis(axis); return }
        guard let pane = layout.panes.first,
              let tab = pane.tabs.last(where: { $0 != pane.selected }) else { return }
        layout.split(tab, beside: pane.id, edge: axis == .horizontal ? .trailing : .bottom)
    }
    func splitSession(_ id: UUID, edge: WorkspaceDropEdge) {
        guard let pane = layout.pane(containing: id) else { return }
        layout.split(id, beside: pane.id, edge: edge)
    }
    func setDesktopPassword(_ password: String, hostID: UUID) { credentials["desktop.\(hostID)"] = password }
    func authenticated(_ host: HostProfile, service: SSHSessionService = SSHSessionService()) async throws
        -> SSHSessionService
    {
        guard !isShuttingDown else { throw CancellationError() }
        let secret = try secretFor(host)
        var keyURL: URL?
        var keyBookmark = host.keyBookmark
        if let bookmark = host.keyBookmark, host.authentication == .privateKey {
            let (url, updated) = try BookmarkStore.resolve(bookmark)
            keyURL = url
            if let updated { keyBookmark = updated }
            if let updated, let i = configuration.hosts.firstIndex(where: { $0.id == host.id }) {
                configuration.hosts[i].keyBookmark = updated
                saveConfiguration()
            }
        }
        return try await withTaskCancellationHandler {
            let identity = try await service.handshake(host: host)
            try Task.checkCancellation()
            if let saved = configuration.knownHosts[identity.id] {
                guard saved == identity.key else {
                    throw MacXError.message("服务器指纹已变化，连接已阻止。请核对后在主机菜单中重置指纹。\n新指纹：\(identity.fingerprint)")
                }
            } else {
                guard
                    confirm(
                        "信任此服务器？", detail: "\(host.hostname):\(host.port)\n\n\(identity.fingerprint)\n\n请通过可信渠道核对指纹。",
                        button: "信任并连接")
                else { throw MacXError.cancelled }
                configuration.knownHosts[identity.id] = identity.key
                saveConfiguration()
            }
            do { try await service.authenticate(host: host, credentials: .init(secret: secret, keyURL: keyURL)) } catch
            {
                credentials[host.credentialID] = nil
                if !Task.isCancelled { try? CredentialStore.save(nil, id: host.credentialID) }
                throw error
            }
            try Task.checkCancellation()
            if host.shouldRememberCredential,
                let storedHost = configuration.hosts.first(where: { $0.id == host.id }),
                storedHost.hostname == host.hostname, storedHost.port == host.port,
                storedHost.username == host.username, storedHost.authentication == host.authentication,
                storedHost.keyBookmark == keyBookmark
            {
                do {
                    try CredentialStore.save(secret, id: host.credentialID)
                    if host.authentication == .password,
                        let index = configuration.hosts.firstIndex(where: { $0.id == host.id }),
                        !configuration.hosts[index].rememberCredential
                    {
                        configuration.hosts[index].rememberCredential = true
                        saveConfiguration()
                    }
                } catch {
                    errorMessage = "SSH 已连接，但密码或口令无法保存到系统钥匙串：" + error.localizedDescription
                }
            }
            return service
        } onCancel: {
            service.cancel()
        }
    }
    private func secretFor(_ host: HostProfile) throws -> String {
        if let secret = credentials[host.credentialID] { return secret }
        if host.shouldRememberCredential, let secret = try CredentialStore.read(host.credentialID) {
            credentials[host.credentialID] = secret
            return secret
        }
        let alert = NSAlert()
        alert.messageText = host.authentication == .password ? "输入 SSH 密码" : "输入私钥口令"
        alert.informativeText =
            host.endpoint
            + (host.authentication == .privateKey ? "\n未加密私钥可以留空。" : "\n首次连接成功后会记住密码。")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { throw MacXError.cancelled }
        let secret = field.stringValue
        credentials[host.credentialID] = secret
        return secret
    }
    func clearCredential(_ host: HostProfile) {
        credentials[host.credentialID] = nil
        credentials["desktop.\(host.id)"] = nil
        for tab in desktopSessions where tab.host.id == host.id { tab.discardPassword() }
        do { try CredentialStore.save(nil, id: host.credentialID) } catch { errorMessage = error.localizedDescription }
    }
    func loadDirectory(_ tab: TerminalSession, path: String? = nil) {
        let generation = UUID()
        tab.listingGeneration = generation
        tab.loadingFiles = true
        tab.fileError = ""
        tab.listingTask?.cancel()
        tab.listingTask = Task {
            do {
                let sftp: SFTPService
                if let existing = tab.fileService {
                    sftp = existing
                } else {
                    let connection = try await authenticated(tab.host)
                    try Task.checkCancellation()
                    tab.fileConnection = connection
                    sftp = try await connection.openSFTP()
                    tab.fileService = sftp
                }
                let canonical = try await sftp.canonicalPath(path ?? tab.directory)
                let entries = try await sftp.list(canonical)
                guard tab.listingGeneration == generation else { return }
                tab.directory = canonical
                tab.entries = entries
                tab.selectedFile = nil
                tab.loadingFiles = false
            } catch {
                guard tab.listingGeneration == generation else { return }
                tab.fileError = error.localizedDescription
                tab.loadingFiles = false
                tab.fileService = nil
                tab.fileConnection?.cancel()
                tab.fileConnection = nil
            }
        }
    }
    func activateFile(_ entry: RemoteEntry, tab: TerminalSession) {
        if entry.attributes.isDirectory {
            loadDirectory(tab, path: entry.path)
        } else {
            editFile(entry, host: tab.host)
        }
    }
    func chooseUpload(tab: TerminalSession) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, tab: tab)
    }
    func upload(_ urls: [URL], tab: TerminalSession, policy: CollisionPolicy = .fail) {
        for url in urls {
            do {
                let path = try RemotePath.join(tab.directory, url.lastPathComponent)
                startTransfer(
                    host: tab.host, name: url.lastPathComponent, direction: .upload, localURL: url, remotePath: path,
                    policy: policy)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func download(_ entry: RemoteEntry, host: HostProfile) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "下载到此目录"
        panel.message = "选择保存“\(entry.name)”的位置"
        if let bookmark = configuration.downloadDirectoryBookmark, let resolved = try? BookmarkStore.resolve(bookmark) {
            panel.directoryURL = resolved.0
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            configuration.downloadDirectoryBookmark = try BookmarkStore.create(folder)
            saveConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let destination = folder.appendingPathComponent(entry.name)
        var policy = CollisionPolicy.fail
        if FileManager.default.fileExists(atPath: destination.path) {
            guard confirm("本地已有同名项目", detail: "继续会替换同名文件；目录会合并。", button: "替换") else { return }
            policy = .replace
        }
        startTransfer(
            host: host, name: entry.name, direction: .download, localURL: destination, remotePath: entry.path,
            policy: policy, scopeURL: folder)
    }
    private func startTransfer(
        host: HostProfile, name: String, direction: TransferDirection, localURL: URL, remotePath: String,
        policy: CollisionPolicy, scopeURL: URL? = nil
    ) {
        do {
            guard transfersWritable else { throw MacXError.message("传输记录无法安全写入，已保留原文件。") }
            let scope = scopeURL ?? localURL
            let lease = SecurityScopedResource(scope)
            defer { withExtendedLifetime(lease) {} }
            let bookmark = try BookmarkStore.create(scope, readOnly: direction == .upload)
            let job = TransferTask(name: name, direction: direction)
            let record = PendingTransfer(
                task: job, hostID: host.id, remotePath: remotePath, scopeBookmark: bookmark,
                destinationName: direction == .download ? localURL.lastPathComponent : nil,
                replaceExisting: policy == .replace)
            transferJournal.records.append(record)
            do { try persistTransfers() } catch {
                transferJournal.records.removeAll { $0.id == job.id }
                throw error
            }
            transfers.append(job)
            taskSection = "transfers"
            showTransfers = true
            drainTransfers()
        } catch { errorMessage = error.localizedDescription }
    }
    private func persistTransfers() throws {
        guard transfersWritable else { throw MacXError.message("传输记录无法安全写入。") }
        try transferStore?.save(transferJournal)
    }
    private func drainTransfers() {
        guard !isShuttingDown else { return }
        for record in transferJournal.records where record.task.state == .queued && transferTasks[record.id] == nil {
            guard transferTasks.count < 3 else { break }
            runTransfer(record)
        }
    }
    private func runTransfer(_ record: PendingTransfer) {
        let job = record.task
        transferTasks[job.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                transferTasks[job.id] = nil
                drainTransfers()
            }
            do {
                guard let host = configuration.hosts.first(where: { $0.id == record.hostID }) else {
                    throw MacXError.message("对应主机已删除，请重新建立任务。")
                }
                let (scope, updated) = try BookmarkStore.resolve(record.scopeBookmark)
                let lease = SecurityScopedResource(scope)
                defer { withExtendedLifetime(lease) {} }
                if let updated, let i = transferJournal.records.firstIndex(where: { $0.id == job.id }) {
                    transferJournal.records[i].scopeBookmark = updated
                    try persistTransfers()
                }
                let localURL = try record.localURL(in: scope)
                updateTransfer(job.id, state: .running, detail: "连接中…")
                let connection = try await authenticated(host)
                defer { connection.cancel() }
                let sftp = try await connection.openSFTP()
                let throttle = ProgressThrottle()
                let progress: TransferProgress = { [weak self] completed, total in
                    guard throttle.shouldPublish(completed: completed, total: total) else { return }
                    Task { @MainActor in
                        guard let self, let i = self.transfers.firstIndex(where: { $0.id == job.id }),
                            self.transfers[i].state == .running
                        else { return }
                        self.transfers[i].completedBytes = completed
                        self.transfers[i].totalBytes = total
                        self.transfers[i].detail = "正在传输当前文件"
                    }
                }
                let policy: CollisionPolicy = record.replaceExisting ? .replace : .fail
                if job.direction == .upload {
                    try await sftp.upload(localURL, to: record.remotePath, policy: policy, progress: progress)
                } else {
                    try await sftp.download(record.remotePath, to: localURL, policy: policy, progress: progress)
                }
                try Task.checkCancellation()
                updateTransfer(job.id, state: .completed, detail: "已完成")
                for tab in sessions where tab.host.id == host.id && tab.state == .connected { loadDirectory(tab) }
            } catch {
                updateTransfer(
                    job.id, state: Task.isCancelled ? .cancelled : .failed,
                    detail: Task.isCancelled ? "已取消，可重试" : error.localizedDescription)
            }
        }
    }
    private func updateTransfer(_ id: UUID, state: JobState, detail: String) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].state = state
            transfers[i].detail = detail
        }
        if state == .completed {
            transferJournal.records.removeAll { $0.id == id }
        } else if let i = transferJournal.records.firstIndex(where: { $0.id == id }) {
            transferJournal.records[i].task.state = state
            transferJournal.records[i].task.detail = detail
        }
        do { try persistTransfers() } catch { errorMessage = error.localizedDescription }
    }
    func cancelTransfer(_ id: UUID) {
        transferTasks[id]?.cancel()
        if transferTasks[id] == nil { updateTransfer(id, state: .cancelled, detail: "已取消，可重试") }
    }
    func removeTransfer(_ id: UUID) {
        guard transferTasks[id] == nil else { return }
        transferJournal.records.removeAll { $0.id == id }
        transfers.removeAll { $0.id == id }
        do { try persistTransfers() } catch { errorMessage = error.localizedDescription }
    }
    func retryTransfer(_ id: UUID) {
        guard let i = transferJournal.records.firstIndex(where: { $0.id == id }), transferTasks[id] == nil else {
            return
        }
        guard
            confirm(
                "重新传输“\(transferJournal.records[i].task.name)”", detail: "将从头传输，并替换目标中的同名文件；目录会合并。", button: "恢复并替换同名文件"
            )
        else { return }
        transferJournal.records[i].replaceExisting = true
        updateTransfer(id, state: .queued, detail: "排队中")
        drainTransfers()
    }
    func reauthorizeTransfer(_ id: UUID) {
        guard let i = transferJournal.records.firstIndex(where: { $0.id == id }), transferTasks[id] == nil else {
            return
        }
        let record = transferJournal.records[i]
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = record.task.direction == .upload
        panel.prompt = "重新授权"
        panel.message = record.task.direction == .upload ? "重新选择上传来源“\(record.task.name)”" : "重新选择下载目标文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard record.task.direction != .upload || url.lastPathComponent == record.task.name else {
                throw MacXError.message("请选择原来同名的上传来源。")
            }
            transferJournal.records[i].scopeBookmark = try BookmarkStore.create(
                url, readOnly: record.task.direction == .upload)
            try persistTransfers()
            updateTransfer(id, state: .paused, detail: "授权已更新，可以恢复传输")
        } catch { errorMessage = error.localizedDescription }
    }
    func chooseEditFolder() throws {
        guard edits.isEmpty else { throw MacXError.message("请先结束当前编辑，再更改工作目录。") }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "用作编辑工作目录"
        panel.message = "远程文件的本地副本会保存在这里。外部编辑器保存后，MacXTerm 会自动回传。"
        guard panel.runModal() == .OK, let url = panel.url else { throw MacXError.cancelled }
        configuration.editDirectoryBookmark = try BookmarkStore.create(url)
        editCoordinator = nil
        saveConfiguration()
    }
    private func ensureEditCoordinator() async throws -> RemoteEditCoordinator {
        if let editCoordinator { return editCoordinator }
        if configuration.editDirectoryBookmark == nil { try chooseEditFolder() }
        guard let data = configuration.editDirectoryBookmark else { throw MacXError.cancelled }
        let (root, updated) = try BookmarkStore.resolve(data)
        editWorkspace = SecurityScopedResource(root)
        if let updated {
            configuration.editDirectoryBookmark = updated
            saveConfiguration()
        }
        let coordinator = try RemoteEditCoordinator(
            root: root, storeURL: JSONStore<[RemoteEditSession]>.applicationURL("remote-edits.json")
        ) { [weak self] records in Task { @MainActor in self?.updateEdits(records) } }
        editCoordinator = coordinator
        edits = await coordinator.sessions()
        return coordinator
    }
    private func updateEdits(_ records: [RemoteEditSession]) {
        let changed = records.filter { record in
            record.state == .completed
                && edits.contains {
                    $0.id == record.id && $0.lastUploadedHash != record.lastUploadedHash
                }
        }
        edits = records
        for tab in sessions where tab.fileService != nil {
            if changed.contains(where: { $0.hostID == tab.host.id && RemotePath.parent($0.remotePath) == tab.directory }
            ) {
                loadDirectory(tab)
            }
        }
    }
    private func openEditor(_ url: URL) async throws {
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        if let bookmark = configuration.editorBookmark {
            let (app, updated) = try BookmarkStore.resolve(bookmark)
            if let updated {
                configuration.editorBookmark = updated
                saveConfiguration()
            }
            let lease = SecurityScopedResource(app)
            defer { withExtendedLifetime(lease) {} }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: options)
        } else {
            // Resolve the Editor role, not Shell/Viewer: a downloaded .command
            // must open for editing rather than run in Terminal on double-click.
            let associated = LSCopyDefaultApplicationURLForURL(url as CFURL, .editor, nil)?.takeRetainedValue() as URL?
            guard
                let editor = associated
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            else {
                throw MacXError.message("未找到此文件类型的编辑器，请在设置中选择文本编辑器。")
            }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: options)
        }
    }
    func isOpeningFile(_ entry: RemoteEntry, host: HostProfile) -> Bool {
        openingFiles.contains(host.id.uuidString + ":" + entry.path)
    }
    func editFile(_ entry: RemoteEntry, host: HostProfile) {
        let openingID = host.id.uuidString + ":" + entry.path
        guard openingFiles.insert(openingID).inserted else { return }
        Task {
            defer { openingFiles.remove(openingID) }
            do {
                let coordinator = try await ensureEditCoordinator()
                let connection = try await authenticated(host)
                let sftp = try await connection.openSFTP()
                let url = try await coordinator.open(hostID: host.id, path: entry.path, client: sftp)
                try await openEditor(url)
                taskSection = "edits"
                showTransfers = true
            } catch { if (error as? MacXError) != .cancelled { errorMessage = error.localizedDescription } }
        }
    }
    func editAction(_ record: RemoteEditSession, action: String) {
        Task {
            do {
                let coordinator = try await ensureEditCoordinator()
                if action == "reveal" {
                    if let url = await coordinator.localURL(for: record.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    return
                }
                if action == "stop" {
                    try await coordinator.stop(record.id)
                    return
                }
                guard let host = configuration.hosts.first(where: { $0.id == record.hostID }) else {
                    throw MacXError.message("对应主机已删除，本地修改仍保留。")
                }
                if action == "overwrite", !confirm("用本地修改覆盖远端版本？", detail: record.remotePath, button: "覆盖远端") { return }
                let connection = try await authenticated(host)
                let sftp = try await connection.openSFTP()
                switch action {
                case "overwrite": await coordinator.overwrite(record.id, client: sftp)
                case "redownload": try await coordinator.redownload(record.id, client: sftp)
                default: await coordinator.resume(record.id, client: sftp)
                }
                if let url = await coordinator.localURL(for: record.id) { try await openEditor(url) }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func chooseEditor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择编辑器"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            configuration.editorBookmark = try BookmarkStore.create(url, readOnly: true)
            configuration.editorDisplayName = url.deletingPathExtension().lastPathComponent
            saveConfiguration()
        } catch { errorMessage = error.localizedDescription }
    }
    func saveTunnel(_ rule: TunnelRule) throws {
        try rule.validate()
        if let i = configuration.tunnels.firstIndex(where: { $0.id == rule.id }) {
            configuration.tunnels[i] = rule
        } else {
            configuration.tunnels.append(rule)
        }
        saveConfiguration()
    }
    func startTunnel(_ rule: TunnelRule) {
        guard tunnelTasks[rule.id] == nil, let host = configuration.hosts.first(where: { $0.id == rule.hostID }) else {
            return
        }
        tunnelStates[rule.id] = "连接中"
        tunnelErrors[rule.id] = nil
        let connection = SSHSessionService()
        tunnelServices[rule.id] = connection
        tunnelTasks[rule.id] = Task { [self] in
            defer {
                tunnelTasks[rule.id] = nil
                tunnelServices[rule.id] = nil
            }
            do {
                _ = try await authenticated(host, service: connection)
                let service = TunnelService(session: connection)
                try await service.run(
                    rule,
                    onReady: { [weak self] port in Task { @MainActor in self?.tunnelStates[rule.id] = "运行中 · \(port)" }
                    },
                    onClientError: { [weak self] error in Task { @MainActor in self?.tunnelErrors[rule.id] = error } })
                tunnelStates[rule.id] = "已停止"
            } catch {
                tunnelStates[rule.id] = Task.isCancelled ? "已停止" : "启动失败"
                if !Task.isCancelled { tunnelErrors[rule.id] = error.localizedDescription }
            }
        }
    }
    func stopTunnel(_ id: UUID) {
        tunnelTasks[id]?.cancel()
        tunnelServices[id]?.cancel()
        tunnelStates[id] = "已停止"
    }
    func tunnelRunning(_ id: UUID) -> Bool { tunnelTasks[id] != nil }
    func deleteTunnel(_ rule: TunnelRule) {
        stopTunnel(rule.id)
        configuration.tunnels.removeAll { $0.id == rule.id }
        saveConfiguration()
    }
    func shutdown() async {
        isShuttingDown = true
        for tab in sessions { tab.disconnect() }
        for tab in desktopSessions { tab.disconnect(); tab.discardPassword() }
        for task in transferTasks.values { task.cancel() }
        for id in tunnelTasks.keys { stopTunnel(id) }
        await editCoordinator?.pauseAll()
    }
    func confirm(_ title: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldPublish(completed: Int64, total: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard completed == total || now.timeIntervalSince(last) >= 0.1 else { return false }
        last = now
        return true
    }
}
