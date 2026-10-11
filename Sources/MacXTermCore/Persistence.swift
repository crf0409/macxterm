import Foundation
import Security

public struct JSONStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load(default defaultValue: @autoclosure () -> Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue() }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }
    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func applicationURL(_ name: String) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("MacXTerm", isDirectory: true).appendingPathComponent(name)
    }
}
public enum CredentialStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "app.macxterm.MacXTerm") + ".credentials" }
    public static func read(_ id: String) throws -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess else { throw MacXError.message("无法读取钥匙串：\(code)") }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func save(_ value: String?, id: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        guard let value else {
            let r = SecItemDelete(q as CFDictionary)
            if r != errSecSuccess && r != errSecItemNotFound { throw MacXError.message("无法删除钥匙串项目：\(r)") }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MacXError.message("无法保存到钥匙串：\(status)") }
    }
}
public enum BookmarkStore {
    public static func create(_ url: URL, readOnly: Bool = false) throws -> Data {
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public static func resolve(_ data: Data, readOnly: Bool = false) throws -> (URL, Data?) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
            bookmarkDataIsStale: &stale)
        let lease = SecurityScopedResource(url)
        defer { withExtendedLifetime(lease) {} }
        return (url, stale ? try create(url, readOnly: readOnly) : nil)
    }
}
public final class SecurityScopedResource: @unchecked Sendable {
    public let url: URL
    private let started: Bool
    public init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}
