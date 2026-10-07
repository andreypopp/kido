import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private func fixture(filter: String = "", client: Int = 0, sessions: [Int] = [0], grouped: Bool = false, descendants: Bool = false) throws -> Snapshot {
    func item(_ id: Int, _ window: Int, run: String? = nil, started: Double? = nil, tail: String = "", children: [[String: Any]] = []) -> [String: Any] {
        ["kind": run == "bash" || run == "stream" ? "run" : "agent", "id": "%\(id)", "pane": "%\(id)", "window": "@\(window)",
         "run": run as Any? ?? NSNull(), "started": started as Any? ?? NSNull(), "indicator": ["kind": "running"],
         "title": [["text": "pane-\(id)", "role": "plain"]], "tail": tail.isEmpty ? [] : [["text": tail, "role": "dim"]],
         "attention": id == 2, "children": children]
    }
    let children = [item(1, 1, run: "agent", started: 100, tail: "working", children: [item(2, 2, run: "stream", started: 100)]),
                    item(3, 3, run: "bash", started: 100), item(4, 4, run: "bash")]
    let nodes: [[String: Any]] = grouped
        ? [["kind": "window", "id": "@0", "window": "@0", "name": "group", "children": descendants
            ? [item(0, 0, children: [item(1, 1, tail: "child", children: [item(2, 2)])]),
               item(5, 0, tail: "parent", children: [item(3, 3)]), item(6, 0)]
            : [item(0, 0), item(5, 0)]]]
        : [item(0, 0, started: 100), item(5, 5, children: children)]
    let object: [String: Any] = ["v": 2, "client": ["session": "$0", "window": "@\(client)", "pane": "%\(client)"],
                               "filter": filter, "error": NSNull(), "sessions": sessions.map {
                                   ["id": "$\($0)", "name": "session-\($0)", "current": $0 == 0, "nodes": nodes]
                               }]
    return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func independentWindowsAndExactSpacing() throws {
    let rows = sidebarRows(try fixture(client: 5))
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map(\.indent) == [0, 0, 1, 2, 1, 1])
    #expect(rows.filter { $0.kind == .divider }.map(\.indent) == [0, 1, 2, 1, 1])
    #expect(rows.filter { $0.kind == .divider }.map(\.height) == [7, 7, 7, 7, 7])
    #expect(rows.map(\.height) == [29, 32, 3, 7, 32, 3, 7, 48, 3, 7, 32, 3, 3, 7, 32, 3, 7, 32, 3, 3, 16])
    #expect(rows.allSatisfy { $0.height > 0 })
    #expect(panes.map(\.active) == [false, true, false, false, false, false])
    #expect(panes.allSatisfy { $0.position == .single })
    let child = sidebarRows(try fixture(client: 2)).filter { $0.target != nil }
    #expect(child.filter(\.active).map(\.title) == ["pane-2"])
}

@Test func groupedPanesStayContiguous() throws {
    let rows = sidebarRows(try fixture(grouped: true))
    #expect(rows.map(\.height) == [29, 32, 32, 3, 16])
    #expect(rows.filter { $0.kind == .divider }.isEmpty)
    #expect(rows.filter { $0.target != nil }.map(\.position) == [.top, .bottom])
    #expect(rows.allSatisfy { $0.height > 0 })
}

@Test func everyPanesChildrenFollowEntireGroup() throws {
    let snapshot = try fixture(grouped: true, descendants: true)
    let rows = sidebarRows(snapshot)
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map { $0.target!.pane } == [0, 5, 6, 1, 2, 3].map { PaneID(number: UInt32($0)) })
    #expect(panes.map(\.position) == [.top, .middle, .bottom, .single, .single, .single])
    #expect(panes.map(\.height) == [32, 48, 32, 48, 32, 32])
    #expect(panes.map(\.indent) == [0, 0, 0, 1, 2, 1])
    #expect(panes.map(\.active) == [true, true, true, false, false, false])
    #expect(rows.filter { $0.kind == .divider }.map(\.indent) == [1, 2, 1])
    #expect(sidebarTarget(snapshot, attention: 1) == panes[4].target)
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test func filteredSessionsKeepIdentity() throws {
    let rows = sidebarRows(try fixture(sessions: [0, 1]))
    let filtered = sidebarRows(try fixture(filter: "session", sessions: [0]))
    #expect(filtered == rows.filter { $0.id.session == SessionID(number: 0) })
    #expect(sidebarRows(try fixture(filter: "absent", sessions: [])).isEmpty)
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(rows.filter { $0.focused }.count == 1)
}

