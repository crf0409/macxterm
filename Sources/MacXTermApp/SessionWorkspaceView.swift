import AppKit
import MacXTermCore
import SwiftUI
import UniformTypeIdentifiers

let sessionTabType = UTType(exportedAs: "app.macxterm.session-tab", conformingTo: .data).identifier

struct SessionWorkspaceView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if model.layout.panes.count == 1 {
                SessionGroupView(pane: model.layout.panes[0])
            } else if model.layout.axis == .horizontal {
                HSplitView {
                    ForEach(model.layout.panes) { pane in SessionGroupView(pane: pane) }
                }
            } else {
                VSplitView {
                    ForEach(model.layout.panes) { pane in SessionGroupView(pane: pane) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionGroupView: View {
    @Environment(AppModel.self) private var model
    let pane: WorkspaceLayout.Pane
    @State private var dropZone: PaneDropZone?
    private var focused: Bool { model.layout.focusedPaneID == pane.id }
    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            GeometryReader { geometry in
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if let dropZone {
                            dropPreview(dropZone, size: geometry.size).allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: [sessionTabType, UTType.utf8PlainText.identifier], delegate: PaneDropDelegate(
                        model: model, paneID: pane.id, size: geometry.size, zone: $dropZone))
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .overlay {
            if model.layout.panes.count == 2 && focused {
                Rectangle().strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(focused ? "当前窗格" : "另一窗格")
    }
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pane.tabs, id: \.self) { id in tab(id) }
                Color.clear.frame(width: 30, height: 30)
                    .onDrop(of: [sessionTabType, UTType.utf8PlainText.identifier], delegate: TabDropDelegate(model: model, paneID: pane.id, anchor: nil))
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.background(.bar)
    }
    @ViewBuilder private func tab(_ id: UUID) -> some View {
        let terminal = model.sessions.first { $0.id == id }
        let desktop = model.desktopSessions.first { $0.id == id }
        if let host = terminal?.host ?? desktop?.host {
            let title = host.name.isEmpty ? host.hostname : host.name
            let state = terminal?.state ?? desktop?.state ?? .disconnected
            let selected = pane.selected == id
            let tabView = SessionTabView(
                id: id, title: title, desktop: desktop != nil, state: state,
                selected: selected, focused: focused,
                select: { model.selectSession(id, focusInput: true) }, close: { model.closeSession(id) },
                dragStarted: { model.draggedSessionID = id }, dragEnded: { model.draggedSessionID = nil },
                acceptDrop: { dragged in
                    guard model.draggedSessionID == dragged else { return false }
                    model.layout.move(dragged, to: pane.id, before: id)
                    return true
                })
            tabView.frame(width: tabView.width, height: 32)
            .contextMenu {
                Button("移到右侧分屏") { model.splitSession(id, edge: .trailing) }.disabled(!canSplit(id))
                Button("移到下方分屏") { model.splitSession(id, edge: .bottom) }.disabled(!canSplit(id))
                if model.layout.panes.count == 2 {
                    Button("移到另一窗格") {
                        if let other = model.layout.panes.first(where: { $0.id != pane.id }) {
                            model.layout.move(id, to: other.id)
                        }
                    }
                    Button("合并分屏") { model.layout.merge() }
                }
                Divider()
                Button("关闭标签") { model.closeSession(id) }
            }
            .help("\(host.endpoint) · 拖动调整顺序，拖到工作区边缘分屏")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(desktop == nil ? "终端" : "远程桌面") \(title)")
        }
    }
    private func canSplit(_ id: UUID) -> Bool {
        model.layout.tabCount > 1 && (model.layout.panes.count == 1 || pane.tabs.count > 1)
    }
    @ViewBuilder private var content: some View {
        if let id = pane.selected, let desktop = model.desktopSessions.first(where: { $0.id == id }) {
            RemoteDesktopPane(session: desktop, onFocus: { model.selectSession(id) }, dropTarget: nativeDropTarget).id(id)
        } else if let id = pane.selected, let terminal = model.sessions.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                if terminal.state != .connected {
                    HStack(spacing: 10) {
                        if terminal.state == .connecting { ProgressView().controlSize(.small) }
                        else { Image(systemName: terminal.state == .failed ? "exclamationmark.circle" : "network") }
                        Text(terminal.status).font(.callout).lineLimit(3)
                        Spacer()
                        if terminal.state != .connecting { Button("重新连接") { model.reconnect(terminal) } }
                    }.padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
                }
                TerminalPane(session: terminal, theme: model.configuration.terminalTheme,
                             isFocused: focused, onFocus: { model.selectSession(id) }, dropTarget: nativeDropTarget).id(id)
            }
        }
    }
    private var nativeDropTarget: SessionTabDropTarget {
        SessionTabDropTarget(
            enabled: { model.draggedSessionID != nil },
            hover: { point, size in
                dropZone = point.map { PaneDropZone.at($0, size: size) }
            },
            drop: { id, point, size in
                guard model.draggedSessionID == id else { return false }
                model.draggedSessionID = nil
                dropZone = nil
                if let edge = PaneDropZone.at(point, size: size).edge {
                    return model.layout.split(id, beside: pane.id, edge: edge)
                }
                model.layout.move(id, to: pane.id)
                return true
            })
    }
    private func dropPreview(_ zone: PaneDropZone, size: CGSize) -> some View {
        let rect = zone.previewRect(size)
        return ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.20))
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
            Label(zone.edge == nil ? "移到此窗格" : "松开以分屏", systemImage: zone.edge?.axis == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                .font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
        }.frame(width: max(0, rect.width - 16), height: max(0, rect.height - 16))
            .position(x: rect.midX, y: rect.midY)
    }
}

