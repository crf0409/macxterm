import Foundation
import Testing
@testable import MacXTermCore

@Suite("远程桌面") struct RemoteDesktopTests {
    @Test func oldHostConfigurationMigratesWithoutChangingSSH() throws {
        let host = HostProfile()
        var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        row.removeValue(forKey: "connectionType")
        row.removeValue(forKey: "remoteDesktop")
        let restored = try JSONDecoder().decode(HostProfile.self, from: JSONSerialization.data(withJSONObject: row))
        #expect(restored.connectionType == .ssh)
        #expect(restored.id == host.id)
        #expect(restored.port == 22)
        #expect(restored.remoteDesktop.port == 3389)
        #expect(restored.remoteDesktop.security == .tls)
    }
    @Test func rdpDoesNotRequireSSHPrivateKeyAndPersistsNoPassword() throws {
        var host = HostProfile()
        host.connectionType = .rdp
        host.hostname = "127.0.0.1"
        host.username = "ubuntu"
        host.authentication = .privateKey
        host.remoteDesktop.port = 13389
        try host.validate()
        let restored = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(host))
        #expect(restored == host)
        #expect(restored.endpoint == "ubuntu@127.0.0.1:13389")
        let json = String(decoding: try JSONEncoder().encode(host), as: UTF8.self)
        #expect(!json.contains("password"))
        #expect(!json.contains("secret"))
    }
    @Test(arguments: [0, 65536, -1]) func rejectsBadRDPPort(_ port: Int) {
        var host = HostProfile(); host.connectionType = .rdp; host.hostname = "server"; host.username = "user"
        host.remoteDesktop.port = port
        #expect(throws: MacXError.self) { try host.validate() }
    }
    @Test(arguments: ["server\r\nsecurity:i:0", "server\0", "\n"]) func rejectsControlCharacters(_ value: String) {
        var host = HostProfile(); host.connectionType = .rdp; host.hostname = value; host.username = "user"
        #expect(throws: MacXError.self) { try host.validate() }
    }
    @Test func resolutionAndTunnelMustBeValid() {
        var host = HostProfile(); host.hostname = "server"; host.username = "user"
        host.remoteDesktop.width = 99999
        #expect(throws: MacXError.self) { try host.remoteDesktop.validate(for: host) }
        host.remoteDesktop.width = 1440
        host.remoteDesktop.useSSHTunnel = true
        host.remoteDesktop.localPort = 0
        #expect(throws: MacXError.self) { try host.remoteDesktop.validate(for: host) }
        host.remoteDesktop.localPort = 13389
        #expect(throws: Never.self) { try host.remoteDesktop.validate(for: host) }
        #expect(host.remoteDesktop.address(for: host) == "127.0.0.1")
        #expect(host.remoteDesktop.endpoint(for: host) == "user@127.0.0.1:3389")
        host.remoteDesktop.hostname = "desktop.internal"
        #expect(host.remoteDesktop.address(for: host) == "desktop.internal")
        host.connectionType = .rdp
        #expect(throws: MacXError.self) { try host.validate() }
    }
    @Test func keyboardMapsNavigationAndSeparateModifiers() {
        #expect(RDPKeyboard.scanCode(for: 0) == 0x1e)
        #expect(RDPKeyboard.scanCode(for: 123) == 0x14b)
        #expect(RDPKeyboard.scanCode(for: 59) == 0x1d)
        #expect(RDPKeyboard.scanCode(for: 62) == 0x11d)
        #expect(RDPKeyboard.scanCode(for: 999) == nil)
    }
    @Test func cancelsBeforeStartAndRejectsInput() throws {
        let service = RDPService()
        service.cancel()
        var host = HostProfile(); host.hostname = "127.0.0.1"; host.username = "user"
        #expect(throws: MacXError.self) { try service.start(host: host, password: "") }
        #expect(throws: MacXError.self) { try service.sendText("input") }
        #expect(service.takeFrame() == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACXTERM_RDP_TEST_PORT"] != nil))
    func liveXRDPFrameThroughAuthorizedTunnel() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = try #require(env["MACXTERM_RDP_TEST_PORT"].flatMap(Int.init))
        let expected = try #require(env["MACXTERM_RDP_TEST_FINGERPRINT"])
        var host = HostProfile(); host.connectionType = .rdp; host.hostname = "127.0.0.1"; host.username = "ubuntu"
        host.remoteDesktop.port = port
        let service = RDPService()
        defer { service.cancel() }
        try service.start(host: host, password: "")
        let timeout = Task { try? await Task.sleep(for: .seconds(20)); service.cancel() }
        defer { timeout.cancel() }
        var connected = false
        for await event in service.events {
            switch event {
            case .certificate(let request):
                // Fingerprint supplied by the operator after reading the certificate through verified SSH.
                let normalized = request.fingerprint.lowercased().replacingOccurrences(of: ":", with: "")
                let known = expected.lowercased().replacingOccurrences(of: ":", with: "")
                request.respond(trust: normalized == known)
                #expect(normalized == known)
            case .connected: connected = true
            case .failed(let message): throw MacXError.message(message)
            case .disconnected(let message): throw MacXError.message(message)
            }
            if connected { break }
        }
        #expect(connected)
        var frame: RDPFrame?
        for _ in 0..<200 {
            if let next = service.takeFrame() { frame = next; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let actual = try #require(frame)
        #expect(actual.width == 1440 && actual.height == 900)
        #expect(actual.data.count == actual.stride * actual.height)
        #expect(Set(actual.data).count > 4)
        // Focus changes only: exercises the real server's input path without submitting credentials.
        service.mouse(flags: 0x0800, x: 700, y: 400)
        service.key(scanCode: 0x0f, down: true); service.key(scanCode: 0x0f, down: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!service.isCancelled)
    }
}
