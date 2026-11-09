import Foundation
import Testing
import KoModel

@Test func foldingKeepsOnlyWaitPathsAndExplicitChoices() {
    let root = PaneID(number: 0), session = SessionID(number: 0)
    let waitingSnapshot = makeSnapshot([pane(0, children: [pane(1, children: [pane(2, lifecycle: agent(waiting()), mark: .waiting)]), pane(3, lifecycle: agent(idle(outcome(1, .failure))), mark: .failed)])])
    let rows = sidebarRows(waitingSnapshot).rows
    #expect(rows.compactMap { $0.target?.pane.number } == [0, 1, 2])
    #expect(rows[1].height == 42)
    if case .folded(let hidden) = rows[1].children { #expect(hidden.map(\.status) == [.error]) } else { Issue.record("missing hidden child") }
    #expect(rows[2].children == .folded([]))
    let cleared = makeSnapshot([pane(0, children: [pane(1, children: [pane(2)]), pane(3)])])
    #expect(sidebarRows(cleared).rows.compactMap { $0.target?.pane.number } == [0])
    var expansion = SidebarExpansion()
    expansion.reconcile(sidebarRows(waitingSnapshot).ids)
    expansion.set(.pane(session, root), expanded: true)
    expansion.reconcile(sidebarRows(cleared).ids)
    #expect(sidebarRows(cleared, expanded: expansion.expanded).rows.compactMap { $0.target?.pane.number } == [0, 1, 3])
    #expect(sidebarRows(cleared, expanded: expansion.expanded).rows[1].height == 28)
    expansion.set(.pane(session, PaneID(number: 3)), expanded: true)
    expansion.reconcile(sidebarRows(makeSnapshot([pane(0, children: [pane(1)])])).ids)
    #expect(expansion.expanded == [.pane(session, root)])
}

@Test(arguments: [0, 1, 6, 7]) func foldedCountsAndIdleSpace(_ count: Int) {
    let snapshot = makeSnapshot([pane(0, children: (1...max(1, count)).prefix(count).map { pane($0) })])
    let row = sidebarRows(snapshot).rows[1]
    if count == 0 { #expect(row.children == .leaf); #expect(row.height == 28) }
    else if case .folded(let hidden) = row.children {
        #expect(hidden.count == count)
        #expect(hidden.allSatisfy { $0.status == .quiet })
        #expect(row.height == 42)
    } else { Issue.record("missing folded children") }
}

@Test func foldedSingleChildNamesOnlyAgents() {
    for (lifecycle, title) in [(agent(working()), Optional("child")), (terminal(), nil)] {
        let snapshot = makeSnapshot([pane(0, children: [pane(1, title: "child", lifecycle: lifecycle, mark: .running)])])
        let row = sidebarRows(snapshot).rows[1]
        guard case .folded(let hidden) = row.children else { Issue.record("missing folded child"); continue }
        #expect(hidden.count == 1)
        #expect(hidden.first?.title == title)
    }
}

@Test func foldedCirclesOrderReducedStatusesAndKeepSidebarTies() {
    let children = (1...6).map { pane($0, title: "idle-\($0)", lifecycle: agent(idle())) } + [
        pane(7, title: "running-7", lifecycle: agent(working()), mark: .running),
        pane(8, title: "error-8", lifecycle: agent(idle(outcome(1, .failure))), mark: .failed),
        pane(9, title: "running-9", lifecycle: agent(working()), mark: .running)
    ]
    let row = sidebarRows(makeSnapshot([pane(0, children: children)])).rows[1]
    #expect(row.children == .folded([
        .init(title: "error-8", status: .error),
        .init(title: "running-7", status: .running),
        .init(title: "running-9", status: .running),
        .init(title: "idle-1", status: .quiet),
        .init(title: "idle-2", status: .quiet),
        .init(title: "idle-3", status: .quiet),
        .init(title: "idle-4", status: .quiet),
        .init(title: "idle-5", status: .quiet),
        .init(title: "idle-6", status: .quiet)
    ]))
}

