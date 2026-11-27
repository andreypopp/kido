import Foundation
import Testing
import KoModel

private let away = 99
private func numbers(_ rows: [SidebarRow]) -> [UInt32] { rows.compactMap { $0.target?.pane.number } }
private func programs(_ rows: [SidebarRow]) -> [String] { rows.filter { if case .program = $0.id { true } else { false } }.map(\.title) }

@Test func tiledChildrenStayVisibleAtRootDepthAndFloatsHaveNoRows() {
    guard case .item(var floating) = pane(2, window: 0, parent: 0, records: [.blocked(.init(id: "float/task"))]) else { return }
    floating.placement = .floating
    let nodes = [group(0, [pane(1, window: 0, parent: 0), pane(0), .item(floating), pane(3, window: 0, parent: 2)])]
    for focus in [away, 0, 1, 2, 3] {
        let snapshot = makeSnapshot(nodes, client: focus, window: 0)
        let rows = sidebarRows(snapshot)
        #expect(numbers(rows) == [1, 0, 3])
        #expect(rows.filter { $0.target != nil }.map(\.indent) == [0, 0, 0])
        #expect(rows.allSatisfy { $0.hidden.isEmpty })
        #expect(programs(rows).isEmpty)
        #expect(visibleSidebarRow(for: floating.id, in: rows, projection: PaneProjection(snapshot)) == nil)
    }
}





@Test func recordsFollowTheirPaneFocus() {
    let records: [KoSchema.ProgramRecord] = [.working(.init(id: "a")), .done(.init(id: "a/b"))]
    let tree = [pane(0, records: records), pane(1, parent: 0)]
    #expect(programs(sidebarRows(makeSnapshot(tree, client: away))) == [])
    #expect(programs(sidebarRows(makeSnapshot(tree, client: 0))) == ["a"])
    #expect(programs(sidebarRows(makeSnapshot(tree, client: 1))).isEmpty)
    let blocked = [pane(0, records: [.working(.init(id: "a")), .blocked(.init(id: "a/b"))])]
    let rows = sidebarRows(makeSnapshot(blocked, client: away))
    #expect(programs(rows) == ["a", "a/b"])
    #expect(rows[1].hidden.isEmpty)
}

@Test func paneAndProgramRowsAreTwoLines() {
    let tree = [pane(0, lifecycle: agent(working(), msg: "busy"), records: [.working(.init(id: "a"))]), pane(1, parent: 0)]
    let rows = sidebarRows(makeSnapshot(tree, client: 0))
    let content = rows.filter { $0.height == 43 }
    #expect(content.count == 3)
    #expect(content.map(\.leading) == [5, 20, 5])
}

@Test func secondLineIsActivityElseNone() {
    let report = report(working(), msg: "Building")
    let cases: [(Lifecycle, SidebarRow.SecondLine)] = [
        (agent(working(), msg: "Thinking"), .activity("Thinking")),
        (agent(working()), .none),
        (terminal(), .none),
        (terminal(running(), report: report), .none),
        (remote(.terminal(.init(interactive: true, status: shell()))), .none),
        (.ended(.exited(.init(code: 2))), .activity("exited with code 2")),
        (.ended(.exited(.init(code: 0))), .none),
        (.lingering(.exited(.init(code: 2))), .none)
    ]
    for (lifecycle, expected) in cases {
        let rows = sidebarRows(makeSnapshot([pane(0, cwd: "/work", lifecycle: lifecycle)]))
        #expect(rows[1].second == expected)
    }
}

@Test func recordRowsKeepTheirMessageAfterSeen() {
    let records: [KoSchema.ProgramRecord] = [.error(.init(id: "e", msg: "boom")), .done(.init(id: "d"))]
    let rows = sidebarRows(makeSnapshot([pane(0, records: records, recordsSeen: true)]))
    #expect(rows[2].status == .quiet)
    #expect(rows[3].second == .record(msg: "boom"))
    #expect(rows[3].status == .quiet)
    #expect(rows[2].second == .record(msg: nil))
}





