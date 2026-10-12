import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private func fixture(client: Int = 0, sessions: [Int] = [0], grouped: Bool = false, descendants: Bool = false, records: [[String: Any]] = [], serial: Int = 7) throws -> Snapshot {
    func item(_ id: Int, _ window: Int, run: String? = nil, started: Double? = nil, tail: String = "", children: [[String: Any]] = []) -> [String: Any] {
        let lifecycle = run == "bash" || run == "stream"
            ? terminal(running(), report: id == 2 ? report(waiting()) : null)
            : agent(id == 2 ? blocked() : working(), msg: tail.isEmpty ? null : tail)
        return pane(id, window: window, title: "pane-\(id)", lifecycle: lifecycle, run: run, started: started,
                    records: id == 0 ? records : [], serial: serial, children: children)
    }
    let children = [item(1, 1, run: "agent", started: 100, tail: "working", children: [item(2, 2, run: "stream", started: 100)]),
                    item(3, 3, run: "bash", started: 100), item(4, 4, run: "bash")]
    let nodes: [[String: Any]] = grouped
        ? [["kind": "window", "id": "@0", "window": "@0", "name": "group", "children": descendants
            ? [item(0, 0, children: [item(1, 1, tail: "child", children: [item(2, 2)])]),
               item(5, 0, tail: "parent", children: [item(3, 3)]), item(6, 0)]
            : [item(0, 0), item(5, 0)]]]
        : [item(0, 0), item(5, 5, children: children)]
    return try decode(snapshotObject(nodes, client: client, sessions: sessions))
}

@Test func nestedWindowsAndExactSpacing() throws {
    let rows = sidebarRows(try fixture(client: 5))
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map(\.indent) == [0, 0, 1, 2, 1, 1])
    #expect(rows.map(\.height) == [29, 32, 32, 48, 32, 32, 32, 16])
    #expect(rows.allSatisfy { $0.height > 0 })
    #expect(panes.filter(\.focused).map(\.title) == ["pane-5"])
    #expect(panes.map(\.indicatorX) == [20, 20, 35, 50, 35, 35])
    #expect(panes[0].guides.isEmpty)
    #expect(panes[1].guides == [.init(x: 20, top: 22, bottom: 32)])
    #expect(panes[2].guides == [.init(x: 35, top: 22, bottom: 48), .init(x: 20, top: 0, bottom: 48)])
    #expect(panes[3].guides == [.init(x: 35, top: 0, bottom: 22), .init(x: 20, top: 0, bottom: 32)])
    #expect(panes[4].guides == [.init(x: 20, top: 0, bottom: 32)])
    #expect(panes[5].guides == [.init(x: 20, top: 0, bottom: 22)])
    #expect(sidebarRows(try fixture(client: 1)).filter(\.focused).map(\.title) == ["@pane-1"])
    #expect(sidebarRows(try fixture(client: 2)).filter(\.focused).map(\.title) == ["pane-2"])
}

@Test func groupedPanesStayContiguous() throws {
    let rows = sidebarRows(try fixture(grouped: true))
    #expect(rows.map(\.height) == [29, 32, 32, 16])
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map(\.guides) == [[.init(x: 5, top: 10, bottom: 32)], [.init(x: 5, top: 0, bottom: 22)]])
    #expect(rows.filter(\.focused).count == 1)
    #expect(rows.allSatisfy { $0.height > 0 })
}

