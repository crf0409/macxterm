import Foundation
import Testing
@testable import MacXTermCore

@Suite("会话分屏与拖动") struct WorkspaceLayoutTests {
    @Test(arguments: [WorkspaceDropEdge.leading, .trailing, .top, .bottom])
    func splitPreservesSessionsAndSelectsMovedTab(_ edge: WorkspaceDropEdge) throws {
        var layout = WorkspaceLayout()
        let first = UUID(), second = UUID(), third = UUID()
        [first, second, third].forEach { layout.insert($0) }
        let original = layout.panes[0].id
        let splitResult1 = layout.split(second, beside: original, edge: edge)
        #expect(splitResult1)
        #expect(layout.panes.count == 2)
        #expect(layout.pane(containing: first)?.id == original)
        #expect(layout.pane(containing: third)?.selected == third)
        #expect(layout.selected == second)
        #expect(layout.axis == edge.axis)
        #expect(layout.panes[edge == .leading || edge == .top ? 0 : 1].tabs == [second])
        assertInvariant(layout, expected: [first, second, third])
    }
    @Test func movingLastTabCollapsesOnlyItsSourcePane() throws {
        var layout = WorkspaceLayout()
        let first = UUID(), second = UUID(), third = UUID()
        [first, second, third].forEach { layout.insert($0) }
        let original = layout.panes[0].id
        layout.split(second, beside: original, edge: .trailing)
        layout.move(second, to: original, before: third)
        #expect(layout.panes.count == 1)
        #expect(layout.panes[0].tabs == [first, second, third])
        #expect(layout.selected == second)
        #expect(layout.focusedPaneID == original)
        assertInvariant(layout, expected: [first, second, third])
    }
    @Test func closingFocusedPaneKeepsOtherSelection() {
        var layout = WorkspaceLayout()
        let first = UUID(), second = UUID(), third = UUID()
        [first, second, third].forEach { layout.insert($0) }
        layout.split(second, beside: layout.panes[0].id, edge: .leading)
        layout.close(second)
        #expect(layout.panes.count == 1)
        #expect(layout.selected == third)
        layout.close(first)
        #expect(layout.selected == third)
        layout.close(third)
        #expect(layout.panes.count == 1)
        #expect(layout.selected == nil)
        assertInvariant(layout, expected: [])
    }
    @Test func independentFocusAndNewConnectionsBelongToFocusedPane() throws {
        var layout = WorkspaceLayout()
        let ssh = UUID(), rdp = UUID(), newSSH = UUID()
        layout.insert(ssh); layout.insert(rdp)
        let original = layout.panes[0].id
        layout.split(rdp, beside: original, edge: .trailing)
        layout.focus(original)
        #expect(layout.selected == ssh)
        layout.insert(newSSH)
        #expect(layout.pane(containing: newSSH)?.id == original)
        #expect(layout.pane(containing: rdp)?.selected == rdp)
        layout.select(rdp)
        #expect(layout.selected == rdp)
        #expect(layout.pane(containing: ssh)?.selected == newSSH)
        assertInvariant(layout, expected: [ssh, rdp, newSSH])
    }
    @Test func reorderMergeAndOrientationKeepSelectionsAndIDs() {
        var layout = WorkspaceLayout()
        let a = UUID(), b = UUID(), c = UUID()
        [a, b, c].forEach { layout.insert($0) }
        let original = layout.panes[0].id
        layout.move(c, to: original, before: a)
        #expect(layout.panes[0].tabs == [c, a, b])
        layout.split(b, beside: original, edge: .bottom)
        layout.setAxis(.horizontal)
        #expect(layout.panes.count == 2)
        layout.merge()
        #expect(layout.panes.count == 1)
        #expect(layout.panes[0].tabs == [c, a, b])
        #expect(layout.selected == b)
        assertInvariant(layout, expected: [a, b, c])
    }
    @Test func rejectsStaleDropsAndSplittingOnlySession() {
        var layout = WorkspaceLayout()
        let a = UUID()
        layout.insert(a)
        var previous = layout
        let splitResult2 = !layout.split(a, beside: layout.panes[0].id, edge: .trailing)
        #expect(splitResult2)
        #expect(layout == previous)
        layout.insert(UUID()); previous = layout
        layout.move(a, to: UUID())
        layout.move(a, to: layout.panes[0].id, before: UUID())
        layout.select(UUID()); layout.close(UUID()); layout.focus(UUID()); layout.insert(a)
        let splitResult3 = !layout.split(UUID(), beside: layout.panes[0].id, edge: .trailing)
        #expect(splitResult3)
        #expect(layout == previous)
    }
    @Test func edgeDropsReuseSecondPaneWithoutCreatingThird() {
        var layout = WorkspaceLayout()
        let a = UUID(), b = UUID(), c = UUID()
        [a, b, c].forEach { layout.insert($0) }
        let original = layout.panes[0].id
        layout.split(b, beside: original, edge: .trailing)
        let splitResult4 = layout.split(c, beside: original, edge: .bottom)
        #expect(splitResult4)
        #expect(layout.panes.count == 2)
        #expect(layout.pane(containing: b)?.id == layout.pane(containing: c)?.id)
        #expect(layout.axis == .vertical)
        let splitResult5 = layout.split(b, beside: original, edge: .leading)
        #expect(splitResult5)
        #expect(layout.panes[0].tabs == [c, b])
        let previous = layout
        let splitResult6 = !layout.split(a, beside: original, edge: .trailing)
        #expect(splitResult6)
        #expect(layout == previous)
        assertInvariant(layout, expected: [a, b, c])
    }
    private func assertInvariant(_ layout: WorkspaceLayout, expected: Set<UUID>) {
        let tabs = layout.panes.flatMap(\.tabs)
        #expect(Set(tabs) == expected)
        #expect(tabs.count == expected.count)
        #expect((1...2).contains(layout.panes.count))
        #expect(layout.panes.contains { $0.id == layout.focusedPaneID })
        #expect(layout.panes.allSatisfy { pane in
            pane.tabs.isEmpty ? pane.selected == nil : pane.selected.map { pane.tabs.contains($0) } == true
        })
        #expect(layout.panes.count == 1 || layout.panes.allSatisfy { !$0.tabs.isEmpty })
    }
}