@Test func foldedCirclesSummarizePaneSubtrees() {
    func runningChild(_ id: Int) -> Node { pane(id, lifecycle: agent(working()), mark: .running) }
    let children = [
        pane(1, title: "done", lifecycle: agent(idle(outcome(1, .success))), mark: .done),
        pane(2, title: "failed", lifecycle: .lingering(.exited(.init(code: 2)))),
        pane(3, title: "live subtree", lifecycle: agent(idle()), children: [runningChild(30)]),
        pane(4, title: "ended subtree", lifecycle: .ended(.exited(.init(code: 0))), children: [runningChild(40)]),
        pane(5, title: "lingering subtree", lifecycle: .lingering(.exited(.init(code: 0))), children: [runningChild(50)]),
        pane(6, title: "working record", lifecycle: agent(idle()), records: [.working(.init(id: "task"))]),
        pane(7, title: "failed subtree", lifecycle: agent(idle()), children: [runningChild(70), pane(10, lifecycle: agent(idle(outcome(1, .failure))), mark: .failed)]),
        pane(8, title: "seen record", lifecycle: agent(idle()), records: [.error(.init(id: "seen"))], recordsSeen: true)
    ]
    let row = sidebarRows(makeSnapshot([pane(0, children: children)])).rows[1]
    guard case .folded(let hidden) = row.children else { Issue.record("missing circles"); return }
    #expect(hidden == [
        .init(title: nil, status: .error),
        .init(title: "failed subtree", status: .error),
        .init(title: "live subtree", status: .running),
        .init(title: nil, status: .running),
        .init(title: nil, status: .running),
        .init(title: "working record", status: .running),
        .init(title: "done", status: .quiet),
        .init(title: "seen record", status: .quiet)
    ])
    #expect(row.status == .quiet)
}

@Test func foldedRecordCirclesSummarizeDescendantRecords() {
    let snapshot = makeSnapshot([pane(0, records: [
        .done(.init(id: "a")), .idle(.init(id: "a/b")), .working(.init(id: "a/b/c")),
        .done(.init(id: "a/d")), .working(.init(id: "a/e")), .error(.init(id: "a/e/f"))
    ])])
    let rows = sidebarRows(snapshot, expanded: [.pane(.init(number: 0), .init(number: 0))]).rows
    let row = rows[2]
    #expect(row.status == .done)
    guard case .folded(let hidden) = row.children else { Issue.record("missing circles"); return }
    #expect(hidden == [
        .init(title: "a/e", status: .error),
        .init(title: "a/b", status: .running),
        .init(title: "a/d", status: .quiet)
    ])
}

@Test func waitOnlyParentsKeepExplicitPaneAndRecordFolds() {
    let session = SessionID(number: 0), root = PaneID(number: 0)
    for records in [false, true] {
        func snapshot(wait: Bool) -> Snapshot {
            if records {
                return makeSnapshot([pane(0, records: [
                    .working(.init(id: "a")),
                    wait ? .blocked(.init(id: "a/b")) : .idle(.init(id: "a/b"))
                ])])
            }
            return makeSnapshot([pane(0, children: [pane(1, lifecycle: agent(wait ? waiting() : idle()), mark: wait ? .waiting : .none_)])])
        }
        let id: SidebarRow.ID = records ? .program(session, root, Data("a".utf8)) : .pane(session, root)
        var expansion = SidebarExpansion()
        if records { expansion.set(.pane(session, root), expanded: true) }
        let folded = sidebarRows(snapshot(wait: true), expanded: expansion.expanded)
        #expect(folded.rows.first { $0.id == id }?.children == .folded([]))
        expansion.set(id, expanded: true)
        let opened = sidebarRows(snapshot(wait: true), expanded: expansion.expanded)
        #expect(opened.rows.map(\.id) == folded.rows.map(\.id))
        #expect(opened.rows.first { $0.id == id }?.children == .expanded)
        #expect(sidebarRows(snapshot(wait: false), expanded: expansion.expanded).rows.map(\.id) == opened.rows.map(\.id))
        expansion.set(id, expanded: false)
        #expect(sidebarRows(snapshot(wait: true), expanded: expansion.expanded).rows.map(\.id) == folded.rows.map(\.id))
        #expect(sidebarRows(snapshot(wait: false), expanded: expansion.expanded).rows.count == folded.rows.count - 1)
        expansion.expandAll(folded)
        #expect(expansion.expanded.contains(id))
    }
}

@Test func aHiddenSelectionUsesItsNearestVisibleAncestor() {
    let snapshot = makeSnapshot([pane(0, children: [pane(1, children: [pane(2)])])], client: 2)
    let projection = PaneProjection(snapshot)
    #expect(visibleSidebarRow(for: PaneID(number: 2), in: sidebarRows(snapshot).rows, projection: projection) == 1)
    let rows = sidebarRows(snapshot, expanded: [.pane(.init(number: 0), .init(number: 0))]).rows
    #expect(visibleSidebarRow(for: PaneID(number: 2), in: rows, projection: projection) == 2)
    #expect(visibleSidebarRow(for: PaneID(number: 99), in: rows, projection: projection) == nil)
}

