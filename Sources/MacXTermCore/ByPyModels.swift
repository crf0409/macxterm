import Foundation

public enum ByPyPath {
    public static let root = "/apps/bypy"
    public static func normalize(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw MacXError.message("网盘路径不能包含控制字符。")
        }
        let path = value == root ? "/" : value.hasPrefix(root + "/") ? String(value.dropFirst(root.count)) : value
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains("..") else { throw MacXError.message("网盘路径不能包含上级目录跳转。") }
        return "/" + parts.filter { $0 != "." }.joined(separator: "/")
    }
    public static func join(_ parent: String, _ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw MacXError.message("文件名称无效。")
        }
        return try normalize(try normalize(parent) + "/" + name)
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func downloadCommand(_ path: String) throws -> String {
        "bypy download " + quote(String(try normalize(path).dropFirst()))
    }
}

public struct ByPyEntry: Codable, Identifiable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Double
    public var id: String { path }
}
public struct ByPyRequest: Codable, Sendable {
    public var operation: String
    public var path: String = "/"
    public var localPath: String = ""
    public var configDirectory: String = ""
    public var persistToken = false
    public var token: String?
    public var authorizationCode: String?
    public var replaceExisting = false
    public var isDirectory = false
    public init(operation: String) { self.operation = operation }
}
public struct ByPyResponse: Codable, Sendable {
    public var ok: Bool
    public var authorized: Bool
    public var needsAuthorization: Bool
    public var version: String
    public var error: String?
    public var entries: [ByPyEntry]?
    public var token: String?
    public var authURL: String?
}
public struct ByPyEvent: Codable, Sendable {
    public var kind: String
    public var completed: Int64?
    public var total: Int64?
    public var result: ByPyResponse?
}
public struct RemoteFileDrag: Codable, Sendable {
    public static let type = "app.macxterm.remote-file"
    public var hostID: UUID
    public var path: String
    public var isDirectory: Bool
    public init(hostID: UUID, path: String, isDirectory: Bool) {
        self.hostID = hostID; self.path = path; self.isDirectory = isDirectory
    }
}
