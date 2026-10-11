import Darwin
import Foundation

public actor RemoteEditCoordinator {
    public static let maximumFileSize = 20 * 1024 * 1024
    private let root: URL
    private let lease: SecurityScopedResource
    private let store: JSONStore<[RemoteEditSession]>
    private var records: [RemoteEditSession]
    private var clients: [UUID: SFTPService] = [:]
    private var monitors: [UUID: FileChangeMonitor] = [:]
    private var debounce: [UUID: Task<Void, Never>] = [:]
    private var uploading = Set<UUID>()
    private var dirty = Set<UUID>()
    private var opening = Set<String>()
    private let onChange: @Sendable ([RemoteEditSession]) -> Void
    public init(root: URL, storeURL: URL, onChange: @escaping @Sendable ([RemoteEditSession]) -> Void) throws {
        self.root = root
        lease = SecurityScopedResource(root)
        store = JSONStore(url: storeURL)
        self.onChange = onChange
        records = try store.load(default: [])
        for i in records.indices {
            let parts = records[i].localRelativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, !parts.contains(".."), !parts.contains(""), parts.first == "MacXTerm" else {
                throw MacXError.message("编辑记录中的本地路径无效，原记录已保留。")
            }
            records[i].state = .paused
            records[i].detail = "已保留工作副本，等待恢复编辑"
        }
    }
    public func sessions() -> [RemoteEditSession] { records }
    public func localURL(for id: UUID) -> URL? {
        records.first { $0.id == id }.map { root.appendingPathComponent($0.localRelativePath) }
    }
    public func open(hostID: UUID, path: String, client: SFTPService) async throws -> URL {
        let canonical = try await client.canonicalPath(path)
        let identity = "\(hostID.uuidString):\(canonical)"
        guard !opening.contains(identity) else { throw MacXError.message("正在打开此文件，请稍候。") }
        opening.insert(identity)
        defer { opening.remove(identity) }
        let filename = RemotePath.basename(canonical)
        _ = try RemotePath.join("/", filename)
        // Runnable macOS document extensions use a text working copy. The
        // original canonical remote path remains the destination for uploads.
        let localName =
            ["command", "tool"].contains((filename as NSString).pathExtension.lowercased())
            ? filename + ".txt" : filename
        if let record = records.first(where: { $0.hostID == hostID && $0.remotePath == canonical }) {
            var url = root.appendingPathComponent(record.localRelativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MacXError.message("本地编辑副本被移走。请结束此编辑，再重新打开远端文件。")
            }
            if url.lastPathComponent != localName {
                let safeURL = url.deletingLastPathComponent().appendingPathComponent(localName)
                try FileManager.default.copyItem(at: url, to: safeURL)
                if let i = records.firstIndex(where: { $0.id == record.id }) {
                    records[i].localRelativePath =
                        (record.localRelativePath as NSString).deletingLastPathComponent + "/" + localName
                    try persist()
                }
                url = safeURL
            }
            bind(record.id, client: client)
            changed(record.id)
            return url
        }
        let data = try await client.read(canonical, limit: Self.maximumFileSize)
        try Self.validateText(data)
        let relative =
            "MacXTerm/\(hostID.uuidString)/\(contentHash(Data(canonical.utf8)).prefix(32))/\(UUID().uuidString)/\(localName)"
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MacXError.message("发现未登记的本地编辑副本，已保留，请先移走该副本再打开。")
        }
        try data.write(to: url, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let record = RemoteEditSession(
            hostID: hostID, remotePath: canonical, localRelativePath: relative, hash: contentHash(data))
        records.append(record)
        try persist()
        bind(record.id, client: client)
        return url
    }
    public func resume(_ id: UUID, client: SFTPService) {
        bind(id, client: client)
        changed(id)
    }
    public func stop(_ id: UUID) throws {
        guard !uploading.contains(id) else { throw MacXError.message("文件正在上传，请等待本次保存完成。") }
        debounce[id]?.cancel()
        debounce[id] = nil
        monitors[id] = nil
        clients[id] = nil
        records.removeAll { $0.id == id }
        try persist()
    }
    public func pauseAll() {
        for task in debounce.values { task.cancel() }
        debounce = [:]
        monitors = [:]
        for client in clients.values { client.cancel() }
        clients = [:]
        for i in records.indices where records[i].state != .conflict {
            records[i].state = .paused
            records[i].detail = "本地副本已保留"
        }
        try? persist()
    }
    public func overwrite(_ id: UUID, client: SFTPService) async {
        bind(id, client: client)
        await synchronize(id, force: true)
    }
    public func redownload(_ id: UUID, client: SFTPService) async throws {
        guard !uploading.contains(id), let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[index]
        let data = try await client.read(record.remotePath, limit: Self.maximumFileSize)
        try Self.validateText(data)
        let url = root.appendingPathComponent(record.localRelativePath)
        // Preserve local work before replacing the working copy with the remote version.
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + ".local-\(UUID().uuidString.prefix(8))")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.copyItem(at: url, to: backup) }
        try data.write(to: url, options: .atomic)
        guard let current = records.firstIndex(where: { $0.id == id }) else { return }
        records[current].baselineHash = contentHash(data)
        records[current].lastUploadedHash = contentHash(data)
        records[current].state = .completed
        records[current].detail = "已取回远端版本，本地旧稿另存为 .local 副本"
        try persist()
        bind(id, client: client)
    }
    public static func validateText(_ data: Data) throws {
        guard data.count <= maximumFileSize else { throw MacXError.message("自动编辑仅支持不超过 20 MB 的文件。") }
        let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard
            (utf16 && data.count % 2 == 0 && String(data: data, encoding: .utf16) != nil)
                || (!data.contains(0) && String(data: data, encoding: .utf8) != nil)
        else { throw MacXError.message("该文件不是支持的 UTF-8/UTF-16 文本，请使用下载功能。") }
    }
    private func bind(_ id: UUID, client: SFTPService) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        clients[id] = client
        monitors[id] = FileChangeMonitor(url: root.appendingPathComponent(record.localRelativePath)) { [weak self] in
            Task { await self?.changed(id) }
        }
    }
    private func changed(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), record.state != .conflict, clients[id] != nil else {
            return
        }
        if uploading.contains(id) {
            dirty.insert(id)
            return
        }
        debounce[id]?.cancel()
        debounce[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                await self?.synchronize(id)
            } catch {}
        }
    }
    private func synchronize(_ id: UUID, force: Bool = false) async {
        guard !uploading.contains(id), let index = records.firstIndex(where: { $0.id == id }), let client = clients[id]
        else { return }
        let record = records[index]
        do {
            let url = root.appendingPathComponent(record.localRelativePath)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw MacXError.message("本地编辑副本不是普通文件，已暂停回传。")
            }
            let size = values.fileSize ?? 0
            guard size <= Self.maximumFileSize else { throw MacXError.message("本地文件超过 20 MB，已暂停回传。") }
            let data = try Data(contentsOf: url)
            try Self.validateText(data)
            let hash = contentHash(data)
            if hash == record.lastUploadedHash && !force {
                records[index].state = .completed
                records[index].detail = "已同步"
                try persist()
                return
            }
            records[index].state = .running
            records[index].detail = "正在回传…"
            try persist()
            uploading.insert(id)
            try await client.replace(record.remotePath, with: data, expectedHash: record.baselineHash, force: force)
            if let i = records.firstIndex(where: { $0.id == id }) {
                records[i].baselineHash = hash
                records[i].lastUploadedHash = hash
                records[i].state = .completed
                records[i].detail = "已同步"
                try persist()
            }
        } catch {
            if let i = records.firstIndex(where: { $0.id == id }) {
                records[i].state = (error as? MacXError) == .conflict ? .conflict : .failed
                records[i].detail = error.localizedDescription
                if records[i].state == .failed {
                    monitors[id] = nil
                    clients[id] = nil
                }
                try? persist()
            }
        }
        uploading.remove(id)
        if dirty.remove(id) != nil { changed(id) }
    }
    private func persist() throws {
        try store.save(records)
        onChange(records)
    }
}

// Watch both the inode and its directory: VS Code and NSDocument can replace
// the inode when saving. Directory events re-arm the file watch after a rename.
private final class FileChangeMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.macxterm.filewatch")
    private let url: URL
    private let callback: @Sendable () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    init(url: URL, callback: @escaping @Sendable () -> Void) {
        self.url = url
        self.callback = callback
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in
                self?.watchFile()
                self?.callback()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            directorySource = source
        }
        queue.sync { watchFile() }
    }
    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: queue)
        source.setEventHandler { [weak self] in self?.callback() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }
    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }
}
