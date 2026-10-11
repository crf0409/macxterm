import AppKit
import Foundation
import MacXTermCore
import Testing
@testable import MacXTermApp

@MainActor @Suite("终端重连与真实 OpenSSH", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MACXTERM_INTEGRATION"] == "1"))
struct TerminalReconnectIntegrationTests {
    private func connect(_ session: TerminalSession) async throws -> SSHSessionService {
        session.prepareForConnection()
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACXTERM_FIXTURE"]!)
        let service = SSHSessionService()
        let identity = try await service.handshake(host: session.host)
        let key = try String(contentsOf: fixture.appendingPathComponent("host_key.pub"), encoding: .utf8)
        #expect(identity.key == Data(base64Encoded: String(key.split(separator: " ")[1])))
        try await service.authenticate(host: session.host,
            credentials: .init(secret: "", keyURL: fixture.appendingPathComponent("client_key")))
        try await service.openTerminal(columns: session.columns, rows: session.rows)
        session.service = service
        session.state = .connected
        session.startWriter(service)
        return service
    }

    private func readUntil(_ marker: String, service: SSHSessionService,
        session: TerminalSession) async throws -> String {
        let generation = session.connectionGeneration
        let deadline = ContinuousClock.now + .seconds(5)
        var output = Data()
        while ContinuousClock.now < deadline {
            let (data, eof) = try await service.readTerminal()
            session.feed(data, from: generation)
            output.append(data)
            let text = String(decoding: output, as: UTF8.self)
            if text.contains(marker) { return text }
            if eof { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MacXError.message("SSH fixture did not emit the expected marker: \(marker)")
    }

    @Test func reconnectAfterMouseTrackingSendsNoUnsolicitedPTYInput() async throws {
        _ = NSApplication.shared
        var host = HostProfile()
        host.hostname = "127.0.0.1"
        host.port = Int(ProcessInfo.processInfo.environment["MACXTERM_SSH_PORT"] ?? "22337")!
        host.username = ProcessInfo.processInfo.environment["MACXTERM_SSH_USER"] ?? NSUserName()
        host.authentication = .privateKey
        let session = TerminalSession(host: host)
        defer { session.disconnect() }
        let terminalView = session.terminalView(theme: "dark", onFocus: {}, dropTarget: nil)
        let first = try await connect(session)
        terminalView.send(txt: "printf '\\033[?1003h\\033[?1015h\\033[?1004h\\033[?1049h\\033[?2004h\\033[?25lOLD_TUI_READY'; sleep 30\r")
        _ = try await readUntil("\u{1b}[?25lOLD_TUI_READY", service: first, session: session)
        #expect(terminalView.getTerminal().mouseMode == .anyEvent)

        let second = try await connect(session)
        // Measure bytes received by the actual remote PTY while moving the mouse
        // and changing focus. Split the marker so shell echo cannot satisfy readUntil.
        terminalView.send(txt: "python3 -c 'import os,select,termios,tty; old=termios.tcgetattr(0); tty.setraw(0); print(\"INPUT\"+\"_READY\",flush=True); ready=select.select([0],[],[],1)[0]; data=os.read(0,4096) if ready else b\"\"; termios.tcsetattr(0,termios.TCSANOW,old); print(\"UNSOLICITED_BYTES=\"+str(len(data)),flush=True)'\r")
        _ = try await readUntil("INPUT_READY", service: second, session: session)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)!
        for _ in 0..<100 { terminalView.mouseMoved(with: event) }
        terminalView.getTerminal().setTerminalFocus(false)
        terminalView.getTerminal().setTerminalFocus(true)
        let output = try await readUntil("UNSOLICITED_BYTES=", service: second, session: session)
        #expect(output.contains("UNSOLICITED_BYTES=0"))
        #expect(terminalView.getTerminal().mouseMode == .off)
        terminalView.insertText("printf '\\116\\117\\122\\115\\101\\114\\137\\111\\116\\120\\125\\124\\n'\r",
            replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = try await readUntil("NORMAL_INPUT", service: second, session: session)
    }
}
