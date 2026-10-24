import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private func windowsFixture(_ state: [Any] = waiting(), group: Bool = false) throws -> Snapshot {
    func item(_ n: Int, children: [[String: Any]] = [], state: [Any] = idle()) -> [String: Any] {
        pane(n, title: "Pane \(n)", lifecycle: agent(state), children: children)
    }
    let parent = item(0, children: [item(1, children: [item(2, state: state)])])
    var peer = item(3)
    peer["window"] = "@0"
    let nodes: [[String: Any]] = group ? [["kind": "window", "id": "@0", "window": "@0", "name": "Group", "children": [parent, peer]]] : [parent, item(3)]
    return try decode(snapshotObject(nodes, client: 2))
}

@Test(arguments: [false, true]) func projectedWindows(group: Bool) throws {
    let snapshot = try windowsFixture(group: group)
    let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: Set((0...3).map(WindowID.init(number:))))
    #expect(projection.ancestors[WindowID(number: 2)] == WindowID(number: 0))
    #expect(projection.statuses[WindowID(number: 0)] == .waiting)
    #expect(projection.statuses[WindowID(number: 1)] == nil)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 7), surviving: []).ancestors.isEmpty)
    #expect(sidebarWindows(nil, session: nil, surviving: []).statuses.isEmpty)
}

@Test func orphanedWindowsSurvive() throws {
    let snapshot = try windowsFixture(idle(outcome(1, "failure")))
    let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 1), WindowID(number: 2)])
    #expect(projection.ancestors[WindowID(number: 1)] == WindowID(number: 1))
    #expect(projection.ancestors[WindowID(number: 2)] == WindowID(number: 1))
    #expect(projection.statuses[WindowID(number: 1)] == .error)
    let lone = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 2)])
    #expect(lone.ancestors[WindowID(number: 2)] == WindowID(number: 2))
    #expect(lone.statuses[WindowID(number: 2)] == .error)
}

@Test func projectionSharesRowStatus() throws {
    for state in [idle(outcome(1, "failure")), waiting(), idle(outcome(1, "success")), working(), idle()] {
        let snapshot = try windowsFixture(state)
        let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)])
        let status = try #require(sidebarRows(snapshot).first { $0.target?.window == WindowID(number: 2) }?.status)
        #expect(projection.statuses[WindowID(number: 0)] == SidebarRow.Status.quiet.mergingTabStatus(status))
    }
}

@Test func tabLabelsShareSidebarAgentRule() throws {
    let cases: [([Any], String?, Bool, Bool)] = [(piAgent(idle()), nil, true, true),
        (["Live", ["Some_agent", ["name": "claude-code", "status": ["since": 1, "msg": null, "state": idle()]]]], nil, true, false),
        (remote(["Remote_agent", ["name": "pi", "status": report(idle())]]), nil, true, false),
        (terminal(), "r-1", false, false), (terminal(), nil, false, false)]
    for (lifecycle, run, isAgent, messageable) in cases {
        for title in ["name", "@name"] {
            let snapshot: Snapshot = try decode(snapshotObject([pane(0, title: title, lifecycle: lifecycle, run: run)]))
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
    let snapshot = try windowsFixture(group: true)
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
    let states: [[Any]] = [idle(), idle(outcome(1, "success")), working(), waiting(), idle(outcome(1, "failure"))]
    let expected: [SidebarRow.Status] = [.quiet, .done, .running, .waiting, .error]
    for first in states.indices {
        for second in states.indices {
            let child = pane(1, lifecycle: agent(states[second]))
            let parent = pane(0, lifecycle: agent(states[first]), children: [child])
            let snapshot: Snapshot = try decode(snapshotObject([parent]))
            let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0), WindowID(number: 1)])
            #expect(projection.statuses[WindowID(number: 0)] == expected[max(first, second)])
        }
    }
    let snapshot = try windowsFixture(idle(outcome(1, "success")))
    var seen = SidebarSeen()
    #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)], seen: seen).statuses[WindowID(number: 0)] == .done)
    seen.observe(snapshot, attended: true)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)], seen: seen).statuses[WindowID(number: 0)] == .quiet)
}
