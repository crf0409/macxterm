import AppKit
import Foundation
import MacXTermCore
import Observation
import UniformTypeIdentifiers

struct ByPyJob: Identifiable {
    var task: TransferTask
    let target: String
    let targetName: String
    var request: ByPyRequest
    let scope: URL?
    var id: UUID { task.id }
}

@MainActor @Observable final class ByPyDriveModel {
    typealias Operation = @MainActor (ByPyRequest, String, @escaping TransferProgress) async throws -> ByPyResponse
    var target = "local"
    var path = "/"
    var entries = [ByPyEntry]()
    var selection: String?
    var authorized = false
    var needsAuthorization = false
    var authorizationCode = ""
    var authURL: String?
    var error = ""
    var status = "打开时自动运行 bypy list"
    var serverPath = ""
    var serverDownloadDirectory = "~"
    var jobs = [ByPyJob]()
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let injectedOperation: Operation?
    @ObservationIgnored private let clipboard: (@MainActor (String) -> Void)?
    @ObservationIgnored private var serverCommands = [String: String]()
    var controlling = false
    var transferring = false
    var busy: Bool { controlling || transferring }
    var selectedEntry: ByPyEntry? { entries.first { $0.id == selection } }
    var hosts: [HostProfile] { app?.configuration.hosts.filter { $0.connectionType == .ssh } ?? [] }
    var targetName: String { target == "local" ? "Mac 本机" : hosts.first { $0.id.uuidString == target }?.name ?? "SSH 服务器" }
    init(app: AppModel? = nil, operation: Operation? = nil, clipboard: (@MainActor (String) -> Void)? = nil) {
        self.app = app; self.injectedOperation = operation; self.clipboard = clipboard
    }
    private func runtime() throws -> ByPyRuntime {
        if let root = Bundle.main.resourceURL?.appendingPathComponent("ByPy"),
            FileManager.default.fileExists(atPath: root.appendingPathComponent("bridge.py").path) {
            return ByPyRuntime(root: root)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/bypy")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("bridge.py").path) else {
            throw MacXError.message("缺少 bypy 运行环境，请使用完整安装包或运行构建脚本。")
        }
        return ByPyRuntime(root: root)
    }
    private func perform(_ original: ByPyRequest, target: String, progress: @escaping TransferProgress = { _, _ in }) async throws -> ByPyResponse {
        if let injectedOperation {
            let result = try await injectedOperation(original, target, progress)
            try Task.checkCancellation(); return result
        }
        let runtime = try runtime()
        let result: ByPyResponse
        if target == "local" {
            var request = original
            request.configDirectory = try JSONStore<AppConfiguration>.applicationURL("ByPy").path
            request.token = try original.token ?? CredentialStore.read("bypy.local.account")
            result = try await runtime.run(request, progress: progress)
            try Task.checkCancellation()
            if let token = result.token { try CredentialStore.save(token, id: "bypy.local.account") }
            else if let token = original.token, result.ok && result.authorized { try CredentialStore.save(token, id: "bypy.local.account") }
        } else {
            guard let app, let host = hosts.first(where: { $0.id.uuidString == target }) else {
                throw MacXError.message("请选择有效的 SSH 主机。")
            }
            let connection = try await app.authenticated(host)
            defer { connection.cancel() }
            let directory = try await runtime.prepareServer(connection)
            serverCommands[target] = directory + "/bypy"
            result = try await withTaskCancellationHandler {
                try await runtime.runOnServer(original, directory: directory, connection: connection, progress: progress)
            } onCancel: { connection.cancel() }
        }
        try Task.checkCancellation()
        return result
    }
    func refresh(path newPath: String? = nil) {
        guard !busy else { return }
        do { path = try ByPyPath.normalize(newPath ?? path) } catch { self.error = error.localizedDescription; return }
        selection = nil; error = ""; controlling = true; status = "正在运行 bypy list…"
        let target = target; let generation = generation
        var request = ByPyRequest(operation: "list"); request.path = path
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.controlling = false; self.controlTask = nil; self.drain() } }
            do {
                let result = try await self.perform(request, target: target)
                guard self.generation == generation else { return }
                self.consume(result)
                self.entries = (result.entries ?? []).sorted {
                    $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                self.status = result.needsAuthorization ? "请先授权所选位置的百度网盘" : "\(self.entries.count) 个项目 · bypy \(result.version)"
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; self.status = "文件列表未加载" } }
        }
    }
    func changeTarget() {
        guard !busy else { return }
        path = "/"; entries = []; authorized = false; authorizationCode = ""; authURL = nil
        serverPath = ""
        serverDownloadDirectory = app?.sessions.first(where: { $0.host.id.uuidString == target })?.directory ?? "~"
        refresh()
    }
    private func consume(_ result: ByPyResponse) {
        authorized = result.authorized; needsAuthorization = result.needsAuthorization; authURL = result.authURL
        error = result.ok ? "" : result.error ?? "网盘操作未完成。"
    }
    func openAuthorization() {
        guard let authURL, let url = URL(string: authURL), url.scheme == "https", url.host == "openapi.baidu.com" else { return }
        NSWorkspace.shared.open(url)
    }
    func authorize() {
        guard !busy, authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16 else { return }
        var request = ByPyRequest(operation: "authorize"); request.authorizationCode = authorizationCode
        authorizationCode = ""; error = ""; controlling = true; status = "正在提交授权…"
        let target = target; let generation = generation
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.controlling = false; self.controlTask = nil } }
            do {
                let result = try await self.perform(request, target: target)
                guard self.generation == generation else { return }
                self.consume(result); self.status = result.ok && result.authorized ? "授权成功" : "授权未完成"
                if result.ok && result.authorized {
                    var list = ByPyRequest(operation: "list"); list.path = self.path
                    let contents = try await self.perform(list, target: target)
                    guard self.generation == generation else { return }
                    self.consume(contents); self.entries = (contents.entries ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    self.status = "\(self.entries.count) 个项目 · bypy \(contents.version)"
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func showAuthorization() { authorized = false; needsAuthorization = true }
    func importAuthorization() {
        guard target == "local", !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]; panel.prompt = "导入 bypy 授权"
        panel.message = "选择已有 bypy 安装中的 bypy.json。验证成功后保存到系统钥匙串。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let lease = SecurityScopedResource(url); defer { withExtendedLifetime(lease) {} }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 256 * 1024 else { throw MacXError.message("授权文件过大，请选择 bypy.json。") }
            let data = try Data(contentsOf: url)
            guard data.count < 256 * 1024, let token = String(data: data, encoding: .utf8),
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["access_token"] is String
            else { throw MacXError.message("所选文件不是有效的 bypy 授权文件。") }
            var request = ByPyRequest(operation: "list"); request.token = token; request.path = path
            controlling = true; error = ""; status = "正在验证已有授权…"
            controlTask = Task { [weak self] in
                guard let self else { return }
                defer { self.controlling = false; self.controlTask = nil }
                do {
                    let result = try await self.perform(request, target: "local")
                    self.consume(result); self.entries = result.entries ?? []; self.status = result.authorized ? "已有授权验证成功" : "授权未完成"
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func copyName() { if let entry = selectedEntry { copy(entry.name) } }
    func copyPath() { if let entry = selectedEntry { copy(String(entry.path.dropFirst())) } }
    func copyCommand() {
        guard let entry = selectedEntry, let command = try? ByPyPath.downloadCommand(entry.path) else { return }
        if let executable = serverCommands[target] { copy(ByPyPath.quote(executable) + String(command.dropFirst(4))) }
        else { copy(command) }
    }
    private func copy(_ value: String) {
        if let clipboard { clipboard(value); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    func chooseUpload() {
        guard authorized else { return }
        if target != "local" { uploadServerPath(); return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "上传到网盘"
        if panel.runModal() == .OK { uploadLocal(panel.urls) }
    }
    func uploadLocal(_ urls: [URL]) {
        guard target == "local" else { error = "本机文件请切换到“Mac 本机”上传；服务器文件可从文件侧栏拖入。"; return }
        for url in urls where url.isFileURL {
            do {
                var request = ByPyRequest(operation: "upload")
                request.path = try ByPyPath.join(path, url.lastPathComponent); request.localPath = url.path
                enqueue(request, name: url.lastPathComponent, direction: .upload, scope: url)
            } catch { self.error = error.localizedDescription }
        }
    }
    func uploadServerPath() {
        guard target != "local", !serverPath.isEmpty else { error = "请填写服务器上要上传的文件或文件夹路径。"; return }
        do {
            var request = ByPyRequest(operation: "upload"); request.localPath = serverPath
            let name = (serverPath as NSString).lastPathComponent
            request.path = try ByPyPath.join(path, name)
            enqueue(request, name: name, direction: .upload, scope: nil)
        } catch { self.error = error.localizedDescription }
    }
    func uploadRemote(_ item: RemoteFileDrag) {
        guard !busy else { return }
        guard target == item.hostID.uuidString else { error = "请先选择文件所属的 SSH 服务器，再拖入上传。"; return }
        serverPath = item.path; uploadServerPath()
    }
    func download() {
        guard let entry = selectedEntry, authorized else { return }
        var request = ByPyRequest(operation: "download"); request.path = entry.path; request.isDirectory = entry.isDirectory
        if target == "local" {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = "下载到此目录"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let destination = folder.appendingPathComponent(entry.name)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard app?.confirm("下载位置已有同名项目", detail: "继续会替换文件或合并目录。", button: "替换") == true else { return }
                request.replaceExisting = true
            }
            request.localPath = destination.path
            enqueue(request, name: entry.name, direction: .download, scope: folder)
        } else {
            guard !serverDownloadDirectory.isEmpty else { error = "请填写服务器下载目录。"; return }
            request.localPath = (serverDownloadDirectory as NSString).appendingPathComponent(entry.name)
            enqueue(request, name: entry.name, direction: .download, scope: nil)
        }
    }
    private func enqueue(_ request: ByPyRequest, name: String, direction: TransferDirection, scope: URL?) {
        guard authorized else { error = "请先授权百度网盘。"; return }
        jobs.append(ByPyJob(task: TransferTask(name: name, direction: direction), target: target, targetName: targetName, request: request, scope: scope))
        drain()
    }
    private func drain() {
        guard !busy, let index = jobs.firstIndex(where: { $0.task.state == .queued }) else { return }
        let job = jobs[index]; jobs[index].task.state = .running; jobs[index].task.detail = "\(job.targetName) · 正在传输…"
        transferring = true
        transferTask = Task { [weak self] in
            guard let self else { return }
            defer { self.transferring = false; self.transferTask = nil; self.drain() }
            let scope = job.scope.map(SecurityScopedResource.init)
            defer { withExtendedLifetime(scope) {} }
            do {
                let result = try await self.perform(job.request, target: job.target, progress: { [weak self] completed, total in
                    Task { @MainActor in
                        guard let self, let i = self.jobs.firstIndex(where: { $0.id == job.id }), self.jobs[i].task.state == .running else { return }
                        self.jobs[i].task.completedBytes = completed; self.jobs[i].task.totalBytes = total
                    }
                })
                guard let i = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                if self.target == job.target { self.consume(result) }
                self.jobs[i].task.state = result.ok && !result.needsAuthorization ? .completed : .failed
                self.jobs[i].task.detail = result.needsAuthorization ? "请先授权，再重试" : result.ok ? "传输完成 · \(job.targetName)" : result.error ?? "传输未完成"
                if result.ok && job.request.operation == "upload" { self.status = "上传完成，点击刷新查看最新列表" }
            } catch {
                if let i = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[i].task.state = Task.isCancelled ? .cancelled : .failed
                    self.jobs[i].task.detail = Task.isCancelled ? "已取消；部分下载文件会保留" : error.localizedDescription
                }
            }
        }
    }
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].task.state == .running { transferTask?.cancel() }
        else { jobs[i].task.state = .cancelled }
    }
    func retry(_ id: UUID, replace: Bool = false) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !busy else { return }
        if replace && app?.confirm("替换同名项目？", detail: "将替换对应的网盘文件或下载目标；目录会合并。", button: "替换并重试") != true { return }
        jobs[i].request.replaceExisting = replace
        jobs[i].task.state = .queued; jobs[i].task.completedBytes = 0; jobs[i].task.detail = "排队中"
        drain()
    }
    func stop() {
        generation = UUID(); controlTask?.cancel(); transferTask?.cancel()
        for i in jobs.indices where jobs[i].task.state == .queued { jobs[i].task.state = .cancelled }
    }
}