@Test func foldedRecordCirclesSummarizeDescendantRecords() {
    let snapshot = makeSnapshot([pane(0, records: [
        .done(.init(id: "a")), .idle(.init(id: "a/b")), .working(.init(id: "a/b/c")),
        .done(.init(id: "a/d")), .working(.init(id: "a/e")), .error(.init(id: "a/e/f")), .blocked(.init(id: "a/x"))
    ])], client: away)
    let rows = sidebarRows(snapshot)
    let row = rows[2]
    #expect(row.status == .done)
    let hidden = row.hidden
    #expect(hidden == [
        .init(title: "a/e", status: .error),
        .init(title: "a/b", status: .running),
        .init(title: "a/d", status: .quiet)
    ])
}

@Test func onlyTheFocusPathOfRecordsIsOpen() {
    let rootFocused = sidebarRows(makeSnapshot([pane(0, records: [.working(.init(id: "a")), .done(.init(id: "a/b"))])], client: 0))
    #expect(programs(rootFocused) == ["a"])
    #expect(rootFocused[2].hidden == [.init(title: "a/b", status: .quiet)])

    let viewed: [KoSchema.ProgramRecord] = [.working(.init(id: "a", selection: .selected)), .working(.init(id: "a/b")), .working(.init(id: "a/b/c"))]
    let rows = sidebarRows(makeSnapshot([pane(0, records: viewed)], client: 0))
    #expect(programs(rows) == ["a", "a/b"])
    #expect(rows[3].hidden == [.init(title: "a/b/c", status: .running)])

    let blocked = sidebarRows(makeSnapshot([pane(0, records: [.working(.init(id: "a")), .blocked(.init(id: "a/b"))])], client: 0))
    #expect(programs(blocked) == ["a", "a/b"])

    let nested: [KoSchema.ProgramRecord] = [.working(.init(id: "a", selection: .selected)), .working(.init(id: "a/b")), .working(.init(id: "a/b/c"))]
    let child = sidebarRows(makeSnapshot([pane(0), pane(1, parent: 0, records: nested)], client: 1))
    #expect(numbers(child) == [0, 1])
    #expect(programs(child) == ["a", "a/b"])
    #expect(child[4].hidden == [.init(title: "a/b/c", status: .running)])
}

@Test func aFoldedRecordSelectionUsesItsNearestVisibleAncestor() {
    let records: [KoSchema.ProgramRecord] = [.working(.init(id: "a")), .working(.init(id: "a/b"))]
    let session = SessionID(number: 0)
    let leaf = SidebarRow.ID.program(session, PaneID(number: 0), Data("a/b".utf8))
    let open = makeSnapshot([pane(0, records: [.working(.init(id: "a", selection: .selected)), .working(.init(id: "a/b"))] )], client: 0)
    let viewed = makeSnapshot([pane(0, records: records)], client: 0)
    #expect(sidebarRows(open).contains { $0.id == leaf })
    #expect(visibleSidebarRow(replacing: leaf, in: sidebarRows(viewed), projection: PaneProjection(viewed)) == 2)
    let elsewhere = makeSnapshot([pane(0, records: records)], client: away)
    #expect(visibleSidebarRow(replacing: leaf, in: sidebarRows(elsewhere), projection: PaneProjection(elsewhere)) == 1)
}

@Test func aPaneSelectionNeverUsesItsLifetimeParent() {
    let snapshot = makeSnapshot([pane(0), pane(1, parent: 0), pane(2, parent: 1)], client: 2)
    let projection = PaneProjection(snapshot)
    let rows = sidebarRows(snapshot)
    #expect(visibleSidebarRow(for: PaneID(number: 2), in: rows, projection: projection) == 3)
    #expect(visibleSidebarRow(for: PaneID(number: 2), in: Array(rows.prefix(3)), projection: projection) == nil)
    #expect(visibleSidebarRow(for: PaneID(number: 99), in: rows, projection: projection) == nil)
}

@testable import SidebarFeed