@Test func childrenAreFoldedUntilTheyWait() {
    let snapshot = makeSnapshot([pane(0, children: [pane(1, children: [pane(2)])]), pane(3)])
    #expect(sidebarRows(snapshot).rows.compactMap { $0.target?.pane.number } == [0, 3])
    let waiting = makeSnapshot([pane(0, children: [pane(1, children: [pane(2, lifecycle: agent(SidebarFeedTests.waiting()), mark: .waiting)]), pane(4)])])
    #expect(sidebarRows(waiting).rows.compactMap { $0.target?.pane.number } == [0, 1, 2])
}
@testable import SidebarFeed

private func fixture(client: Int = 0, sessions: [Int] = [0], grouped: Bool = false, descendants: Bool = false, records: [KoSchema.ProgramRecord] = [], serial: Int = 7) -> Snapshot {
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

@Test func visibleWindowBlockSlices() {
    let single = sidebarRows(makeSnapshot([pane(0)])).rows
    #expect(single.compactMap(\.block) == [.single])
    let snapshot = fixture(client: 2, grouped: true, descendants: true, records: [.working(.init(id: "task"))])
    let rows = expandedRows(snapshot)
    let block = rows.filter { $0.root == WindowID(number: 0) }
    #expect(block.first?.block == .first)
    #expect(block.last?.block == .last)
    #expect(block.dropFirst().dropLast().allSatisfy { $0.block == .middle })
    #expect(block.contains { if case .program = $0.kind { true } else { false } })
    #expect(rows.filter { $0.root == nil }.allSatisfy { $0.block == nil })
    let folded = sidebarRows(makeSnapshot([pane(0, children: [pane(1)])], client: 1)).rows
    #expect(folded.compactMap(\.block) == [.single])
    let sessions = expandedRows(fixture(sessions: [0, 1]))
    #expect(sessions.filter { $0.id.session != SessionID(number: 0) }.allSatisfy { $0.block == nil })
}

@Test func dividerPassAfterWindowRemoval() {
    let rows = sidebarRows(makeSnapshot([pane(0), pane(1), pane(2)])).rows
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

@Test func shownPaneUsesCurrentProjectionTitles() {
    let snapshot = makeSnapshot([pane(0, title: "Root", lifecycle: agent(working()), children: [pane(1, title: "Child", lifecycle: agent(working()), children: [pane(2, title: "Shown", lifecycle: agent(working()))])])])
    let projection = PaneProjection(snapshot)
    var slots = PaneSlots()
    slots.show(PaneID(number: 2), in: projection)
    let shown = projection.shown(PaneID(number: 0), slots: slots)
    #expect(shown?.shown.title == "Shown")
    #expect(shown?.ancestors.map(\.title) == ["Root", "Child"])
    #expect(shown?.ancestors.map { $0.position.pane.number } == [0, 1])
    slots.show(PaneID(number: 0), in: projection)
    #expect(projection.shown(PaneID(number: 0), slots: slots)?.ancestors.isEmpty == true)
    #expect(projection.shown(PaneID(number: 99), slots: slots) == nil)
}

@Test func dividersSeparateOnlyTopLevelWindows() {
    let snapshot = fixture(sessions: [0, 1], grouped: true, descendants: true)
    #expect(sidebarRows(snapshot).rows.filter { $0.height == 9 }.isEmpty)
    let separate = fixture(sessions: [0, 1])
    let rows = expandedRows(separate)
    #expect(rows.filter { $0.height == 9 }.count == 2)
    #expect(rows.filter { $0.height == 9 }.allSatisfy { $0.target == nil && $0.root == nil })
}

@Test func nestedWindowsAndExactSpacing() throws {
    let rows = expandedRows(fixture(client: 5))
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map(\.indent) == [0, 0, 1, 2, 1, 1])
    #expect(rows.map(\.height) == [26, 28, 9, 28, 42, 28, 28, 28, 10])
    #expect(rows.allSatisfy { $0.height > 0 })
    #expect(panes.filter(\.focused).map(\.title) == ["pane-5"])
    #expect(expandedRows(fixture(client: 1)).filter(\.focused).map(\.title) == ["@pane-1"])
    #expect(expandedRows(fixture(client: 2)).filter(\.focused).map(\.title) == ["pane-2"])
}

@Test func groupedPanesStayContiguous() throws {
    let rows = expandedRows(fixture(grouped: true))
    #expect(rows.map(\.height) == [26, 28, 28, 10])
    #expect(rows.filter(\.focused).count == 1)
    #expect(rows.allSatisfy { $0.height > 0 })
}

@Test func eachPanesChildrenPrecedeItsNextSibling() throws {
    let rows = expandedRows(fixture(grouped: true, descendants: true))
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map { $0.target!.pane } == [0, 1, 2, 5, 3, 6].map { PaneID(number: UInt32($0)) })
    #expect(panes.map(\.height) == [28, 42, 28, 42, 28, 28])
    #expect(panes.map(\.indent) == [0, 1, 2, 0, 1, 0])
    #expect(rows.filter(\.focused).count == 1)
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test(arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                  (true, false, false), (true, false, true)])
func heightAndPaddingMatrix(_ nested: Bool, _ multi: Bool, _ activity: Bool) throws {
    let lifecycle = agent(working(), msg: activity ? "working" : nil)
    let leaf = pane(1, lifecycle: lifecycle)
    let node = multi ? group(1, [leaf, pane(2, window: 1, lifecycle: lifecycle)]) : leaf
    let snapshot = makeSnapshot([nested ? pane(0, lifecycle: lifecycle, children: [node]) : node], client: 1)
    let row = try #require(expandedRows(snapshot).first { $0.target?.pane == PaneID(number: 1) })
    #expect(row.height == (activity ? 42 : 28))
    #expect(row.padding == 5)
    #expect(row.leading == (nested ? 38 : 23))
    #expect(row.tailY == 23)
    #expect(row.focused)
    #expect(expandedRows(snapshot).filter(\.focused).count == 1)
    #expect(expandedRows(snapshot).allSatisfy { $0.height > 0 })
}