@Test func eachPanesChildrenPrecedeItsNextSibling() throws {
    let rows = sidebarRows(try fixture(grouped: true, descendants: true))
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map { $0.target!.pane } == [0, 1, 2, 5, 3, 6].map { PaneID(number: UInt32($0)) })
    #expect(panes.map(\.height) == [32, 48, 32, 48, 32, 32])
    #expect(panes.map(\.indent) == [0, 1, 2, 0, 1, 0])
    #expect(panes.map { $0.guides.last! } == [
        .init(x: 5, top: 10, bottom: 32), .init(x: 5, top: 0, bottom: 48),
        .init(x: 5, top: 0, bottom: 32), .init(x: 5, top: 0, bottom: 48),
        .init(x: 5, top: 0, bottom: 32), .init(x: 5, top: 0, bottom: 22)
    ])
    #expect(rows.filter(\.focused).count == 1)
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test(arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                  (true, false, false), (true, false, true), (true, true, false), (true, true, true)])
func heightAndPaddingMatrix(_ nested: Bool, _ multi: Bool, _ activity: Bool) throws {
    var pane = SidebarFeedTests.pane(1, lifecycle: agent(working(), msg: activity ? "working" : null))
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
    let snapshot = try decode(snapshotObject([nested ? pane : node], client: 1))
    let row = try #require(sidebarRows(snapshot).first { $0.target?.pane == PaneID(number: 1) })
    #expect(row.height == (activity ? 48 : 32))
    #expect(row.padding == 7)
    #expect(row.leading == (nested ? 51 : 36))
    #expect(row.indicatorX == (nested ? 35 : 20))
    if nested && multi { #expect(sidebarRows(snapshot).allSatisfy { !$0.guides.contains { $0.x == 5 } }) }
    #expect(row.tailY == 26)
    #expect(row.focused)
    #expect(sidebarRows(snapshot).filter(\.focused).count == 1)
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
    #expect(panes.map(\.height) == [32, 32, 48, 32, 32, 32])
}

@Test(arguments: [(0, "0s"), (59, "59s"), (60, "1m00s"), (3599, "59m59s"), (3600, "1h00m"), (7260, "2h01m"), (-1, "0s")])
func elapsed(_ seconds: Int, _ expected: String) {
    #expect(sidebarElapsed(started: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: Double(100 + seconds))) == expected)
}

@Test func agentWeightAndDisplayOnlyPrefix() throws {
    let cases: [([Any], String?, String, String, String, Bool)] = [
        (["Live", ["Pi_agent", ["id": "pi-session", "status": report(idle())]]], nil, "Ada", "@Ada", "Ada", true),
        (["Live", ["Some_agent", ["name": "claude-code", "status": ["since": 1, "msg": null, "state": idle()]]]], nil, "Ada", "Ada", "Ada", true),
        (agent(), nil, "@Ada", "@Ada", "@Ada", true),
        (remote(["Remote_agent", ["name": "pi", "status": ["since": 1, "msg": null, "state": idle()]]]), nil, "Ada", "Ada", "Ada", true),
        (terminal(running()), "agent", "Ada", "@Ada", "Ada", true),
        (["Ended", ["result": "completed"]], "agent", "Ada", "@Ada", "Ada", true),
        (terminal(["Unknown"]), nil, "zsh", "zsh", "zsh", false),
        (remote(["Remote_terminal", ["interactive": true, "status": shell()]]), nil, "ssh", "ssh alice@devbox", "ssh alice@devbox", false),
        (terminal(running()), "bash", "job", "job", "job", false),
        (["Ended", ["result": "failed"]], "stream", "monitor", "monitor", "monitor", false)
    ]
    for (lifecycle, run, title, expected, tab, agent) in cases {
        let snapshot = try decode(snapshotObject([pane(0, title: title, lifecycle: lifecycle, run: run)]))
        let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
        #expect(row.title == expected)
        #expect(row.agent == agent)
        #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)],
                               activePanes: [WindowID(number: 0): PaneID(number: 0)]).labels[WindowID(number: 0)]?.title == tab)
    }
}