private func fixture(client: Int = 0, sessions: [Int] = [0], grouped: Bool = false, descendants: Bool = false, records: [KoSchema.ProgramRecord] = [], serial: Int = 7) -> Snapshot {
    func item(_ id: Int, _ window: Int, tail: String = "", lifecycle: Lifecycle? = nil) -> Node {
        let lifecycle = lifecycle ?? agent(id == 2 ? waiting() : working(), msg: tail.isEmpty ? nil : tail)
        return pane(id, window: window, title: "pane-\(id)", lifecycle: lifecycle,
                    records: id == 0 ? records : [], serial: serial)
    }
    let nodes: [Node] = grouped
        ? [group(0, descendants
            ? [item(0, 0), item(1, 0, tail: "child"), item(2, 0), item(5, 0, tail: "parent"), item(3, 0), item(6, 0)]
            : [item(0, 0), item(5, 0)])]
        : [item(0, 0), item(5, 5), item(1, 1, tail: "working", lifecycle: koaAgent(working(), msg: "working")),
           item(2, 2, lifecycle: terminal(running(), report: report(waiting()))), item(3, 3, lifecycle: terminal(running())),
           item(4, 4, lifecycle: terminal(running()))]
    return makeSnapshot(nodes, client: client, window: grouped ? 0 : nil, sessions: sessions)
}

@Test func visibleWindowBlockSlices() {
    let single = sidebarRows(makeSnapshot([pane(0)]))
    #expect(single.compactMap(\.block).isEmpty)
    let snapshot = fixture(client: 2, grouped: true, descendants: true, records: [.working(.init(id: "task"))])
    let rows = renderedRows(snapshot)
    let block = rows.filter { $0.root == WindowID(number: 0) }
    #expect(block.first?.block == .first)
    #expect(block.last?.block == .last)
    #expect(block.dropFirst().dropLast().allSatisfy { $0.block == .middle })
    #expect(!block.contains { if case .program = $0.kind { true } else { false } })
    #expect(rows.filter { $0.root == nil }.allSatisfy { $0.block == nil })
    let parent = makeSnapshot([pane(0), pane(1, parent: 0)], client: 1)
    let folded = sidebarRows(parent)
    #expect(folded.compactMap(\.block).isEmpty)
    #expect(renderedRows(parent).compactMap(\.block).isEmpty)
    let sessions = renderedRows(fixture(sessions: [0, 1], grouped: true))
    let current = sessions.filter { $0.id.session == SessionID(number: 0) && $0.root == WindowID(number: 0) }
    #expect(current.compactMap(\.block) == [.first, .last])
    #expect(sessions.filter { $0.id.session != SessionID(number: 0) || $0.root != WindowID(number: 0) }.allSatisfy { $0.block == nil })
}

@Test func dividerPassAfterWindowRemoval() {
    let rows = sidebarRows(makeSnapshot([pane(0), pane(1), pane(2)]))
    for removed in 0...2 {
        let kept = rows.filter { $0.root != WindowID(number: UInt32(removed)) }
        let divided = sidebarDividers(kept)
        #expect(divided.filter { $0.kind == .divider }.map(\.id) == [.divider(SessionID(number: 0), WindowID(number: removed == 2 ? 1 : 2))])
        #expect(divided.first?.kind == .header)
        #expect(divided.last?.kind == .gap)
        let divider = divided.firstIndex { $0.kind == .divider }!
        #expect(divided[divider - 1].root != nil)
        #expect(divided[divider + 1].root != nil)
    }
}

@Test func dividersSeparateOnlyTopLevelWindows() {
    let snapshot = fixture(sessions: [0, 1], grouped: true, descendants: true)
    #expect(sidebarRows(snapshot).filter { $0.height == 9 }.isEmpty)
    let separate = fixture(sessions: [0, 1])
    let rows = renderedRows(separate)
    #expect(rows.filter { $0.height == 9 }.count == 10)
    #expect(rows.filter { $0.height == 9 }.allSatisfy { $0.target == nil && $0.root == nil })
}

