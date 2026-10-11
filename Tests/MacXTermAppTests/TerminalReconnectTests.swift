import AppKit
import Foundation
import MacXTermCore
import Testing
@preconcurrency import SwiftTerm
@testable import MacXTermApp

@MainActor @Suite(.serialized) struct TerminalReconnectTests {
    private func makeSession() -> TerminalSession {
        _ = NSApplication.shared
        var host = HostProfile()
        host.name = "Reconnect fixture"
        let session = TerminalSession(host: host)
        session.state = .connected
        return session
    }

    private func view(_ session: TerminalSession) -> TerminalView {
        session.terminalView(theme: "dark", onFocus: {}, dropTarget: nil)
    }

    private func attachInput(_ session: TerminalSession) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        session.writer = continuation
        session.state = .connected
        return stream
    }

    private func collectedInput(_ session: TerminalSession, stream: AsyncStream<Data>) async -> Data {
        session.writer?.finish()
        var result = Data()
        for await bytes in stream { result.append(bytes) }
        return result
    }

    @Test func reconnectDisablesMouseAndFocusReports() async {
        let session = makeSession()
        let terminalView = view(session)
        session.feed(Data("\u{1b}[?1003;1015;1004h".utf8), from: session.connectionGeneration)
        #expect(terminalView.getTerminal().mouseMode == .anyEvent)

        session.prepareForConnection()
        let stream = attachInput(session)
        // Deliver native movement callbacks to this test-owned view only.
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)!
        for _ in 0..<100 { terminalView.mouseMoved(with: event) }
        terminalView.getTerminal().setTerminalFocus(false)
        terminalView.getTerminal().setTerminalFocus(true)

        #expect(terminalView.getTerminal().mouseMode == .off)
        #expect(await collectedInput(session, stream: stream).isEmpty)
    }

    @Test func reconnectClearsOldScreenAndInputModes() async {
        let session = makeSession()
        let terminalView = view(session)
        session.feed(Data("\u{1b}[?1049;2004;1h\u{1b}[?25l\u{1b}[6;18HOLD-TUI".utf8), from: session.connectionGeneration)
        terminalView.selectAll()
        terminalView.setMarkedText("旧的输入", selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        session.prepareForConnection()
        #expect(terminalView.getTerminal().buffer.x == 0)
        #expect(terminalView.getTerminal().buffer.y == 0)
        let stream = attachInput(session)
        session.feed(Data("NEW-SHELL".utf8), from: session.connectionGeneration)
        terminalView.insertText("new-input", replacementRange: NSRange(location: NSNotFound, length: 0))
        let terminal = terminalView.getTerminal()
        #expect(!terminal.isCurrentBufferAlternate)
        #expect(!terminal.applicationCursor)
        #expect(!terminal.bracketedPasteMode)
        #expect(!terminalView.selectionActive)
        #expect(!terminalView.hasMarkedText())
        let screen = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        #expect(!screen.contains("OLD-TUI"))
        #expect(screen.hasPrefix("NEW-SHELL"))
        #expect(await collectedInput(session, stream: stream) == Data("new-input".utf8))
        terminalView.feed(text: "\u{1b}[?1049h")
        #expect(!String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("OLD-TUI"))
    }

    @Test func movingBetweenPanesKeepsRunningApplicationModes() {
        let session = makeSession()
        let original = view(session)
        session.feed(Data("\u{1b}[?1003;1006;1049;2004hRUNNING-TUI".utf8), from: session.connectionGeneration)
        let reused = view(session)
        #expect(original === reused)
        #expect(reused.getTerminal().mouseMode == .anyEvent)
        #expect(reused.getTerminal().isCurrentBufferAlternate)
        #expect(reused.getTerminal().bracketedPasteMode)
        #expect(String(decoding: reused.getTerminal().getBufferAsData(), as: UTF8.self).contains("RUNNING-TUI"))
    }

    @Test func reconnectCancelsIncompleteControlSequences() {
        for suffix in ["\u{1b}[?1003", "\u{1b}]0;unfinished", "\u{1b}P$q", "\u{1b}_Gunfinished"] {
            let session = makeSession()
            let terminalView = view(session)
            session.feed(Data(suffix.utf8), from: session.connectionGeneration)
            session.prepareForConnection()
            session.state = .connected
            session.feed(Data("NEW-SHELL".utf8), from: session.connectionGeneration)
            #expect(terminalView.getTerminal().mouseMode == .off)
            #expect(String(decoding: terminalView.getTerminal().getBufferAsData(), as: UTF8.self).contains("NEW-SHELL"))
        }
    }

    @Test func reconnectRestoresCursorAndDefaultMouseEncoding() async {
        let session = makeSession()
        let terminalView = view(session)
        session.feed(Data("\u{1b}[?1004;1005;1006;1015;1016h\u{1b}[?25l".utf8), from: session.connectionGeneration)
        session.prepareForConnection()
        let stream = attachInput(session)
        // Query modes through the public terminal protocol, including state not exposed by SwiftTerm.
        for mode in [25, 1004, 1005, 1006, 1015, 1016] {
            terminalView.feed(text: "\u{1b}[?\(mode)$p")
        }
        let reports = String(decoding: await collectedInput(session, stream: stream), as: UTF8.self)
        #expect(reports.contains("\u{1b}[?25;1$y"))
        for mode in [1004, 1005, 1006, 1015, 1016] {
            #expect(reports.contains("\u{1b}[?\(mode);2$y"))
        }
        // Applications on the new connection can still opt in to mouse reporting.
        terminalView.feed(text: "\u{1b}[?1003;1006h")
        #expect(terminalView.getTerminal().mouseMode == .anyEvent)
    }

    @Test func reconnectDropsBufferedOutputAndRejectsPreviousConnection() async {
        let session = makeSession()
        let oldGeneration = session.connectionGeneration
        session.feed(Data("\u{1b}[?1003hOLD-PENDING".utf8), from: oldGeneration)
        let oldStream = attachInput(session)
        let oldWriter = session.writer!
        session.prepareForConnection()
        #expect(session.writer == nil)
        if case .terminated = oldWriter.yield(Data("old-input".utf8)) {} else {
            Issue.record("The previous connection still accepts input")
        }
        var oldInput = Data()
        for await bytes in oldStream { oldInput.append(bytes) }
        #expect(oldInput.isEmpty)
        session.state = .connected
        session.feed(Data("\u{1b}[?1003hLATE-OLD-OUTPUT".utf8), from: oldGeneration)
        session.feed(Data("NEW-SHELL".utf8), from: session.connectionGeneration)
        let terminalView = view(session)
        let screen = String(decoding: terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
        #expect(!screen.contains("OLD-PENDING"))
        #expect(!screen.contains("LATE-OLD-OUTPUT"))
        #expect(screen.contains("NEW-SHELL"))
        #expect(terminalView.getTerminal().mouseMode == .off)
    }
}
