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

@Test func nestedWindowsAndExactSpacing() throws {
    let rows = sidebarRows(try fixture(client: 5))
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map(\.indent) == [0, 0, 1, 2, 1, 1])
    #expect(rows.filter { $0.kind == .divider }.map(\.indent) == [0])
    #expect(rows.filter { $0.kind == .divider }.map(\.height) == [7])
    #expect(rows.map(\.height) == [29, 32, 3, 7, 32, 40, 28, 3, 3, 3, 28, 3, 28, 3, 3, 3, 16])
    #expect(rows.allSatisfy { $0.height > 0 })
    #expect(panes.map(\.active) == [false, true, true, true, true, true])
    #expect(panes.allSatisfy { !$0.multiPane })
    #expect(panes.dropFirst().map { $0.windows.first!.height } == [174, 174, 174, 174, 174])
    #expect(panes.dropFirst().map { $0.windows.first!.offset } == [0, 32, 72, 109, 140])
    #expect(panes[2].windows.map(\.height) == [174, 74])
    #expect(panes[3].windows.map(\.offset) == [72, 40, 0])
    #expect(rows.filter { $0.active && $0.target == nil }.count == 6)
    let child = sidebarRows(try fixture(client: 1)).filter { $0.target != nil }
    #expect(child.filter(\.active).map(\.title) == ["@pane-1", "pane-2"])
    #expect(child[2].windows.map(\.active) == [false, true])
    #expect(child[3].windows.map(\.active) == [false, true, false])
    let grandchild = sidebarRows(try fixture(client: 2)).filter { $0.target != nil }
    #expect(grandchild.filter(\.active).map(\.title) == ["pane-2"])
}

@Test func groupedPanesStayContiguous() throws {
    let rows = sidebarRows(try fixture(grouped: true))
    #expect(rows.map(\.height) == [29, 30, 30, 3, 16])
    #expect(rows.filter { $0.kind == .divider }.isEmpty)
    #expect(rows.filter { $0.target != nil }.allSatisfy { $0.multiPane })
    #expect(rows.filter { $0.target != nil }.map { $0.windows[0].offset } == [0, 30])
    #expect(rows.filter { $0.target != nil }.map { $0.windows[0].height } == [60, 60])
    #expect(rows.allSatisfy { $0.height > 0 })
}

@Test func eachPanesChildrenPrecedeItsNextSibling() throws {
    let snapshot = try fixture(grouped: true, descendants: true)
    let rows = sidebarRows(snapshot)
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map { $0.target!.pane } == [0, 1, 2, 5, 3, 6].map { PaneID(number: UInt32($0)) })
    #expect(panes.map(\.multiPane) == [true, false, false, true, false, true])
    #expect(panes.map(\.height) == [30, 40, 28, 42, 28, 30])
    #expect(panes.map(\.indent) == [0, 1, 2, 0, 1, 0])
    #expect(panes.allSatisfy { $0.active })
    #expect(panes.map { $0.windows[0].height } == [216, 216, 216, 216, 216, 216])
    #expect(rows.filter { $0.kind == .divider }.isEmpty)
    #expect(sidebarTarget(snapshot, attention: 1) == panes[2].target)
    #expect(sidebarTarget(snapshot, selected: panes[5].target, attention: -1) == panes[2].target)
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test(arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                  (true, false, false), (true, false, true), (true, true, false), (true, true, true)])
func heightAndPaddingMatrix(_ nested: Bool, _ multi: Bool, _ activity: Bool) throws {
    var pane: [String: Any] = ["kind": "agent", "id": "%1", "pane": "%1", "window": "@1",
                               "title": [], "tail": activity ? [["text": "working", "role": "dim"]] : [], "attention": false, "children": []]
    let node: [String: Any]
    if multi {
        var sibling = pane
        sibling["id"] = "%2"; sibling["pane"] = "%2"
        node = ["kind": "window", "id": "@1", "window": "@1", "name": "group", "children": [pane, sibling]]
    } else { node = pane }
    if nested {
        pane["id"] = "%0"; pane["pane"] = "%0"; pane["window"] = "@0"
        pane["children"] = [node]
    }
    let object: [String: Any] = ["v": 2, "client": ["session": "$0", "window": "@1", "pane": "%1"], "filter": "",
                               "sessions": [["id": "$0", "name": "main", "current": true, "nodes": [nested ? pane : node]]]]
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    let row = try #require(sidebarRows(snapshot).first { $0.target?.pane == PaneID(number: 1) })
    #expect(row.height == (activity ? 44 : 32) - (nested ? 4 : 0) - (multi ? 2 : 0))
    #expect(row.padding == (nested ? 5 : 7) - (multi ? 1 : 0))
    #expect(row.leading == (nested ? 48 : 36))
    #expect(row.tailY == (nested ? 22.5 : 25.5) - (multi ? 1 : 0))
    #expect(row.multiPane == multi)
    #expect(row.windows.count == (nested ? 2 : 1))
    #expect(row.windows.last?.active == true)
    #expect(row.windows.first?.active == !nested)
    #expect(sidebarRows(snapshot).allSatisfy { $0.height > 0 })
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
    #expect(panes.map(\.height) == [32, 32, 40, 28, 28, 28])
}

@Test(arguments: [(0, "0s"), (59, "59s"), (60, "1m00s"), (3599, "59m59s"), (3600, "1h00m"), (7260, "2h01m"), (-1, "0s")])
func elapsed(_ seconds: Int, _ expected: String) {
    #expect(sidebarElapsed(started: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: Double(100 + seconds))) == expected)
}

@Test(arguments: [("agent", "null", "Ada", "@Ada", SidebarRow.Icon.agent),
                  ("agent", "null", "@Ada", "@Ada", .agent),
                  ("run", "\"agent\"", "Ada", "@Ada", .agent),
                  ("shell", "null", "zsh", "Terminal", .terminal),
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

@Test(arguments: [("shell", "null", "idle", true, SidebarRow.Status.quiet),
                  ("shell", "null", "done", true, .done), ("shell", "null", "failed", true, .error),
                  ("shell", "null", "waiting", true, .quiet), ("shell", "null", "running", false, .running),
                  ("shell", "null", "compacting", false, .running), ("ssh", "null", "idle", false, .quiet),
                  ("run", "\"bash\"", "done", false, .done), ("run", "\"stream\"", "failed", false, .error),
                  ("shell", "\"bash\"", "idle", false, .quiet)])
func idleShellIsDisplayOnly(_ kind: String, _ run: String, _ indicator: String, _ quiet: Bool, _ status: SidebarRow.Status) throws {
    let json = """
    {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},"filter":"","sessions":[
      {"id":"$0","name":"main","current":true,"nodes":[
        {"kind":"\(kind)","run":\(run),"id":"%0","pane":"%0","window":"@0","indicator":{"kind":"\(indicator)"},
         "title":[{"text":"last-command","role":"plain"}],"tail":[],"attention":false,"children":[]}]}]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
    #expect(row.title == (quiet ? "Terminal" : "last-command"))
    #expect(row.quietShell == quiet)
    #expect(row.status == status)
    #expect(row.indicatorDescription == indicator)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)],
                           activePanes: [WindowID(number: 0): PaneID(number: 0)]).titles[WindowID(number: 0)] == "last-command")
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
