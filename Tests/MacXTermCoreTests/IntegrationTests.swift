import Foundation
import Testing

@testable import MacXTermCore

@Suite("真实 OpenSSH 集成", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACXTERM_INTEGRATION"] == "1"))
struct IntegrationTests {
    private var fixture: URL {
        URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["MACXTERM_FIXTURE"] ?? FileManager.default
                .currentDirectoryPath + "/.build/integration")
    }
    private func connected(keyName: String = "client_key", secret: String = "") async throws -> SSHSessionService {
        var host = HostProfile()
        host.hostname = "127.0.0.1"
        host.port = Int(ProcessInfo.processInfo.environment["MACXTERM_SSH_PORT"] ?? "22337")!
        host.username = ProcessInfo.processInfo.environment["MACXTERM_SSH_USER"] ?? NSUserName()
        host.authentication = .privateKey
        let service = SSHSessionService()
        let identity = try await service.handshake(host: host)
        let publicText = try String(contentsOf: fixture.appendingPathComponent("host_key.pub"), encoding: .utf8)
        let expected = try #require(Data(base64Encoded: String(publicText.split(separator: " ")[1])))
        #expect(identity.key == expected)
        try await service.authenticate(
            host: host, credentials: .init(secret: secret, keyURL: fixture.appendingPathComponent(keyName)))
        return service
    }
    private func remoteRoot() throws -> URL {
        let root = fixture.appendingPathComponent("remote/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func terminalPTYResizeAndUnicode() async throws {
        let connection = try await connected()
        defer { connection.cancel() }
        try await connection.openTerminal(columns: 80, rows: 24)
        try await connection.resize(columns: 91, rows: 33)
        try await connection.writeTerminal(
            Data(
                "printf '\\115\\130\\137\\117\\113\\137\\063\\071\\n'; stty size; printf '\\344\\270\\255\\346\\226\\207\\n'; exit\n"
                    .utf8))
        var output = Data()
        for _ in 0..<400 {
            let (data, eof) = try await connection.readTerminal()
            output.append(data)
            if eof { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("MX_OK_39"))
        #expect(text.contains("33 91"))
        #expect(text.contains("中文"))
    }
    @Test func execUsesIndependentChannelsAndReportsFailure() async throws {
        let connection = try await connected()
        defer { connection.cancel() }
        #expect(try await connection.execute("printf 'first command'") == Data("first command".utf8))
        #expect(try await connection.execute("printf 'second command'") == Data("second command".utf8))
        await #expect(throws: MacXError.self) {
            _ = try await connection.execute("printf 'expected failure' >&2; exit 1")
        }
    }
    @Test func slowMonitorCommandDoesNotBlockTerminalAndTimeoutKeepsConnection() async throws {
        let connection = try await connected()
        defer { connection.cancel() }
        try await connection.openTerminal()
        let slow = Task { try await connection.execute("sleep 2; printf done") }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        try await connection.writeTerminal(
            Data("printf '\\115\\130\\137\\111\\116\\124\\105\\122\\101\\103\\124\\111\\126\\105\\n'\n".utf8))
        var output = Data()
        for _ in 0..<90 {
            output.append(try await connection.readTerminal().0)
            if String(decoding: output, as: UTF8.self).contains("MX_INTERACTIVE") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(String(decoding: output, as: UTF8.self).contains("MX_INTERACTIVE"))
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(try await slow.value == Data("done".utf8))
        let timeout = Task { try await connection.execute("sleep 3", timeout: .milliseconds(200)) }
        try await Task.sleep(for: .milliseconds(300))
        let timeoutStart = ContinuousClock.now
        try await connection.writeTerminal(
            Data("printf '\\115\\130\\137\\103\\114\\105\\101\\116\\125\\120\\n'\n".utf8))
        output = Data()
        for _ in 0..<90 {
            output.append(try await connection.readTerminal().0)
            if String(decoding: output, as: UTF8.self).contains("MX_CLEANUP") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(String(decoding: output, as: UTF8.self).contains("MX_CLEANUP"))
        #expect(timeoutStart.duration(to: .now) < .seconds(1))
        await #expect(throws: MacXError.self) { _ = try await timeout.value }
        #expect(try await connection.execute("printf still-connected") == Data("still-connected".utf8))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACXTERM_DOCKER"] == "1"))
    func containerPasswordAndLinuxMonitoring() async throws {
        var host = HostProfile()
        host.hostname = "127.0.0.1"
        host.port = 22337
        host.username = "macxterm"
        let service = SSHSessionService()
        defer { service.cancel() }
        let identity = try await service.handshake(host: host)
        let publicText = try String(contentsOf: fixture.appendingPathComponent("host_key.pub"), encoding: .utf8)
        #expect(identity.key == Data(base64Encoded: String(publicText.split(separator: " ")[1])))
        try await service.authenticate(host: host, credentials: .init(secret: "fixture-password-only"))
        let sample = try await ServerMonitor.fetch(using: service)
        #expect(sample.memoryTotal > 0)
        #expect(sample.cores > 0)
        #expect(!sample.disks.isEmpty)
    }
    @Test func uploadDownloadRecursiveAndCollision() async throws {
        let connection = try await connected()
        defer { connection.cancel() }
        let sftp = try await connection.openSFTP()
        let root = try remoteRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let data = Data(String(repeating: "中文 test\n", count: 10000).utf8)
        try data.write(to: local.appendingPathComponent("中文 a.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: local.appendingPathComponent("skip-link").path, withDestinationPath: "/etc/passwd")
        let path = root.appendingPathComponent("uploaded").path
        try await sftp.upload(local, to: path)
        let entries = try await sftp.list(path)
        #expect(entries.count == 1)
        #expect(entries.first?.name == "中文 a.txt")
        #expect(try await sftp.read(path + "/中文 a.txt") == data)
        let download = root.appendingPathComponent("download")
        try await sftp.download(path, to: download)
        #expect(try Data(contentsOf: download.appendingPathComponent("中文 a.txt")) == data)
        await #expect(throws: MacXError.self) { try await sftp.upload(local, to: path) }
        try await sftp.upload(local, to: path, policy: .replace)
        #expect(try await sftp.read(path + "/中文 a.txt") == data)
    }
    @Test func atomicReplacementDetectsContentConflictAndPreservesPermissions() async throws {
        let connection = try await connected()
        defer { connection.cancel() }
        let sftp = try await connection.openSFTP()
        let root = try remoteRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.txt")
        let original = Data("original".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let updated = Data("updated".utf8)
        try await sftp.replace(file.path, with: updated, expectedHash: contentHash(original))
        #expect(try await sftp.read(file.path) == updated)
        #expect((try await sftp.attributes(file.path)?.permissions ?? 0) & 0o777 == 0o640)
        await #expect(throws: MacXError.conflict) {
            try await sftp.replace(file.path, with: Data("stale".utf8), expectedHash: contentHash(original))
        }
        #expect(try await sftp.read(file.path) == updated)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".macxterm") }.isEmpty)
    }
    @Test func editorAtomicSaveConflictAndRecovery() async throws {
        let connection = try await connected()
        defer { connection.cancel() }
        let sftp = try await connection.openSFTP()
        let root = try remoteRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.txt")
        let initial = Data("initial".utf8)
        try initial.write(to: file)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("edits.json")
        let editor = try RemoteEditCoordinator(root: workspace, storeURL: store, onChange: { _ in })
        let local = try await editor.open(hostID: UUID(), path: file.path, client: sftp)
        let newer = Data("saved atomically".utf8)
        try newer.write(to: local, options: .atomic)
        for _ in 0..<40 {
            if await editor.sessions().first?.lastUploadedHash == contentHash(newer) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await sftp.read(file.path) == newer)
        let external = Data("external change".utf8)
        try await sftp.replace(file.path, with: external, expectedHash: contentHash(newer))
        try Data("my local draft".utf8).write(to: local, options: .atomic)
        for _ in 0..<40 {
            if await editor.sessions().first?.state == .conflict { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let record = try #require(await editor.sessions().first)
        #expect(record.state == .conflict)
        #expect(try await sftp.read(file.path) == external)
        await editor.pauseAll()
        let restored = try RemoteEditCoordinator(root: workspace, storeURL: store, onChange: { _ in })
        #expect(await restored.sessions().count == 1)
        #expect(try Data(contentsOf: local) == Data("my local draft".utf8))
        try await restored.stop(record.id)
        let nextConnection = try await connected()
        defer { nextConnection.cancel() }
        let nextSFTP = try await nextConnection.openSFTP()
        let next = try await restored.open(hostID: record.hostID, path: file.path, client: nextSFTP)
        #expect(next != local)
        #expect(try Data(contentsOf: local) == Data("my local draft".utf8))
        await restored.pauseAll()
    }
    @Test func executableDocumentTextCopyKeepsRemoteName() async throws {
        let connection = try await connected()
        defer { connection.cancel() }
        let sftp = try await connection.openSFTP()
        let root = try remoteRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("sample.command")
        try Data("# original comment\n".utf8).write(to: remote)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let coordinator = try RemoteEditCoordinator(
            root: workspace, storeURL: root.appendingPathComponent("edits.json"), onChange: { _ in })
        let local = try await coordinator.open(hostID: UUID(), path: remote.path, client: sftp)
        #expect(local.lastPathComponent == "sample.command.txt")
        let changed = Data("# saved in a text editor\n".utf8)
        try changed.write(to: local, options: .atomic)
        for _ in 0..<40 {
            if await coordinator.sessions().first?.lastUploadedHash == contentHash(changed) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await sftp.read(remote.path) == changed)
        #expect(try await sftp.attributes(remote.path + ".txt") == nil)
        await coordinator.pauseAll()
    }
    @Test(arguments: [
        ("client_key", ""), ("rsa_key", ""), ("encrypted_key", "fixture-passphrase"), ("pem_key", ""),
        ("encrypted_rsa_key", "fixture-passphrase"), ("encrypted_pem_key", "fixture-passphrase"),
    ])
    func privateKeyFormats(_ input: (String, String)) async throws {
        let connection = try await connected(keyName: input.0, secret: input.1)
        connection.cancel()
    }
    @Test func rejectsWrongKeyPassphrase() async throws {
        await #expect(throws: MacXError.self) {
            _ = try await connected(keyName: "encrypted_key", secret: "incorrect-fixture-passphrase")
        }
    }
    @Test(arguments: [TunnelKind.local, TunnelKind.remote, TunnelKind.socks5])
    func forwarding(_ kind: TunnelKind) async throws {
        let connection = try await connected()
        defer { connection.cancel() }
        var rule = TunnelRule(hostID: UUID())
        rule.kind = kind
        rule.bindPort = kind == .local ? 22339 : kind == .remote ? 22340 : 22341
        if kind == .remote && ProcessInfo.processInfo.environment["MACXTERM_DOCKER"] == "1" {
            rule.bindHost = "0.0.0.0"
        }
        rule.targetHost = "127.0.0.1"
        rule.targetPort = 22338
        let service = TunnelService(session: connection)
        let fixedRule = rule
        let readiness = Readiness()
        let task = Task { try await service.run(fixedRule, onReady: { _ in Task { await readiness.setReady() } }) }
        for _ in 0..<300 {
            if await readiness.ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await readiness.ready)
        var arguments = ["--silent", "--show-error", "--max-time", "5", "--noproxy", ""]
        if kind == .socks5 {
            arguments += ["--socks5-hostname", "127.0.0.1:22341", "http://localhost:22338/"]
        } else {
            arguments += ["--proxy", "", "http://127.0.0.1:\(rule.bindPort)/"]
        }
        let fixedArguments = arguments
        let result = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = fixedArguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        task.cancel()
        _ = try? await task.value
        #expect(result.0 == 0)
        #expect(result.1.contains("MACXTERM_FORWARD_OK"))
    }

}

private actor Readiness {
    var ready = false
    func setReady() { ready = true }
}
