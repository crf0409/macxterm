import AppKit
import MacXTermCore
import Observation
@preconcurrency import SwiftTerm
import SwiftUI

enum ConnectionState: String {
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case failed = "连接失败"
}
@MainActor @Observable final class TerminalSession: Identifiable {
    let id = UUID()
    var host: HostProfile
    var state: ConnectionState = .disconnected
    var status = ""
    var title = ""
    var directory = "."
    var entries = [RemoteEntry]()
    var selectedFile: String?
    var fileError = ""
    var loadingFiles = false
    var showHidden = false
    let monitor = ServerMonitorState()
    @ObservationIgnored var service: SSHSessionService?
    @ObservationIgnored var fileService: SFTPService?
    @ObservationIgnored var fileConnection: SSHSessionService?
    @ObservationIgnored var connectionTask: Task<Void, Never>?
    @ObservationIgnored var listingTask: Task<Void, Never>?
    @ObservationIgnored var writerTask: Task<Void, Never>?
    @ObservationIgnored var writer: AsyncStream<Data>.Continuation?
    @ObservationIgnored var listingGeneration = UUID()
    @ObservationIgnored var connectionGeneration = UUID()
    @ObservationIgnored var columns = 100
    @ObservationIgnored var rows = 30
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var sentColumns: Int?
    @ObservationIgnored private var sentRows: Int?
    @ObservationIgnored private var terminal: AccessibleTerminalView?
    @ObservationIgnored private var adapter: TerminalAdapter?
    @ObservationIgnored private var pending = Data()
    init(host: HostProfile) { self.host = host }
    var selectedEntry: RemoteEntry? { entries.first { $0.path == selectedFile } }
    func prepareForConnection() {
        disconnect()
        pending.removeAll()
        title = ""
        terminal?.resetForConnection()
        state = .connecting
    }
    func terminalView(theme: String, onFocus: @escaping () -> Void, dropTarget: SessionTabDropTarget?) -> TerminalView {
        if let terminal {
            terminal.onFocus = onFocus
            terminal.dropTarget = dropTarget
            applyTheme(theme, view: terminal)
            return terminal
        }
        let view = AccessibleTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 650),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.setAccessibilityIdentifier("ssh-terminal")
        view.setAccessibilityLabel("SSH 终端 \(host.name.isEmpty ? host.hostname : host.name)")
        view.onFocus = onFocus
        view.dropTarget = dropTarget
        view.registerForDraggedTypes([.init(sessionTabType), .string])
        let adapter = TerminalAdapter(session: self)
        self.adapter = adapter
        view.terminalDelegate = adapter
        applyTheme(theme, view: view)
        terminal = view
        view.feed(byteArray: Array(pending)[...])
        pending.removeAll()
        return view
    }
    private func applyTheme(_ theme: String, view: TerminalView) {
        let light =
            theme == "light"
            || (theme == "system" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua)
        view.nativeBackgroundColor =
            light
            ? NSColor(calibratedWhite: 0.98, alpha: 1)
            : NSColor(calibratedRed: 0.065, green: 0.076, blue: 0.10, alpha: 1)
        view.nativeForegroundColor = light ? .black : NSColor(calibratedWhite: 0.88, alpha: 1)
        view.caretColor = light ? .systemBlue : .systemTeal
    }
    func focusInput() { if let terminal { terminal.window?.makeFirstResponder(terminal) } }
    /// Serialize PTY resize requests so a transient frame cannot overwrite the final split size.
    func synchronizeTerminalSize(columns: Int? = nil, rows: Int? = nil) {
        if let columns { self.columns = max(1, columns) }
        if let rows { self.rows = max(1, rows) }
        guard resizeTask == nil, state == .connected, let service,
              self.columns != sentColumns || self.rows != sentRows else { return }
        let generation = connectionGeneration
        resizeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.connectionGeneration == generation { self.resizeTask = nil } }
            while !Task.isCancelled && self.connectionGeneration == generation && self.state == .connected {
                await Task.yield()
                guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                let size = (self.columns, self.rows)
                do { try await service.resize(columns: size.0, rows: size.1) }
                catch { return }
                guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                self.sentColumns = size.0; self.sentRows = size.1
                if self.columns == size.0 && self.rows == size.1 { return }
            }
        }
    }
    func feed(_ data: Data, from generation: UUID) {
        guard connectionGeneration == generation, state == .connected else { return }
        if let terminal {
            terminal.feed(byteArray: Array(data)[...])
        } else {
            pending.append(data)
            if pending.count > 2 * 1024 * 1024 { pending.removeFirst(pending.count - 2 * 1024 * 1024) }
        }
    }
    func startWriter(_ service: SSHSessionService) {
        stopWriter()
        let generation = connectionGeneration
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { self.writer = $0 }
        writerTask = Task { [weak self] in
            do {
                for await data in stream {
                    try Task.checkCancellation()
                    guard let self, self.connectionGeneration == generation, self.state == .connected else { return }
                    try await service.writeTerminal(data)
                }
            } catch {
                if !Task.isCancelled, let self, self.connectionGeneration == generation {
                    self.status = error.localizedDescription
                }
            }
        }
    }
    func stopWriter() {
        writer?.finish()
        writer = nil
        writerTask?.cancel()
        writerTask = nil
    }
    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionGeneration = UUID()
        resizeTask?.cancel()
        resizeTask = nil
        sentColumns = nil; sentRows = nil
        listingTask?.cancel()
        listingGeneration = UUID()
        loadingFiles = false
        stopWriter()
        service?.cancel()
        fileConnection?.cancel()
        service = nil
        fileService = nil
        fileConnection = nil
        state = .disconnected
        status = "连接已关闭"
    }
}
@MainActor private final class AccessibleTerminalView: TerminalView {
    var onFocus: (() -> Void)?
    var dropTarget: SessionTabDropTarget?
    func resetForConnection() {
        inputContext?.discardMarkedText()
        unmarkText()
        selectNone()
        // Cancel an unfinished escape sequence before RIS. SwiftTerm's RIS retains
        // the alternate buffer, focus reporting, mouse encoding and cursor visibility.
        // Clear both screens and home the cursor locally with the old writer detached.
        feed(text: "\u{18}\u{1b}c\u{1b}[?1049h\u{1b}[?1049l\u{1b}[?1004;1005;1006;1015;1016l\u{1b}[?25h\u{1b}[H")
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropTarget?.update(sender, in: self) ?? [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropTarget?.update(sender, in: self) ?? [] }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropTarget?.hover(nil, bounds.size) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropTarget?.enabled() ?? false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropTarget?.perform(sender, in: self) ?? false }
    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeFirstResponder(self)
        paste(self) // SwiftTerm retains bracketed-paste handling and UTF-8 input.
    }
    override func rightMouseUp(with event: NSEvent) {} // Do not forward an unmatched release to mouse-reporting apps.
    override func rightMouseDragged(with event: NSEvent) {}
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? {
        String(decoding: getTerminal().getBufferAsData().suffix(65536), as: UTF8.self)
    }
    override func accessibilityPerformPress() -> Bool {
        onFocus?()
        return window?.makeFirstResponder(self) ?? false
    }
}
@MainActor private final class TerminalAdapter: NSObject, @preconcurrency TerminalViewDelegate {
    weak var session: TerminalSession?
    init(session: TerminalSession) { self.session = session }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.synchronizeTerminalSize(columns: newCols, rows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) { session?.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if session?.state == .connected { session?.writer?.yield(Data(data)) }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardRead(source: TerminalView) -> Data? { nil }
}
struct TerminalPane: NSViewRepresentable {
    let session: TerminalSession
    let theme: String
    let isFocused: Bool
    let onFocus: () -> Void
    let dropTarget: SessionTabDropTarget?
    final class Coordinator { var wasFocused = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TerminalView {
        let view = session.terminalView(theme: theme, onFocus: onFocus, dropTarget: dropTarget)
        updateFocus(view, context: context)
        synchronizeSizeAfterLayout(view)
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {
        _ = session.terminalView(theme: theme, onFocus: onFocus, dropTarget: dropTarget)
        updateFocus(view, context: context)
        synchronizeSizeAfterLayout(view)
    }
    private func synchronizeSizeAfterLayout(_ view: TerminalView) {
        DispatchQueue.main.async { [weak view, weak session] in
            guard let view, view.window != nil, let session else { return }
            view.setFrameSize(view.frame.size)
            session.synchronizeTerminalSize(columns: view.getTerminal().cols, rows: view.getTerminal().rows)
        }
    }
    private func updateFocus(_ view: TerminalView, context: Context) {
        if isFocused && !context.coordinator.wasFocused {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
        context.coordinator.wasFocused = isFocused
    }
}
