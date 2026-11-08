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
