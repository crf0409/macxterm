import AppKit
import MacXTermCore
import SwiftUI

struct RemoteDesktopPane: View {
    var session: RemoteDesktopSession
    var onFocus: () -> Void = {}
    var dropTarget: SessionTabDropTarget? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                Text("XRDP / RDP").font(.callout.weight(.medium))
                if session.desktopSize.width > 0 {
                    Text("\(Int(session.desktopSize.width)) × \(Int(session.desktopSize.height))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("发送剪贴板文本") {
                    if let text = NSPasteboard.general.string(forType: .string) { session.sendText(text) }
                }.disabled(session.state != .connected)
                Button("Ctrl + Alt + Delete") { session.sendControlAltDelete() }.disabled(session.state != .connected)
                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } label: { Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right") }
            }.padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
            ZStack {
                RemoteDesktopCanvas(session: session, onFocus: onFocus, dropTarget: dropTarget)
                if session.image == nil {
                    VStack(spacing: 14) {
                        if session.state == .connecting { ProgressView().controlSize(.large) }
                        else { Image(systemName: "desktopcomputer").font(.system(size: 48, weight: .light)) }
                        Text(session.status).multilineTextAlignment(.center).textSelection(.enabled)
                        if session.state != .connecting {
                            Button("重新连接") { session.connect() }.buttonStyle(.borderedProminent)
                            if session.state == .failed {
                                Button("重新输入密码") { session.discardPassword(); session.connect() }
                            }
                        }
                    }.foregroundStyle(.white).padding(30).frame(maxWidth: 520)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
            HStack(spacing: 8) {
                Circle().fill(session.state == .connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(session.status).lineLimit(2).textSelection(.enabled)
                Spacer()
                if session.state != .connecting {
                    Button(session.state == .connected ? "断开桌面" : "重新连接") {
                        if session.state == .connected { session.disconnect() } else { session.connect() }
                    }.buttonStyle(.borderless)
                } else { Button("取消连接") { session.disconnect() }.buttonStyle(.borderless) }
            }.font(.caption).padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
        }
    }
}

private struct RemoteDesktopCanvas: NSViewRepresentable {
    var session: RemoteDesktopSession
    var onFocus: () -> Void
    var dropTarget: SessionTabDropTarget?
    func makeNSView(context: Context) -> DesktopInputView {
        let view = DesktopInputView()
        view.registerForDraggedTypes([.init(sessionTabType), .string])
        session.focusInput = { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
        }
        view.session = session
        view.onFocus = onFocus
        view.dropTarget = dropTarget
        view.setAccessibilityIdentifier("rdp-desktop")
        view.setAccessibilityLabel("RDP 远程桌面，点击后使用键盘和鼠标操作")
        return view
    }
    func updateNSView(_ view: DesktopInputView, context: Context) {
        view.onFocus = onFocus
        view.dropTarget = dropTarget
        view.image = session.image
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: DesktopInputView, coordinator: ()) { view.releaseKeys() }
}

@MainActor private final class DesktopInputView: NSView, @preconcurrency NSTextInputClient {
    weak var session: RemoteDesktopSession?
    var image: CGImage?
    var onFocus: (() -> Void)?
    var dropTarget: SessionTabDropTarget?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropTarget?.update(sender, in: self) ?? [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropTarget?.update(sender, in: self) ?? [] }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropTarget?.hover(nil, bounds.size) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropTarget?.enabled() ?? false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropTarget?.perform(sender, in: self) ?? false }
    private var tracking: NSTrackingArea?
    private var heldKeys = Set<UInt32>()
    private var marked = NSAttributedString(string: "")
    private var focusObserver: (any NSObjectProtocol)?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    private var imageRect: NSRect {
        guard let image else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: NSRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    private func point(_ event: NSEvent) -> (UInt16, UInt16)? {
        guard let image else { return nil }
        let rect = imageRect
        let location = convert(event.locationInWindow, from: nil)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = min(max((location.x - rect.minX) / rect.width * CGFloat(image.width), 0), CGFloat(image.width - 1))
        let y = min(max((location.y - rect.minY) / rect.height * CGFloat(image.height), 0), CGFloat(image.height - 1))
        return (UInt16(x), UInt16(y))
    }
    private func mouse(_ event: NSEvent, flags: UInt16) {
        guard let (x, y) = point(event) else { return }
        session?.mouse(flags: flags, x: x, y: y)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); syncModifiers(event.modifierFlags); mouse(event, flags: 0x9000)
    }
    override func mouseUp(with event: NSEvent) { mouse(event, flags: 0x1000) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); mouse(event, flags: 0xa000) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, flags: 0x2000) }
    override func otherMouseDown(with event: NSEvent) { mouse(event, flags: 0xc000) }
    override func otherMouseUp(with event: NSEvent) { mouse(event, flags: 0x4000) }
    override func mouseMoved(with event: NSEvent) { mouse(event, flags: 0x0800) }
    override func mouseDragged(with event: NSEvent) { mouse(event, flags: 0x0800) }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, flags: 0x0800) }
    override func otherMouseDragged(with event: NSEvent) { mouse(event, flags: 0x0800) }
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let amount = UInt16(min(max(Int(abs(delta) * (event.hasPreciseScrollingDeltas ? 3 : 120)), 1), 255))
        mouse(event, flags: delta > 0 ? 0x0200 | amount : 0x0300 | (0x100 - amount))
    }
    override func keyDown(with event: NSEvent) {
        syncModifiers(event.modifierFlags)
        let shortcuts = !event.modifierFlags.intersection([.control, .option, .command]).isEmpty
        var printable = false
        if let characters = event.characters {
            for scalar in characters.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) && scalar.value < 0xf700 {
                printable = true
            }
        }
        if printable && !shortcuts { interpretKeyEvents([event]) }
        else if let code = RDPKeyboard.scanCode(for: event.keyCode) {
            heldKeys.insert(code); session?.key(scanCode: code, down: true)
        }
    }
    override func keyUp(with event: NSEvent) {
        if let code = RDPKeyboard.scanCode(for: event.keyCode), heldKeys.remove(code) != nil {
            session?.key(scanCode: code, down: false)
        }
        syncModifiers(event.modifierFlags)
    }
    private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
        // Some event sources encode modifiers on the key event without sending flagsChanged.
        for (flag, left, right): (NSEvent.ModifierFlags, UInt32, UInt32) in [
            (.control, 0x1d, 0x11d), (.shift, 0x2a, 0x36), (.option, 0x38, 0x138), (.command, 0x15b, 0x15c)
        ] {
            if flags.contains(flag) {
                if !heldKeys.contains(left) && !heldKeys.contains(right) {
                    heldKeys.insert(left); session?.key(scanCode: left, down: true)
                }
            } else {
                for code in [left, right] where heldKeys.remove(code) != nil {
                    session?.key(scanCode: code, down: false)
                }
            }
        }
    }
    override func flagsChanged(with event: NSEvent) {
        guard let code = RDPKeyboard.scanCode(for: event.keyCode) else { return }
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 54, 55: flag = .command
        case 56, 60: flag = .shift
        case 58, 61: flag = .option
        case 59, 62: flag = .control
        case 57:
            session?.key(scanCode: code, down: true); session?.key(scanCode: code, down: false); return
        default: return
        }
        let down = event.modifierFlags.contains(flag) && !heldKeys.contains(code)
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        session?.key(scanCode: code, down: down)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            releaseKeys()
            if let text = NSPasteboard.general.string(forType: .string) { session?.sendText(text) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    func releaseKeys() {
        for code in heldKeys { session?.key(scanCode: code, down: false) }
        heldKeys.removeAll(); unmarkText()
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
    override func resignFirstResponder() -> Bool { releaseKeys(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        if newWindow == nil { releaseKeys() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseKeys() }
        }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText(); session?.sendText(text)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 20), to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    override func doCommand(by selector: Selector) {}
}
