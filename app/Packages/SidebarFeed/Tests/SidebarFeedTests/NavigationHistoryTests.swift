import Testing
import KoModel
@testable import SidebarFeed

private func at(_ number: UInt32, window: UInt32 = 0) -> Snapshot.Position {
    Snapshot.Position(session: SessionID(number: 0), window: WindowID(number: window), pane: PaneID(number: number))
}

private func history(_ panes: [UInt32]) -> NavigationHistory {
    var history = NavigationHistory()
    panes.forEach { history.push(at($0)) }
    return history
}

private func live(_ panes: [UInt32]) -> (PaneID) -> Snapshot.Position? {
    { pane in panes.contains(pane.number) ? at(pane.number) : nil }
}

extension NavigationHistory {
    fileprivate mutating func go(_ step: Step) {
        if let target = target(step) { go(step, to: target) }
    }
}

@Test func pushRepeatsDoNothingAndBothEndsDisable() {
    var h = NavigationHistory()
    #expect(!h.canBack && !h.canForward)
    h.push(at(1))
    h.push(at(1))
    #expect(!h.canBack && !h.canForward)
    h.push(at(2))
    #expect(h.canBack && !h.canForward)
    #expect(h.target(.back) == at(1))
    h.go(.back)
    #expect(!h.canBack && h.canForward)
    #expect(h.target(.forward) == at(2))
    h.go(.back)
    #expect(h.current == at(1))
}

@Test func pushAfterBackDropsTheForwardEntries() {
    var h = history([1, 2, 3])
    h.go(.back)
    h.go(.back)
    h.push(at(4))
    #expect(!h.canForward)
    h.go(.back)
    #expect(h.current == at(1))
    h.go(.forward)
    #expect(h.current == at(4))
}

@Test func capacityDropsTheOldest() {
    var h = NavigationHistory()
    for number in 0..<150 { h.push(at(UInt32(number))) }
    var steps = 0
    while h.canBack { h.go(.back); steps += 1 }
    #expect(steps == NavigationHistory.capacity - 1)
    #expect(h.current == at(50))
}

@Test func pruneKeepsTheCursorOnTheCurrentEntry() {
    var before = history([1, 2, 3, 4])
    before.go(.back)
    before.prune(live: live([1, 3, 4]))
    #expect(before.current == at(3))
    #expect(before.target(.back) == at(1))
    #expect(before.target(.forward) == at(4))

    var after = history([1, 2, 3])
    after.go(.back)
    after.go(.back)
    after.prune(live: live([1, 3]))
    #expect(after.current == at(1))
    #expect(after.target(.forward) == at(3))
}

@Test func pruneOfTheCurrentEntryKeepsAGapBetweenSurvivors() {
    var h = history([1, 2, 3])
    h.go(.back)
    h.prune(live: live([1, 3]))
    #expect(h.current == nil)
    #expect(h.target(.back) == at(1))
    #expect(h.target(.forward) == at(3))
    var forward = h
    forward.go(.forward)
    #expect(forward.current == at(3))
    #expect(!forward.canForward)
    h.go(.back)
    #expect(h.current == at(1))
    var pushed = history([1, 2, 3])
    pushed.go(.back)
    pushed.prune(live: live([1, 3]))
    pushed.push(at(5))
    #expect(pushed.target(.back) == at(1))
    #expect(!pushed.canForward)
}

@Test func pruneDropsEverythingAndMergesRepeatsAndFollowsMoves() {
    var empty = history([1, 2])
    empty.prune { _ in nil }
    #expect(empty.isEmpty && !empty.canBack && !empty.canForward)
    empty.push(at(7))
    #expect(empty.current == at(7))

    var merged = history([1, 2, 1])
    merged.prune(live: live([1]))
    #expect(!merged.canBack && !merged.canForward)

    var moved = history([1, 2])
    moved.prune { $0.number == 1 ? at(1, window: 5) : at(2) }
    #expect(moved.target(.back) == at(1, window: 5))
}

@Test func aMoveCommitsOnlyToItsOwnTarget() {
    var h = history([1, 2, 1, 3])
    h.go(.back)
    h.go(.back)
    #expect(h.current == at(2))
    let target = at(1)
    #expect(h.target(.forward) == target)
    h.prune(live: live([1, 3]))
    #expect(h.target(.forward) == target)
    h.go(.forward, to: target)
    #expect(h.target(.forward) == at(3))
    #expect(h.target(.back) == at(1))

    var moved = history([1, 2, 3])
    moved.go(.back)
    moved.go(.back, to: at(3))
    #expect(moved.current == at(2))
    moved.go(.forward, to: at(9))
    #expect(moved.current == at(2))
}
