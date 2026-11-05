import Foundation
import KoModel
@testable import SidebarFeed

typealias Node = SidebarFeed.Node
typealias PaneKind = SidebarFeed.PaneKind

let since = Date(timeIntervalSince1970: 1780000000)

func idle(_ outcome: Outcome? = nil) -> Report.State { .idle(outcome) }
func outcome(_ serial: Int, _ result: KoSchema.OutcomeResult) -> Outcome { Outcome(serial: serial, result: result) }
func waiting(_ kind: KoSchema.ProgramKind? = nil, progress: Int? = nil) -> Report.State { .waiting(kind, progress: progress) }
func working(_ progress: Int? = nil) -> Report.State { .running(progress: progress) }
func report(_ state: Report.State, msg: String? = nil) -> Report { Report(since: since, msg: msg, state: state) }

func agent(_ state: Report.State = idle(), msg: String? = nil, name: String = "claude-code") -> Lifecycle {
    .live(.someAgent(name: name, report(state, msg: msg)))
}
func piAgent(_ state: Report.State = idle(), msg: String? = nil) -> Lifecycle { .live(.piAgent(session: "pi-session", report(state, msg: msg))) }

func shell(_ phase: ShellStatus.Phase = .idle(last: nil), report: Report? = nil) -> ShellStatus { ShellStatus(phase: phase, report: report) }
func terminal(_ phase: ShellStatus.Phase = .idle(last: nil), report: Report? = nil) -> Lifecycle { .live(.terminal(shell(phase, report: report))) }
func exited(_ code: Int, started: Double = 1780000000, ended: Double = 1780000001.25) -> ShellStatus.Phase {
    .idle(last: ShellStatus.Exit(code: code, command: "false", startedAt: Date(timeIntervalSince1970: started), endedAt: Date(timeIntervalSince1970: ended)))
}
func running(_ command: String? = "make", fullscreen: Bool = false) -> ShellStatus.Phase {
    .running(command.map { ShellStatus.Command(command: $0, startedAt: since) }, fullscreen: fullscreen)
}
func remote(_ pane: PaneKind.Remote, user: String = "alice", host: String = "devbox") -> Lifecycle {
    .live(.ssh(PaneKind.Destination(user: user, host: host), pane))
}

func record(_ id: String, _ state: ProgramStatus.Record.State, app: String? = nil, kind: KoSchema.ProgramKind? = nil, progress: Int? = nil,
            title: String? = nil, msg: String? = nil) -> ProgramStatus.Record {
    ProgramStatus.Record(id: id, started: nil, state: state, app: app, kind: kind, progress: progress, title: title, msg: msg)
}

func pane(_ id: Int, window: Int? = nil, title: String = "", lifecycle: Lifecycle = terminal(),
          records: [ProgramStatus.Record] = [], serial: Int = 0, recordsSeen: Bool = false, mark: KoSchema.Mark = .none_, children: [Node] = []) -> Node {
    let pi = if case .live(.piAgent) = lifecycle { true } else { false }
    return .item(Item(id: PaneID(number: UInt32(id)), window: WindowID(number: UInt32(window ?? id)), title: title, started: 0, parent: nil, lifecycle: lifecycle,
                      program_status: ProgramStatus(serial: serial, records: records),
                      children: children, mark: mark, recordsSeen: recordsSeen, inbox: pi))
}

func group(_ id: Int, name: String = "group", _ children: [Node]) -> Node {
    .window(.init(id: WindowID(number: UInt32(id)), name: name, children: children.compactMap { if case .item(let item) = $0 { item } else { nil } }))
}

func makeSnapshot(_ nodes: [Node], client: Int = 0, window: Int? = nil, clientSession: Int = 0, sessions: [Int] = [0],
                  instance: String = "12345/1780000000") -> Snapshot {
    Snapshot(clock: .init(now: 0, local: 0), client: .init(session: SessionID(number: UInt32(clientSession)), window: WindowID(number: UInt32(window ?? client)), pane: PaneID(number: UInt32(client))),
             serverInstance: ServerInstance(instance),
             sessions: sessions.map { SessionNodes(id: SessionID(number: UInt32($0)), name: "session-\($0)", current: $0 == 0, nodes: nodes) })
}

// The snapshot as the core marks it after an attended view showed every pane: the outcomes and the records are seen.
func markedSeen(_ snapshot: Snapshot) -> Snapshot {
    func item(_ item: Item) -> Item {
        var item = item
        item.children = item.children.map(node)
        if [.done, .failed].contains(item.mark) { item.mark = .none_ }
        item.recordsSeen = true
        return item
    }
    func node(_ node: Node) -> Node {
        switch node {
        case .item(let i): .item(item(i))
        case .window(let group): .window(.init(id: group.id, name: group.name, children: group.children.map(item)))
        }
    }
    var snapshot = snapshot
    snapshot.sessions = snapshot.sessions.map { SessionNodes(id: $0.id, name: $0.name, current: $0.current, nodes: $0.nodes.map(node)) }
    return snapshot
}
