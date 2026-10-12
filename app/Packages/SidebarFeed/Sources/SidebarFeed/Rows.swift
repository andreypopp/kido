import Foundation
import TmuxControl

public struct SidebarRow: Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case header(SessionID), pane(SessionID, PaneID), program(SessionID, PaneID, Data), gap(SessionID)
        public var session: SessionID {
            switch self { case .header(let s), .pane(let s, _), .program(let s, _, _), .gap(let s): s }
        }
    }
    public enum Status: Equatable, Sendable {
        case quiet, running, waiting, error, done, stalled
        public var tabStatus: Self { self == .stalled ? .error : self == .error || self == .waiting ? self : .quiet }
    }
    public enum Kind: Equatable, Sendable {
        case header, pane(Snapshot.Position?), gap
    }
    public struct Guide: Equatable, Sendable {
        public let x: Double
        public let top: Double
        public let bottom: Double
    }
    public let id: ID
    public let kind: Kind
    public let indent: Int
    public let height: Double
    public let title: String
    public let tail: String
    public let status: Status
    public var indicatorDescription = ""
    public let started: Date?
    public let focused: Bool
    public var guides: [Guide] = []
    public var quietShell = false
    public var agent = false
    public var padding: Double { 7 }
    public var leading: Double { 36 + Double(indent) * 15 }
    public var indicatorX: Double { 20 + Double(indent) * 15 }
    public var tailY: Double { 26 }
    public var target: Snapshot.Position? {
        if case .pane(let target) = kind { return target }; return nil
    }
}

enum OutcomeSource: Hashable, Sendable { case agent, report, command }

enum OutcomeIdentity: Hashable, Sendable {
    case serial(Int)
    case command(started: Date, ended: Date)
}

public struct SidebarSeen: Equatable, Sendable {
    private var instance: ServerInstance?
    private var outcomes: [PaneID: [OutcomeSource: OutcomeIdentity]] = [:]

    public init() {}

    func contains(_ pane: PaneID, _ source: OutcomeSource, _ identity: OutcomeIdentity) -> Bool {
        outcomes[pane]?[source] == identity
    }

    public mutating func observe(_ snapshot: Snapshot, attended: Bool) {
        guard snapshot.error == nil else { return }
        let baseline = instance == nil
        if instance != snapshot.serverInstance { self = Self(); instance = snapshot.serverInstance }
        guard baseline || attended || !outcomes.isEmpty else { return }
        var present: Set<PaneID> = [], client: Item?
        func visit(_ node: Node) {
            if case .item(let item) = node {
                if baseline {
                    for outcome in item.outcomes { outcomes[item.pane, default: [:]][outcome.source] = outcome.identity }
                }
                if outcomes[item.pane] != nil { present.insert(item.pane) }
                if item.pane == snapshot.client.pane { client = item }
            }
            node.children.forEach(visit)
        }
        for session in snapshot.sessions { session.nodes.forEach(visit) }
        for pane in outcomes.keys where !present.contains(pane) { outcomes[pane] = nil }
        guard attended, let client else { return }
        for outcome in client.outcomes { outcomes[client.pane, default: [:]][outcome.source] = outcome.identity }
    }
}

public func sidebarTitle(_ title: String, messageable: Bool) -> String {
    messageable && !title.hasPrefix("@") ? "@" + title : title
}

extension Item {
    var isAgent: Bool { run == .agent || agent != nil }
    var isMessageable: Bool {
        if case .live(.piAgent) = lifecycle { return true }
        return run == .agent
    }
    var agent: AgentStatus? {
        switch lifecycle {
        case .live(.someAgent(_, let status)), .live(.piAgent(_, let status)), .live(.ssh(_, .agent(_, let status))): status
        default: nil
        }
    }

    var shell: ShellStatus? {
        switch lifecycle {
        case .live(.terminal(let status)), .live(.ssh(_, .terminal(_, let status))): status
        default: nil
        }
    }

