import Foundation
import KoModel
@testable import SidebarFeed
import PaneGeometry

// The sidebar tree of a live session list: five sessions, nested child panes, window groups.

let fixtureHome = "/Users/dev"
func fixtureAbbreviate(_ path: String) -> String { path.hasPrefix(fixtureHome + "/") ? "~" + path.dropFirst(fixtureHome.count) : path }

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

func fixtureItem(_ id: UInt32, window: UInt32? = nil, parent: UInt32? = nil, cwd: String = "", _ title: String, _ lifecycle: Lifecycle,
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
    return Item(pane: .init(close: close, command: [], cwd: cwd, dead: dead, id: PaneID(number: id), inbox: pi,
                           label: title, mark: mark, parent: parent.map(PaneID.init(number:)), recordsSeen: false, started: 0,
                           status: live.map { .init(kind: $0, programStatus: .init(records: records, serial: serial), since: 0, title: title) },
                           title: title, vars: [:]), window: WindowID(number: window ?? id), children: children)
}

func fixtureNode(_ pane: UInt32, window: UInt32? = nil, _ title: String, _ lifecycle: Lifecycle,
                 mark: KoSchema.Mark = .none_, children: [SidebarFeed.Node] = []) -> SidebarFeed.Node {
    .item(fixtureItem(pane, window: window, title, lifecycle, mark: mark, children: children))
}

// A snapshot whose client is the given pane; the first session is the current one.
func fixtureSnapshot(window: UInt32, pane: UInt32, _ sessions: [(name: String, nodes: [SidebarFeed.Node])]) -> Snapshot {
    var snapshot = Snapshot(clock: .init(now: 0, local: 0), client: .init(session: SessionID(number: 0), window: WindowID(number: window), pane: PaneID(number: pane)),
             serverInstance: ServerInstance("4242/1791000000"),
             sessions: sessions.enumerated().map { SessionNodes(id: SessionID(number: UInt32($0.offset)), name: $0.element.name, nodes: $0.element.nodes) })
    snapshot.fillCwds()
    return snapshot
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
    snapshot.fillCwds()
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
    mutating func mapItems(_ edit: (inout Item) -> Void) { mapItems { _, item in edit(&item) } }

    mutating func mapItems(_ edit: (String, inout Item) -> Void) {
        sessions = sessions.map { session in
            func item(_ item: Item) -> Item {
                var item = item
                edit(session.name, &item)
                item.children = item.children.map(node)
                return item
            }
            func node(_ node: SidebarFeed.Node) -> SidebarFeed.Node {
                switch node {
                case .item(let i): .item(item(i))
                case .window(var group): { group.children = group.children.map(item); return .window(group) }()
                }
            }
            var session = session
            session.nodes = session.nodes.map(node)
            return session
        }
    }

    // Feed-shaped working directories: absolute local paths under `fixtureHome`, an absolute remote path for ssh panes.
    mutating func fillCwds() {
        let bases = ["main": "Workspace/kido", "work": "Workspace/kido-app", "visa": "Documents/visa", "pi": "Workspace/pi", "video": "Movies/kido", "umbrella": "Workspace/umbrella"]
        mapItems { name, item in
            guard item.pane.cwd.isEmpty else { return }
            if case .live(let kind) = item.lifecycle, case .ssh = kind { item.pane.cwd = "/home/dev/src"; return }
            item.pane.cwd = fixtureHome + "/" + (bases[name] ?? "Workspace/kido") + (name == "main" && item.agent == nil ? "/app" : "")
        }
    }

    // Copies of the first session under the given numbers.
    mutating func repeatSession(_ numbers: [UInt32]) {
        let original = sessions[0]
        sessions = numbers.map { var session = original; session.id = SessionID(number: $0); session.name = "session-\($0)"; return session }
    }
}

let sidebarChildrenNow = 2_951_768_000_000_000

