import Darwin
import Foundation
import SSHBridge

public enum CollisionPolicy: Sendable { case fail, replace, skip }
public typealias TransferProgress = @Sendable (_ completed: Int64, _ total: Int64) -> Void
public final class SFTPService: Sendable {
    let worker: SSHWorker
    init(worker: SSHWorker) { self.worker = worker }
    public func cancel() { mx_cancel(worker.handle) }
    public func canonicalPath(_ path: String) async throws -> String {
        try await worker.run { w in
            var bytes = [CChar](repeating: 0, count: 32768)
            let n = mx_realpath(w.handle, path, &bytes, bytes.count - 1)
            guard n >= 0 else { throw w.error() }
            return String(decoding: bytes.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
    public func list(_ path: String) async throws -> [RemoteEntry] {
        try await worker.run { try Self.listSync($0, path) }
    }
    public func attributes(_ path: String, follow: Bool = false) async throws -> RemoteAttributes? {
        try await worker.run { try Self.statSync($0, path, follow: follow) }
    }
    public func read(_ path: String, limit: Int = 20 * 1024 * 1024) async throws -> Data {
        try await worker.run { try Self.readSync($0, path, limit: limit) }
    }
    public func download(
        _ path: String, to destination: URL, policy: CollisionPolicy = .fail,
        progress: @escaping TransferProgress = { _, _ in }
    ) async throws {
        try await withTaskCancellationHandler {
            try await worker.run { w in try Self.downloadSync(w, path, destination, policy, progress) }
        } onCancel: {
            self.cancel()
        }
    }
    public func upload(
        _ source: URL, to path: String, policy: CollisionPolicy = .fail,
        progress: @escaping TransferProgress = { _, _ in }
    ) async throws {
        try await withTaskCancellationHandler {
            try await worker.run { w in try Self.uploadTree(w, source, path, policy, progress) }
        } onCancel: {
            self.cancel()
        }
    }
    public func replace(_ path: String, with data: Data, expectedHash: String, force: Bool = false) async throws {
        try await worker.run { w in
            guard let attrs = try Self.statSync(w, path, follow: false), attrs.isRegular else {
                throw MacXError.message("远端文件已删除或类型变化，请另存本地修改。")
            }
            try Self.atomicUpload(
                w, path, permissions: attrs.permissions, replace: true, expectedHash: force ? nil : expectedHash,
                progress: { _, _ in }, total: Int64(data.count)
            ) { write in try write(data) }
        }
    }
    private static func convert(_ a: MXAttributes) -> RemoteAttributes {
        .init(size: a.size, permissions: a.permissions, modified: a.modified, uid: a.uid, gid: a.gid)
    }
    private static func statSync(_ w: SSHWorker, _ path: String, follow: Bool = false) throws -> RemoteAttributes? {
        var a = MXAttributes()
        let r = mx_stat(w.handle, path, follow ? 1 : 0, &a)
        if r == 1 { return nil }
        guard r == 0 else { throw w.error() }
        return convert(a)
    }
    private static func listSync(_ w: SSHWorker, _ path: String) throws -> [RemoteEntry] {
        guard let dir = mx_opendir(w.handle, path) else { throw w.error() }
        defer { _ = mx_file_close(w.handle, dir) }
        var entries = [RemoteEntry]()
        var bytes = [CChar](repeating: 0, count: 32768)
        while true {
            var a = MXAttributes()
            let n = mx_readdir(w.handle, dir, &bytes, bytes.count - 1, &a)
            guard n >= 0 else { throw w.error() }
            if n == 0 { break }
            let name = String(decoding: bytes.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "." || name == ".." { continue }
            let child = try RemotePath.join(path, name)
            entries.append(.init(path: child, name: name, attributes: convert(a)))
        }
        return entries.sorted { a, b in
            a.attributes.isDirectory != b.attributes.isDirectory
                ? a.attributes.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    private static func readSync(_ w: SSHWorker, _ path: String, limit: Int) throws -> Data {
        guard let attrs = try statSync(w, path, follow: true), attrs.isRegular, attrs.size <= limit else {
            throw MacXError.message("仅支持编辑不超过 20 MB 的普通文本文件。")
        }
        guard let file = mx_open_read(w.handle, path) else { throw w.error() }
        defer { _ = mx_file_close(w.handle, file) }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = mx_file_read(w.handle, file, &bytes, bytes.count)
            guard n >= 0 else { throw w.error() }
            if n == 0 { break }
            guard result.count + n <= limit else { throw MacXError.message("文件超出编辑大小限制。") }
            result.append(contentsOf: bytes.prefix(n))
        }
        return result
    }
    private static func downloadSync(
        _ w: SSHWorker, _ path: String, _ destination: URL, _ policy: CollisionPolicy,
        _ progress: @escaping TransferProgress
    ) throws {
        guard let attrs = try statSync(w, path) else { throw MacXError.missingFile }
        if attrs.isSymbolicLink { throw MacXError.message("递归传输不会遍历符号链接：\(path)") }
        let fm = FileManager.default
        if attrs.isDirectory {
            let existing = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if existing?.isSymbolicLink == true || existing?.isDirectory == false {
                throw MacXError.message("下载目标不是普通目录。")
            }
            try fm.createDirectory(
                at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for entry in try listSync(w, path) where !entry.attributes.isSymbolicLink {
                try downloadSync(w, entry.path, destination.appendingPathComponent(entry.name), policy, progress)
            }
            return
        }
        guard attrs.isRegular else { throw MacXError.message("不支持传输特殊设备文件。") }
        let exists = fm.fileExists(atPath: destination.path)
        if exists && policy == .skip { return }
        if exists && policy == .fail { throw MacXError.message("本地已有同名文件：\(destination.lastPathComponent)") }
        if exists, (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw MacXError.message("不能覆盖本地符号链接。")
        }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".macxterm-\(UUID().uuidString).part")
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MacXError.message("无法创建下载文件。")
        }
        defer { try? fm.removeItem(at: temp) }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        guard let file = mx_open_read(w.handle, path) else { throw w.error() }
        defer { _ = mx_file_close(w.handle, file) }
        var bytes = [UInt8](repeating: 0, count: 65536)
        var written: Int64 = 0
        while true {
            let n = mx_file_read(w.handle, file, &bytes, bytes.count)
            guard n >= 0 else { throw w.error() }
            if n == 0 { break }
            try output.write(contentsOf: Data(bytes.prefix(n)))
            written += Int64(n)
            progress(written, Int64(clamping: attrs.size))
        }
        guard UInt64(written) == attrs.size, let current = try statSync(w, path), current.size == attrs.size,
            current.modified == attrs.modified
        else { throw MacXError.message("下载期间远端文件发生变化，未提交不完整文件，请重试。") }
        try output.synchronize()
        try output.close()
        if policy == .replace {
            guard Darwin.rename(temp.path, destination.path) == 0 else {
                throw MacXError.message("无法提交下载文件：\(String(cString:strerror(errno)))")
            }
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }
    private static func uploadTree(
        _ w: SSHWorker, _ source: URL, _ path: String, _ policy: CollisionPolicy, _ progress: @escaping TransferProgress
    ) throws {
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
        ])
        guard values.isSymbolicLink != true else { throw MacXError.message("上传不会遍历本地符号链接：\(source.lastPathComponent)") }
        let existing = try statSync(w, path)
        if existing?.isSymbolicLink == true { throw MacXError.message("不能覆盖远端符号链接：\(path)") }
        if values.isDirectory == true {
            if let existing {
                guard existing.isDirectory else { throw MacXError.message("目标已存在且不是目录。") }
            } else if mx_mkdir(w.handle, path, 0o755) != 0 {
                throw w.error()
            }
            for child in try FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
            {
                if (try child.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { continue }
                try uploadTree(w, child, try RemotePath.join(path, child.lastPathComponent), policy, progress)
            }
            return
        }
        guard values.isRegularFile == true else { throw MacXError.message("不支持上传特殊设备文件。") }
        if let existing {
            guard existing.isRegular else { throw MacXError.message("目标不是普通文件。") }
            if policy == .skip { return }
            if policy == .fail { throw MacXError.message("远端已有同名文件：\(path)") }
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try atomicUpload(
            w, path, permissions: existing?.permissions ?? 0o644, replace: existing != nil, expectedHash: nil,
            progress: progress, total: Int64(values.fileSize ?? 0)
        ) { write in
            while let data = try input.read(upToCount: 65536), !data.isEmpty { try write(data) }
        }
    }
    private static func atomicUpload(
        _ w: SSHWorker, _ path: String, permissions: UInt32, replace: Bool, expectedHash: String?,
        progress: @escaping TransferProgress, total: Int64, produce: (_ write: (Data) throws -> Void) throws -> Void
    ) throws {
        let temp = try RemotePath.join(RemotePath.parent(path), ".macxterm-\(UUID().uuidString).part")
        guard let file = mx_open_write(w.handle, temp, 0o600) else { throw w.error() }
        var closed = false
        var committed = false
        defer {
            if !closed { _ = mx_file_close(w.handle, file) }
            if !committed { _ = mx_remove(w.handle, temp) }
        }
        var written: Int64 = 0
        try produce { data in
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = mx_file_write(
                        w.handle, file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    guard n > 0 else { throw w.error() }
                    offset += n
                    written += Int64(n)
                    progress(written, total)
                }
            }
        }
        guard written == total else { throw MacXError.message("上传期间本地文件大小发生变化，未替换目标文件，请重试。") }
        let closeResult = mx_file_close(w.handle, file)
        closed = true
        guard closeResult == 0 else { throw w.error() }
        guard mx_chmod(w.handle, temp, UInt(permissions & 0o7777)) == 0 else { throw w.error() }
        if let expectedHash {
            guard let current = try statSync(w, path), current.isRegular,
                contentHash(try readSync(w, path, limit: 20 * 1024 * 1024)) == expectedHash
            else { throw MacXError.conflict }
        }
        guard mx_rename(w.handle, temp, path, replace ? 1 : 0) == 0 else { throw w.error() }
        committed = true
    }
}
