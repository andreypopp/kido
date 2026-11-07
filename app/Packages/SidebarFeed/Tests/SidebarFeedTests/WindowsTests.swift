import Foundation
import Testing
import KoModel
@testable import SidebarFeed

private func windowsFixture(_ state: KoSchema.AgentState = waiting(), mark: KoSchema.Mark = .waiting, group: Bool = false) -> Snapshot {
    func item(_ n: Int, window: Int? = nil, children: [Node] = [], state: KoSchema.AgentState = idle(), mark: KoSchema.Mark = .none_) -> Node {
        pane(n, window: window, title: "Pane \(n)", lifecycle: agent(state), mark: mark, children: children)
    }
    let parent = item(0, children: [item(1, children: [item(2, state: state, mark: mark)])])
    let nodes: [Node] = group ? [SidebarFeedTests.group(0, [parent, item(3, window: 0)])] : [parent, item(3)]
    return makeSnapshot(nodes, client: 2)
}

@Test(arguments: [false, true]) func projectedWindows(group: Bool) throws {
    let snapshot = windowsFixture(group: group)
    let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: Set((0...3).map(WindowID.init(number:))))
    #expect(projection.ancestors[WindowID(number: 2)] == WindowID(number: 0))
    #expect(projection.statuses[WindowID(number: 0)] == .waiting)
    #expect(projection.statuses[WindowID(number: 1)] == nil)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 7), surviving: []).ancestors.isEmpty)
    #expect(sidebarWindows(nil, session: nil, surviving: []).statuses.isEmpty)
}

@Test func orphanedWindowsSurvive() throws {
    let snapshot = windowsFixture(idle(outcome(1, .failure)), mark: .failed)
    let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 1), WindowID(number: 2)])
    #expect(projection.ancestors[WindowID(number: 1)] == WindowID(number: 1))
    #expect(projection.ancestors[WindowID(number: 2)] == WindowID(number: 1))
    #expect(projection.statuses[WindowID(number: 1)] == .error)
    let lone = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 2)])
    #expect(lone.ancestors[WindowID(number: 2)] == WindowID(number: 2))
    #expect(lone.statuses[WindowID(number: 2)] == .error)
}

@Test func projectionSharesRowStatus() throws {
    let cases: [(KoSchema.AgentState, KoSchema.Mark)] = [(idle(outcome(1, .failure)), .failed), (waiting(), .waiting), (idle(outcome(1, .success)), .done),
                                                 (working(), .running), (idle(), .none_)]
    for (state, mark) in cases {
        let snapshot = windowsFixture(state, mark: mark)
        let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)])
        let status = try #require(sidebarRows(snapshot).first { $0.target?.window == WindowID(number: 2) }?.status)
        #expect(projection.statuses[WindowID(number: 0)] == SidebarRow.Status.quiet.mergingTabStatus(status))
    }
}

@Test func tabLabelsShareSidebarAgentRule() throws {
    let cases: [(Lifecycle, Bool, Bool)] = [(piAgent(idle()), true, true),
        (agent(idle()), true, false),
        (remote(.agent(.init(name: "pi", status: report(idle())))), true, false),
        (terminal(), false, false)]
    for (lifecycle, isAgent, messageable) in cases {
        for title in ["name", "@name"] {
            let snapshot: Snapshot = makeSnapshot([pane(0, title: title, lifecycle: lifecycle)])
            let label = try #require(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)],
                                                   activePanes: [WindowID(number: 0): PaneID(number: 0)]).labels[WindowID(number: 0)])
            #expect(label.title == title)
            #expect(label.agent == isAgent)
            #expect(label.messageable == messageable)
            #expect(sidebarTitle(label.title, messageable: label.messageable) == (messageable && title == "name" ? "@name" : title))
        }
    }
}

@Test func projectedTitlesUseActivePane() throws {
    let snapshot = windowsFixture(group: true)
    let window = WindowID(number: 0), session = SessionID(number: 0)
    let rows = sidebarRows(snapshot)
    for pane in [PaneID(number: 0), PaneID(number: 3)] {
        let projection = sidebarWindows(snapshot, session: session, surviving: [window], activePanes: [window: pane])
        #expect(projection.labels[window]?.title == "Pane \(pane.number)")
        #expect(rows.first { $0.id == .pane(session, pane) }?.title == "Pane \(pane.number)")
        #expect(projection.labels.count == 1)
    }
    #expect(sidebarWindows(snapshot, session: session, surviving: [window], activePanes: [window: PaneID(number: 99)]).labels.isEmpty)
    #expect(sidebarWindows(nil, session: session, surviving: [window], activePanes: [window: PaneID(number: 0)]).labels.isEmpty)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 9), surviving: [window], activePanes: [window: PaneID(number: 0)]).labels.isEmpty)
    let child = WindowID(number: 2)
    let projection = sidebarWindows(snapshot, session: session, surviving: [window, child], activePanes: [window: PaneID(number: 3), child: PaneID(number: 2)])
    #expect(projection.labels[window]?.title == "Pane 3")
    #expect(projection.labels[child]?.title == "Pane 2")
    #expect(projection.ancestors[child] == window)
}

