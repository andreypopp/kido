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
    #expect(sidebarWindows(snapshot, session: SessionID(number: 7), surviving: []).ancestors.isEmpty)
}

@Test func orphanedWindowsSurvive() throws {
    let snapshot = try windowsFixture(idle(outcome(1, "failure")))
    let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 1), WindowID(number: 2)])
    #expect(projection.ancestors[WindowID(number: 1)] == WindowID(number: 1))
    #expect(projection.ancestors[WindowID(number: 2)] == WindowID(number: 1))
    let lone = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 2)])
    #expect(lone.ancestors[WindowID(number: 2)] == WindowID(number: 2))
}