@Test func singleSessionKeepsIdentity() throws {
    let rows = expandedRows(fixture(sessions: [0, 1]))
    let singleSession = expandedRows(fixture(sessions: [0]))
    #expect(singleSession == rows.filter { $0.id.session == SessionID(number: 0) })
    #expect(expandedRows(fixture(sessions: [])).isEmpty)
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(rows.filter { $0.focused }.count == 1)
}

@Test func paneTargetsAndCaptions() throws {
    let panes = expandedRows(fixture()).filter { $0.target != nil }
    #expect(panes.allSatisfy { if case .pane = $0.kind { return true }; return false })
    #expect(panes.first { $0.title == "@pane-1" }?.tail == "working")
    #expect(panes.map(\.height) == [28, 28, 42, 28, 28, 28])
}

@Test func agentWeightAndDisplayOnlyPrefix() throws {
    let cases: [(Lifecycle, String, String, String, Bool)] = [
        (piAgent(idle()), "Ada", "@Ada", "Ada", true),
        (agent(idle()), "Ada", "Ada", "Ada", true),
        (agent(), "@Ada", "@Ada", "@Ada", true),
        (remote(.agent(.init(name: "pi", status: report(idle())))), "Ada", "Ada", "Ada", true),
        (.ended(.exited(.init(code: 0))), "Ada", "Ada", "Ada", false),
        (terminal(.unknown), "zsh", "zsh", "zsh", false),
        (remote(.terminal(.init(interactive: true, status: shell()))), "ssh", "ssh alice@devbox", "ssh alice@devbox", false),
        (.live(.ssh(.init(destination: "@host", pane: .terminal(.init(interactive: true, status: shell()))))), "ssh", "ssh @host", "ssh @host", false),
        (.ended(.exited(.init(code: 2))), "monitor", "monitor", "monitor", false)
    ]
    for (lifecycle, title, expected, tab, agent) in cases {
        let snapshot = makeSnapshot([pane(0, title: title, lifecycle: lifecycle)])
        let row = try #require(expandedRows(snapshot).first { $0.target != nil })
        #expect(row.title == expected)
        #expect(row.agent == agent)
        #expect(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0)],
                               activePanes: [WindowID(number: 0): PaneID(number: 0)]).labels[WindowID(number: 0)]?.title == tab)
    }
}

