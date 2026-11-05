import Foundation
import Testing
import KoModel
@testable import SidebarFeed

private func fixture(client: Int = 0, sessions: [Int] = [0], grouped: Bool = false, descendants: Bool = false, records: [ProgramStatus.Record] = [], serial: Int = 7) -> Snapshot {
    func item(_ id: Int, _ window: Int, tail: String = "", lifecycle: Lifecycle? = nil, children: [Node] = []) -> Node {
        let lifecycle = lifecycle ?? agent(id == 2 ? waiting() : working(), msg: tail.isEmpty ? nil : tail)
        return pane(id, window: window, title: "pane-\(id)", lifecycle: lifecycle,
                    records: id == 0 ? records : [], serial: serial, children: children)
    }
    let children = [item(1, 1, tail: "working", lifecycle: piAgent(working(), msg: "working"),
                         children: [item(2, 2, lifecycle: terminal(running(), report: report(waiting())))]),
                    item(3, 3, lifecycle: terminal(running())),
                    item(4, 4, lifecycle: terminal(running()))]
    let nodes: [Node] = grouped
        ? [group(0, descendants
            ? [item(0, 0, children: [item(1, 1, tail: "child", children: [item(2, 2)])]),
               item(5, 0, tail: "parent", children: [item(3, 3)]), item(6, 0)]
            : [item(0, 0), item(5, 0)])]
        : [item(0, 0), item(5, 5, children: children)]
    return makeSnapshot(nodes, client: client, sessions: sessions)
}

@Test func nestedWindowsAndExactSpacing() throws {
    let rows = sidebarRows(fixture(client: 5))
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
    #expect(sidebarRows(fixture(client: 1)).filter(\.focused).map(\.title) == ["@pane-1"])
    #expect(sidebarRows(fixture(client: 2)).filter(\.focused).map(\.title) == ["pane-2"])
}

@Test func groupedPanesStayContiguous() throws {
    let rows = sidebarRows(fixture(grouped: true))
    #expect(rows.map(\.height) == [29, 32, 32, 16])
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map(\.guides) == [[.init(x: 5, top: 10, bottom: 32)], [.init(x: 5, top: 0, bottom: 22)]])
    #expect(rows.filter(\.focused).count == 1)
    #expect(rows.allSatisfy { $0.height > 0 })
}

@Test func eachPanesChildrenPrecedeItsNextSibling() throws {
    let rows = sidebarRows(fixture(grouped: true, descendants: true))
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
    let lifecycle = agent(working(), msg: activity ? "working" : nil)
    let leaf = pane(1, lifecycle: lifecycle)
    let node = multi ? group(1, [leaf, pane(2, window: 1, lifecycle: lifecycle)]) : leaf
    let snapshot = makeSnapshot([nested ? pane(0, lifecycle: lifecycle, children: [node]) : node], client: 1)
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

@Test func singleSessionKeepsIdentity() throws {
    let rows = sidebarRows(fixture(sessions: [0, 1]))
    let singleSession = sidebarRows(fixture(sessions: [0]))
    #expect(singleSession == rows.filter { $0.id.session == SessionID(number: 0) })
    #expect(sidebarRows(fixture(sessions: [])).isEmpty)
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(rows.filter { $0.focused }.count == 1)
}

@Test func paneTargetsAndCaptions() throws {
    let panes = sidebarRows(fixture()).filter { $0.target != nil }
    #expect(panes.allSatisfy { if case .pane = $0.kind { return true }; return false })
    #expect(panes.first { $0.title == "@pane-1" }?.tail == "working")
    #expect(panes.map(\.height) == [32, 32, 48, 32, 32, 32])
}

@Test func agentWeightAndDisplayOnlyPrefix() throws {
    let cases: [(Lifecycle, String, String, String, Bool)] = [
        (piAgent(idle()), "Ada", "@Ada", "Ada", true),
        (agent(idle()), "Ada", "Ada", "Ada", true),
        (agent(), "@Ada", "@Ada", "@Ada", true),
        (remote(.agent(name: "pi", report(idle()))), "Ada", "Ada", "Ada", true),
        (.ended(.exited(.init(code: 0))), "Ada", "Ada", "Ada", false),
        (terminal(.unknown), "zsh", "zsh", "zsh", false),
        (remote(.terminal(interactive: true, shell())), "ssh", "ssh alice@devbox", "ssh alice@devbox", false),
        (.ended(.exited(.init(code: 2))), "monitor", "monitor", "monitor", false)
    ]
    for (lifecycle, title, expected, tab, agent) in cases {
        let snapshot = makeSnapshot([pane(0, title: title, lifecycle: lifecycle)])
        let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
        #expect(row.title == expected)
        #expect(row.agent == agent)
        #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)],
                               activePanes: [WindowID(number: 0): PaneID(number: 0)]).labels[WindowID(number: 0)]?.title == tab)
    }
}

