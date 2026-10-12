import AppKit
import SwiftUI

struct NativeFileDropTarget<Content: View>: NSViewRepresentable {
    let content: Content
    let enabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void
    let onError: (any Error) -> Void

    func makeNSView(context: Context) -> FileDropContainer<Content> {
        FileDropContainer(rootView: content)
    }
    func updateNSView(_ view: FileDropContainer<Content>, context: Context) {
        view.hosting.rootView = content
        view.enabled = enabled
        let target = $isTargeted
        view.onTargetChanged = { target.wrappedValue = $0 }
        view.onDrop = onDrop
        view.onError = onError
        view.registerForDraggedTypes([.fileURL])
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileDropContainer<Content>, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

@MainActor final class FileDropContainer<Content: View>: NSView {
    let hosting: NSHostingView<Content>
    var enabled = false
    var onTargetChanged: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onError: ((any Error) -> Void)?

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        hosting.frame = bounds
    }
    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        enabled && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = accepts(sender)
        onTargetChanged?(accepted)
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onTargetChanged?(false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { accepts(sender) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        guard accepts(sender) else { return false }
        do {
            let urls = try LocalFileDrop.fileURLs(from: sender.draggingPasteboard)
            onDrop?(urls)
            return true
        } catch {
            onError?(error)
            return false
        }
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { onTargetChanged?(false) }
}
