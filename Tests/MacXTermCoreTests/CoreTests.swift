import Foundation
import Testing

@testable import MacXTermCore

@Suite("配置与协议") struct CoreTests {
    @Test(arguments: [0, -1, 65536]) func rejectsInvalidPort(_ port: Int) {
        var host = HostProfile()
        host.hostname = "127.0.0.1"
        host.username = "test"
        host.port = port
        #expect(throws: MacXError.self) { try host.validate() }
    }
    @Test func rejectsMissingKey() {
        var host = HostProfile()
        host.hostname = "server"
        host.username = "user"
        host.authentication = .privateKey
        #expect(throws: MacXError.self) { try host.validate() }
    }
    @Test func passwordRememberPolicyIncludesExistingHosts() throws {
        var host = HostProfile()
        #expect(host.authentication == .password)
        #expect(host.rememberCredential == false)
        #expect(host.shouldRememberCredential)
        let restored = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(host))
        #expect(restored.shouldRememberCredential)
        host.authentication = .privateKey
        #expect(!host.shouldRememberCredential)
        host.rememberCredential = true
        #expect(host.shouldRememberCredential)
    }
    @Test func keychainRoundTripAndDeletion() throws {
        let id = "test.\(UUID().uuidString)"
        defer { try? CredentialStore.save(nil, id: id) }
        try CredentialStore.save("fixture-value", id: id)
        #expect(try CredentialStore.read(id) == "fixture-value")
        try CredentialStore.save("updated-fixture", id: id)
        #expect(try CredentialStore.read(id) == "updated-fixture")
        try CredentialStore.save(nil, id: id)
        #expect(try CredentialStore.read(id) == nil)
    }
    @Test(arguments: ["..", ".", "x/y", "x\0y", ""]) func rejectsTraversal(_ component: String) {
        #expect(throws: MacXError.self) { try RemotePath.join("/safe", component) }
    }
    @Test func preservesUnicodePaths() throws {
        #expect(try RemotePath.join("/home/test", "中文 a.txt") == "/home/test/中文 a.txt")
        #expect(try RemotePath.join("/", "a") == "/a")
        #expect(RemotePath.parent("/file") == "/")
    }
    @Test func socksOnlyListensLocally() {
        var rule = TunnelRule(hostID: UUID())
        rule.kind = .socks5
        rule.bindHost = "0.0.0.0"
        #expect(throws: MacXError.self) { try rule.validate() }
        rule.bindHost = "::1"
        #expect(throws: Never.self) { try rule.validate() }
    }
    @Test func socksFragmentationAndEarlyPayload() throws {
        var parser = SOCKS5Parser()
        #expect(try parser.receive(Data([5])).isEmpty)
        #expect(try parser.receive(Data([1, 0])) == [.reply(Data([5, 0]))])
        let host = Array("db.internal".utf8)
        let request = Data([5, 1, 0, 3, UInt8(host.count)] + host + [0x15, 0x38] + Array("payload".utf8))
        #expect(try parser.receive(request.prefix(6)).isEmpty)
        #expect(try parser.receive(request.dropFirst(6)) == [.connect("db.internal", 5432)])
        #expect(parser.takeRemainder() == Data("payload".utf8))
    }
    @Test func socksPipelinedIPv4() throws {
        var parser = SOCKS5Parser()
        let events = try parser.receive(Data([5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, 0, 80]))
        #expect(events == [.reply(Data([5, 0])), .connect("127.0.0.1", 80)])
    }
    @Test func socksRejectsUnsupportedAuthentication() throws {
        var parser = SOCKS5Parser()
        #expect(try parser.receive(Data([5, 1, 2])) == [.reject(Data([5, 255]))])
    }
    @Test func socksRejectsUDP() throws {
        var parser = SOCKS5Parser()
        _ = try parser.receive(Data([5, 1, 0]))
        #expect(try parser.receive(Data([5, 3, 0, 1])) == [.reject(SOCKS5Parser.response(7))])
    }
    @Test func socksIPv6() throws {
        var parser = SOCKS5Parser()
        _ = try parser.receive(Data([5, 1, 0]))
        let request = Data([5, 1, 0, 4] + Array(repeating: UInt8(0), count: 15) + [1, 1, 187])
        #expect(try parser.receive(request) == [.connect("::1", 443)])
    }
    @Test func rejectsBinaryEdit() {
        #expect(throws: MacXError.self) { try RemoteEditCoordinator.validateText(Data([0, 1, 2, 3])) }
        #expect(throws: Never.self) { try RemoteEditCoordinator.validateText(Data("中文 UTF8\n".utf8)) }
        #expect(throws: Never.self) { try RemoteEditCoordinator.validateText(Data([255, 254, 65, 0])) }
    }
    @Test func corruptionDoesNotResetConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStore<AppConfiguration>(url: root.appendingPathComponent("config.json"))
        try Data("corrupt".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load(default: AppConfiguration()) }
        #expect(try Data(contentsOf: store.url) == Data("corrupt".utf8))
    }
    @Test func persistenceRoundTripHasNoSecretField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStore<AppConfiguration>(url: root.appendingPathComponent("config.json"))
        var config = AppConfiguration()
        var host = HostProfile()
        host.hostname = "localhost"
        host.username = "test"
        config.hosts = [host]
        try store.save(config)
        let read = try store.load(default: AppConfiguration())
        #expect(read.hosts == config.hosts)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        let row = try #require((object["hosts"] as? [[String: Any]])?.first)
        #expect(row["password"] == nil)
        #expect(row["secret"] == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
    @Test func fingerprintStable() {
        let identity = ServerIdentity(hostname: "EXAMPLE.COM", port: 2222, key: Data("host-key".utf8))
        #expect(identity.id == "[example.com]:2222")
        #expect(identity.fingerprint.hasPrefix("SHA256:"))
        #expect(!identity.fingerprint.contains("="))
    }
}
