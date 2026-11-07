import Foundation
import KoModel
@testable import SidebarFeed
import PaneGeometry

// The sidebar tree of a live session list: five sessions, nested child panes, window groups.

let fixtureSince = 1_791_131_000_000_000_000

func piLifecycle(_ state: KoSchema.AgentState = .idle(.init()), msg: String? = nil, session: String = "session") -> Lifecycle {
    .live(.host(.init(pane: .piAgent(.init(session: session, status: .init(msg: msg, since: fixtureSince, state: state))))))
}

func agentLifecycle(_ state: KoSchema.AgentState, msg: String? = nil, name: String = "claude-code") -> Lifecycle {
    .live(.host(.init(pane: .someAgent(.init(name: name, status: .init(msg: msg, since: fixtureSince, state: state))))))
}

func shellLifecycle(_ phase: KoSchema.Phase = .idle(.init()), report: KoSchema.Agent? = nil) -> Lifecycle {
    .live(.host(.init(pane: .terminal(.init(phase: phase, report: report)))))
}

func shellExit(_ code: Int, command: String = "true") -> KoSchema.Phase {
    .idle(.init(last: .init(code: code, command: command, endedAt: fixtureSince + 1_000_000_000, startedAt: fixtureSince)))
}

extension Item {
    var fixtureLifecycle: Lifecycle {
        get { lifecycle }
        set {
            switch newValue {
            case .live(let kind):
                pane.dead = nil
                pane.status = .init(kind: kind, programStatus: pane.status?.programStatus ?? .init(records: [], serial: 0), since: 0, title: pane.label)
            case .ended(let cause):
                pane.dead = .init(at: 0, cause: cause)
                pane.close = nil
            case .lingering(let cause):
                pane.dead = .init(at: 0, cause: cause)
                pane.close = .onExit
            }
        }
    }
}

func fixtureItem(_ id: UInt32, window: UInt32? = nil, _ title: String, _ lifecycle: Lifecycle,
                 records: [KoSchema.ProgramRecord] = [], serial: Int = 0, mark: KoSchema.Mark = .none_, children: [SidebarFeed.Node] = []) -> Item {
    let live: KoSchema.Live?
    let dead: KoSchema.Dead?
    let close: KoSchema.Close?
    switch lifecycle {
    case .live(let kind): live = kind; dead = nil; close = nil
    case .ended(let cause): live = nil; dead = .init(at: 0, cause: cause); close = nil
    case .lingering(let cause): live = nil; dead = .init(at: 0, cause: cause); close = .onExit
    }
    let pi = if let live, case .piAgent = live.local { true } else { false }
    return Item(pane: .init(close: close, command: [], cwd: "", dead: dead, id: PaneID(number: id), inbox: pi,
                           label: title, mark: mark, recordsSeen: false, started: 0,
                           status: live.map { .init(kind: $0, programStatus: .init(records: records, serial: serial), since: 0, title: title) },
                           title: title, vars: [:]), window: WindowID(number: window ?? id), children: children)
}

func fixtureNode(_ pane: UInt32, window: UInt32? = nil, _ title: String, _ lifecycle: Lifecycle,
                 mark: KoSchema.Mark = .none_, children: [SidebarFeed.Node] = []) -> SidebarFeed.Node {
    .item(fixtureItem(pane, window: window, title, lifecycle, mark: mark, children: children))
}

// A snapshot whose client is the given pane; the first session is the current one.
func fixtureSnapshot(window: UInt32, pane: UInt32, _ sessions: [(name: String, nodes: [SidebarFeed.Node])]) -> Snapshot {
    Snapshot(clock: .init(now: 0, local: 0), client: .init(session: SessionID(number: 0), window: WindowID(number: window), pane: PaneID(number: pane)),
             serverInstance: ServerInstance("4242/1791000000"),
             sessions: sessions.enumerated().map { SessionNodes(id: SessionID(number: UInt32($0.offset)), name: $0.element.name, nodes: $0.element.nodes) })
}

func sidebarFixture(_ edit: (inout Snapshot) -> Void = { _ in }) -> Snapshot {
    func session(_ id: UInt32, _ name: String, _ nodes: [SidebarFeed.Node]) -> SessionNodes {
        SessionNodes(id: SessionID(number: id), name: name, nodes: nodes)
    }
    var snapshot = Snapshot(
        clock: .init(now: 0, local: 0),
        client: .init(session: SessionID(number: 0), window: WindowID(number: 824), pane: PaneID(number: 936)),
        serverInstance: ServerInstance("4242/1791000000"),
        sessions: [
            session(0, "main", [
                fixtureNode(0, "working-on-kido", piLifecycle(session: "session-0"), children: [
                    fixtureNode(892, window: 786, "main-watch",
                                shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "main-watch", startedAt: 1_791_098_646_000_000_000))))),
                                mark: .running),
                ]),
                .window(.init(id: WindowID(number: 458), children: [
                    fixtureItem(502, window: 458, "kido-app", piLifecycle(session: "session-502"), children: [
                        fixtureNode(936, window: 824, "sidebar-mockup", piLifecycle(.running(.init()), session: "session-936"),
                                    mark: .running),
                    ]),
                    fixtureItem(937, window: 458, "make -C ../kido-app/app demo", shellLifecycle()),
                ])),
                fixtureNode(905, window: 797, "pi-ui", piLifecycle(session: "session-905"), children: [
                    fixtureNode(934, window: 822, "pi-ui-perf", piLifecycle(.running(.init()), session: "session-934"),
                                mark: .running),
                ]),
            ]),
            session(1, "visa", [fixtureNode(11, "main", piLifecycle(session: "session-11"))]),
            session(2, "pi", [fixtureNode(23, window: 17, "main", piLifecycle(session: "session-23"))]),
            session(3, "video", [
                .window(.init(id: WindowID(number: 76), children: [
                    fixtureItem(86, window: 76, "video", piLifecycle(session: "session-86")),
                    fixtureItem(783, window: 76, "zsh", shellLifecycle()),
                ])),
            ]),
            session(4, "umbrella", [fixtureNode(193, window: 166, "household", piLifecycle(session: "session-193"))]),
        ])
    edit(&snapshot)
    snapshot.mapItems { item in
        item.pane.inbox = if case .live(let kind) = item.lifecycle, case .piAgent = kind.local { true } else { false }
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
