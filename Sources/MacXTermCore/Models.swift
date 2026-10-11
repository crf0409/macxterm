import CryptoKit
import Foundation

public enum MacXError: Error, LocalizedError, Sendable, Equatable {
    case message(String)
    case conflict, missingFile, cancelled
    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .conflict: "远端文件已变化。已保留本地修改，请处理冲突后继续。"
        case .missingFile: "文件不存在或已被移走。"
        case .cancelled: "操作已取消。"
        }
    }
}
public enum AuthenticationMethod: String, Codable, CaseIterable, Sendable { case password, privateKey }
public enum HostConnectionType: String, Codable, CaseIterable, Sendable { case ssh, rdp }
public struct HostProfile: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var name: String = ""
    public var group: String = "我的主机"
    public var hostname: String = ""
    public var port: Int = 22
    public var username: String = ""
    public var authentication: AuthenticationMethod = .password
    public var keyBookmark: Data?
    public var keyDisplayName: String?
    public var rememberCredential = false
    public var connectionType: HostConnectionType = .ssh
    public var remoteDesktop = RemoteDesktopConfiguration()
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case id, name, group, hostname, port, username, authentication, keyBookmark, keyDisplayName,
            rememberCredential, connectionType, remoteDesktop
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(String.self, forKey: .group)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authentication = try c.decode(AuthenticationMethod.self, forKey: .authentication)
        keyBookmark = try c.decodeIfPresent(Data.self, forKey: .keyBookmark)
        keyDisplayName = try c.decodeIfPresent(String.self, forKey: .keyDisplayName)
        rememberCredential = try c.decode(Bool.self, forKey: .rememberCredential)
        connectionType = try c.decodeIfPresent(HostConnectionType.self, forKey: .connectionType) ?? .ssh
        remoteDesktop = try c.decodeIfPresent(RemoteDesktopConfiguration.self, forKey: .remoteDesktop) ?? .init()
    }
    public var credentialID: String { "host.\(id.uuidString).\(authentication.rawValue)" }
    public var shouldRememberCredential: Bool { authentication == .password || rememberCredential }
    public var endpoint: String {
        connectionType == .rdp ? remoteDesktop.endpoint(for: self) : "\(username)@\(hostname):\(port)"
    }
    public func validate() throws {
        if connectionType == .rdp { try remoteDesktop.validate(for: self); return }
        guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !username.isEmpty, ![hostname, username].contains(where: { $0.contains("\0") || $0.contains("\n") }),
            (1...65535).contains(port)
        else { throw MacXError.message("请填写有效的主机、用户名与 SSH 端口（1–65535）。") }
        if authentication == .privateKey && keyBookmark == nil { throw MacXError.message("请选择私钥文件。") }
    }
}
public enum TunnelKind: String, Codable, CaseIterable, Sendable {
    case local, remote, socks5
    public var title: String {
        switch self {
        case .local: "本地转发"
        case .remote: "远程转发"
        case .socks5: "SOCKS5 代理"
        }
    }
}
public struct TunnelRule: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var name = ""
    public var hostID: UUID
    public var kind: TunnelKind = .local
    public var bindHost = "127.0.0.1"
    public var bindPort = 8080
    public var targetHost = "127.0.0.1"
    public var targetPort = 80
    public init(hostID: UUID) { self.hostID = hostID }
    public func validate() throws {
        guard (1...65535).contains(bindPort), !bindHost.isEmpty, !bindHost.contains("\0") else {
            throw MacXError.message("监听地址或端口无效。")
        }
        if kind == .socks5 {
            guard ["127.0.0.1", "::1", "localhost"].contains(bindHost) else {
                throw MacXError.message("SOCKS5 仅允许监听本机回环地址。")
            }
        } else if !(1...65535).contains(targetPort) || targetHost.isEmpty || targetHost.contains("\0") {
            throw MacXError.message("目标主机或端口无效。")
        }
    }
    public var summary: String {
        "\(bindHost):\(bindPort) → " + (kind == .socks5 ? "SOCKS5" : "\(targetHost):\(targetPort)")
    }
}
public struct RemoteAttributes: Codable, Hashable, Sendable {
    public var size: UInt64
    public var permissions: UInt32
    public var modified: UInt64
    public var uid: UInt32
    public var gid: UInt32
    public var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
    public var isSymbolicLink: Bool { permissions & 0o170000 == 0o120000 }
    public var isRegular: Bool { permissions & 0o170000 == 0o100000 }
    public init(size: UInt64, permissions: UInt32, modified: UInt64, uid: UInt32 = 0, gid: UInt32 = 0) {
        self.size = size
        self.permissions = permissions
        self.modified = modified
        self.uid = uid
        self.gid = gid
    }
}
public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public var path: String
    public var name: String
    public var attributes: RemoteAttributes
    public var id: String { path }
    public init(path: String, name: String, attributes: RemoteAttributes) {
        self.path = path
        self.name = name
        self.attributes = attributes
    }
}
public enum RemotePath {
    public static func join(_ directory: String, _ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw MacXError.message("服务器返回了无效的文件名称。")
        }
        return directory == "/"
            ? "/" + name
            : directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash + "/" + name
    }
    public static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
    public static func basename(_ path: String) -> String { (path as NSString).lastPathComponent }
}
extension String { fileprivate var withLeadingSlash: String { "/" + self } }
public func contentHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public struct ServerIdentity: Identifiable, Sendable {
    public var hostname: String
    public var port: Int
    public var key: Data
    public var fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    public var id: String { "[\(hostname.lowercased())]:\(port)" }
    public init(hostname: String, port: Int, key: Data) {
        self.hostname = hostname
        self.port = port
        self.key = key
    }
}
public struct AppConfiguration: Codable, Sendable {
    public var version = 1
    public var hosts: [HostProfile] = []
    public var tunnels: [TunnelRule] = []
    public var knownHosts: [String: Data] = [:]
    public var editDirectoryBookmark: Data?
    public var editorBookmark: Data?
    public var editorDisplayName: String?
    public var downloadDirectoryBookmark: Data?
    public var terminalTheme = "dark"
    public init() {}
}
public enum TransferDirection: String, Codable, Sendable { case upload, download, edit }
public enum JobState: String, Codable, Sendable { case queued, running, completed, failed, cancelled, conflict, paused }
public struct TransferTask: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var name: String
    public var direction: TransferDirection
    public var completedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var state: JobState = .queued
    public var detail = ""
    public init(name: String, direction: TransferDirection) {
        self.name = name
        self.direction = direction
    }
    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}