    var outcomes: [(source: OutcomeSource, identity: OutcomeIdentity, failed: Bool)] {
        var outcomes: [(source: OutcomeSource, identity: OutcomeIdentity, failed: Bool)] = []
        if case .idle(let outcome?) = agent?.state { outcomes.append((.agent, .serial(outcome.serial), outcome.result == .failure)) }
        if case .idle(let outcome?) = shell?.report?.state { outcomes.append((.report, .serial(outcome.serial), outcome.result == .failure)) }
        if run == nil, case .idle(let exit?) = shell?.phase {
            outcomes.append((.command, .command(started: exit.startedAt, ended: exit.endedAt), exit.code != 0))
        }
        return outcomes
    }

    var label: String {
        switch lifecycle {
        case .live(.terminal(let status)) where status.report == nil && run == nil:
            if case .running(let command?, fullscreen: false) = status.phase, !command.command.isEmpty { return command.command }
            return title
        case .live(.ssh(let destination, .terminal(let interactive, let status))):
            if status.report == nil, interactive, case .running(let command?, fullscreen: false) = status.phase, !command.command.isEmpty {
                return "ssh \(destination): \(command.command)"
            }
            return "ssh \(destination)"
        default: return title
        }
    }

    var searchTitles: [String] {
        switch lifecycle {
        case .live(.ssh(let destination, .terminal)): [destination.description]
        case .live(.ssh(let destination, .agent)): [title, destination.description]
        case .live(.terminal): []
        case .live: [title]
        case .ended: run == .agent ? [title] : []
        }
    }

