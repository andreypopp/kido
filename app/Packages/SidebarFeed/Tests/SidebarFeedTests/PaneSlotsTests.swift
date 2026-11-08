import Testing
import KoModel
@testable import SidebarFeed

@Test func projectionPathsUseCurrentAncestry() {
    let projection = PaneProjection(makeSnapshot([pane(0, children: [pane(1, children: [pane(2)])])]))
    for (pane, expected) in [(0, [0]), (1, [0, 1]), (2, [0, 1, 2]), (9, [])] {
        #expect(projection.path(to: .init(number: UInt32(pane))).map(\.pane.number) == expected.map(UInt32.init))
    }
    let removed = PaneProjection(makeSnapshot([pane(0), pane(2)]))
    #expect(removed.path(to: .init(number: 2)).map(\.pane.number) == [2])
    #expect(removed.path(to: .init(number: 1)).isEmpty)
}

@Test func independentSlotsRememberEachLevelAndRepairRemoval() {
    let first = pane(0, children: [pane(1, children: [pane(2)]), pane(3)])
    let second = pane(4, window: 0, children: [pane(5)])
    let snapshot = makeSnapshot([group(0, [first, second])])
    var slots = PaneSlots()
    let projection = PaneProjection(snapshot)
    slots.show(PaneID(number: 2), in: projection)
    slots.show(PaneID(number: 5), in: projection)
    #expect(slots.shown(PaneID(number: 0)) == PaneID(number: 2))
    #expect(slots.shown(PaneID(number: 4)) == PaneID(number: 5))
    #expect(slots.selected(in: WindowID(number: 0), fallback: PaneID(number: 0)) == PaneID(number: 5))
    #expect(slots.step(from: PaneID(number: 2), direction: .parent, in: projection) == PaneID(number: 1))
    #expect(slots.step(from: PaneID(number: 1), direction: .parent, in: projection) == PaneID(number: 0))
    #expect(slots.step(from: PaneID(number: 0), direction: .child, in: projection) == PaneID(number: 1))
    #expect(slots.step(from: PaneID(number: 1), direction: .child, in: projection) == PaneID(number: 2))
    slots.reconcile(projection)
    #expect(slots.shown(PaneID(number: 0)) == PaneID(number: 2))
    let removed = PaneProjection(makeSnapshot([group(0, [pane(0, children: [pane(1), pane(3)]), second])]))
    #expect(slots.reconcile(removed, selected: PaneID(number: 2)).map(\.pane) == [PaneID(number: 0)])
    #expect(slots.shown(PaneID(number: 0)) == PaneID(number: 0))
    #expect(slots.shown(PaneID(number: 4)) == PaneID(number: 5))
    #expect(slots.step(from: PaneID(number: 0), direction: .child, in: removed) == PaneID(number: 1))
    #expect(slots.step(from: PaneID(number: 1), direction: .child, in: removed) == nil)
}

@Test func movingAnAncestorAcrossSessionsDoesNotRepairALiveChildToItsOldRoot() {
    let before = PaneProjection(makeSnapshot([pane(0, children: [pane(1, children: [pane(2)])])], client: 2))
    var moved = makeSnapshot([pane(0)])
    moved.sessions.append(SessionNodes(id: .init(number: 1), name: "other", nodes: [pane(1, children: [pane(2)])]))
    moved.client = .init(session: .init(number: 1), window: .init(number: 2), pane: .init(number: 2))
    let projection = PaneProjection(moved)
    var slots = PaneSlots()
    slots.show(.init(number: 2), in: before)
    #expect(slots.reconcile(projection, selected: .init(number: 2)).isEmpty)
    slots.observe(.init(number: 2), in: projection)
    #expect(slots.shown(.init(number: 0)) == PaneID(number: 0))
    #expect(slots.shown(.init(number: 1)) == PaneID(number: 2))
}

@Test func removalRepairSurvivesASeparateSelectedEventUntilNavigationSupersedesIt() {
    let root = PaneID(number: 0), parent = PaneID(number: 1), child = PaneID(number: 2)
    let before = PaneProjection(makeSnapshot([pane(0, children: [pane(1, children: [pane(2)])])], client: 2))
    let after = PaneProjection(makeSnapshot([pane(0, children: [pane(1)])], client: 1))
    var slots = PaneSlots()
    slots.show(child, in: before)
    #expect(slots.reconcile(after, selected: child).map(\.pane) == [root])
    slots.observe(parent, in: after)
    #expect(slots.shown(root) == root)
    #expect(slots.reconcile(after, selected: parent).isEmpty)
    slots.observe(parent, in: after)
    #expect(slots.shown(root) == root)
    slots.show(parent, in: after)
    #expect(slots.shown(root) == parent)
    slots.show(child, in: before)
    #expect(slots.reconcile(after, selected: parent).map(\.pane) == [root])
    slots.observe(root, in: after)
    slots.observe(parent, in: after)
    #expect(slots.shown(root) == parent)
}