@Test func layoutWindowsAndExactSpacing() throws {
    let rows = renderedRows(fixture(client: 2))
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map(\.indent) == [0, 0, 0, 0, 0, 0])
    #expect(rows.map(\.height) == [26, 43, 9, 43, 9, 43, 9, 43, 9, 43, 9, 43, 10])
    #expect(panes.filter(\.focused).map(\.title) == ["pane-2"])
    #expect(renderedRows(fixture(client: 1)).filter(\.focused).map(\.title) == ["@pane-1"])
    #expect(renderedRows(fixture(client: 2)).filter(\.focused).map(\.title) == ["pane-2"])
}

@Test func groupedPanesStayContiguous() throws {
    let rows = renderedRows(fixture(grouped: true))
    #expect(rows.map(\.height) == [26, 43, 43, 10])
    #expect(rows.filter(\.focused).count == 1)
    #expect(rows.allSatisfy { $0.height > 0 })
}

@Test func everyTiledPaneStaysVisibleInLayoutOrder() throws {
    let rows = renderedRows(fixture(client: 2, grouped: true, descendants: true))
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map { $0.target!.pane } == [0, 1, 2, 5, 3, 6].map { PaneID(number: UInt32($0)) })
    #expect(panes.map(\.indent) == [0, 0, 0, 0, 0, 0])
    let sibling = renderedRows(fixture(client: 3, grouped: true, descendants: true)).filter { $0.target != nil }
    #expect(sibling.map { $0.target!.pane } == [0, 1, 2, 5, 3, 6].map { PaneID(number: UInt32($0)) })
    #expect(sibling.map(\.indent) == [0, 0, 0, 0, 0, 0])
    #expect(rows.filter(\.focused).count == 1)
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test(arguments: [(false, false), (false, true), (true, false)])
func heightAndPaddingMatrix(_ nested: Bool, _ multi: Bool) throws {
    let lifecycle = agent(working())
    let leaf = pane(1, lifecycle: lifecycle)
    let node = multi ? group(1, [leaf, pane(2, window: 1, lifecycle: lifecycle)]) : leaf
    let snapshot = makeSnapshot(nested ? [pane(0, lifecycle: lifecycle), node] : [node], client: 1)
    let row = try #require(renderedRows(snapshot).first { $0.target?.pane == PaneID(number: 1) })
    #expect(row.height == 43)
    #expect(row.padding == 5)
    #expect(row.leading == 5)
    #expect(row.tailY == 24)
    #expect(row.focused)
    #expect(renderedRows(snapshot).filter(\.focused).count == 1)
    #expect(renderedRows(snapshot).allSatisfy { $0.height > 0 })
}

@Test func singleSessionKeepsIdentity() throws {
    let rows = renderedRows(fixture(sessions: [0, 1]))
    let singleSession = renderedRows(fixture(sessions: [0]))
    #expect(singleSession == rows.filter { $0.id.session == SessionID(number: 0) })
    #expect(renderedRows(fixture(sessions: [])).isEmpty)
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(rows.filter { $0.focused }.count == 1)
}

@Test func paneTargetsAndCaptions() throws {
    let panes = renderedRows(fixture(client: 2)).filter { $0.target != nil }
    #expect(panes.allSatisfy { if case .pane = $0.kind { return true }; return false })
    #expect(panes.first { $0.title == "@pane-1" }?.second == .activity("working"))
    #expect(panes.map(\.height) == [43, 43, 43, 43, 43, 43])
}

@Test func agentWeightAndDisplayOnlyPrefix() throws {
    let cases: [(Lifecycle, String, String, String, Bool)] = [
        (koaAgent(idle()), "Ada", "@Ada", "Ada", true),
        (agent(idle()), "Ada", "Ada", "Ada", true),
        (agent(), "@Ada", "@Ada", "@Ada", true),
        (remote(.agent(.init(name: "pi", status: report(idle())))), "Ada", "Ada", "Ada", true),
        (.ended(.exited(.init(code: 0))), "Ada", "Ada", "Ada", false),
        (terminal(.unknown), "zsh", "zsh", "zsh", false),
        (remote(.terminal(.init(interactive: true, status: shell()))), "ssh", "ssh alice@devbox", "ssh alice@devbox", false),
        (.live(.ssh(.init(destination: "@host", foreground: 1, pane: .terminal(.init(interactive: true, status: shell()))))), "ssh", "ssh @host", "ssh @host", false),
        (.ended(.exited(.init(code: 2))), "monitor", "monitor", "monitor", false)
    ]
    for (lifecycle, title, expected, tab, agent) in cases {
        let snapshot = makeSnapshot([pane(0, title: title, lifecycle: lifecycle)])
        let row = try #require(renderedRows(snapshot).first { $0.target != nil })
        #expect(row.title == expected)
        #expect(row.showsTitleWhenFolded == agent)
        #expect(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0)],
                               activePanes: [WindowID(number: 0): PaneID(number: 0)]).labels[WindowID(number: 0)]?.title == tab)
    }
}

