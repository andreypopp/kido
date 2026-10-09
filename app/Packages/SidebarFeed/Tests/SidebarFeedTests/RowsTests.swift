import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private func fixture(client: Int = 0, sessions: [Int] = [0], grouped: Bool = false, descendants: Bool = false, records: [[String: Any]] = [], serial: Int = 7) throws -> Snapshot {
    func item(_ id: Int, _ window: Int, run: String? = nil, started: Double? = nil, tail: String = "", children: [[String: Any]] = []) -> [String: Any] {
        ["kind": run == "bash" || run == "stream" ? "run" : "agent", "id": "%\(id)", "pane": "%\(id)", "window": "@\(window)",
         "run": run as Any? ?? NSNull(), "started": started as Any? ?? NSNull(), "indicator": ["kind": "running"],
         "program_status": ["serial": serial, "records": id == 0 ? records : []], "title": [["text": "pane-\(id)", "role": "plain"]], "tail": tail.isEmpty ? [] : [["text": tail, "role": "dim"]],
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
                               "asks": [], "error": NSNull(), "sessions": sessions.map {
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
                               "program_status": ["serial": 0, "records": []], "title": [], "tail": activity ? [["text": "working", "role": "dim"]] : [], "attention": false, "children": []]
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
    let object: [String: Any] = ["v": 2, "client": ["session": "$0", "window": "@1", "pane": "%1"], "asks": [],
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
    let filtered = sidebarRows(try fixture(sessions: [0]))
    #expect(filtered == rows.filter { $0.id.session == SessionID(number: 0) })
    #expect(sidebarRows(try fixture(sessions: [])).isEmpty)
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
                  ("shell", "null", "zsh", "zsh", .terminal),
                  ("ssh", "null", "host", "host", .terminal),
                  ("run", "\"bash\"", "job", "job", .terminal),
                  ("run", "\"stream\"", "monitor", "monitor", .terminal)])
func iconsAndDisplayOnlyPrefix(_ kind: String, _ run: String, _ title: String, _ expected: String, _ icon: SidebarRow.Icon) throws {
    let json = """
    {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},"asks":[],"sessions":[
      {"id":"$0","name":"main","current":true,"nodes":[
        {"kind":"\(kind)","run":\(run),"id":"%0","pane":"%0","window":"@0",
         "program_status":{"serial":0,"records":[]},"title":[{"text":"\(title)","role":"plain"}],"tail":[],"attention":false,"children":[]}]}]}
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
                  ("shell", "null", "stalled", false, .stalled), ("shell", "null", "unknown", false, .quiet),
                  ("shell", "null", "null", false, .quiet),
                  ("shell", "null", "waiting", false, .attention), ("shell", "null", "running", false, .running),
                  ("shell", "null", "compacting", false, .running), ("ssh", "null", "idle", false, .quiet),
                  ("run", "\"bash\"", "done", false, .done), ("run", "\"stream\"", "failed", false, .error),
                  ("shell", "\"bash\"", "idle", false, .quiet)])
func idleShellIsDisplayOnly(_ kind: String, _ run: String, _ indicator: String, _ quiet: Bool, _ status: SidebarRow.Status) throws {
    let title = indicator == "null" ? "nvim" : "last-command"
    let resolved = indicator == "null" ? "null" : "{\"kind\":\"\(indicator)\"}"
    let json = """
    {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},"asks":[],"sessions":[
      {"id":"$0","name":"main","current":true,"nodes":[
        {"kind":"\(kind)","run":\(run),"id":"%0","pane":"%0","window":"@0","indicator":\(resolved),
         "program_status":{"serial":0,"records":[]},"title":[{"text":"\(title)","role":"plain"}],"tail":[],"attention":false,"children":[]}]}]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
    #expect(row.title == (quiet ? "Terminal" : title))
    #expect(row.quietShell == quiet)
    #expect(row.status == status)
    #expect(row.indicatorDescription == (indicator == "null" ? "" : indicator))
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
        {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},"asks":[],"sessions":[
          {"id":"$0","name":"main","current":true,"nodes":[
            {"kind":"agent","id":"%0","pane":"%0","window":"@0","indicator":{"kind":"\(kind)","outcome":\(outcome.map { "\"\($0)\"" } ?? "null")},
             "program_status":{"serial":0,"records":[]},"title":[],"tail":[],"attention":true,"children":[]}]}]}
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

@Test func programRowsOrderingGeometryAndNavigation() throws {
    let records: [[String: Any]] = [
        ["id": "z", "state": "idle", "title": ""],
        ["id": "a-", "state": "error"],
        ["id": "a/missing/leaf", "state": "blocked", "msg": "Record-only caption"],
        ["id": "a", "state": "working", "title": "Record-only title"],
        ["id": "a/child", "state": "done"],
        ["id": "é", "state": "idle"], ["id": "é", "state": "idle"],
        ["id": "", "state": "working", "title": "Root"]
    ]
    let snapshot = try fixture(grouped: true, descendants: true, records: records)
    let rows = sidebarRows(snapshot)
    let programs = rows.filter { if case .program = $0.kind { true } else { false } }
    #expect(programs.map(\.title) == ["Record-only title", "a/child", "a/missing/leaf", "a-", "é", "z", "é"])
    #expect(programs.map(\.leading) == [48, 60, 72, 48, 48, 48, 48])
    #expect(programs.map(\.height) == [24, 24, 39, 24, 24, 24, 24])
    #expect(programs.allSatisfy { $0.padding == 4 && $0.tailY == 21 && $0.active && !$0.focused && $0.target == nil && $0.started == nil && !$0.attention })
    #expect(programs.map(\.status) == [.running, .done, .attention, .error, .quiet, .quiet, .quiet])
    #expect(rows[1].target?.pane == PaneID(number: 0))
    #expect(rows[9].target?.pane == PaneID(number: 1))
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(sidebarTarget(snapshot) == rows[1].target)
    #expect(sidebarTarget(snapshot, selected: rows[1].target, attention: 1)?.pane == PaneID(number: 2))
    #expect(sidebarSearch(snapshot, query: "Record-only title")?.sessions.isEmpty == true)
    #expect(sidebarSearch(snapshot, query: "Record-only caption")?.sessions.isEmpty == true)
    #expect(sidebarRows(sidebarSearch(snapshot, query: "session-0")) == rows)
}

@Test func programIDsOrderBySlashComponents() throws {
    let records: [[String: Any]] = [
        ["id": "a-b", "state": "working"],
        ["id": "a/b", "state": "working"],
        ["id": "a", "state": "working"]
    ]
    let rows = sidebarRows(try fixture(records: records)).filter { if case .program = $0.kind { true } else { false } }
    #expect(rows.map(\.title) == ["a", "a/b", "a-b"])
}

@Test func programSeenSerialsAndContentChanges() throws {
    let records: [[String: Any]] = [
        ["id": "done", "state": "done"], ["id": "error", "state": "error"],
        ["id": "working", "state": "working"], ["id": "blocked", "state": "blocked"]
    ]
    let unvisited = try fixture(client: 5, records: records)
    let visited = try fixture(records: records)
    var seen = sidebarProgramSeen(unvisited, previous: [:])
    #expect(seen[PaneID(number: 0)] == nil)
    seen = sidebarProgramSeen(visited, previous: seen)
    seen = sidebarProgramSeen(unvisited, previous: seen)
    let suppressed = sidebarRows(unvisited, programSeen: seen).filter { if case .program = $0.kind { true } else { false } }
    #expect(suppressed.map(\.status) == [.attention, .quiet, .quiet, .running])
    #expect(suppressed.map(\.indicatorDescription) == ["blocked", "idle", "idle", "working"])
    let newer = try fixture(client: 5, records: records, serial: 8)
    let restored = sidebarRows(newer, programSeen: seen).filter { if case .program = $0.kind { true } else { false } }
    #expect(restored.map(\.status) == [.attention, .done, .error, .running])
    #expect(!unvisited.sameSidebarContent(as: newer))
    var changed = records
    changed[0]["title"] = "New title"
    let edited = try fixture(client: 5, records: changed)
    #expect(!unvisited.sameSidebarContent(as: edited))
    let before = sidebarRows(unvisited), after = sidebarRows(edited)
    #expect(before.map(\.id) == after.map(\.id))
    #expect(before.map(\.height) == after.map(\.height))
    #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    #expect(sidebarProgramSeen(nil, previous: seen) == seen)
    #expect(sidebarProgramSeen(try fixture(sessions: []), previous: seen).isEmpty)
}
