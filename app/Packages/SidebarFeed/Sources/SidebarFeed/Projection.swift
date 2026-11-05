import Foundation
import KoModel

extension Snapshot {
    /// The sidebar tree of the model, in the core's outline. Nil when the model holds no pane.
    public init?(model: KoModel, marks: [PaneID: RuntimeMark]? = nil) {
        guard let (session, window, pane) = model.current else { return nil }
        let projection = Projection(model, marks: marks ?? model.runtimeMarks)
        self.init(clock: .init(now: model.now, local: Int(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))), client: Position(session: session.id, window: window.id, pane: pane), serverInstance: ServerInstance(model.instance),
                  sessions: projection.sessions(current: session.id))
    }
}

private struct Projection {
    let model: KoModel
    let panes: [PaneID: KoSchema.PaneJson]
    let windows: [WindowID: KoSchema.Window]
    let marks: [PaneID: RuntimeMark]

    init(_ model: KoModel, marks: [PaneID: RuntimeMark]) {
        self.model = model
        self.marks = marks
        panes = Dictionary(model.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        windows = Dictionary(model.layout.layout.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // The outline lists each session and then its panes, a pane with a parent under that parent.
    func sessions(current: SessionID) -> [SessionNodes] {
        var result: [SessionNodes] = []
        var outline: [KoSchema.ItemPane] = []
        func close() {
            guard let last = result.indices.last else { return }
            var start = 0
            result[last].nodes = nodes(outline, from: &start, depth: 0)
            outline = []
        }
        for entry in model.outline {
            switch entry {
            case .session(let session):
                close()
                result.append(SessionNodes(id: session.id, name: session.name, current: session.id == current, nodes: []))
            case .pane(let pane): outline.append(pane)
            }
        }
        close()
        return result
    }

    // The entries at `depth` from `start` on, each with the deeper entries that follow it as its children.
    // Neighbouring entries of one window form its group.
    private func nodes(_ outline: [KoSchema.ItemPane], from start: inout Int, depth: Int) -> [Node] {
        var nodes: [Node] = []
        while start < outline.count, outline[start].depth >= depth {
            let entry = outline[start]
            start += 1
            let children = self.nodes(outline, from: &start, depth: entry.depth + 1)
            guard let item = item(entry, children: children) else { continue }
            switch nodes.last {
            case .item(let previous) where previous.window == item.window:
                nodes[nodes.count - 1] = .window(.init(id: item.window, name: windows[item.window]?.name ?? "", children: [previous, item]))
            case .window(var group) where group.id == item.window:
                group.children.append(item)
                nodes[nodes.count - 1] = .window(group)
            default: nodes.append(.item(item))
            }
        }
        return nodes
    }

    private func item(_ entry: KoSchema.ItemPane, children: [Node]) -> Item? {
        guard let pane = panes[entry.id] else { return nil }
        return Item(
            id: entry.id, window: entry.window, title: pane.label, started: pane.started, parent: pane.parent,
            lifecycle: lifecycle(pane),
            program_status: programStatus(pane.status?.programStatus),
            children: children, mark: pane.mark, recordsSeen: pane.recordsSeen, inbox: pane.inbox == true,
            runtime: marks[entry.id], pid: pane.pid, foreground: pane.foreground)
    }

    private func lifecycle(_ pane: KoSchema.PaneJson) -> Lifecycle {
        guard let dead = pane.dead else { return .live(kind(pane)) }
        if pane.close == .onExit { return .lingering(dead.cause) }
        return .ended(dead.cause)
    }

    private func kind(_ pane: KoSchema.PaneJson) -> PaneKind {
        guard let live = pane.status?.kind else { return .terminal(ShellStatus(phase: .unknown, report: nil)) }
        switch live {
        case .terminal(let shell): return .terminal(Self.shell(shell))
        case .someAgent(let agent): return .someAgent(name: agent.name, Self.report(agent.status))
        case .piAgent(let agent): return .piAgent(session: agent.session, Self.report(agent.status))
        case .ssh(let ssh):
            let remote: PaneKind.Remote = switch ssh.pane {
            case .terminal(let terminal): .terminal(interactive: terminal.interactive, Self.shell(terminal.status))
            case .agent(let agent): .agent(name: agent.name, Self.report(agent.status))
            }
            return .ssh(.init(ssh.destination), remote)
        }
    }

    private func programStatus(_ status: KoSchema.ProgramStatus?) -> ProgramStatus {
        guard let status else { return ProgramStatus(serial: 0, records: []) }
        return ProgramStatus(serial: status.serial, records: status.records.map { record in
            typealias Record = ProgramStatus.Record
            let values: (String, Int?, Record.State, String?, KoSchema.ProgramKind?, Int?, String?, String?) = switch record {
            case .idle(let r): (r.id, r.started, .idle, r.app, nil, nil, r.title, r.msg)
            case .working(let r): (r.id, r.started, .working, r.app, nil, r.progress, r.title, r.msg)
            case .done(let r): (r.id, r.started, .done, r.app, nil, nil, r.title, r.msg)
            case .blocked(let r): (r.id, r.started, .blocked, r.app, r.kind, r.progress, r.title, r.msg)
            case .error(let r): (r.id, r.started, .error, r.app, nil, nil, r.title, r.msg)
            }
            let (id, started, state, app, kind, progress, title, msg) = values
            return Record(id: id, started: started, state: state, app: app, kind: kind, progress: progress, title: title, msg: msg)
        })
    }

    static func date(_ monotonic: Int) -> Date { Date(timeIntervalSince1970: Double(monotonic) / 1e9) }

    static func report(_ agent: KoSchema.Agent) -> Report {
        let state: Report.State = switch agent.state {
        case .running(let running): .running(progress: running.progress)
        case .waiting(let waiting): .waiting(waiting.kind, progress: waiting.progress)
        case .idle(let idle): .idle(idle.outcome.map { Outcome(serial: $0.serial, result: $0.result) })
        }
        return Report(since: date(agent.since), msg: agent.msg, state: state)
    }

    static func shell(_ shell: KoSchema.Shell) -> ShellStatus {
        let phase: ShellStatus.Phase = switch shell.phase {
        case .unknown: .unknown
        case .idle(let idle):
            .idle(last: idle.last.map {
                ShellStatus.Exit(code: $0.code, command: $0.command, startedAt: date($0.startedAt), endedAt: date($0.endedAt))
            })
        case .running(let running):
            switch running.origin {
            case .command(let command): .running(.init(command: command.command, startedAt: date(command.startedAt)), fullscreen: running.fullscreen)
            case .unknown: .running(nil, fullscreen: running.fullscreen)
            }
        }
        return ShellStatus(phase: phase, report: shell.report.map(report))
    }
}