@Test func composedLabelsCaptionsAndStatuses() throws {
    let failedReport = report(idle(outcome(4, .failure)), msg: "Build failed")
    let cases: [(Lifecycle, String, Bool, SidebarRow.Status, KoSchema.Mark, String, String)] = [
        (terminal(), "Terminal", true, .quiet, .none_, "idle", ""),
        (terminal(exited(0)), "Terminal", true, .done, .done, "done", ""),
        (terminal(exited(130)), "Terminal", true, .error, .failed, "failed", ""),
        (terminal(report: report(idle())), "Terminal", true, .quiet, .none_, "idle", ""),
        (terminal(report: failedReport), "Terminal", true, .error, .failed, "failed", "Build failed"),
        (terminal(.unknown), "zsh", false, .quiet, .none_, "idle", ""),
        (terminal(.unknown, report: report(idle(outcome(2, .success)), msg: "Built")), "zsh", false, .done, .done, "done", "Built"),
        (terminal(running(nil, fullscreen: true)), "zsh", false, .quiet, .none_, "idle", ""),
        (terminal(running("nvim", fullscreen: true), report: report(waiting(.auth), msg: "Login required")), "zsh", false, .waiting, .waiting, "waiting", "Login required"),
        (terminal(running()), "make", false, .running, .running, "running", ""),
        (terminal(running("")), "zsh", false, .running, .running, "running", ""),
        (terminal(running(), report: report(working(42), msg: "Building")), "zsh", false, .running, .running, "running", "Building 42%"),
        (terminal(exited(1), report: report(waiting(.auth), msg: "Login required")), "zsh", false, .waiting, .waiting, "waiting", "Login required"),
        (remote(.terminal(interactive: true, shell(running()))), "ssh alice@devbox: make", false, .running, .running, "running", ""),
        (remote(.terminal(interactive: false, shell(running()))), "ssh alice@devbox", false, .running, .running, "running", ""),
        (remote(.terminal(interactive: true, shell(running(), report: report(working())))), "ssh alice@devbox", false, .running, .running, "running", ""),
        (remote(.terminal(interactive: true, shell(exited(2)))), "ssh alice@devbox", false, .error, .failed, "failed", ""),
        (agent(working(42), msg: "Thinking"), "zsh", false, .running, .running, "running", "Thinking 42%"),
        (agent(waiting(.permission), msg: "Approve deployment"), "zsh", false, .waiting, .waiting, "waiting", "Approve deployment"),
        (agent(idle(outcome(17, .success)), msg: "Finished"), "zsh", false, .done, .done, "done", "Finished"),
        (agent(idle(outcome(18, .failure)), msg: "Failed"), "zsh", false, .error, .failed, "failed", "Failed"),
        (.ended(.exited(.init(code: 0))), "zsh", false, .done, .none_, "gone, completed", ""),
        (.ended(.exited(.init(code: 2))), "zsh", false, .error, .none_, "gone, exited with code 2", "exited with code 2"),
        (.ended(.signaled(.init(signal: 9))), "zsh", false, .error, .none_, "gone, killed by signal 9", "killed by signal 9"),
        (.lingering(.exited(.init(code: 0))), "zsh", false, .endedClean, .none_, "gone, exited", ""),
        (.lingering(.exited(.init(code: 2))), "zsh", false, .endedFailed, .none_, "gone, exited with code 2", ""),
    ]
    for (lifecycle, title, quiet, status, mark, description, tail) in cases {
        let snapshot = makeSnapshot([pane(0, title: "zsh", lifecycle: lifecycle, mark: mark)])
        let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
        #expect(row.title == title)
        #expect(row.quietShell == quiet)
        #expect(row.status == status)
        #expect(row.indicatorDescription == description)
        #expect(row.tail == tail)
        #expect(row.height == (tail.isEmpty ? 32 : 48))
        #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == status.mergingTabStatus(.quiet))
    }
}

@Test func navigationOrderAndFallback() throws {
    let snapshot = fixture(sessions: [0, 1])
    let panes = sidebarRows(snapshot).compactMap(\.target)
    #expect(panes.map(\.pane) == [0, 5, 1, 2, 3, 4, 0, 5, 1, 2, 3, 4].map { PaneID(number: UInt32($0)) })
    #expect(panes.first == Snapshot.Position(session: SessionID(number: 0), window: WindowID(number: 0), pane: PaneID(number: 0)))
    #expect(sidebarRows(fixture(sessions: [])).compactMap(\.target).isEmpty)
}

