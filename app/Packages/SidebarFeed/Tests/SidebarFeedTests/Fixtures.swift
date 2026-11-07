import Foundation
import KoModel
@testable import SidebarFeed

typealias Node = SidebarFeed.Node

let since = 1_780_000_000_000_000_000

func idle(_ outcome: KoSchema.Outcome? = nil) -> KoSchema.AgentState { .idle(.init(outcome: outcome)) }
func outcome(_ serial: Int, _ result: KoSchema.OutcomeResult) -> KoSchema.Outcome { .init(result: result, serial: serial) }
func waiting(_ kind: KoSchema.ProgramKind? = nil, progress: Int? = nil) -> KoSchema.AgentState { .waiting(.init(kind: kind, progress: progress)) }
func working(_ progress: Int? = nil) -> KoSchema.AgentState { .running(.init(progress: progress)) }
func report(_ state: KoSchema.AgentState, msg: String? = nil) -> KoSchema.Agent { .init(msg: msg, since: since, state: state) }

func agent(_ state: KoSchema.AgentState = idle(), msg: String? = nil, name: String = "claude-code") -> Lifecycle {
    .live(.host(.init(pane: .someAgent(.init(name: name, status: report(state, msg: msg))))))
}
func piAgent(_ state: KoSchema.AgentState = idle(), msg: String? = nil) -> Lifecycle {
    .live(.host(.init(pane: .piAgent(.init(session: "pi-session", status: report(state, msg: msg))))))
}

func shell(_ phase: KoSchema.Phase = .idle(.init()), report: KoSchema.Agent? = nil) -> KoSchema.Shell { .init(phase: phase, report: report) }
func terminal(_ phase: KoSchema.Phase = .idle(.init()), report: KoSchema.Agent? = nil) -> Lifecycle { .live(.host(.init(pane: .terminal(shell(phase, report: report))))) }
func exited(_ code: Int, started: Int = since, ended: Int = since + 1_250_000_000) -> KoSchema.Phase {
    .idle(.init(last: .init(code: code, command: "false", endedAt: ended, startedAt: started)))
}
func running(_ command: String? = "make", fullscreen: Bool = false) -> KoSchema.Phase {
    .running(.init(fullscreen: fullscreen, origin: command.map { .command(.init(command: $0, startedAt: since)) } ?? .unknown))
}
func remote(_ pane: KoSchema.Remote, user: String = "alice", host: String = "devbox") -> Lifecycle {
    .live(.ssh(.init(destination: user.isEmpty ? host : user + "@" + host, pane: pane)))
}

func pane(_ id: Int, window: Int? = nil, title: String = "", lifecycle: Lifecycle = terminal(),
          records: [KoSchema.ProgramRecord] = [], serial: Int = 0, recordsSeen: Bool = false, mark: KoSchema.Mark = .none_, children: [Node] = []) -> Node {
    let live: KoSchema.Live?
    let dead: KoSchema.Dead?
    let close: KoSchema.Close?
    switch lifecycle {
    case .live(let kind): live = kind; dead = nil; close = nil
    case .ended(let cause): live = nil; dead = .init(at: 0, cause: cause); close = nil
    case .lingering(let cause): live = nil; dead = .init(at: 0, cause: cause); close = .onExit
    }
    let pi = if case .host(let host) = live, case .piAgent = host.pane { true } else { false }
    return .item(Item(pane: .init(close: close, command: [], cwd: "", dead: dead, id: PaneID(number: UInt32(id)), inbox: pi,
                                 label: title, mark: mark, recordsSeen: recordsSeen, started: 0,
                                 status: live.map { .init(kind: $0, programStatus: .init(records: records, serial: serial), since: 0, title: title) },
                                 title: title, vars: [:]), window: WindowID(number: UInt32(window ?? id)), children: children))
}

func group(_ id: Int, _ children: [Node]) -> Node {
    .window(.init(id: WindowID(number: UInt32(id)), children: children.compactMap { if case .item(let item) = $0 { item } else { nil } }))
}

func makeSnapshot(_ nodes: [Node], client: Int = 0, window: Int? = nil, clientSession: Int = 0, sessions: [Int] = [0],
                  instance: String = "12345/1780000000") -> Snapshot {
    Snapshot(clock: .init(now: 0, local: 0), client: .init(session: SessionID(number: UInt32(clientSession)), window: WindowID(number: UInt32(window ?? client)), pane: PaneID(number: UInt32(client))),
             serverInstance: ServerInstance(instance),
             sessions: sessions.map { SessionNodes(id: SessionID(number: UInt32($0)), name: "session-\($0)", nodes: nodes) })
}

// The snapshot as the core marks it after an attended view showed every pane: the outcomes and the records are seen.
func markedSeen(_ snapshot: Snapshot) -> Snapshot {
    func item(_ item: Item) -> Item {
        var item = item
        item.children = item.children.map(node)
        if [.done, .failed].contains(item.pane.mark) { item.pane.mark = .none_ }
        item.pane.recordsSeen = true
        return item
    }
    func node(_ node: Node) -> Node {
        switch node {
        case .item(let i): .item(item(i))
        case .window(let group): .window(.init(id: group.id, children: group.children.map(item)))
        }
    }
    var snapshot = snapshot
    snapshot.sessions = snapshot.sessions.map { SessionNodes(id: $0.id, name: $0.name, nodes: $0.nodes.map(node)) }
    return snapshot
}
