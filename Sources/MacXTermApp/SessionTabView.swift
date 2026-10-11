import AppKit
import SwiftUI

/// Native tracking starts the drag synchronously, before the mouse-up event.
struct SessionTabView: NSViewRepresentable {
    let id: UUID
    let title: String
    let desktop: Bool
    let state: ConnectionState
    let selected: Bool
    let focused: Bool
    let select: () -> Void
    let close: () -> Void
    let dragStarted: () -> Void
    let dragEnded: () -> Void
    let acceptDrop: (UUID) -> Bool
    var width: CGFloat {
        min(240, max(96, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + (desktop ? 76 : 58)))
    }
    func makeNSView(context: Context) -> NativeSessionTab { NativeSessionTab() }
    func updateNSView(_ view: NativeSessionTab, context: Context) { view.configuration = self }
}

@MainActor final class NativeSessionTab: NSView, NSDraggingSource {
    var configuration: SessionTabView? {
        didSet {
            needsDisplay = true
            setAccessibilityLabel("\(configuration?.desktop == true ? "远程桌面" : "终端") \(configuration?.title ?? "")")
            closeButton.setAccessibilityLabel("关闭标签 \(configuration?.title ?? "")")
        }
    }
    private let closeButton = NSButton()
    private var hovered = false
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? { [closeButton] }
    override func accessibilityPerformPress() -> Bool { configuration?.select(); return true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.init(sessionTabType), .string])
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.target = self; closeButton.action = #selector(closeTab)
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.width - 26, y: 8, width: 14, height: 16)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return closeButton.frame.contains(local) ? closeButton : self
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let configuration else { return }
        if configuration.selected || hovered {
            let color = hovered ? NSColor.controlAccentColor.withAlphaComponent(0.25)
                : configuration.focused ? NSColor.controlAccentColor.withAlphaComponent(0.13) : NSColor.labelColor.withAlphaComponent(0.09)
            color.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let dot = configuration.state == .connected ? NSColor.systemGreen : configuration.state == .connecting ? .systemOrange : .tertiaryLabelColor
        dot.setFill(); NSBezierPath(ovalIn: NSRect(x: 12, y: 13, width: 6, height: 6)).fill()
        var x: CGFloat = 26
        if configuration.desktop {
            NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)?.draw(in: NSRect(x: x, y: 9, width: 14, height: 14))
            x += 20
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (configuration.title as NSString).draw(in: NSRect(x: x, y: 8, width: max(0, bounds.width - x - 30), height: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: configuration.selected ? .semibold : .regular),
                             .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    }
    @objc private func closeTab() { configuration?.close() }
    override func mouseDown(with event: NSEvent) {
        guard let window, let configuration else { return }
        let origin = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { configuration.select(); return }
            guard hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y) > 4 else { continue }
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(configuration.id.uuidString, forType: .init(sessionTabType))
            pasteboard.setString(configuration.id.uuidString, forType: .string)
            let item = NSDraggingItem(pasteboardWriter: pasteboard)
            let image = NSImage(size: bounds.size)
            if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: rep); image.addRepresentation(rep)
            }
            item.setDraggingFrame(bounds, contents: image)
            configuration.dragStarted()
            beginDraggingSession(with: [item], event: next, source: self)
            return
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        configuration?.dragEnded()
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .move }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hovered = true; needsDisplay = true
        return .move
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { hovered = false; needsDisplay = true }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        hovered = false; needsDisplay = true
        guard let type = sender.draggingPasteboard.availableType(from: [.init(sessionTabType), .string]),
              let text = sender.draggingPasteboard.string(forType: type), let id = UUID(uuidString: text) else { return false }
        return configuration?.acceptDrop(id) ?? false
    }
}