@Test func composedLabelsCaptionsAndStatuses() throws {
    let failedReport = report(idle(outcome(4, .failure)), msg: "Build failed")
    let cases: [(Lifecycle, String, Bool, SidebarRow.Status, KoSchema.Mark, String, String?)] = [
        (terminal(), "Terminal", true, .quiet, .none_, "idle", nil),
        (terminal(.pending(.init(last: nil))), "Terminal", true, .quiet, .none_, "idle", nil),
        (terminal(.pending(.init(last: .init(code: 130, command: "false", endedAt: since + 1, startedAt: since)))), "Terminal", true, .error, .failed, "failed", nil),
        (terminal(exited(0)), "Terminal", true, .done, .done, "done", nil),
        (terminal(exited(130)), "Terminal", true, .error, .failed, "failed", nil),
        (terminal(report: report(idle())), "Terminal", true, .quiet, .none_, "idle", nil),
        (terminal(report: failedReport), "Terminal", true, .error, .failed, "failed", nil),
        (terminal(.unknown), "zsh", false, .quiet, .none_, "idle", nil),
        (terminal(.unknown, report: report(idle(outcome(2, .success)), msg: "Built")), "zsh", false, .done, .done, "done", nil),
        (terminal(running(nil, fullscreen: true)), "zsh", false, .quiet, .none_, "idle", nil),
        (terminal(running(nil)), "zsh", false, .running, .running, "running", nil),
        (remote(.terminal(.init(interactive: true, status: shell(running(nil))))), "ssh alice@devbox", false, .running, .running, "running", nil),
        (remote(.terminal(.init(interactive: true, status: shell(running("nvim", fullscreen: true))))), "ssh alice@devbox", false, .running, .running, "running", nil),
        (terminal(running("nvim", fullscreen: true), report: report(waiting(.auth), msg: "Login required")), "zsh", false, .waiting, .waiting, "waiting", nil),
        (terminal(running()), "make", false, .running, .running, "running", nil),
        (terminal(running("")), "zsh", false, .running, .running, "running", nil),
        (terminal(running(), report: report(working(42), msg: "Building")), "zsh", false, .running, .running, "running", nil),
        (terminal(exited(1), report: report(waiting(.auth), msg: "Login required")), "zsh", false, .waiting, .waiting, "waiting", nil),
        (remote(.terminal(.init(interactive: true, status: shell(running())))), "ssh alice@devbox: make", false, .running, .running, "running", nil),
        (remote(.terminal(.init(interactive: false, status: shell(running())))), "ssh alice@devbox", false, .running, .running, "running", nil),
        (remote(.terminal(.init(interactive: true, status: shell(running(), report: report(working()))))), "ssh alice@devbox", false, .running, .running, "running", nil),
        (remote(.terminal(.init(interactive: true, status: shell(exited(2))))), "ssh alice@devbox", false, .error, .failed, "failed", nil),
        (agent(working(42), msg: "Thinking"), "zsh", false, .running, .running, "running", "Thinking 42%"),
        (agent(waiting(.permission), msg: "Approve deployment"), "zsh", false, .waiting, .waiting, "waiting", "Approve deployment"),
        (agent(idle(outcome(17, .success)), msg: "Finished"), "zsh", false, .done, .done, "done", "Finished"),
        (agent(idle(outcome(18, .failure)), msg: "Failed"), "zsh", false, .error, .failed, "failed", "Failed"),
        (.ended(.exited(.init(code: 0))), "zsh", false, .done, .none_, "gone, completed", nil),
        (.ended(.exited(.init(code: 2))), "zsh", false, .error, .none_, "gone, exited with code 2", "exited with code 2"),
        (.ended(.signaled(.init(signal: 9))), "zsh", false, .error, .none_, "gone, killed by signal 9", "killed by signal 9"),
        (.lingering(.exited(.init(code: 0))), "zsh", false, .endedClean, .none_, "gone, exited", nil),
        (.lingering(.exited(.init(code: 2))), "zsh", false, .endedFailed, .none_, "gone, exited with code 2", nil),
    ]
    for (lifecycle, title, quiet, status, mark, description, activity) in cases {
        let snapshot = makeSnapshot([pane(0, title: "zsh", lifecycle: lifecycle, mark: mark)])
        let row = try #require(renderedRows(snapshot).first { $0.target != nil })
        #expect(row.title == title)
        #expect(row.quietShell == quiet)
        if case .live(let kind) = lifecycle, case .terminal(let shell) = kind.local, case .pending(let exit) = shell.phase,
           case .item(let item) = snapshot.sessions[0].nodes[0] {
            #expect(item.lastCommand == exit.last)
        }
        #expect(row.status == status)
        #expect(row.indicatorDescription == description)
        #expect(row.second == activity.map { .activity($0) } ?? .none)
        #expect(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == status.mergingTabStatus(.quiet))
    }
}