@Test func composedLabelsCaptionsAndStatuses() throws {
    let failedReport = report(idle(outcome(4, "failure")), msg: "Build failed")
    let cases: [([Any], String?, String, Bool, SidebarRow.Status, String, String)] = [
        (terminal(), nil, "Terminal", true, .quiet, "idle", ""),
        (terminal(exited(0)), nil, "Terminal", true, .done, "done", ""),
        (terminal(exited(130)), nil, "Terminal", true, .error, "failed", ""),
        (terminal(report: report(idle())), nil, "Terminal", true, .quiet, "idle", ""),
        (terminal(report: failedReport), nil, "Terminal", true, .error, "failed", "Build failed"),
        (terminal(["Unknown"]), nil, "zsh", false, .quiet, "", ""),
        (terminal(["Unknown"], report: report(idle(outcome(2, "success")), msg: "Built")), nil, "zsh", false, .done, "done", "Built"),
        (terminal(running(nil, fullscreen: true)), nil, "zsh", false, .quiet, "", ""),
        (terminal(running("nvim", fullscreen: true), report: report(waiting("auth"), msg: "Login required")), nil, "zsh", false, .waiting, "waiting", "Login required"),
        (terminal(running()), nil, "make", false, .running, "running", ""),
        (terminal(running("")), nil, "zsh", false, .running, "running", ""),
        (terminal(running(), report: report(working(42), msg: "Building")), nil, "zsh", false, .running, "running", "Building 42%"),
        (terminal(exited(1), report: report(waiting("auth"), msg: "Login required")), nil, "zsh", false, .waiting, "waiting", "Login required"),
        (terminal(report: report(idle())), "bash", "zsh", false, .quiet, "idle", ""),
        (terminal(exited(1)), "bash", "zsh", false, .running, "running", ""),
        (remote(["Remote_terminal", ["interactive": true, "status": shell(running())]]), nil, "ssh alice@devbox: make", false, .running, "running", ""),
        (remote(["Remote_terminal", ["interactive": false, "status": shell(running())]]), nil, "ssh alice@devbox", false, .running, "running", ""),
        (remote(["Remote_terminal", ["interactive": true, "status": shell(running(), report: report(working()))]]), nil, "ssh alice@devbox", false, .running, "running", ""),
        (remote(["Remote_terminal", ["interactive": true, "status": shell(exited(2))]]), nil, "ssh alice@devbox", false, .error, "failed", ""),
        (agent(working(42), msg: "Thinking"), nil, "zsh", false, .running, "running", "Thinking 42%"),
        (agent(blocked("permission"), msg: "Approve deployment"), nil, "zsh", false, .waiting, "waiting", "Approve deployment"),
        (agent(["Waiting", ["source": ["Ask", ["id": "ask-id"]], "progress": null]]), nil, "zsh", false, .waiting, "waiting", ""),
        (agent(["Stalled"]), nil, "zsh", false, .stalled, "stalled", ""),
        (agent(idle(outcome(17, "success")), msg: "Finished"), nil, "zsh", false, .done, "done", "Finished"),
        (agent(idle(outcome(18, "failure")), msg: "Failed"), nil, "zsh", false, .error, "failed", "Failed"),
        (["Ended", ["result": "unknown"]], "bash", "zsh", false, .quiet, "gone", ""),
        (["Ended", ["result": "completed"]], "bash", "zsh", false, .done, "gone, completed", ""),
        (["Ended", ["result": "failed"]], "bash", "zsh", false, .error, "gone, failed", "failed"),
        (["Ended", ["result": "died"]], "agent", "@zsh", false, .error, "gone, died", "died"),
        (["Ended", ["result": "stopped"]], "agent", "@zsh", false, .quiet, "gone, stopped", "stopped")
    ]
    for (lifecycle, run, title, quiet, status, description, tail) in cases {
        let snapshot = try decode(snapshotObject([pane(0, title: "zsh", lifecycle: lifecycle, run: run)]))
        let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
        #expect(row.title == title)
        #expect(row.quietShell == quiet)
        #expect(row.status == status)
        #expect(row.indicatorDescription == description)
        #expect(row.tail == tail)
        #expect(row.height == (tail.isEmpty ? 32 : 48))
        #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == status.tabStatus)
    }
}

@Test func navigationOrderAndFallback() throws {
    let snapshot = try fixture(sessions: [0, 1])
    let panes = sidebarRows(snapshot).compactMap(\.target)
    #expect(panes.map(\.pane) == [0, 5, 1, 2, 3, 4, 0, 5, 1, 2, 3, 4].map { PaneID(number: UInt32($0)) })
    #expect(panes.first == Snapshot.Position(session: SessionID(number: 0), window: WindowID(number: 0), pane: PaneID(number: 0)))
    #expect(sidebarRows(try fixture(sessions: [])).compactMap(\.target).isEmpty)
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
    let programs = rows.filter { if case .program = $0.id { true } else { false } }
    #expect(programs.map(\.title) == ["Record-only title", "a/child", "a/missing/leaf", "a-", "é", "z", "é"])
    #expect(programs.map(\.leading) == [51, 66, 81, 51, 51, 51, 51])
    #expect(programs.map(\.indicatorX) == [35, 50, 65, 35, 35, 35, 35])
    #expect(programs.allSatisfy { $0.kind == .pane(nil) && $0.agent })
    #expect(programs.map(\.height) == [32, 32, 48, 32, 32, 32, 32])
    #expect(programs.allSatisfy { $0.padding == 7 && $0.tailY == 26 && !$0.focused && $0.target == nil && $0.started == nil })
    #expect(programs.map(\.status) == [.running, .done, .waiting, .error, .quiet, .quiet, .quiet])
    #expect(rows[1].guides == [.init(x: 20, top: 22, bottom: 32), .init(x: 5, top: 10, bottom: 32)])
    #expect(programs[0].guides == [.init(x: 35, top: 22, bottom: 32), .init(x: 20, top: 0, bottom: 32), .init(x: 5, top: 0, bottom: 32)])
    #expect(programs[1].guides == [.init(x: 35, top: 0, bottom: 32), .init(x: 20, top: 0, bottom: 32), .init(x: 5, top: 0, bottom: 32)])
    #expect(programs[2].guides == [.init(x: 35, top: 0, bottom: 38), .init(x: 20, top: 0, bottom: 48), .init(x: 5, top: 0, bottom: 48)])
    #expect(programs.last!.guides == [.init(x: 20, top: 0, bottom: 32), .init(x: 5, top: 0, bottom: 32)])
    #expect(programs.allSatisfy { Set($0.guides.map(\.x)).count == $0.guides.count })
    #expect(rows[1].target?.pane == PaneID(number: 0))
    #expect(rows[9].target?.pane == PaneID(number: 1))
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(rows.compactMap(\.target).map(\.pane) == [0, 1, 2, 5, 3, 6].map { PaneID(number: UInt32($0)) })
    #expect(sidebarSearch(snapshot, query: "Record-only title")?.sessions.isEmpty == true)
    #expect(sidebarSearch(snapshot, query: "Record-only caption")?.sessions.isEmpty == true)
    #expect(sidebarRows(sidebarSearch(snapshot, query: "session-0")) == rows)
}