private enum PaneDropZone: Equatable {
    case center, edge(WorkspaceDropEdge)
    var edge: WorkspaceDropEdge? { if case .edge(let edge) = self { return edge }; return nil }
    static func at(_ point: CGPoint, size: CGSize) -> Self {
        let x = point.x / max(size.width, 1), y = point.y / max(size.height, 1)
        if min(x, 1 - x) < 0.22 && min(x, 1 - x) <= min(y, 1 - y) {
            return .edge(x < 0.5 ? .leading : .trailing)
        }
        if y < 0.22 { return .edge(.top) }
        if y > 0.78 { return .edge(.bottom) }
        return .center
    }
    func previewRect(_ size: CGSize) -> CGRect {
        switch edge {
        case .leading: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .trailing: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case nil: CGRect(origin: .zero, size: size)
        }
    }
}

private struct PaneDropDelegate: DropDelegate {
    let model: AppModel
    let paneID: UUID
    let size: CGSize
    @Binding var zone: PaneDropZone?
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [sessionTabType, UTType.utf8PlainText.identifier]) && model.draggedSessionID != nil
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = PaneDropZone.at(info.location, size: size)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { zone = nil }
    func performDrop(info: DropInfo) -> Bool {
        let destination = PaneDropZone.at(info.location, size: size)
        zone = nil
        return receiveSession(info, model: model) { id in
            if let edge = destination.edge { model.layout.split(id, beside: paneID, edge: edge) }
            else { model.layout.move(id, to: paneID) }
        }
    }
}
private struct TabDropDelegate: DropDelegate {
    let model: AppModel
    let paneID: UUID
    let anchor: UUID?
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [sessionTabType, UTType.utf8PlainText.identifier]) && model.draggedSessionID != nil
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        receiveSession(info, model: model) { id in model.layout.move(id, to: paneID, before: anchor) }
    }
}
@MainActor private func receiveSession(_ info: DropInfo, model: AppModel, action: @escaping @MainActor (UUID) -> Void) -> Bool {
    guard let id = model.draggedSessionID, let provider = info.itemProviders(for: [sessionTabType, UTType.utf8PlainText.identifier]).first else { return false }
    model.draggedSessionID = nil
    provider.loadDataRepresentation(forTypeIdentifier: sessionTabType) { data, _ in
        guard let data, String(data: data, encoding: .utf8) == id.uuidString else { return }
        Task { @MainActor in action(id) }
    }
    return true
}

/// AppKit content views own their native drag destinations. SwiftUI's drop modifier
/// covers the surrounding chrome; these callbacks cover SSH and RDP canvases.
@MainActor final class SessionTabDropTarget {
    let enabled: () -> Bool
    let hover: (CGPoint?, CGSize) -> Void
    let drop: (UUID, CGPoint, CGSize) -> Bool
    init(enabled: @escaping () -> Bool, hover: @escaping (CGPoint?, CGSize) -> Void,
         drop: @escaping (UUID, CGPoint, CGSize) -> Bool) {
        self.enabled = enabled; self.hover = hover; self.drop = drop
    }
    func update(_ sender: any NSDraggingInfo, in view: NSView) -> NSDragOperation {
        guard enabled(), sender.draggingPasteboard.availableType(from: [.init(sessionTabType), .string]) != nil else { return [] }
        let point = location(sender, in: view)
        hover(point, view.bounds.size)
        return .move
    }
    func perform(_ sender: any NSDraggingInfo, in view: NSView) -> Bool {
        defer { hover(nil, view.bounds.size) }
        guard enabled(), let type = sender.draggingPasteboard.availableType(from: [.init(sessionTabType), .string]),
              let text = sender.draggingPasteboard.string(forType: type), let id = UUID(uuidString: text) else { return false }
        return drop(id, location(sender, in: view), view.bounds.size)
    }
    private func location(_ sender: any NSDraggingInfo, in view: NSView) -> CGPoint {
        let point = view.convert(sender.draggingLocation, from: nil)
        return CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
    }
}
