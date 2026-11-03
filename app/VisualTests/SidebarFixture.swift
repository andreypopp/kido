import Foundation
import KoModel
@testable import SidebarFeed
import PaneGeometry

// The sidebar tree of a live session list: five sessions, nested runs, window groups.

let fixtureSince = Date(timeIntervalSince1970: 1791131000)

func piLifecycle(_ state: Report.State = .idle(nil), msg: String? = nil, session: String = "session") -> Lifecycle {
    .live(.piAgent(session: session, Report(since: fixtureSince, msg: msg, state: state)))
}

func agentLifecycle(_ state: Report.State, msg: String? = nil, name: String = "claude-code") -> Lifecycle {
    .live(.someAgent(name: name, Report(since: fixtureSince, msg: msg, state: state)))
}

func shellLifecycle(_ phase: ShellStatus.Phase = .idle(last: nil), report: Report? = nil) -> Lifecycle {
    .live(.terminal(ShellStatus(phase: phase, report: report)))
}

func shellExit(_ code: Int, command: String = "true") -> ShellStatus.Phase {
    .idle(last: .init(code: code, command: command, startedAt: fixtureSince, endedAt: fixtureSince + 1))
}

func programRecord(_ id: String, _ state: ProgramStatus.Record.State, app: String? = nil, kind: KoSchema.ProgramKind? = nil,
                   title: String? = nil, msg: String? = nil) -> ProgramStatus.Record {
    ProgramStatus.Record(id: id, state: state, app: app, kind: kind, progress: nil, title: title, msg: msg)
}

func fixtureItem(_ pane: UInt32, window: UInt32? = nil, _ title: String, _ lifecycle: Lifecycle, run: String? = nil, started: Double? = nil,
                 records: [ProgramStatus.Record] = [], serial: Int = 0, mark: KoSchema.Mark = .none_, children: [SidebarFeed.Node] = []) -> Item {
    Item(id: PaneID(number: pane), window: WindowID(number: window ?? pane), title: title, lifecycle: lifecycle,
         program_status: ProgramStatus(serial: serial, records: records), run: run, started: started.map(Date.init(timeIntervalSince1970:)),
         children: children, mark: mark, inbox: { if case .live(.piAgent) = lifecycle { true } else { false } }())
}

func fixtureNode(_ pane: UInt32, window: UInt32? = nil, _ title: String, _ lifecycle: Lifecycle, run: String? = nil, started: Double? = nil,
                 mark: KoSchema.Mark = .none_, children: [SidebarFeed.Node] = []) -> SidebarFeed.Node {
    .item(fixtureItem(pane, window: window, title, lifecycle, run: run, started: started, mark: mark, children: children))
}

// A snapshot whose client is the given pane; the first session is the current one.
func fixtureSnapshot(window: UInt32, pane: UInt32, _ sessions: [(name: String, nodes: [SidebarFeed.Node])]) -> Snapshot {
    Snapshot(client: .init(session: SessionID(number: 0), window: WindowID(number: window), pane: PaneID(number: pane)),
             serverInstance: ServerInstance("4242/1791000000"),
             sessions: sessions.enumerated().map { SessionNodes(id: SessionID(number: UInt32($0.offset)), name: $0.element.name, current: $0.offset == 0, nodes: $0.element.nodes) })
}

func sidebarFixture(_ edit: (inout Snapshot) -> Void = { _ in }) -> Snapshot {
    func session(_ id: UInt32, _ name: String, _ nodes: [SidebarFeed.Node]) -> SessionNodes {
        SessionNodes(id: SessionID(number: id), name: name, current: id == 0, nodes: nodes)
    }
    var snapshot = Snapshot(
        client: .init(session: SessionID(number: 0), window: WindowID(number: 824), pane: PaneID(number: 936)),
        serverInstance: ServerInstance("4242/1791000000"),
        sessions: [
            session(0, "main", [
                fixtureNode(0, "working-on-kido", piLifecycle(session: "session-0"), children: [
                    fixtureNode(892, window: 786, "main-watch",
                                shellLifecycle(.running(.init(command: "main-watch", startedAt: Date(timeIntervalSince1970: 1791098646)), fullscreen: false)),
                                run: "r-892", started: 1791098646.964646, mark: .running),
                ]),
                .window(.init(id: WindowID(number: 458), name: "kido-app", children: [
                    fixtureItem(502, window: 458, "kido-app", piLifecycle(session: "session-502"), children: [
                        fixtureNode(936, window: 824, "sidebar-mockup", piLifecycle(.running(progress: nil), session: "session-936"),
                                    run: "r-936", started: 1791131078.818641, mark: .running),
                    ]),
                    fixtureItem(937, window: 458, "make -C ../kido-app/app demo", shellLifecycle()),
                ])),
                fixtureNode(905, window: 797, "pi-ui", piLifecycle(session: "session-905"), children: [
                    fixtureNode(934, window: 822, "pi-ui-perf", piLifecycle(.running(progress: nil), session: "session-934"),
                                run: "r-934", started: 1791125890.55034, mark: .running),
                ]),
            ]),
            session(1, "visa", [fixtureNode(11, "main", piLifecycle(session: "session-11"))]),
            session(2, "pi", [fixtureNode(23, window: 17, "main", piLifecycle(session: "session-23"))]),
            session(3, "video", [
                .window(.init(id: WindowID(number: 76), name: "node", children: [
                    fixtureItem(86, window: 76, "video", piLifecycle(session: "session-86")),
                    fixtureItem(783, window: 76, "zsh", shellLifecycle()),
                ])),
            ]),
            session(4, "umbrella", [fixtureNode(193, window: 166, "household", piLifecycle(session: "session-193"))]),
        ])
    edit(&snapshot)
    snapshot.mapItems { item in
        item.inbox = if case .live(.piAgent) = item.lifecycle { true } else { false }
    }
    return snapshot
}

extension SidebarFeed.Node {
    var item: Item {
        get { guard case .item(let item) = self else { preconditionFailure("not a pane: \(id)") }; return item }
        set { self = .item(newValue) }
    }
    var group: Window {
        get { guard case .window(let group) = self else { preconditionFailure("not a window group: \(id)") }; return group }
        set { self = .window(newValue) }
    }
}

extension Snapshot {
    // Every pane of the tree, edited in place.
    mutating func mapItems(_ edit: (inout Item) -> Void) {
        func item(_ item: Item) -> Item {
            var item = item
            edit(&item)
            item.children = item.children.map(node)
            return item
        }
        func node(_ node: SidebarFeed.Node) -> SidebarFeed.Node {
            switch node {
            case .item(let i): .item(item(i))
            case .window(var group): { group.children = group.children.map(item); return .window(group) }()
            }
        }
        sessions = sessions.map { var session = $0; session.nodes = session.nodes.map(node); return session }
    }

    // Copies of the first session under the given numbers.
    mutating func repeatSession(_ numbers: [UInt32]) {
        let original = sessions[0]
        sessions = numbers.map { var session = original; session.id = SessionID(number: $0); session.name = "session-\($0)"; return session }
    }
}