@Test func recordGuidesGrowFromPaneAndRecordIndicators() throws {
    let records: [[String: Any]] = [
        ["id": "a", "state": "working", "msg": "Activity"],
        ["id": "a/b", "state": "working"]
    ]
    let rows = sidebarRows(try fixture(records: records))
    #expect(rows[1].guides == [.init(x: 20, top: 22, bottom: 32)])
    #expect(rows[2].guides == [.init(x: 35, top: 22, bottom: 48), .init(x: 20, top: 0, bottom: 48)])
    #expect(rows[3].guides == [.init(x: 35, top: 0, bottom: 22), .init(x: 20, top: 0, bottom: 22)])
}

@Test func stalledPaneMakesItsAncestorTabRed() throws {
    let snapshot = try decode(snapshotObject([pane(0, children: [pane(1, window: 1, lifecycle: agent(["Stalled"]))])]))
    let row = try #require(sidebarRows(snapshot).first { $0.target?.pane == PaneID(number: 1) })
    #expect(row.status == .stalled && row.indicatorDescription == "stalled")
    #expect(row.status.tabStatus == .error)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == .error)
}

@Test func programIDsOrderBySlashComponents() throws {
    let records: [[String: Any]] = [
        ["id": "a-b", "state": "working"],
        ["id": "a/b", "state": "working"],
        ["id": "a", "state": "working"]
    ]
    let rows = sidebarRows(try fixture(records: records)).filter { if case .program = $0.id { true } else { false } }
    #expect(rows.map(\.title) == ["a", "a/b", "a-b"])
}

@Test func appOwnedSeenSuppressesChildOutcomes() throws {
    let records: [[String: Any]] = [
        ["id": "done", "state": "done"], ["id": "error", "state": "error"],
        ["id": "working", "state": "working"], ["id": "blocked", "state": "blocked"]
    ]
    func snapshot(client: Int = 0, serial: Int = 7, command: Double = 1780000001.25, pid: Int = 12345, error: Any = null, failed: Bool = true) throws -> Snapshot {
        var object = snapshotObject([pane(0, lifecycle: agent(idle(outcome(serial, failed ? "failure" : "success"))), records: records, serial: serial),
                                     pane(5, lifecycle: terminal(exited(1, ended: command)))], client: client, error: error)
        object["server_instance"] = ["started_at": 1780000000, "pid": pid]
        return try decode(object)
    }
    func statuses(_ snapshot: Snapshot, _ seen: SidebarSeen) -> [SidebarRow.Status] { sidebarRows(snapshot, seen: seen).filter { $0.kind != .gap && $0.kind != .header }.map(\.status) }
    let raw: [SidebarRow.Status] = [.waiting, .done, .error, .running]
    let acknowledged: [SidebarRow.Status] = [.waiting, .quiet, .quiet, .running]
    var seen = SidebarSeen()
    seen.observe(try snapshot(serial: 6, command: 1780000001), attended: false)
    let visited = try snapshot()
    seen.observe(visited, attended: false)
    #expect(statuses(visited, seen) == [.error] + raw + [.error])
    seen.observe(visited, attended: true)
    #expect(statuses(visited, seen) == [.quiet] + acknowledged + [.error])
    let tabs = sidebarWindows(visited, session: SessionID(number: 0), surviving: [WindowID(number: 0), WindowID(number: 5)], seen: seen).statuses
    #expect(tabs[WindowID(number: 0)] == .quiet && tabs[WindowID(number: 5)] == .error)
    #expect(sidebarWindows(visited, session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == .error)
    #expect(statuses(try snapshot(client: 5), seen) == [.quiet] + acknowledged + [.error])
    #expect(statuses(try snapshot(serial: 8), seen) == [.error] + raw + [.error])
    #expect(statuses(try snapshot(failed: false), seen) == [.quiet] + acknowledged + [.error])
    var other = seen
    other.observe(try snapshot(client: 5, error: "unreadable"), attended: true)
    #expect(other == seen)
    other.observe(try snapshot(client: 5), attended: true)
    #expect(statuses(try snapshot(client: 5), other) == [.quiet] + acknowledged + [.quiet])
    #expect(statuses(try snapshot(command: 1780000002), other) == [.quiet] + acknowledged + [.error])
    #expect(statuses(try snapshot(command: 1780000001.5), other) == [.quiet] + acknowledged + [.error])
    var pruned = other
    pruned.observe(try decode(snapshotObject([pane(5, lifecycle: terminal(exited(1)))], client: 5)), attended: false)
    #expect(statuses(try snapshot(client: 5), pruned) == [.error] + raw + [.quiet])
    other.observe(try snapshot(client: 5, pid: 12346), attended: false)
    #expect(statuses(try snapshot(client: 5), other) == [.error] + raw + [.error])
}

