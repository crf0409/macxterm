import Foundation

public enum RemoteFileOpenAction: Sendable, Equatable {
    case directory, textEditor, documentPreview
    public static func action(for entry: RemoteEntry) -> Self {
        if entry.attributes.isDirectory { return .directory }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return ["doc", "docx", "docm", "dot", "dotx", "dotm", "pdf"].contains(ext) ? .documentPreview : .textEditor
    }
}

public struct RemotePreviewDocument: Sendable {
    public let remotePath: String
    public let localURL: URL
    public var name: String { localURL.lastPathComponent }
    fileprivate init(remotePath: String, localURL: URL) {
        self.remotePath = remotePath; self.localURL = localURL
    }
    public func discard() { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
}

public enum RemoteDocumentPreview {
    public static let maximumBytes: UInt64 = 100 * 1024 * 1024
    public static func validate(_ entry: RemoteEntry) throws {
        guard entry.attributes.isRegular, !entry.attributes.isSymbolicLink else {
            throw MacXError.message("只能预览普通文件，请先下载符号链接或特殊文件。")
        }
        guard entry.attributes.size <= maximumBytes else {
            throw MacXError.message("在线预览支持不超过 100 MB 的文件，请使用下载功能。")
        }
        _ = try RemotePath.join("/", entry.name)
    }
    public static func stage(_ entry: RemoteEntry, using service: SFTPService, root: URL) async throws -> RemotePreviewDocument {
        try validate(entry)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(entry.name)
        do {
            try await service.download(entry.path, to: destination, maximumBytes: maximumBytes)
            try Task.checkCancellation()
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size >= 0, UInt64(size) <= maximumBytes else {
                throw MacXError.message("文件已变大，超出 100 MB 预览范围，请使用下载功能。")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return RemotePreviewDocument(remotePath: entry.path, localURL: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