@Test func nestedTabStatusPrecedence() throws {
    let states: [KoSchema.AgentState] = [idle(), idle(outcome(1, .success)), working(), waiting(), idle(outcome(1, .failure))]
    let marks: [KoSchema.Mark] = [.none_, .done, .running, .waiting, .failed]
    let expected: [SidebarRow.Status] = [.quiet, .done, .running, .waiting, .error]
    for first in states.indices {
        for second in states.indices {
            let child = pane(1, lifecycle: agent(states[second]), mark: marks[second])
            let parent = pane(0, lifecycle: agent(states[first]), mark: marks[first], children: [child])
            let snapshot: Snapshot = makeSnapshot([parent])
            let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0), WindowID(number: 1)])
            #expect(projection.statuses[WindowID(number: 0)] == expected[max(first, second)])
        }
    }
    let snapshot = windowsFixture(idle(outcome(1, .success)), mark: .done)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == .done)
    #expect(sidebarWindows(markedSeen(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == .quiet)
}

private struct Step: Sendable, CustomTestStringConvertible {
    let name: String, sessions: [[Node]], from: UInt32, next: Bool, expected: UInt32?
    var surviving: [[UInt32]]? = nil
    var testDescription: String { name }
}

private func adjacent(_ step: Step) -> UInt32? {
    let snapshot = Snapshot(clock: .init(now: 0, local: 0), client: .init(session: SessionID(number: 0), window: WindowID(number: 0), pane: PaneID(number: 0)), serverInstance: ServerInstance("12345/1780000000"),
                            sessions: step.sessions.enumerated().map { SessionNodes(id: SessionID(number: UInt32($0.offset)), name: "s", nodes: $0.element) })
    let surviving = Dictionary(uniqueKeysWithValues: step.sessions.indices.map { index in
        (SessionID(number: UInt32(index)), Set((step.surviving?[index] ?? step.sessions[index].map(\.window.number)).map(WindowID.init(number:))))
    })
    return adjacentWindow(snapshot, surviving: surviving, from: WindowID(number: step.from), next: step.next)?.number
}

private let flat = [pane(0), pane(1), pane(2)]
private let twoSessions = [[pane(0), pane(1)], [pane(2), pane(3)]]
private let mixed = [pane(0, children: [pane(1)]), pane(2), pane(3)]
private let siblings = [pane(0, children: [pane(1), pane(2), pane(3)]), pane(4)]
private let grand = [pane(0, children: [pane(1, children: [pane(2)]), pane(3)]), pane(4)]
private let twoPanes = [group(0, [pane(0, children: [pane(1)]), pane(5, window: 0, children: [pane(2)])]), pane(3)]
private let appearsTwice = [pane(0, children: [pane(1)]), pane(5, window: 0, children: [pane(1)]), pane(3)]
private let hiddenRoot = [pane(0, children: [pane(1)]), pane(2)]
private let chain = [pane(0, children: [pane(1, children: [pane(2)])]), pane(3)]

