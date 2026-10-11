import Foundation

public enum WorkspaceSplitAxis: Sendable, Equatable { case horizontal, vertical }
public enum WorkspaceDropEdge: Sendable, Equatable {
    case leading, trailing, top, bottom
    public var axis: WorkspaceSplitAxis {
        self == .leading || self == .trailing ? .horizontal : .vertical
    }
    var insertsBefore: Bool { self == .leading || self == .top }
}

/// Session ownership and selection are independent of the live SSH/RDP connection.
/// Every session belongs to exactly one pane; empty secondary panes collapse.
public struct WorkspaceLayout: Sendable, Equatable {
    public struct Pane: Identifiable, Sendable, Equatable {
        public let id: UUID
        public fileprivate(set) var tabs: [UUID]
        public fileprivate(set) var selected: UUID?
        fileprivate init(tabs: [UUID] = [], selected: UUID? = nil) {
            id = UUID(); self.tabs = tabs; self.selected = selected
        }
    }
    public private(set) var panes: [Pane]
    public private(set) var focusedPaneID: UUID
    public private(set) var axis: WorkspaceSplitAxis = .horizontal
    public init() {
        let pane = Pane()
        panes = [pane]; focusedPaneID = pane.id
    }
    public var selected: UUID? { panes.first { $0.id == focusedPaneID }?.selected }
    public var tabCount: Int { panes.reduce(0) { $0 + $1.tabs.count } }
    public func pane(containing tab: UUID) -> Pane? { panes.first { $0.tabs.contains(tab) } }
    public mutating func insert(_ tab: UUID) {
        guard pane(containing: tab) == nil,
              let index = panes.firstIndex(where: { $0.id == focusedPaneID }) else { return }
        panes[index].tabs.append(tab); panes[index].selected = tab
    }
    public mutating func focus(_ paneID: UUID) {
        if panes.contains(where: { $0.id == paneID }) { focusedPaneID = paneID }
    }
    public mutating func select(_ tab: UUID) {
        guard let index = panes.firstIndex(where: { $0.tabs.contains(tab) }) else { return }
        panes[index].selected = tab; focusedPaneID = panes[index].id
    }
    public mutating func close(_ tab: UUID) {
        guard let index = panes.firstIndex(where: { $0.tabs.contains(tab) }) else { return }
        remove(tab, at: index)
        collapseEmptyPane()
    }
    /// Move to another pane or reorder before a tab without duplicating a session.
    public mutating func move(_ tab: UUID, to paneID: UUID, before anchor: UUID? = nil) {
        guard tab != anchor, let source = panes.firstIndex(where: { $0.tabs.contains(tab) }),
              let target = panes.firstIndex(where: { $0.id == paneID }),
              anchor == nil || panes[target].tabs.contains(anchor!) else { return }
        remove(tab, at: source)
        let position = anchor.flatMap { panes[target].tabs.firstIndex(of: $0) } ?? panes[target].tabs.endIndex
        panes[target].tabs.insert(tab, at: position)
        panes[target].selected = tab; focusedPaneID = paneID
        collapseEmptyPane()
    }
    /// At most two panes. With two panes an edge drop moves into/repositions the other pane.
    @discardableResult public mutating func split(_ tab: UUID, beside paneID: UUID, edge: WorkspaceDropEdge) -> Bool {
        guard let source = panes.firstIndex(where: { $0.tabs.contains(tab) }),
              let target = panes.firstIndex(where: { $0.id == paneID }), tabCount > 1 else { return false }
        let otherID: UUID
        if panes.count == 1 {
            remove(tab, at: source)
            let newPane = Pane(tabs: [tab], selected: tab)
            panes.append(newPane); otherID = newPane.id
        } else {
            let other = 1 - target
            // Splitting the only tab off its own pane would leave no session beside it.
            guard source != target || panes[source].tabs.count > 1 else { return false }
            otherID = panes[other].id
            move(tab, to: otherID)
        }
        axis = edge.axis
        if let other = panes.firstIndex(where: { $0.id == otherID }) {
            let movedPane = panes.remove(at: other)
            panes.insert(movedPane, at: edge.insertsBefore ? 0 : panes.endIndex)
        }
        focusedPaneID = otherID
        return true
    }
    public mutating func setAxis(_ axis: WorkspaceSplitAxis) { self.axis = axis }
    public mutating func merge() {
        guard panes.count == 2 else { return }
        let selection = selected
        let tabs = panes.flatMap(\.tabs)
        var survivor = panes.first { $0.id == focusedPaneID }!
        survivor.tabs = tabs; survivor.selected = selection
        panes = [survivor]
    }
    private mutating func remove(_ tab: UUID, at index: Int) {
        guard let position = panes[index].tabs.firstIndex(of: tab) else { return }
        panes[index].tabs.remove(at: position)
        if panes[index].selected == tab {
            panes[index].selected = panes[index].tabs.isEmpty ? nil
                : panes[index].tabs[min(position, panes[index].tabs.count - 1)]
        }
    }
    private mutating func collapseEmptyPane() {
        if panes.count == 2, let empty = panes.firstIndex(where: { $0.tabs.isEmpty }) {
            let removed = panes.remove(at: empty)
            if focusedPaneID == removed.id { focusedPaneID = panes[0].id }
        }
    }
}
