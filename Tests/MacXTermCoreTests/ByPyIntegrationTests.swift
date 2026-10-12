import Foundation
import Testing
@testable import MacXTermCore

@Suite("bypy 与隔离 OpenSSH", .serialized, .enabled(if: ProcessInfo.processInfo.environment["MACXTERM_INTEGRATION"] == "1"))
struct ByPyIntegrationTests {
    private func connected() async throws -> SSHSessionService {
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACXTERM_FIXTURE"]!)
        var host = HostProfile(); host.hostname = "127.0.0.1"; host.port = 22337
        host.username = ProcessInfo.processInfo.environment["MACXTERM_SSH_USER"] ?? NSUserName(); host.authentication = .privateKey
        let connection = SSHSessionService()
        let identity = try await connection.handshake(host: host)
        let key = try String(contentsOf: fixture.appendingPathComponent("host_key.pub"), encoding: .utf8)
        #expect(identity.key == Data(base64Encoded: String(key.split(separator: " ")[1])))
        try await connection.authenticate(host: host, credentials: .init(secret: "", keyURL: fixture.appendingPathComponent("client_key")))
        return connection
    }
    @Test func streamedCommandInputStaysOffTheInteractiveTerminal() async throws {
        let connection = try await connected(); defer { connection.cancel() }
        try await connection.openTerminal()
        let input = Data("MOCK_SECRET_NOT_AN_ARGUMENT_中文\n".utf8)
        let command = "python3 -u -c 'import sys,time; s=sys.stdin.readline().strip(); print(len(s),flush=True); time.sleep(0.2); print(\"STREAM_DONE\",flush=True)'"
        let output = try await connection.execute(command, standardInput: input)
        #expect(String(decoding: output, as: UTF8.self).contains("STREAM_DONE"))
        var terminal = Data()
        for _ in 0..<20 {
            let (data, _) = try await connection.readTerminal(); terminal.append(data)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!String(decoding: terminal, as: UTF8.self).contains("MOCK_SECRET"))
    }
    @Test func installsPinnedPackagesInFixtureAndRunsServerProbe() async throws {
        let connection = try await connected(); defer { connection.cancel() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = ByPyRuntime(root: root.appendingPathComponent(".build/bypy"))
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACXTERM_FIXTURE"]!).appendingPathComponent("bypy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = try await runtime.prepareServer(connection, installationDirectory: fixture.path)
        let again = try await runtime.prepareServer(connection, installationDirectory: fixture.path)
        #expect(directory == again)
        let result = try await runtime.runOnServer(ByPyRequest(operation: "status"), directory: directory, connection: connection)
        #expect(result.version == "1.8.9")
        #expect(!result.authorized)
        #expect(result.authURL?.hasPrefix("https://openapi.baidu.com/") == true)
    }
}