@Test func navigationOrderAndFallback() throws {
    let snapshot = fixture(client: 2, sessions: [0, 1])
    let panes = renderedRows(snapshot).compactMap(\.target)
    #expect(panes.map(\.pane) == [0, 5, 1, 2, 3, 4, 0, 5, 1, 2, 3, 4].map { PaneID(number: UInt32($0)) })
    #expect(panes.first == Snapshot.Position(session: SessionID(number: 0), window: WindowID(number: 0), pane: PaneID(number: 0)))
    #expect(renderedRows(fixture(sessions: [])).compactMap(\.target).isEmpty)
}

@Test func programRowsOrderingGeometryAndNavigation() throws {
    let records: [KoSchema.ProgramRecord] = [
        .idle(.init(id: "z", title: "")),
        .error(.init(id: "a-")),
        .blocked(.init(id: "a/missing/leaf", msg: "Record-only caption")),
        .working(.init(id: "a", title: "Record-only title")),
        .blocked(.init(id: "a/child")),
        .idle(.init(id: "é")), .idle(.init(id: "é")),
        .working(.init(id: "", title: "Root"))
    ]
    let snapshot = fixture(grouped: true, descendants: true, records: records)
    let rows = renderedRows(snapshot)
    let programs = rows.filter { if case .program = $0.id { true } else { false } }
    #expect(programs.map(\.title) == ["Record-only title", "a/child", "a/missing/leaf", "a-", "é", "z", "é"])
    #expect(programs.map(\.leading) == [20, 35, 35, 20, 20, 20, 20])
    #expect(programs.allSatisfy { $0.target == nil && $0.showsTitleWhenFolded })
    #expect(programs.allSatisfy { $0.height == 43 })
    #expect(programs.allSatisfy { $0.padding == 5 && $0.tailY == 24 && !$0.focused && $0.target == nil })
    #expect(programs.map(\.status) == [.running, .waiting, .waiting, .error, .quiet, .quiet, .quiet])
    #expect(rows[1].target?.pane == PaneID(number: 0))
    #expect(rows[9].target?.pane == PaneID(number: 1))
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(rows.compactMap(\.target).map(\.pane) == [0, 1, 2, 5, 3, 6].map { PaneID(number: UInt32($0)) })
}

