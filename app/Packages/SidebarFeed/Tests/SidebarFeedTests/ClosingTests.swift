import Foundation
import Testing
import KoModel
@testable import SidebarFeed

@Test func closingFollowsRawParentsAcrossSessions() {
    var snapshot = makeSnapshot([pane(0)])
    snapshot.sessions.append(SessionNodes(id: SessionID(number: 1), name: "other", nodes: [pane(1, parent: 0, children: [pane(2, parent: 1, lifecycle: agent(working()))])]))
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 0))).ask)
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 1))).ask)
    #expect(closeScope(PaneProjection(snapshot), target: .session(SessionID(number: 0))).ask)
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 0))).panes == 3)
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 0))).running == 1)
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 1))).panes == 2)
    #expect(!closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 99))).ask)
}

@Test(arguments: [false, true]) func closingPaneIncludesDescendants(_ waitingState: Bool) throws {
    let child = pane(2, parent: 1, lifecycle: agent(waitingState ? waiting() : working()), mark: waitingState ? .waiting : .running)
    let snapshot: Snapshot = makeSnapshot([pane(0, children: [pane(1, parent: 0, children: [child])]), pane(3)])
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 0))).ask)
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 1))).ask)
    #expect(!closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 3))).ask)
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 0))).panes == 3)
    #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 0))).running == 1)
}

@Test func closingWindowIncludesEveryPaneAndDescendants() throws {
    let window = group(0, [pane(0), pane(1, window: 0, children: [pane(2, parent: 1, lifecycle: agent(waiting()), mark: .waiting)])])
    let snapshot = makeSnapshot([window, pane(3)])
    #expect(closeScope(PaneProjection(snapshot), target: .window(WindowID(number: 0))).ask)
    #expect(!closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 0))).ask)
    #expect(!closeScope(PaneProjection(snapshot), target: .window(WindowID(number: 3))).ask)
    #expect(closeScope(PaneProjection(snapshot), target: .window(WindowID(number: 0))).panes == 3)
    #expect(closeScope(PaneProjection(snapshot), target: .window(WindowID(number: 0))).running == 1)
}

@Test func closingAsksUnlessEveryLivePaneIsAQuietTerminal() throws {
    let cases: [(Lifecycle, KoSchema.Mark, Bool)] = [
        (terminal(), .none_, false),
        (terminal(exited(0)), .done, false),
        (terminal(exited(1)), .failed, false),
        (terminal(), .running, true),
        (agent(), .none_, true),
        (terminal(running("nvim", fullscreen: true)), .none_, true),
        (terminal(running("sleep 60")), .none_, true),
        (terminal(.unknown), .none_, true),
        (remote(.terminal(.init(interactive: true, status: shell()))), .none_, false),
        (.ended(.exited(.init(code: 0))), .running, false),
    ]
    for (lifecycle, mark, ask) in cases {
        let node = pane(0, lifecycle: lifecycle, mark: mark)
        let snapshot = makeSnapshot([node])
        #expect(closeScope(PaneProjection(snapshot), target: .pane(PaneID(number: 0))).ask == ask)
    }
    let mixed = makeSnapshot([group(0, [pane(0), pane(1, window: 0, lifecycle: agent())])])
    #expect(closeScope(PaneProjection(mixed), target: .window(WindowID(number: 0))).ask)
    #expect(closeScope(PaneProjection(mixed), target: .session(SessionID(number: 0))).ask)
    #expect(!closeScope(PaneProjection(nil), target: .pane(PaneID(number: 0))).ask)
}

