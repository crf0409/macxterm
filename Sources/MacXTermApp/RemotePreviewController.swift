import AppKit
import MacXTermCore
import QuickLookUI

@MainActor final class RemotePreviewController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var preview: QLPreviewView?
    private var document: RemotePreviewDocument?

    func show(_ document: RemotePreviewDocument) throws {
        close()
        let frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = document.name + " · 在线预览（只读）"
        window.identifier = NSUserInterfaceItemIdentifier("remote-document-preview")
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        guard let preview = QLPreviewView(frame: frame, style: .normal) else {
            document.discard(); window.close()
            throw MacXError.message("无法启动系统文档预览，请使用下载功能。")
        }
        preview.autoresizingMask = [.width, .height]
        preview.autostarts = false
        preview.shouldCloseWithWindow = false
        preview.previewItem = document.localURL as NSURL
        window.contentView = preview
        self.document = document; self.preview = preview; self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func close() {
        if let window { window.close() }
        else { document?.discard(); document = nil; preview = nil }
    }
    func windowWillClose(_ notification: Notification) {
        preview?.close(); preview = nil
        document?.discard(); document = nil; window = nil
    }
}
