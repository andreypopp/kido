import Foundation
import TmuxControl

public struct SidebarRow: Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case header(SessionID), pane(SessionID, PaneID), program(SessionID, PaneID, Data), divider(SessionID, String), gap(SessionID), spacing(SessionID, String)
        public var session: SessionID {
            switch self { case .header(let s), .pane(let s, _), .program(let s, _, _), .divider(let s, _), .gap(let s), .spacing(let s, _): s }
        }
    }
    public enum Status: Equatable, Sendable {
        case quiet, running, waiting, error, done, stalled
        public var tabStatus: Self { self == .error || self == .waiting ? self : .quiet }
    }
    public enum Kind: Equatable, Sendable {
        case header, pane(Snapshot.Position), program(depth: Int), divider, gap
    }
    public struct WindowSlice: Equatable, Sendable {
        public let offset: Double
        public let height: Double
        public let active: Bool
    }
    public enum Icon: String, Equatable, Sendable { case agent = "text.bubble", terminal }
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
    public var windows: [WindowSlice] = []
    public var multiPane = false
    public var quietShell = false
    public var icon: Icon = .terminal
    public var active: Bool { windows.contains { $0.active } }
    public var padding: Double {
        if case .program = kind { return 4 }
        return (indent == 0 ? 7 : 5) - (multiPane ? 1 : 0)
    }
    public var leading: Double {
        let extra: Double = if case .program(let depth) = kind { Double(depth) * 12 } else { 0 }
        return Double(indent) * 16 + (indent == 0 ? 36 : 32) + extra
    }
    public var tailY: Double {
        if case .program = kind { return 21 }
        return padding + (indent == 0 ? 18.5 : 17.5)
    }
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
        if instance != snapshot.serverInstance { self = Self(); instance = snapshot.serverInstance }
        guard snapshot.error == nil, attended || !outcomes.isEmpty else { return }
        var present: Set<PaneID> = [], client: Item?
        func visit(_ node: Node) {
            if case .item(let item) = node {
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

extension Item {
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
        if case .ended(let result) = lifecycle { return result == .unknown ? "" : result.rawValue }
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
        var y = 0.0
        func windows(_ nodes: [Node], depth: Int) {
            for (index, node) in nodes.enumerated() {
                if depth == 0 && index > 0 {
                    rows.append(SidebarRow(id: .divider(session.id, node.id), kind: .divider, indent: depth, height: 7,
                                           title: "", tail: "", status: .quiet, started: nil, focused: false))
                    y += 7
                }
                let start = rows.count
                let top = y
                let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
                let multiPane = panes.count > 1
                for item in panes {
                    let (status, description) = item.indicator(seen)
                    let target = Snapshot.Position(session: session.id, window: item.window, pane: item.pane)
                    let tail = item.caption
                    let agent = item.run == .agent || item.agent != nil
                    let label = item.label
                    let quietShell = if case .live(.terminal(let shell)) = item.lifecycle, case .idle = shell.phase { item.run == nil && [.quiet, .done, .error].contains(status) } else { false }
                    let height = (tail.isEmpty ? 32.0 : 44.0) - (depth == 0 ? 0 : 4) - (multiPane ? 2 : 0)
                    rows.append(SidebarRow(id: .pane(session.id, item.id), kind: .pane(target), indent: depth,
                                           height: height,
                                           title: quietShell ? "Terminal" : agent && !label.hasPrefix("@") ? "@" + label : label,
                                           tail: tail, status: status, indicatorDescription: description,
                                           started: item.started,
                                           focused: target == snapshot.client,
                                           multiPane: multiPane, quietShell: quietShell,
                                           icon: agent ? .agent : .terminal))
                    y += height
                    let records = item.program_status.records.filter { !$0.id.isEmpty }.sorted { a, b in
                        let left = a.id.split(separator: "/", omittingEmptySubsequences: false)
                        let right = b.id.split(separator: "/", omittingEmptySubsequences: false)
                        for (a, b) in zip(left, right) {
                            if !a.utf8.elementsEqual(b.utf8) { return a.utf8.lexicographicallyPrecedes(b.utf8) }
                        }
                        return left.count < right.count
                    }
                    for record in records {
                        let status: SidebarRow.Status = switch record.state {
                        case .working: .running
                        case .blocked: .waiting
                        case .done: .done
                        case .error: .error
                        case .idle, .unknown: .quiet
                        }
                        let caption = record.msg ?? ""
                        let height = caption.isEmpty ? 24.0 : 39.0
                        rows.append(SidebarRow(id: .program(session.id, item.pane, Data(record.id.utf8)),
                                               kind: .program(depth: record.id.split(separator: "/", omittingEmptySubsequences: false).count),
                                               indent: depth, height: height,
                                               title: record.title.flatMap { $0.isEmpty ? nil : $0 } ?? record.id,
                                               tail: caption, status: status,
                                               indicatorDescription: record.state.rawValue,
                                               started: nil, focused: false))
                        y += height
                    }
                    if !item.children.isEmpty {
                        windows(item.children, depth: depth + 1)
                        rows.append(SidebarRow(id: .spacing(session.id, "children:" + item.id.description), kind: .gap, indent: depth + 1, height: 3,
                                               title: "", tail: "", status: .quiet, started: nil, focused: false))
                        y += 3
                    }
                }
                let height = y - top
                let window: WindowID = switch node { case .window(let group): group.window; case .item(let item): item.window }
                let active = session.id == snapshot.client.session && window == snapshot.client.window
                var offset = 0.0
                for index in start..<rows.count {
                    rows[index].windows.append(.init(offset: offset, height: height, active: active))
                    offset += rows[index].height
                }
                rows.append(SidebarRow(id: .spacing(session.id, "window:" + node.id), kind: .gap, indent: depth, height: 3,
                                       title: "", tail: "", status: .quiet, started: nil, focused: false))
                y += 3
            }
        }
        windows(session.nodes, depth: 0)
        rows.append(SidebarRow(id: .gap(session.id), kind: .gap, indent: 0, height: 16,
                               title: "", tail: "", status: .quiet, started: nil, focused: false))
    }
    for index in rows.indices { rows[index].windows.reverse() }
    return rows
}

public func sidebarElapsed(started: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(started)))
    return s < 60 ? "\(s)s" : s < 3600 ? String(format: "%dm%02ds", s / 60, s % 60)
        : String(format: "%dh%02dm", s / 3600, (s / 60) % 60)
}