public struct PendingTransfer: Identifiable, Codable, Sendable {
    public var task: TransferTask
    public var hostID: UUID
    public var remotePath: String
    public var scopeBookmark: Data
    public var destinationName: String?
    public var replaceExisting: Bool
    public var id: UUID { task.id }
    public init(
        task: TransferTask, hostID: UUID, remotePath: String, scopeBookmark: Data, destinationName: String?,
        replaceExisting: Bool
    ) {
        self.task = task
        self.hostID = hostID
        self.remotePath = remotePath
        self.scopeBookmark = scopeBookmark
        self.destinationName = destinationName
        self.replaceExisting = replaceExisting
    }
    public func localURL(in scope: URL) throws -> URL {
        guard let destinationName else { return scope }
        _ = try RemotePath.join("/", destinationName)
        return scope.appendingPathComponent(destinationName)
    }
}
public struct TransferJournal: Codable, Sendable {
    public var version = 1
    public var records: [PendingTransfer] = []
    public init() {}
    public mutating func prepareForRecovery() throws {
        guard version == 1 else { throw MacXError.message("传输记录版本不受支持，原文件已保留。") }
        records.removeAll { $0.task.state == .completed }
        for i in records.indices {
            records[i].task.state = .paused
            records[i].task.detail = "上次传输未完成，选择恢复后从头传输"
            records[i].task.completedBytes = 0
            records[i].task.totalBytes = 0
        }
    }
}
public struct RemoteEditSession: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var hostID: UUID
    public var remotePath: String
    public var localRelativePath: String
    public var baselineHash: String
    public var lastUploadedHash: String
    public var state: JobState = .completed
    public var detail = "已同步"
    public init(hostID: UUID, remotePath: String, localRelativePath: String, hash: String) {
        self.hostID = hostID
        self.remotePath = remotePath
        self.localRelativePath = localRelativePath
        self.baselineHash = hash
        self.lastUploadedHash = hash
    }
}