    var caption: String {
        func compose(_ msg: String?, _ progress: Int?) -> String {
            [msg ?? "", progress.map { "\($0)%" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if case .ended(let result) = lifecycle { return result == .unknown || result == .completed ? "" : result.rawValue }
        if let agent {
            switch agent.state {
            case .running(let progress), .waiting(_, let progress): return compose(agent.msg, progress)
            case .stalled, .idle: return compose(agent.msg, nil)
            }
        }
        guard let report = shell?.report else { return "" }
        switch report.state {
        case .running(let progress), .waiting(_, let progress): return compose(report.msg, progress)
        case .idle: return compose(report.msg, nil)
        }
    }

    func indicator(_ seen: SidebarSeen) -> (status: SidebarRow.Status, description: String) {
        func outcome(_ source: OutcomeSource) -> (SidebarRow.Status, String) {
            guard let outcome = outcomes.first(where: { $0.source == source }), !seen.contains(pane, source, outcome.identity) else { return (.quiet, "idle") }
            return outcome.failed ? (.error, "failed") : (.done, "done")
        }
        if case .ended(let result) = lifecycle {
            let status: SidebarRow.Status = switch result {
            case .completed: .done
            case .failed, .died: .error
            case .stopped, .unknown: .quiet
            }
            return (status, result == .unknown ? "gone" : "gone, " + result.rawValue)
        }
        if let agent {
            switch agent.state {
            case .running: return (.running, "running")
            case .waiting: return (.waiting, "waiting")
            case .stalled: return (.stalled, "stalled")
            case .idle: return outcome(.agent)
            }
        }
        guard let shell else { return (.quiet, "") }
        if shell.report == nil, run != nil { return (.running, "running") }
        if let report = shell.report {
            switch report.state {
            case .running: return (.running, "running")
            case .waiting: return (.waiting, "waiting")
            case .idle: return outcome(.report)
            }
        }
        if case .running(_, fullscreen: true) = shell.phase { return (.quiet, "") }
        switch shell.phase {
        case .unknown: return (.quiet, "")
        case .running: return (.running, "running")
        case .idle: return outcome(.command)
        }
    }
}

public func sidebarRows(_ snapshot: Snapshot?, seen: SidebarSeen = SidebarSeen()) -> [SidebarRow] {
    guard let snapshot else { return [] }
    var rows: [SidebarRow] = []
    for session in snapshot.sessions {
        rows.append(SidebarRow(id: .header(session.id), kind: .header, indent: 0, height: 29,
                               title: session.name, tail: "", status: .quiet, started: nil, focused: false))
        func guide(_ start: Int, end: Int? = nil, x: Double, topInset: Double = 10) {
            let end = end ?? rows.count
            let height = rows[start..<end].reduce(0) { $0 + $1.height }
            var offset = 0.0
            for index in start..<end {
                let top = max(0, topInset - offset)
                let bottom = min(rows[index].height, height - 10 - offset)
                if bottom > top { rows[index].guides.append(.init(x: x, top: top, bottom: bottom)) }
                offset += rows[index].height
            }
        }
        func windows(_ nodes: [Node], depth: Int) {
            for node in nodes {
                let start = rows.count
                let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
                let multiPane = panes.count > 1
                for item in panes {
                    let (status, description) = item.indicator(seen)
                    let target = Snapshot.Position(session: session.id, window: item.window, pane: item.pane)
                    let tail = item.caption
                    let agent = item.isAgent
                    let label = item.label
                    let quietShell = if case .live(.terminal(let shell)) = item.lifecycle, case .idle = shell.phase { item.run == nil && [.quiet, .done, .error].contains(status) } else { false }
                    let height = tail.isEmpty ? 32.0 : 48.0
                    let parent = rows.count
                    rows.append(SidebarRow(id: .pane(session.id, item.id), kind: .pane(target), indent: depth,
                                           height: height,
                                           title: quietShell ? "Terminal" : sidebarTitle(label, messageable: item.isMessageable),
                                           tail: tail, status: status, indicatorDescription: description,
                                           started: item.started,
                                           focused: target == snapshot.client,
                                           quietShell: quietShell,
                                           agent: agent))
                    let records = item.program_status.records.filter { !$0.id.isEmpty }.sorted { a, b in
                        let left = a.id.split(separator: "/", omittingEmptySubsequences: false)
                        let right = b.id.split(separator: "/", omittingEmptySubsequences: false)
                        for (a, b) in zip(left, right) {
                            if !a.utf8.elementsEqual(b.utf8) { return a.utf8.lexicographicallyPrecedes(b.utf8) }
                        }
                        return left.count < right.count
                    }
                    let recordStart = rows.count
                    for record in records {
                        let status: SidebarRow.Status = switch record.state {
                        case .working: .running
                        case .blocked: .waiting
                        case .done: .done
                        case .error: .error
                        case .idle, .unknown: .quiet
                        }
                        let caption = record.msg ?? ""
                        let height = caption.isEmpty ? 32.0 : 48.0
                        rows.append(SidebarRow(id: .program(session.id, item.pane, Data(record.id.utf8)),
                                               kind: .pane(nil),
                                               indent: depth + record.id.split(separator: "/", omittingEmptySubsequences: false).count, height: height,
                                               title: record.title.flatMap { $0.isEmpty ? nil : $0 } ?? record.id,
                                               tail: caption, status: [.done, .error].contains(status) && seen.contains(item.pane, item.agent != nil ? .agent : .report, .serial(item.program_status.serial)) ? .quiet : status,
                                               indicatorDescription: record.state.rawValue,
                                               started: nil, focused: false, agent: true))
                    }
                    if !records.isEmpty {
                        for (index, record) in records.enumerated() {
                            let prefix = record.id + "/"
                            let count = records[(index + 1)...].prefix { $0.id.hasPrefix(prefix) }.count
                            if count > 0 {
                                guide(recordStart + index, end: recordStart + index + count + 1,
                                      x: rows[recordStart + index].indicatorX, topInset: 22)
                            }
                        }
                    }
                    if !item.children.isEmpty {
                        windows(item.children, depth: depth + 1)
                    }
                    if rows.count > parent + 1 {
                        guide(parent, x: rows[parent].indicatorX, topInset: 22)
                    }
                }
                if depth == 0 && multiPane { guide(start, x: 5) }
            }
        }
        windows(session.nodes, depth: 0)
        rows.append(SidebarRow(id: .gap(session.id), kind: .gap, indent: 0, height: 16,
                               title: "", tail: "", status: .quiet, started: nil, focused: false))
    }
    return rows
}

public func sidebarElapsed(started: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(started)))
    return s < 60 ? "\(s)s" : s < 3600 ? String(format: "%dm%02ds", s / 60, s % 60)
        : String(format: "%dh%02dm", s / 3600, (s / 60) % 60)
}
