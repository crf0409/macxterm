import CryptoKit
import Darwin
import Foundation

public struct LocalPublicKey: Identifiable, Sendable, Equatable {
    public let file: URL
    public let algorithm: String
    public let comment: String
    public let line: String
    public let fingerprint: String
    public var id: String { file.standardizedFileURL.path }
    public var filename: String { file.lastPathComponent }
    public var clipboardText: String { line + "\n" }

    public static func parse(_ data: Data, file: URL) throws -> LocalPublicKey {
        guard data.count <= LocalPublicKeyReader.maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw MacXError.message("公钥文件不是有效的 UTF-8 文本，或超过 64 KB。")
        }
        guard !text.contains("PRIVATE KEY"), !text.contains("openssh-key-v1") else {
            throw MacXError.message("这是私钥文件。请选择对应的 .pub 公钥文件。")
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.count == 1, let line = lines.first,
            !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" })
        else { throw MacXError.message("请选择只包含一条 OpenSSH 公钥的 .pub 文件。") }
        let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw MacXError.message("公钥格式无效，应为密钥类型、Base64 内容和可选备注。")
        }
        let algorithm = String(parts[0])
        var fields = KeyFields(bytes: Array(blob))
        guard String(data: try fields.next(), encoding: .utf8) == algorithm else {
            throw MacXError.message("公钥类型与内容不匹配。")
        }
        switch algorithm {
        case "ssh-ed25519", "sk-ssh-ed25519@openssh.com":
            guard try fields.next().count == 32 else { throw KeyFields.invalid }
            if algorithm.hasPrefix("sk-") { guard try !fields.next().isEmpty else { throw KeyFields.invalid } }
        case "ssh-rsa":
            try fields.positiveInteger()
            try fields.positiveInteger()
        case "ssh-dss":
            for _ in 0..<4 { try fields.positiveInteger() }
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "sk-ecdsa-sha2-nistp256@openssh.com":
            let curve = String(data: try fields.next(), encoding: .utf8) ?? ""
            let lengths = ["nistp256": 65, "nistp384": 97, "nistp521": 133]
            let point = try fields.next()
            guard let length = lengths[curve], algorithm.contains("sha2-" + curve),
                point.count == length, point.first == 4
            else { throw KeyFields.invalid }
            if algorithm.hasPrefix("sk-") { guard try !fields.next().isEmpty else { throw KeyFields.invalid } }
        default:
            throw MacXError.message("暂不支持此公钥类型。请选择 RSA、Ed25519、ECDSA 或对应的 FIDO 公钥文件。")
        }
        guard fields.isAtEnd else { throw KeyFields.invalid }
        let comment = parts.count == 3 ? String(parts[2]).trimmingCharacters(in: .whitespaces) : ""
        let normalized = algorithm + " " + blob.base64EncodedString() + (comment.isEmpty ? "" : " " + comment)
        return LocalPublicKey(
            file: file, algorithm: algorithm, comment: comment, line: normalized,
            fingerprint: "SHA256:"
                + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: ""))
    }
}

private struct KeyFields {
    let bytes: [UInt8]
    var offset = 0
    static let invalid = MacXError.message("公钥内容不完整或结构无效。")
    var isAtEnd: Bool { offset == bytes.count }
    mutating func next() throws -> Data {
        guard bytes.count - offset >= 4 else { throw Self.invalid }
        let count = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard count <= bytes.count - offset else { throw Self.invalid }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }
    mutating func positiveInteger() throws {
        let value = try next()
        guard let first = value.first, first & 0x80 == 0, value.contains(where: { $0 != 0 }) else { throw Self.invalid }
    }
}

public struct PublicKeyScan: Sendable {
    public var keys: [LocalPublicKey] = []
    public var issues: [String] = []
    public init() {}
}

public enum LocalPublicKeyReader {
    public static let maximumBytes = 64 * 1024

    /// The caller holds the security-scoped lease. Only regular .pub files are opened.
    public static func read(_ url: URL) throws -> LocalPublicKey {
        guard url.pathExtension.lowercased() == "pub" else {
            throw MacXError.message("请选择扩展名为 .pub 的公钥文件。")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw MacXError.message("无法读取公钥；请确认文件授权有效且文件不是符号链接。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw MacXError.message("公钥必须是普通文件。")
        }
        guard attributes.st_size <= maximumBytes else { throw MacXError.message("公钥文件超过 64 KB。") }
        var data = Data()
        while data.count <= maximumBytes {
            let chunk = try handle.read(upToCount: maximumBytes + 1 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return try LocalPublicKey.parse(data, file: url)
    }

    public static func scan(_ directory: URL) throws -> PublicKeyScan {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pub" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var result = PublicKeyScan()
        for file in entries {
            try Task.checkCancellation()
            do { result.keys.append(try read(file)) } catch {
                result.issues.append(file.lastPathComponent + "：" + error.localizedDescription)
            }
        }
        return result
    }
}
