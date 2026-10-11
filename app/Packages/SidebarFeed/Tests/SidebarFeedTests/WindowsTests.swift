import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private func windowsFixture(_ state: [Any] = blocked(), group: Bool = false) throws -> Snapshot {
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
    for state in [idle(outcome(1, "failure")), blocked(), ["Stalled"], idle(outcome(1, "success")), working(), idle()] {
        let snapshot = try windowsFixture(state)
        let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)])
        let status = try #require(sidebarRows(snapshot).first { $0.target?.window == WindowID(number: 2) }?.status)
        #expect(projection.statuses[WindowID(number: 0)] == status.tabStatus)
    }
}

@Test func projectedTitlesUseActivePane() throws {
    let snapshot = try windowsFixture(group: true)
    let window = WindowID(number: 0), session = SessionID(number: 0)
    let rows = sidebarRows(snapshot)
    for pane in [PaneID(number: 0), PaneID(number: 3)] {
        let projection = sidebarWindows(snapshot, session: session, surviving: [window], activePanes: [window: pane])
        #expect(projection.titles[window] == "Pane \(pane.number)")
        #expect(rows.first { $0.id == .pane(session, pane) }?.title == "@Pane \(pane.number)")
        #expect(projection.titles.count == 1)
    }
    #expect(sidebarWindows(snapshot, session: session, surviving: [window], activePanes: [window: PaneID(number: 99)]).titles.isEmpty)
    #expect(sidebarWindows(nil, session: session, surviving: [window], activePanes: [window: PaneID(number: 0)]).titles.isEmpty)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 9), surviving: [window], activePanes: [window: PaneID(number: 0)]).titles.isEmpty)
    let child = WindowID(number: 2)
    let projection = sidebarWindows(snapshot, session: session, surviving: [window, child], activePanes: [window: PaneID(number: 3), child: PaneID(number: 2)])
    #expect(projection.titles[window] == "Pane 3")
    #expect(projection.titles[child] == "Pane 2")
    #expect(projection.ancestors[child] == window)
}