@Test(arguments: [
    Step(name: "next in a session", sessions: [flat], from: 0, next: true, expected: 1),
    Step(name: "previous in a session", sessions: [flat], from: 1, next: false, expected: 0),
    Step(name: "next wraps", sessions: [flat], from: 2, next: true, expected: 0),
    Step(name: "previous wraps", sessions: [flat], from: 0, next: false, expected: 2),
    Step(name: "next across sessions", sessions: twoSessions, from: 1, next: true, expected: 2),
    Step(name: "previous across sessions", sessions: twoSessions, from: 2, next: false, expected: 1),
    Step(name: "next wraps to the first session", sessions: twoSessions, from: 3, next: true, expected: 0),
    Step(name: "previous wraps to the last session", sessions: twoSessions, from: 0, next: false, expected: 3),
    Step(name: "top-level next skips a child", sessions: [mixed], from: 0, next: true, expected: 2),
    Step(name: "an unparented window is visited", sessions: [mixed], from: 2, next: true, expected: 3),
    Step(name: "previous visits the unparented window", sessions: [mixed], from: 3, next: false, expected: 2),
    Step(name: "previous skips a child", sessions: [mixed], from: 2, next: false, expected: 0),
    Step(name: "a sole root next", sessions: [[pane(0)]], from: 0, next: true, expected: nil),
    Step(name: "a sole root previous", sessions: [[pane(0)]], from: 0, next: false, expected: nil),
    Step(name: "a sole surviving root", sessions: [[pane(0), pane(1)]], from: 0, next: true, expected: nil, surviving: [[0]]),
    Step(name: "an unknown window", sessions: [[pane(0), pane(1)]], from: 9, next: true, expected: nil),
    Step(name: "a window that does not survive", sessions: [[pane(0), pane(1)]], from: 1, next: true, expected: nil, surviving: [[0]]),
    Step(name: "child next", sessions: [siblings], from: 1, next: true, expected: 2),
    Step(name: "child previous", sessions: [siblings], from: 3, next: false, expected: 2),
    Step(name: "previous from the first child", sessions: [siblings], from: 1, next: false, expected: 0),
    Step(name: "next from the last child", sessions: [siblings], from: 3, next: true, expected: 4),
    Step(name: "next from the last child wraps", sessions: [[pane(4), pane(0, children: [pane(1)])]], from: 1, next: true, expected: 4),
    Step(name: "next from the last child, in the next session", sessions: [[pane(0, children: [pane(1)])], [pane(2)]], from: 1, next: true, expected: 2),
    Step(name: "previous from the first grandchild", sessions: [grand], from: 2, next: false, expected: 1),
    Step(name: "next from the last grandchild", sessions: [grand], from: 2, next: true, expected: 4),
    Step(name: "next from a child with a grandchild", sessions: [grand], from: 1, next: true, expected: 3),
    Step(name: "siblings under two panes, forward", sessions: [twoPanes], from: 1, next: true, expected: 2),
    Step(name: "siblings under two panes, backward", sessions: [twoPanes], from: 2, next: false, expected: 1),
    Step(name: "previous from the first sibling under two panes", sessions: [twoPanes], from: 1, next: false, expected: 0),
    Step(name: "a window under two panes keeps its first place", sessions: [appearsTwice], from: 1, next: true, expected: 3),
    Step(name: "a window under two panes has its first parent", sessions: [appearsTwice], from: 1, next: false, expected: 0),
    Step(name: "a surviving descendant of a hidden root is a root", sessions: [hiddenRoot], from: 1, next: true, expected: 2, surviving: [[1, 2]]),
    Step(name: "a hidden root's descendant steps back to the last root", sessions: [hiddenRoot], from: 1, next: false, expected: 2, surviving: [[1, 2]]),
    Step(name: "a nested window whose parent is not listed", sessions: [chain], from: 2, next: false, expected: 1, surviving: [[0, 2, 3]]),
]) private func adjacentWindows(_ step: Step) {
    #expect(adjacent(step) == step.expected)
}

@Test func navigationFollowsAPendingReorder() {
    let snapshot = Snapshot(clock: .init(now: 0, local: 0), client: .init(session: SessionID(number: 0), window: WindowID(number: 0), pane: PaneID(number: 0)), serverInstance: ServerInstance("12345/1780000000"),
                            sessions: [SessionNodes(id: SessionID(number: 0), name: "a", nodes: [pane(0), pane(1), pane(2)]),
                                       SessionNodes(id: SessionID(number: 1), name: "b", nodes: [pane(3), pane(4)])])
    let surviving: [SessionID: Set<WindowID>] = [SessionID(number: 0): [WindowID(number: 0), WindowID(number: 1), WindowID(number: 2)],
                                                 SessionID(number: 1): [WindowID(number: 3), WindowID(number: 4)]]
    var windows = ReorderState()
    _ = windows.submit(.window(SessionID(number: 0), WindowID(number: 2), relativeTo: WindowID(number: 0), .before), to: snapshot)
    #expect(adjacentWindow(windows.project(snapshot), surviving: surviving, from: WindowID(number: 2), next: true)?.number == 0)
    #expect(adjacentWindow(snapshot, surviving: surviving, from: WindowID(number: 2), next: true)?.number == 3)
    var sessions = ReorderState()
    _ = sessions.submit(.session(SessionID(number: 1), relativeTo: SessionID(number: 0), .before), to: snapshot)
    #expect(adjacentWindow(sessions.project(snapshot), surviving: surviving, from: WindowID(number: 4), next: true)?.number == 0)
    #expect(adjacentWindow(sessions.project(snapshot), surviving: surviving, from: WindowID(number: 2), next: true)?.number == 3)
}