@Test func programRowsOrderingGeometryAndNavigation() throws {
    let records: [ProgramStatus.Record] = [
        record("z", .idle, title: ""),
        record("a-", .error),
        record("a/missing/leaf", .blocked, msg: "Record-only caption"),
        record("a", .working, title: "Record-only title"),
        record("a/child", .done),
        record("é", .idle), record("é", .idle),
        record("", .working, title: "Root")
    ]
    let snapshot = fixture(grouped: true, descendants: true, records: records)
    let rows = sidebarRows(snapshot)
    let programs = rows.filter { if case .program = $0.id { true } else { false } }
    #expect(programs.map(\.title) == ["Record-only title", "a/child", "a/missing/leaf", "a-", "é", "z", "é"])
    #expect(programs.map(\.leading) == [51, 66, 81, 51, 51, 51, 51])
    #expect(programs.map(\.indicatorX) == [35, 50, 65, 35, 35, 35, 35])
    #expect(programs.allSatisfy { $0.kind == .pane(nil) && $0.agent })
    #expect(programs.map(\.height) == [32, 32, 48, 32, 32, 32, 32])
    #expect(programs.allSatisfy { $0.padding == 7 && $0.tailY == 26 && !$0.focused && $0.target == nil })
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
}

@Test func recordGuidesGrowFromPaneAndRecordIndicators() throws {
    let records: [ProgramStatus.Record] = [
        record("a", .working, msg: "Activity"),
        record("a/b", .working)
    ]
    let rows = sidebarRows(fixture(records: records))
    #expect(rows[1].guides == [.init(x: 20, top: 22, bottom: 32)])
    #expect(rows[2].guides == [.init(x: 35, top: 22, bottom: 48), .init(x: 20, top: 0, bottom: 48)])
    #expect(rows[3].guides == [.init(x: 35, top: 0, bottom: 22), .init(x: 20, top: 0, bottom: 22)])
}

@Test func programIDsOrderBySlashComponents() throws {
    let records: [ProgramStatus.Record] = [
        record("a-b", .working),
        record("a/b", .working),
        record("a", .working)
    ]
    let rows = sidebarRows(fixture(records: records)).filter { if case .program = $0.id { true } else { false } }
    #expect(rows.map(\.title) == ["a", "a/b", "a-b"])
}

// The core's mark decides an outcome's status; seen records read their done and error as idle.
@Test func theSeenMarkQuietsTheOutcomeAndTheFinishedRecords() throws {
    let records: [ProgramStatus.Record] = [
        record("done", .done), record("error", .error),
        record("working", .working), record("blocked", .blocked)
    ]
    let snapshot: Snapshot = makeSnapshot([pane(0, lifecycle: agent(idle(outcome(7, .failure))), records: records, serial: 7, mark: .failed),
                                                        pane(5, lifecycle: terminal(exited(1)), mark: .failed)])
    func statuses(_ snapshot: Snapshot) -> [SidebarRow.Status] { sidebarRows(snapshot).filter { $0.kind != .gap && $0.kind != .header }.map(\.status) }
    #expect(statuses(snapshot) == [.error, .waiting, .done, .error, .running, .error])
    let seen = markedSeen(snapshot)
    #expect(statuses(seen) == [.quiet, .waiting, .quiet, .quiet, .running, .quiet])
    let tabs = sidebarWindows(seen, session: SessionID(number: 0), surviving: [WindowID(number: 0), WindowID(number: 5)]).statuses
    #expect(tabs[WindowID(number: 0)] == .quiet && tabs[WindowID(number: 5)] == .quiet)
}

@Test func contentChangesAndServerIdentity() throws {
    let records: [ProgramStatus.Record] = [record("done", .done), record("error", .error)]
    let base = fixture(client: 5, records: records)
    #expect(base != fixture(client: 5, records: records, serial: 8))
    var changed = records
    changed[0] = record("done", .done, title: "New title")
    let edited = fixture(client: 5, records: changed)
    #expect(base != edited)
    let before = sidebarRows(base), after = sidebarRows(edited)
    #expect(before.map(\.id) == after.map(\.id))
    #expect(before.map(\.height) == after.map(\.height))
    #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    #expect(makeSnapshot([pane(0)]) != makeSnapshot([pane(0)], instance: "1/1780000000"))
}

@Test func aNestedRowOmitsItsRuntimeWhenItIsTheOneOfThePaneRowAboveAndTheTopLevelAlwaysShowsIt() {
    func mark(_ name: String, routed: Bool = false, state: KoSchema.LinkState = .up) -> RuntimeMark {
        RuntimeMark(name: name, kind: .ssh, color: nil, state: state, routed: routed)
    }
    func item(_ id: Int, _ runtime: RuntimeMark?, _ children: [Node] = []) -> Node {
        guard case .item(var item) = pane(id, title: "pane-\(id)", children: children) else { preconditionFailure() }
        item.runtime = runtime
        return .item(item)
    }
    let tree = item(0, mark("buildbox"), [
        item(1, mark("buildbox", routed: true)),
        item(2, mark("py311"), [item(3, mark("py311")), item(4, nil, [item(5, mark("buildbox"))])]),
        item(6, nil),
    ])
    let rows = sidebarRows(makeSnapshot([tree, item(7, mark("buildbox", state: .starting))])).filter { $0.target != nil }
    #expect(rows.map { $0.target?.pane.number } == Array(0...7))
    #expect(rows.map { $0.runtime?.name } == ["buildbox", nil, "py311", nil, nil, "buildbox", nil, "buildbox"])
    #expect(rows.last?.runtime?.state == .starting)
}
