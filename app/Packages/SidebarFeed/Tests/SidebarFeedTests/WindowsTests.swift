import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private func windowsFixture(_ indicator: String = "waiting", attention: Bool = false, group: Bool = false) throws -> Snapshot {
    func item(_ n: Int, children: [[String: Any]] = [], indicator: String = "idle") -> [String: Any] {
        ["kind": "shell", "id": "%\(n)", "pane": "%\(n)", "window": "@\(n)", "title": [], "tail": [],
         "indicator": ["kind": indicator], "attention": n == 2 && attention, "children": children]
    }
    let parent = item(0, children: [item(1, children: [item(2, indicator: indicator)])])
    var peer = item(3)
    peer["window"] = "@0"
    let nodes: [[String: Any]] = group ? [["kind": "window", "id": "@0", "window": "@0", "name": "Group", "children": [parent, peer]]] : [parent, item(3)]
    return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: [
        "v": 2, "filter": "", "client": ["session": "$0", "window": "@2", "pane": "%2"],
        "sessions": [["id": "$0", "name": "s", "current": true, "nodes": nodes]]]))
}

@Test(arguments: [false, true]) func projectedWindows(group: Bool) throws {
    let snapshot = try windowsFixture(group: group)
    let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: Set((0...3).map(WindowID.init(number:))))
    #expect(projection.ancestors[WindowID(number: 2)] == WindowID(number: 0))
    #expect(projection.statuses[WindowID(number: 0)] == .attention)
    #expect(projection.statuses[WindowID(number: 1)] == nil)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 7), surviving: []).ancestors.isEmpty)
    #expect(sidebarWindows(nil, session: nil, surviving: []).statuses.isEmpty)
}

@Test func orphanedWindowsSurvive() throws {
    let snapshot = try windowsFixture("failed")
    let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 1), WindowID(number: 2)])
    #expect(projection.ancestors[WindowID(number: 1)] == WindowID(number: 1))
    #expect(projection.ancestors[WindowID(number: 2)] == WindowID(number: 1))
    #expect(projection.statuses[WindowID(number: 1)] == .error)
    let lone = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 2)])
    #expect(lone.ancestors[WindowID(number: 2)] == WindowID(number: 2))
    #expect(lone.statuses[WindowID(number: 2)] == .error)
}

@Test(arguments: ["failed", "waiting", "stalled", "running", "compacting", "idle"])
func projectionSharesRowStatus(indicator: String) throws {
    let snapshot = try windowsFixture(indicator)
    let projection = sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)])
    let status = try #require(sidebarRows(snapshot, folded: []).first { $0.target?.window == WindowID(number: 2) }?.status)
    #expect(projection.statuses[WindowID(number: 0)] == (status == .running ? .quiet : status))
    #expect(sidebarWindows(try windowsFixture(indicator, attention: true), session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == (indicator == "failed" ? .error : .attention))
}