@Test func reportAndCommandOutcomesAreSeenIndependently() throws {
    func snapshot(_ code: Int, report serial: Int) throws -> Snapshot {
        try decode(snapshotObject([pane(0, lifecycle: terminal(exited(code, ended: 1780000000 + Double(code)), report: report(idle(outcome(serial, "failure")))))]))
    }
    var seen = SidebarSeen()
    seen.observe(try snapshot(1, report: 3), attended: true)
    let rows = try [(1, 3), (2, 3), (1, 4)].map { code, serial in try #require(sidebarRows(snapshot(code, report: serial), seen: seen).first { $0.target != nil }) }
    #expect(rows.map(\.status) == [.quiet, .quiet, .error])
}

@Test func contentChangesAndServerIdentity() throws {
    let records: [[String: Any]] = [["id": "done", "state": "done"], ["id": "error", "state": "error"]]
    let base = try fixture(client: 5, records: records)
    #expect(!base.sameSidebarContent(as: try fixture(client: 5, records: records, serial: 8)))
    var changed = records
    changed[0]["title"] = "New title"
    let edited = try fixture(client: 5, records: changed)
    #expect(!base.sameSidebarContent(as: edited))
    let before = sidebarRows(base), after = sidebarRows(edited)
    #expect(before.map(\.id) == after.map(\.id))
    #expect(before.map(\.height) == after.map(\.height))
    #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    var object = snapshotObject([pane(0)])
    let same = try decode(object)
    object["error"] = "unreadable"
    #expect(same.sameSidebarContent(as: try decode(object)))
    object["server_instance"] = ["started_at": 1780000000, "pid": 1]
    #expect(!same.sameSidebarContent(as: try decode(object)))
}

@Test func freshSeenBaselinesFinishedOutcomes() throws {
    func snapshot(serial: Int = 7, error: Any = null, pid: Int = 12345) throws -> Snapshot {
        var object = snapshotObject([pane(0), pane(1, lifecycle: agent(idle(outcome(serial, "success"))), children: [
            pane(2, lifecycle: terminal(report: report(idle(outcome(serial, "failure"))))),
            pane(3, lifecycle: terminal(exited(1)))
        ])], sessions: [0, 1], error: error)
        object["server_instance"] = ["started_at": 1780000000, "pid": pid]
        return try decode(object)
    }
    func statuses(_ snapshot: Snapshot, _ seen: SidebarSeen) -> [SidebarRow.Status] {
        sidebarRows(snapshot, seen: seen).filter { $0.target != nil }.map(\.status)
    }
    var seen = SidebarSeen()
    let initial = try snapshot()
    seen.observe(initial, attended: false)
    #expect(statuses(initial, seen) == Array(repeating: .quiet, count: 8))
    let later = try snapshot(serial: 8)
    seen.observe(later, attended: false)
    #expect(statuses(later, seen) == [.quiet, .done, .error, .quiet, .quiet, .done, .error, .quiet])
    let restarted = try snapshot(pid: 12346)
    seen.observe(restarted, attended: false)
    #expect(statuses(restarted, seen) == [.quiet, .done, .error, .error, .quiet, .done, .error, .error])
    var delayed = SidebarSeen()
    delayed.observe(try snapshot(error: "unreadable"), attended: false)
    delayed.observe(initial, attended: false)
    #expect(statuses(initial, delayed) == Array(repeating: .quiet, count: 8))
}