@Test func recordIndentsCountOnlyPresentAncestors() throws {
    let records = ["a/b/c", "a/b", "a", "a/d/e", "a/", "a//b", "/", "/b", "", "e\u{301}", "z", "\u{e9}/child"]
        .map { KoSchema.ProgramRecord.blocked(.init(id: $0)) }
    let snapshot = makeSnapshot([pane(0), pane(1, parent: 0, records: records)], client: 1)
    let rows = renderedRows(snapshot).filter { if case .program = $0.id { true } else { false } }
    #expect(rows.map(\.title) == ["/", "/b", "a", "a/", "a//b", "a/b", "a/b/c", "a/d/e", "e\u{301}", "z", "\u{e9}/child"])
    #expect(rows.map(\.indent) == [1, 1, 1, 2, 3, 2, 3, 2, 1, 1, 1])
}

@Test func programIDsOrderBySlashComponents() throws {
    let records: [KoSchema.ProgramRecord] = [
        .blocked(.init(id: "a-b")),
        .blocked(.init(id: "a/b")),
        .blocked(.init(id: "a"))
    ]
    let rows = renderedRows(fixture(records: records)).filter { if case .program = $0.id { true } else { false } }
    #expect(rows.map(\.title) == ["a", "a/b", "a-b"])
}

// The core's mark decides an outcome's status; seen records read their done and error as idle.
@Test func theSeenMarkQuietsTheOutcomeAndTheFinishedRecords() throws {
    let records: [KoSchema.ProgramRecord] = [
        .done(.init(id: "done")), .error(.init(id: "error")),
        .working(.init(id: "working")), .blocked(.init(id: "blocked"))
    ]
    let snapshot: Snapshot = makeSnapshot([pane(0, lifecycle: agent(idle(outcome(7, .failure))), records: records, serial: 7, mark: .failed),
                                                        pane(5, lifecycle: terminal(exited(1)), mark: .failed)])
    func statuses(_ snapshot: Snapshot) -> [SidebarRow.Status] { renderedRows(snapshot).filter { switch $0.kind { case .pane, .program: true; default: false } }.map(\.status) }
    #expect(statuses(snapshot) == [.error, .waiting, .done, .error, .running, .error])
    let seen = markedSeen(snapshot)
    #expect(statuses(seen) == [.quiet, .waiting, .quiet, .quiet, .running, .quiet])
    let tabs = sidebarWindows(seen, projection: PaneProjection(seen), session: SessionID(number: 0), surviving: [WindowID(number: 0), WindowID(number: 5)]).statuses
    #expect(tabs[WindowID(number: 0)] == .quiet && tabs[WindowID(number: 5)] == .quiet)
}

@Test func contentChangesAndServerIdentity() throws {
    let records: [KoSchema.ProgramRecord] = [.done(.init(id: "done")), .error(.init(id: "error"))]
    let base = fixture(records: records)
    #expect(base != fixture(records: records, serial: 8))
    var changed = records
    changed[0] = .done(.init(id: "done", title: "New title"))
    let edited = fixture(records: changed)
    #expect(base != edited)
    let before = renderedRows(base), after = renderedRows(edited)
    #expect(before.map(\.id) == after.map(\.id))
    #expect(before.map(\.height) == after.map(\.height))
    #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    #expect(makeSnapshot([pane(0)]) != makeSnapshot([pane(0)], instance: "1/1780000000"))
}

@Test func everyPaneRowShowsItsRuntime() {
    func mark(_ name: String, routed: Bool = false, state: KoSchema.LinkState = .up) -> RuntimeMark {
        RuntimeMark.known(.init(kind: .ssh, name: name, source: .config, state: state), routed: routed)
    }
    func item(_ id: Int, _ runtime: RuntimeMark?) -> Node {
        guard case .item(var item) = pane(id, title: "pane-\(id)") else { preconditionFailure() }
        item.runtime = runtime
        return .item(item)
    }
    let tree = [item(0, mark("buildbox")), item(1, mark("buildbox", routed: true)),
                item(2, mark("py311")), item(3, mark("py311")), item(4, nil), item(5, mark("buildbox")), item(6, nil),
                item(7, mark("buildbox", state: .starting))]
    let rows = renderedRows(makeSnapshot(tree, client: 5)).filter { $0.target != nil }
    #expect(rows.map { $0.target?.pane.number } == Array(0...7))
    #expect(rows.map { $0.runtime?.name } == ["buildbox", "buildbox", "py311", "py311", nil, "buildbox", nil, "buildbox"])
    #expect(rows.last?.runtime?.state == .starting)
}