func sidebarChildrenFixture(records: Bool = false) -> Snapshot {
    var snapshot = sidebarFixture()
    snapshot.client = .init(session: .init(number: 0), window: .init(number: 458), pane: .init(number: 937))
    snapshot.sessions[0].nodes[0].item.pane.mark = .done
    var parent = snapshot.sessions[0].nodes[1].group.children[0]
    parent.fixtureLifecycle = piLifecycle(.running(.init()), msg: "Refining the native sidebar")
    parent.pane.mark = .running
    parent.children[0].item.fixtureLifecycle = piLifecycle(.running(.init()), msg: "Designing session cards and pane states")
    parent.children[0].item.pane.parent = parent.id
    parent.children[0].item.pane.started = 184_000_000_000
    var notes = fixtureItem(941, parent: 940, "review-notes", .ended(.exited(.init(code: 0))), mark: .done, children: [
        .item(fixtureItem(942, parent: 941, "lint", shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "lint", startedAt: 0))))), mark: .running)),
        .item(fixtureItem(943, parent: 941, "zsh", shellLifecycle())),
    ])
    notes.pane.started = 0
    var tests = fixtureItem(940, parent: 502, "sidebar-tests", piLifecycle(.waiting(.init()), msg: "Allow running make test?"), mark: .waiting, children: [
        .item(notes), .item(fixtureItem(944, parent: 940, "perf-notes", agentLifecycle(.idle(.init()), name: "pi"))),
    ])
    tests.pane.started = 41_000_000_000
    parent.children += [.item(tests), .item(fixtureItem(945, parent: 502, "make test", .ended(.exited(.init(code: 0))), mark: .done))]
    snapshot.sessions[0].nodes[1].group.children[0] = parent
    snapshot.sessions[0].nodes[1].group.children[1].pane.mark = .done
    snapshot.sessions[0].nodes[2].item.children[0].item.fixtureLifecycle = piLifecycle(.idle(.init(outcome: .init(result: .failure, serial: 1))), msg: "Profiling long sidebar updates")
    snapshot.sessions[0].nodes[2].item.children[0].item.pane.mark = .failed
    snapshot.sessions[1].name = "work"
    snapshot.sessions[1].nodes = [
        .window(.init(id: .init(number: 2000), children: [
            fixtureItem(2001, window: 2000, "cargo build --release", shellLifecycle(.unknown), mark: .failed),
            fixtureItem(2002, window: 2000, "ssh devbox: tail -f /var/log/system.log", .live(.ssh(.init(destination: "devbox", pane: .terminal(.init(interactive: true, status: .init(phase: .running(.init(fullscreen: false, origin: .command(.init(command: "tail -f /var/log/system.log", startedAt: 0)))))))))), mark: .running),
        ])),
        .item(fixtureItem(2003, "pi-review on devbox", agentLifecycle(.running(.init()), msg: "Reviewing the remote checkout", name: "pi"), mark: .running)),
        .item(fixtureItem(2004, "review the sidebar implementation and accessibility changes", piLifecycle(.waiting(.init()), msg: "Needs your review before continuing"), mark: .waiting)),
    ]
    snapshot.mapItems { $0.pane.started += sidebarChildrenNow - 368_000_000_000 }
    snapshot.sessions[0].nodes[2].item.children[0].item.pane.parent = PaneID(number: 905)
    snapshot.sessions[0].nodes[2].item.children[0].item.pane.started = 368_000_000_000
    snapshot.sessions[1].nodes[2].item.pane.parent = PaneID(number: 502)
    snapshot.sessions[1].nodes[2].item.pane.started = sidebarChildrenNow - 143_000_000_000
    if records {
        snapshot.sessions[0].nodes.insert(.item(fixtureItem(3000, "Claude Code", agentLifecycle(.running(.init())), records: [
            .working(.init(app: "claude-code", id: "")),
            .working(.init(id: "agent-c", title: "Review accessibility")),
            .blocked(.init(id: "agent-a/permission", kind: .permission, msg: "May I run the integration tests?", title: "Approve test command")),
            .working(.init(id: "agent-b", title: "Check toolbar geometry")),
            .working(.init(id: "agent-a", msg: "Comparing native row measurements", title: "Investigate sidebar layout")),
        ], serial: 7, mark: .running)), at: 0)
        snapshot.client = .init(session: .init(number: 0), window: .init(number: 3000), pane: .init(number: 3000))
    }
    snapshot.fillCwds()
    return snapshot
}