@Test func paneTargetsAndTimePolicy() throws {
    let panes = sidebarRows(try fixture()).filter { $0.target != nil }
    #expect(panes.map(\.started) == [nil, nil, Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 100), nil])
    #expect(panes.allSatisfy { if case .pane = $0.kind { return true }; return false })
    #expect(panes.first { $0.title == "@pane-1" }?.tail == "working")
    #expect(panes.map(\.height) == [32, 32, 48, 32, 32, 32])
}

@Test(arguments: [(0, "0s"), (59, "59s"), (60, "1m00s"), (3599, "59m59s"), (3600, "1h00m"), (7260, "2h01m"), (-1, "0s")])
func elapsed(_ seconds: Int, _ expected: String) {
    #expect(sidebarElapsed(started: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: Double(100 + seconds))) == expected)
}

@Test(arguments: [("agent", "null", "Ada", "@Ada", SidebarRow.Icon.agent),
                  ("agent", "null", "@Ada", "@Ada", .agent),
                  ("run", "\"agent\"", "Ada", "@Ada", .agent),
                  ("shell", "null", "zsh", "zsh", .terminal),
                  ("ssh", "null", "host", "host", .terminal),
                  ("run", "\"bash\"", "job", "job", .terminal),
                  ("run", "\"stream\"", "monitor", "monitor", .terminal)])
func iconsAndDisplayOnlyPrefix(_ kind: String, _ run: String, _ title: String, _ expected: String, _ icon: SidebarRow.Icon) throws {
    let json = """
    {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},"filter":"","sessions":[
      {"id":"$0","name":"main","current":true,"nodes":[
        {"kind":"\(kind)","run":\(run),"id":"%0","pane":"%0","window":"@0",
         "title":[{"text":"\(title)","role":"plain"}],"tail":[],"attention":false,"children":[]}]}]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
    #expect(row.title == expected)
    #expect(row.icon == icon)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)],
                           activePanes: [WindowID(number: 0): PaneID(number: 0)]).titles[WindowID(number: 0)] == title)
}

@Test func originalIndicatorDescriptions() throws {
    let indicators: [(String, String?, SidebarRow.Status, String)] = [
        ("waiting", nil, .attention, "waiting"), ("stalled", nil, .stalled, "stalled"),
        ("done", nil, .done, "done"), ("idle", nil, .quiet, "idle"),
        ("gone", "completed", .done, "gone, completed")
    ]
    for (kind, outcome, status, description) in indicators {
        let data = """
        {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},"filter":"","sessions":[
          {"id":"$0","name":"main","current":true,"nodes":[
            {"kind":"agent","id":"%0","pane":"%0","window":"@0","indicator":{"kind":"\(kind)","outcome":\(outcome.map { "\"\($0)\"" } ?? "null")},
             "title":[],"tail":[],"attention":true,"children":[]}]}]}
        """
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(data.utf8))
        let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
        #expect(row.status == status)
        #expect(row.indicatorDescription == description)
        #expect(row.attention)
        #expect(sidebarTarget(snapshot, attention: 1) == row.target)
    }
}

@Test func navigationOrderWrappingAndFallback() throws {
    let snapshot = try fixture(sessions: [0, 1])
    let panes = sidebarRows(snapshot).compactMap(\.target)
    #expect(panes.map(\.pane) == [0, 5, 1, 2, 3, 4, 0, 5, 1, 2, 3, 4].map { PaneID(number: UInt32($0)) })
    #expect(sidebarTarget(snapshot) == panes.first)
    #expect(sidebarTarget(snapshot, attention: 1) == panes[3])
    #expect(sidebarTarget(snapshot, attention: -1) == panes[9])
    #expect(sidebarTarget(snapshot, selected: panes[9], attention: 1) == panes[3])
    #expect(sidebarTarget(snapshot, selected: panes[3], attention: -1) == panes[9])
    #expect(sidebarTarget(snapshot, selected: panes[0], attention: 1) == panes[3])
    #expect(sidebarTarget(try fixture(sessions: [])) == nil)
    #expect(sidebarTarget(try fixture(sessions: []), attention: 1) == nil)
}