private func recordRows(_ records: [KoSchema.ProgramRecord], client: Int, lifecycle: Lifecycle = koaAgent()) -> [SidebarRow] {
    sidebarRows(makeSnapshot([pane(0, lifecycle: lifecycle, records: records)], client: client)).filter { $0.target != nil || programs([$0]) != [] }
}

@Test func recordsWithASelectionOnAnOpenInboxAreClickTargets() {
    let records: [KoSchema.ProgramRecord] = [.working(.init(id: "a", selection: .selected)), .idle(.init(id: "b", selection: .offered)), .done(.init(id: "c"))]
    let rows = recordRows(records, client: 0)
    #expect(rows.map { $0.clickTarget != nil } == [true, true, true, false])
    #expect(rows.map(\.pick) == [nil, .init(pane: rows[0].target!, record: "a"), .init(pane: rows[0].target!, record: "b"), nil])
}

@Test func thePaneRowOfAShownRecordOnAnOpenInboxCarriesTheRootPick() {
    let shown: [KoSchema.ProgramRecord] = [.working(.init(id: "a", selection: .selected)), .idle(.init(id: "b", selection: .offered))]
    let own = recordRows(shown, client: 0)
    #expect(own[0].rootPick == .init(pane: own[0].target!, record: ""))
    #expect(own[0].pick == nil)
    let other = sidebarRows(makeSnapshot([pane(0, lifecycle: koaAgent(), records: shown), pane(1)], client: 1)).filter { $0.target != nil }
    #expect(other[0].rootPick == .init(pane: other[0].target!, record: ""))
    #expect(recordRows([.idle(.init(id: "b", selection: .offered))], client: 0)[0].rootPick == nil)
    #expect(recordRows(shown, client: 0, lifecycle: agent())[0].rootPick == nil)
}

@Test func onlyACloseableRecordOnAnOpenInboxOffersAClose() {
    let records: [KoSchema.ProgramRecord] = [.working(.init(closeable: true, id: "a", selection: .offered)), .idle(.init(closeable: true, id: "c")), .done(.init(id: "d", selection: .offered))]
    let rows = recordRows(records, client: 0)
    #expect(rows.map { $0.closing?.record } == [nil, "a", "c", nil])
    #expect(rows.map { $0.pick?.record } == [nil, "a", nil, "d"])
    #expect(rows[1].closing?.actions == [.select, .close])
    #expect(rows[2].clickTarget == nil)
    #expect(recordRows(records, client: 0, lifecycle: agent()).map { $0.closing == nil } == [true, true, true, true])
}

@Test func aSelectionOnAClosedInboxMarksButIsNoClickTarget() {
    let rows = recordRows([.working(.init(id: "a", selection: .selected)), .idle(.init(id: "b", selection: .offered))], client: 0, lifecycle: agent())
    #expect(rows.map { $0.clickTarget != nil } == [true, false, false])
    #expect(rows.map(\.focused) == [false, true, false])
}

@Test func theMarkMovesToTheSelectedRecordOnlyWhileThePaneIsFocused() {
    let selected: [KoSchema.ProgramRecord] = [.working(.init(id: "a")), .idle(.init(id: "b", selection: .selected))]
    #expect(recordRows(selected, client: 0).map(\.focused) == [false, false, true])
    #expect(recordRows(selected, client: away).map(\.focused) == [false])
    #expect(recordRows([.working(.init(id: "a")), .idle(.init(id: "b", selection: .offered))], client: 0).map(\.focused) == [true, false, false])
}

@Test func theFirstSelectedRecordByIdIsMarked() {
    let rows = recordRows([.idle(.init(id: "b", selection: .selected)), .idle(.init(id: "a", selection: .selected))], client: 0)
    #expect(rows.filter(\.focused).map(\.title) == ["a"])
}
