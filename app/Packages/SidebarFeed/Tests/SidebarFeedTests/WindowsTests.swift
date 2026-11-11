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
    let projection = sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: Set((0...3).map(WindowID.init(number:))))
    #expect(PaneProjection(snapshot).rootWindows[WindowID(number: 2)] == WindowID(number: 0))
    #expect(projection.statuses[WindowID(number: 0)] == .waiting)
    #expect(projection.statuses[WindowID(number: 1)] == nil)
    #expect(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 7), surviving: []).order.isEmpty)
    #expect(sidebarWindows(nil, projection: PaneProjection(nil), session: nil, surviving: []).statuses.isEmpty)
}

@Test func orphanedWindowsSurvive() throws {
    var snapshot = windowsFixture(idle(outcome(1, .failure)), mark: .failed)
    snapshot.sessions[0].nodes = snapshot.sessions[0].nodes[0].children
    let projection = sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 1), WindowID(number: 2)])
    #expect(PaneProjection(snapshot).rootWindows[WindowID(number: 1)] == WindowID(number: 1))
    #expect(PaneProjection(snapshot).rootWindows[WindowID(number: 2)] == WindowID(number: 1))
    #expect(projection.statuses[WindowID(number: 1)] == .error)
    snapshot.sessions[0].nodes = snapshot.sessions[0].nodes[0].children
    let lone = sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 2)])
    #expect(PaneProjection(snapshot).rootWindows[WindowID(number: 2)] == WindowID(number: 2))
    #expect(lone.statuses[WindowID(number: 2)] == .error)
}

@Test func projectionSharesRowStatus() throws {
    let cases: [(KoSchema.AgentState, KoSchema.Mark)] = [(idle(outcome(1, .failure)), .failed), (waiting(), .waiting), (idle(outcome(1, .success)), .done),
                                                 (working(), .running), (idle(), .none_)]
    for (state, mark) in cases {
        let snapshot = windowsFixture(state, mark: mark)
        let projection = sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0)])
        let status = try #require(renderedRows(snapshot).first { $0.target?.window == WindowID(number: 2) }?.status)
        #expect(projection.statuses[WindowID(number: 0)] == SidebarRow.Status.quiet.mergingTabStatus(status))
    }
}

@Test func tabLabelsShareSidebarMessageableRule() throws {
    let cases: [(Lifecycle, Bool)] = [(piAgent(idle()), true),
        (agent(idle()), false),
        (remote(.agent(.init(name: "pi", status: report(idle())))), false),
        (terminal(), false)]
    for (lifecycle, messageable) in cases {
        for title in ["name", "@name"] {
            let snapshot: Snapshot = makeSnapshot([pane(0, title: title, lifecycle: lifecycle)])
            let label = try #require(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0)],
                                                   activePanes: [WindowID(number: 0): PaneID(number: 0)]).labels[WindowID(number: 0)])
            #expect(label.title == title)
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
        let projection = sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: session, surviving: [window], activePanes: [window: pane])
        #expect(projection.labels[window]?.title == "Pane \(pane.number)")
        #expect(rows.first { $0.id == .pane(session, pane) }?.title == "Pane \(pane.number)")
        #expect(projection.labels.count == 1)
    }
    #expect(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: session, surviving: [window], activePanes: [window: PaneID(number: 99)]).labels.isEmpty)
    #expect(sidebarWindows(nil, projection: PaneProjection(nil), session: session, surviving: [window], activePanes: [window: PaneID(number: 0)]).labels.isEmpty)
    #expect(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 9), surviving: [window], activePanes: [window: PaneID(number: 0)]).labels.isEmpty)
    let child = WindowID(number: 2)
    let projection = sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: session, surviving: [window, child], activePanes: [window: PaneID(number: 3), child: PaneID(number: 2)])
    #expect(projection.labels[window]?.title == "Pane 3")
    #expect(projection.labels[child]?.title == "Pane 2")
    #expect(PaneProjection(snapshot).rootWindows[child] == window)
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
            let projection = sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0), WindowID(number: 1)])
            #expect(projection.statuses[WindowID(number: 0)] == expected[max(first, second)])
        }
    }
    let snapshot = windowsFixture(idle(outcome(1, .success)), mark: .done)
    #expect(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == .done)
    #expect(sidebarWindows(markedSeen(snapshot), projection: PaneProjection(markedSeen(snapshot)), session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == .quiet)
}