@Test func composedLabelsCaptionsAndStatuses() throws {
    let failedReport = report(idle(outcome(4, .failure)), msg: "Build failed")
    let cases: [(Lifecycle, String, Bool, SidebarRow.Status, KoSchema.Mark, String, String)] = [
        (terminal(), "Terminal", true, .quiet, .none_, "idle", ""),
        (terminal(.pending(.init(last: nil))), "Terminal", true, .quiet, .none_, "idle", ""),
        (terminal(.pending(.init(last: .init(code: 130, command: "false", endedAt: since + 1, startedAt: since)))), "Terminal", true, .error, .failed, "failed", ""),
        (terminal(exited(0)), "Terminal", true, .done, .done, "done", ""),
        (terminal(exited(130)), "Terminal", true, .error, .failed, "failed", ""),
        (terminal(report: report(idle())), "Terminal", true, .quiet, .none_, "idle", ""),
        (terminal(report: failedReport), "Terminal", true, .error, .failed, "failed", "Build failed"),
        (terminal(.unknown), "zsh", false, .quiet, .none_, "idle", ""),
        (terminal(.unknown, report: report(idle(outcome(2, .success)), msg: "Built")), "zsh", false, .done, .done, "done", "Built"),
        (terminal(running(nil, fullscreen: true)), "zsh", false, .quiet, .none_, "idle", ""),
        (terminal(running(nil)), "zsh", false, .running, .running, "running", ""),
        (remote(.terminal(.init(interactive: true, status: shell(running(nil))))), "ssh alice@devbox", false, .running, .running, "running", ""),
        (remote(.terminal(.init(interactive: true, status: shell(running("nvim", fullscreen: true))))), "ssh alice@devbox", false, .running, .running, "running", ""),
        (terminal(running("nvim", fullscreen: true), report: report(waiting(.auth), msg: "Login required")), "zsh", false, .waiting, .waiting, "waiting", "Login required"),
        (terminal(running()), "make", false, .running, .running, "running", ""),
        (terminal(running("")), "zsh", false, .running, .running, "running", ""),
        (terminal(running(), report: report(working(42), msg: "Building")), "zsh", false, .running, .running, "running", "Building 42%"),
        (terminal(exited(1), report: report(waiting(.auth), msg: "Login required")), "zsh", false, .waiting, .waiting, "waiting", "Login required"),
        (remote(.terminal(.init(interactive: true, status: shell(running())))), "ssh alice@devbox: make", false, .running, .running, "running", ""),
        (remote(.terminal(.init(interactive: false, status: shell(running())))), "ssh alice@devbox", false, .running, .running, "running", ""),
        (remote(.terminal(.init(interactive: true, status: shell(running(), report: report(working()))))), "ssh alice@devbox", false, .running, .running, "running", ""),
        (remote(.terminal(.init(interactive: true, status: shell(exited(2))))), "ssh alice@devbox", false, .error, .failed, "failed", ""),
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
        let row = try #require(expandedRows(snapshot).first { $0.target != nil })
        #expect(row.title == title)
        #expect(row.quietShell == quiet)
        if case .live(let kind) = lifecycle, case .terminal(let shell) = kind.local, case .pending(let exit) = shell.phase,
           case .item(let item) = snapshot.sessions[0].nodes[0] {
            #expect(item.lastCommand == exit.last)
        }
        #expect(row.status == status)
        #expect(row.indicatorDescription == description)
        #expect(row.tail == tail)
        #expect(row.height == (tail.isEmpty ? 28 : 42))
        #expect(sidebarWindows(snapshot, projection: PaneProjection(snapshot), session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == status.mergingTabStatus(.quiet))
    }
}

@Test func navigationOrderAndFallback() throws {
    let snapshot = fixture(sessions: [0, 1])
    let panes = expandedRows(snapshot).compactMap(\.target)
    #expect(panes.map(\.pane) == [0, 5, 1, 2, 3, 4, 0, 5, 1, 2, 3, 4].map { PaneID(number: UInt32($0)) })
    #expect(panes.first == Snapshot.Position(session: SessionID(number: 0), window: WindowID(number: 0), pane: PaneID(number: 0)))
    #expect(expandedRows(fixture(sessions: [])).compactMap(\.target).isEmpty)
}

