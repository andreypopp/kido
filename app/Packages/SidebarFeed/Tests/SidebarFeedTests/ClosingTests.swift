import Foundation
import Testing
import KoModel
@testable import SidebarFeed

@Test(arguments: [false, true]) func closingPaneIncludesDescendants(_ waitingState: Bool) throws {
    let child = pane(2, lifecycle: agent(waitingState ? waiting() : working()), mark: waitingState ? .waiting : .running)
    let snapshot: Snapshot = makeSnapshot([pane(0, children: [pane(1, children: [child])]), pane(3)])
    #expect(closeScope(snapshot, target: .pane(PaneID(number: 0))).ask)
    #expect(closeScope(snapshot, target: .pane(PaneID(number: 1))).ask)
    #expect(!closeScope(snapshot, target: .pane(PaneID(number: 3))).ask)
    #expect(closeScope(snapshot, target: .pane(PaneID(number: 0))).descendants == [WindowID(number: 2), WindowID(number: 1)])
}

@Test func closingWindowIncludesEveryPaneAndDescendants() throws {
    let window = group(0, [pane(0), pane(1, window: 0, children: [pane(2, lifecycle: agent(waiting()), mark: .waiting)])])
    let snapshot = makeSnapshot([window, pane(3)])
    #expect(closeScope(snapshot, target: .window(WindowID(number: 0))).ask)
    #expect(!closeScope(snapshot, target: .pane(PaneID(number: 0))).ask)
    #expect(!closeScope(snapshot, target: .window(WindowID(number: 3))).ask)
    #expect(closeScope(snapshot, target: .window(WindowID(number: 0))).descendants == [WindowID(number: 2)])
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
        (remote(.terminal(interactive: true, shell())), .none_, false),
        (.ended(.exited(.init(code: 0))), .running, false),
    ]
    for (lifecycle, mark, ask) in cases {
        let node = pane(0, lifecycle: lifecycle, mark: mark)
        let snapshot = makeSnapshot([node])
        #expect(closeScope(snapshot, target: .pane(PaneID(number: 0))).ask == ask)
    }
    let mixed = makeSnapshot([group(0, [pane(0), pane(1, window: 0, lifecycle: agent())])])
    #expect(closeScope(mixed, target: .window(WindowID(number: 0))).ask)
    #expect(closeScope(mixed, target: .session(SessionID(number: 0))).ask)
    #expect(!closeScope(nil, target: .pane(PaneID(number: 0))).ask)
}

@Test func terminalCloseUsesTrueIdleWithoutAProcessComparison() throws {
    let cases: [(ShellStatus, KoSchema.Mark, Bool)] = [
        (shell(), .none_, false),
        (shell(exited(1)), .failed, false),
        (shell(.pending(last: nil)), .none_, true),
        (shell(running()), .running, true),
        (shell(.unknown), .none_, true),
        (shell(report: report(waiting())), .waiting, true),
    ]
    for (status, mark, ask) in cases {
        for kind in [PaneKind.host(.terminal(status)), .runtime(.terminal(status)), .ssh(.init(user: "", host: "host"), .terminal(interactive: true, status))] {
            let node = pane(0, lifecycle: .live(kind), mark: mark)
            #expect(closeScope(makeSnapshot([node]), target: .pane(PaneID(number: 0))).ask == ask)
            if case .pending = status.phase, case .item(let item) = node {
                if kind.local != nil { #expect(item.rowTitle == "Terminal") }
                #expect(item.indicator.status == .quiet)
            }
        }
    }
    for kind in [PaneKind.ssh(.init(user: "", host: "host"), .terminal(interactive: false, shell())), .host(.someAgent(name: "pi", report(idle()))), .runtime(.piAgent(session: "s", report(idle())))] {
        #expect(closeScope(makeSnapshot([pane(0, lifecycle: .live(kind))]), target: .pane(PaneID(number: 0))).ask)
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