@Test func terminalCloseUsesTrueIdleWithoutAProcessComparison() throws {
    let cases: [(KoSchema.Shell, KoSchema.Mark, Bool)] = [
        (shell(), .none_, false),
        (shell(exited(1)), .failed, false),
        (shell(.pending(.init(last: nil))), .none_, true),
        (shell(running()), .running, true),
        (shell(.unknown), .none_, true),
        (shell(report: report(waiting())), .waiting, true),
    ]
    for (status, mark, ask) in cases {
        for kind in [KoSchema.Live.host(.init(pane: .terminal(status))), .runtime(.init(pane: .terminal(status))), .ssh(.init(destination: "host", pane: .terminal(.init(interactive: true, status: status))))] {
            let node = pane(0, lifecycle: .live(kind), mark: mark)
            #expect(closeScope(PaneProjection(makeSnapshot([node])), target: .pane(PaneID(number: 0))).ask == ask)
            if case .pending = status.phase, case .item(let item) = node {
                if kind.local != nil { #expect(item.rowTitle == "Terminal") }
                #expect(item.indicator.status == .quiet)
            }
        }
    }
    for kind in [KoSchema.Live.ssh(.init(destination: "host", pane: .terminal(.init(interactive: false, status: shell())))), .host(.init(pane: .someAgent(.init(name: "pi", status: report(idle()))))), .runtime(.init(pane: .piAgent(.init(session: "s", status: report(idle())))))] {
        #expect(closeScope(PaneProjection(makeSnapshot([pane(0, lifecycle: .live(kind))])), target: .pane(PaneID(number: 0))).ask)
    }
}

@Test func recentHostsAddRefreshOrderClearAndEmpty() throws {
    var recent = RecentHosts()
    #expect(recent.isEmpty)
    recent.add("first", at: Date(timeIntervalSince1970: 10))
    recent.add("second", at: Date(timeIntervalSince1970: 20))
    #expect(recent.entries.map(\.host) == ["second", "first"])
    recent.add("first", at: Date(timeIntervalSince1970: 30))
    #expect(recent.entries.map(\.host) == ["first", "second"])
    #expect(recent.entries[0].date == Date(timeIntervalSince1970: 30))
    #expect(try JSONDecoder().decode(RecentHosts.self, from: JSONEncoder().encode(recent)) == recent)
    recent.clear()
    #expect(recent.isEmpty)
    #expect(recent.entries.isEmpty)
}

private func fixed(_ node: Node, title: String? = nil, confirm: KoSchema.CloseConfirm? = nil, foreground: String? = nil) -> Node {
    guard case .item(var item) = node else { return node }
    item.pane.fixedTitle = title
    if let title { item.pane.label = title }
    item.pane.closeConfirm = confirm
    item.pane.foreground = foreground.map { .init(name: $0, pid: 7) }
    return .item(item)
}

@Test func aFixedTitleNamesTheRowTheTabAndTheCloseAlertAndTheForegroundIsTheActivity() throws {
    let editor = fixed(pane(1, title: "from-osc", lifecycle: terminal(running("nvim", fullscreen: true)), layer: .floating), title: "Draft for @ko", foreground: "nvim")
    let quiet = fixed(pane(2, title: "from-osc"), title: "Draft for @ko")
    let snapshot = makeSnapshot([pane(0), editor, quiet])
    let projection = PaneProjection(snapshot)
    for id in [1, 2] {
        #expect(projection.items[PaneID(number: UInt32(id))]?.item.rowTitle == "Draft for @ko")
    }
    #expect(projection.items[PaneID(number: 0)]?.item.rowTitle == "Terminal")
    let rows = sidebarRows(snapshot)
    #expect(rows.contains { $0.title == "Draft for @ko" })
    #expect(rows.contains { if case .activity("nvim") = $0.second { true } else { false } })
    let windows = sidebarWindows(snapshot, projection: projection, session: SessionID(number: 0), surviving: [WindowID(number: 1)], activePanes: [WindowID(number: 1): PaneID(number: 1)])
    #expect(windows.labels[WindowID(number: 1)]?.title == "Draft for @ko")
}

@Test func closeConfirmNeverClosesWithoutAskingButARunningDescendantAndAnOrdinaryFloatStillAsk() throws {
    let running = terminal(running("nvim", fullscreen: true))
    let never = fixed(pane(1, lifecycle: running, layer: .floating), confirm: .never)
    let ordinary = pane(2, lifecycle: running, layer: .floating)
    let parent = fixed(pane(3, lifecycle: running, layer: .floating, children: [pane(4, parent: 3, lifecycle: agent(working()), mark: .running)]), confirm: .never)
    let projection = PaneProjection(makeSnapshot([pane(0), never, ordinary, parent]))
    #expect(!closeScope(projection, target: .pane(PaneID(number: 1))).ask)
    #expect(closeScope(projection, target: .pane(PaneID(number: 2))).ask)
    #expect(closeScope(projection, target: .pane(PaneID(number: 3))).ask)
    #expect(closeScope(projection, target: .pane(PaneID(number: 3))).running == 1)
}

@Test func theCloseTitleIsOneLineAndCutInTheMiddleAtFortyCharacters() {
    #expect(closeTitle("Draft for @ko") == "Close “Draft for @ko”?")
    let forty = String(repeating: "a", count: 40)
    #expect(closeTitle(forty) == "Close “\(forty)”?")
    let long = "/var/folders/xx/koa-editor-123456/koa-draft-pane_18.md"
    let cut = closeTitle(long)
    #expect(cut == "Close “/var/folders/xx/koa…koa-draft-pane_18.md”?")
    #expect(cut.dropFirst(7).dropLast(2).count == 40)
    #expect(closeTitle("one\ntwo\nthree") == "Close “one two three”?")
}