@Test func programRowsOrderingGeometryAndNavigation() throws {
    let records: [KoSchema.ProgramRecord] = [
        .idle(.init(id: "z", title: "")),
        .error(.init(id: "a-")),
        .blocked(.init(id: "a/missing/leaf", msg: "Record-only caption")),
        .working(.init(id: "a", title: "Record-only title")),
        .done(.init(id: "a/child")),
        .idle(.init(id: "é")), .idle(.init(id: "é")),
        .working(.init(id: "", title: "Root"))
    ]
    let snapshot = fixture(grouped: true, descendants: true, records: records)
    let rows = expandedRows(snapshot)
    let programs = rows.filter { if case .program = $0.id { true } else { false } }
    #expect(programs.map(\.title) == ["Record-only title", "a/child", "a/missing/leaf", "a-", "é", "z", "é"])
    #expect(programs.map(\.leading) == [38, 53, 53, 38, 38, 38, 38])
    #expect(programs.allSatisfy { $0.target == nil && $0.agent })
    #expect(programs.map(\.height) == [28, 28, 42, 28, 28, 28, 28])
    #expect(programs.allSatisfy { $0.padding == 5 && $0.tailY == 23 && !$0.focused && $0.target == nil })
    #expect(programs.map(\.status) == [.running, .done, .waiting, .error, .quiet, .quiet, .quiet])
    #expect(rows[1].target?.pane == PaneID(number: 0))
    #expect(rows[9].target?.pane == PaneID(number: 1))
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(rows.compactMap(\.target).map(\.pane) == [0, 1, 2, 5, 3, 6].map { PaneID(number: UInt32($0)) })
}

@Test func recordIndentsCountOnlyPresentAncestors() throws {
    let records = ["a/b/c", "a/b", "a", "a/d/e", "a/", "a//b", "/", "/b", "", "e\u{301}", "z", "\u{e9}/child"]
        .map { KoSchema.ProgramRecord.working(.init(id: $0)) }
    let snapshot = makeSnapshot([pane(0, children: [pane(1, records: records)])])
    let rows = expandedRows(snapshot).filter { if case .program = $0.id { true } else { false } }
    #expect(rows.map(\.title) == ["/", "/b", "a", "a/", "a//b", "a/b", "a/b/c", "a/d/e", "e\u{301}", "z", "\u{e9}/child"])
    #expect(rows.map(\.indent) == [2, 2, 2, 3, 4, 3, 4, 3, 2, 2, 2])
}

@Test func programIDsOrderBySlashComponents() throws {
    let records: [KoSchema.ProgramRecord] = [
        .working(.init(id: "a-b")),
        .working(.init(id: "a/b")),
        .working(.init(id: "a"))
    ]
    let rows = expandedRows(fixture(records: records)).filter { if case .program = $0.id { true } else { false } }
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
    func statuses(_ snapshot: Snapshot) -> [SidebarRow.Status] { expandedRows(snapshot).filter { switch $0.kind { case .pane, .program: true; default: false } }.map(\.status) }
    #expect(statuses(snapshot) == [.error, .waiting, .done, .error, .running, .error])
    let seen = markedSeen(snapshot)
    #expect(statuses(seen) == [.quiet, .waiting, .quiet, .quiet, .running, .quiet])
    let tabs = sidebarWindows(seen, projection: PaneProjection(seen), session: SessionID(number: 0), surviving: [WindowID(number: 0), WindowID(number: 5)]).statuses
    #expect(tabs[WindowID(number: 0)] == .quiet && tabs[WindowID(number: 5)] == .quiet)
}

@Test func contentChangesAndServerIdentity() throws {
    let records: [KoSchema.ProgramRecord] = [.done(.init(id: "done")), .error(.init(id: "error"))]
    let base = fixture(client: 5, records: records)
    #expect(base != fixture(client: 5, records: records, serial: 8))
    var changed = records
    changed[0] = .done(.init(id: "done", title: "New title"))
    let edited = fixture(client: 5, records: changed)
    #expect(base != edited)
    let before = expandedRows(base), after = expandedRows(edited)
    #expect(before.map(\.id) == after.map(\.id))
    #expect(before.map(\.height) == after.map(\.height))
    #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    #expect(makeSnapshot([pane(0)]) != makeSnapshot([pane(0)], instance: "1/1780000000"))
}

@Test func aNestedRowOmitsItsRuntimeWhenItIsTheOneOfThePaneRowAboveAndTheTopLevelAlwaysShowsIt() {
    func mark(_ name: String, routed: Bool = false, state: KoSchema.LinkState = .up) -> RuntimeMark {
        RuntimeMark.known(.init(kind: .ssh, name: name, source: .config, state: state), routed: routed)
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
    let rows = expandedRows(makeSnapshot([tree, item(7, mark("buildbox", state: .starting))])).filter { $0.target != nil }
    #expect(rows.map { $0.target?.pane.number } == Array(0...7))
    #expect(rows.map { $0.runtime?.name } == ["buildbox", nil, "py311", nil, nil, "buildbox", nil, "buildbox"])
    #expect(rows.last?.runtime?.state == .starting)
}
