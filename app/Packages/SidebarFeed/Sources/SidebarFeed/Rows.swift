import Foundation
import KoModel

public struct SidebarRow: Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case header(SessionID), pane(SessionID, PaneID), program(SessionID, PaneID, Data), gap(SessionID)
        public var session: SessionID {
            switch self { case .header(let s), .pane(let s, _), .program(let s, _, _), .gap(let s): s }
        }
    }
    public enum Status: Comparable, Sendable {
        case error, waiting, running, done, quiet, endedFailed, endedClean
        func mergingTabStatus(_ other: Self) -> Self { min(self, other) }
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
    public var height: Double
    public let title: String
    public var tail: String
    // The runtime after the title; a nested row omits the one of the pane row above it.
    public var runtime: RuntimeMark?
    public let status: Status
    public var indicatorDescription = ""
    public let focused: Bool
    public var guides: [Guide] = []
    public var quietShell = false
    public var agent = false
    public var root: WindowID?
    public var started: Int?
    public var padding: Double { 7 }
    public var leading: Double { 36 + Double(indent) * 15 }
    public var indicatorX: Double { 20 + Double(indent) * 15 }
    public var tailY: Double { 26 }
    public var topLevel: Snapshot.Position? { indent == 0 ? target : nil }
    public var target: Snapshot.Position? {
        if case .pane(let target) = kind { return target }; return nil
    }
}

public func sidebarTitle(_ title: String, messageable: Bool) -> String {
    messageable && !title.hasPrefix("@") ? "@" + title : title
}

fileprivate extension KoSchema.Shell {
    var commandTitle: String? {
        guard report == nil, case .running(let running) = phase, !running.fullscreen,
              case .command(let command) = running.origin, !command.command.isEmpty else { return nil }
        return command.command
    }
}

extension KoSchema.ProgramRecord {
    fileprivate var id: String {
        switch self {
        case .idle(let r): r.id
        case .working(let r): r.id
        case .done(let r): r.id
        case .blocked(let r): r.id
        case .error(let r): r.id
        }
    }
}

extension Item {
    var isAgent: Bool { agent != nil }
    var isMessageable: Bool {
        if case .live(let kind) = lifecycle, case .piAgent = kind.local { pane.inbox == true } else { false }
    }
    var agent: KoSchema.Agent? {
        guard case .live(let kind) = lifecycle else { return nil }
        if case .ssh(let ssh) = kind, case .agent(let agent) = ssh.pane { return agent.status }
        switch kind.local {
        case .someAgent(let agent): return agent.status
        case .piAgent(let agent): return agent.status
        default: return nil
        }
    }

    var shell: KoSchema.Shell? {
        guard case .live(let kind) = lifecycle else { return nil }
        if case .ssh(let ssh) = kind, case .terminal(let terminal) = ssh.pane { return terminal.status }
        if case .terminal(let status) = kind.local { return status }
        return nil
    }

    var label: String {
        guard case .live(let kind) = lifecycle else { return pane.label }
        if case .ssh(let ssh) = kind, case .terminal(let terminal) = ssh.pane {
            if terminal.interactive, let command = terminal.status.commandTitle {
                return "ssh \(ssh.destination): \(command)"
            }
            return "ssh \(ssh.destination)"
        }
        if case .terminal(let status) = kind.local, let command = status.commandTitle { return command }
        return pane.label
    }

    var departure: (status: SidebarRow.Status, caption: String)? {
        let cause: KoSchema.Cause? = switch lifecycle {
        case .ended(let cause), .lingering(let cause): cause
        default: nil
        }
        guard let cause else { return nil }
        return switch cause {
        case .exited(let exited) where exited.code == 0: (.done, "")
        case .exited(let exited): (.error, "exited with code \(exited.code)")
        case .signaled(let signaled): (.error, "killed by signal \(signaled.signal)")
        case .failed: (.error, "failed to start")
        }
    }

    var caption: String {
        if case .ended = lifecycle, let departure { return departure.caption }
        guard let report = agent ?? shell?.report else { return "" }
        let progress: Int? = switch report.state {
        case .running(let running): running.progress
        case .waiting(let waiting): waiting.progress
        case .idle: nil
        }
        return [report.msg ?? "", progress.map { "\($0)%" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // The last command of a plain shell, which neither an agent nor a report covers.
    var lastCommand: KoSchema.CommandExit? {
        guard agent == nil, let shell, shell.report == nil else { return nil }
        switch shell.phase {
        case .idle(let idle): return idle.last
        case .pending(let pending): return pending.last
        case .unknown, .running: return nil
        }
    }

    var quietShell: Bool {
        guard case .live(let kind) = lifecycle, case .terminal(let shell) = kind.local else { return false }
        switch shell.phase {
        case .idle, .pending: return [.quiet, .done, .error].contains(indicator.status)
        case .unknown, .running: return false
        }
    }

    var closesQuietly: Bool {
        guard case .live(let kind) = lifecycle, case .idle = shell?.phase,
              [.quiet, .done, .error].contains(indicator.status) else { return false }
        if case .terminal = kind.local { return true }
        if case .ssh(let ssh) = kind, case .terminal(let terminal) = ssh.pane { return terminal.interactive }
        return false
    }

    var rowTitle: String {
        quietShell ? "Terminal" : sidebarTitle(label, messageable: isMessageable)
    }

    var indicator: (status: SidebarRow.Status, description: String) {
        if let departure {
            if case .ended = lifecycle, departure.status == .done { return (.done, "gone, completed") }
            let status: SidebarRow.Status = if case .lingering = lifecycle {
                departure.status == .done ? .endedClean : .endedFailed
            } else { departure.status }
            return (status, departure.status == .done ? "gone, exited" : "gone, \(departure.caption)")
        }
        switch pane.mark {
        case .running: return (.running, "running")
        case .waiting: return (.waiting, "waiting")
        case .done: return (.done, "done")
        case .failed: return (.error, "failed")
        case .none_: return (.quiet, "idle")
        }
    }
}

public func sidebarRows(_ snapshot: Snapshot?) -> [SidebarRow] {
    guard let snapshot else { return [] }
    var rows: [SidebarRow] = []
    for session in snapshot.sessions {
        rows.append(SidebarRow(id: .header(session.id), kind: .header, indent: 0, height: 29,
                               title: session.name, tail: "", status: .quiet, focused: false))
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
        func windows(_ nodes: [Node], depth: Int, root: WindowID?, above: String? = nil) {
            for node in nodes {
                let root = root ?? node.window
                let start = rows.count
                let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
                let multiPane = panes.count > 1
                for item in panes {
                    let (status, description) = item.indicator
                    let target = Snapshot.Position(session: session.id, window: item.window, pane: item.id)
                    let tail = item.caption
                    let agent = item.isAgent
                    let title = item.rowTitle
                    let height = tail.isEmpty ? 32.0 : 48.0
                    let parent = rows.count
                    rows.append(SidebarRow(id: .pane(session.id, item.id), kind: .pane(target), indent: depth,
                                           height: height,
                                           title: title,
                                           tail: tail, runtime: item.runtime.flatMap { $0.name == above ? nil : $0 },
                                           status: status, indicatorDescription: description,
                                           focused: target == snapshot.client,
                                           quietShell: item.quietShell,
                                           agent: agent, root: root, started: { if case .live = item.lifecycle, item.pane.parent != nil { item.pane.started } else { nil } }()))
                    let records = (item.pane.status?.programStatus.records ?? []).filter { !$0.id.isEmpty }.sorted { a, b in
                        let left = a.id.split(separator: "/", omittingEmptySubsequences: false)
                        let right = b.id.split(separator: "/", omittingEmptySubsequences: false)
                        for (a, b) in zip(left, right) {
                            if !a.utf8.elementsEqual(b.utf8) { return a.utf8.lexicographicallyPrecedes(b.utf8) }
                        }
                        return left.count < right.count
                    }
                    let recordIDs = Set(records.map { Array($0.id.utf8) })
                    let recordStart = rows.count
                    for record in records {
                        let (status, description, title, msg, started): (SidebarRow.Status, String, String?, String?, Int?) = switch record {
                        case .working(let r): (.running, "working", r.title, r.msg, r.started)
                        case .blocked(let r): (.waiting, "blocked", r.title, r.msg, r.started)
                        case .done(let r): (.done, "done", r.title, r.msg, nil)
                        case .error(let r): (.error, "error", r.title, r.msg, nil)
                        case .idle(let r): (.quiet, "idle", r.title, r.msg, nil)
                        }
                        let caption = msg ?? ""
                        let height = caption.isEmpty ? 32.0 : 48.0
                        let ancestors = record.id.utf8.indices.count {
                            record.id.utf8[$0] == UInt8(ascii: "/") && recordIDs.contains(Array(record.id.utf8[..<$0]))
                        }
                        rows.append(SidebarRow(id: .program(session.id, item.id, Data(record.id.utf8)),
                                               kind: .pane(nil),
                                               indent: depth + 1 + ancestors, height: height,
                                               title: title.flatMap { $0.isEmpty ? nil : $0 } ?? record.id,
                                               tail: caption, status: [.done, .error].contains(status) && item.pane.recordsSeen ? .quiet : status,
                                               indicatorDescription: description,
                                               focused: false, agent: true, root: root,
                                               started: started))
                    }
                    if !records.isEmpty {
                        for (index, record) in records.enumerated() {
                            let prefix = record.id + "/"
                            let count = records[(index + 1)...].prefix { $0.id.utf8.starts(with: prefix.utf8) }.count
                            if count > 0 {
                                guide(recordStart + index, end: recordStart + index + count + 1,
                                      x: rows[recordStart + index].indicatorX, topInset: 22)
                            }
                        }
                    }
                    if !item.children.isEmpty {
                        windows(item.children, depth: depth + 1, root: root, above: item.runtime?.name)
                    }
                    if rows.count > parent + 1 {
                        guide(parent, x: rows[parent].indicatorX, topInset: 22)
                    }
                }
                if depth == 0 && multiPane { guide(start, x: 5) }
            }
        }
        windows(session.nodes, depth: 0, root: nil)
        rows.append(SidebarRow(id: .gap(session.id), kind: .gap, indent: 0, height: 16,
                               title: "", tail: "", status: .quiet, focused: false))
    }
    return rows
}

public func sidebarElapsed(started: Int, now: Int) -> String {
    let s = max(0, now - started) / 1_000_000_000
    return s < 60 ? "\(s)s" : s < 3600 ? String(format: "%dm%02ds", s / 60, s % 60)
        : String(format: "%dh%02dm", s / 3600, (s / 60) % 60)
}

public struct SidebarCaptions {
    private struct Caption {
        var shown: String
        var pending: (text: String, deadline: TimeInterval)?
    }
    private var captions: [SidebarRow.ID: Caption] = [:]
    public init() {}
    public var deadline: TimeInterval? { captions.values.compactMap { $0.pending?.deadline }.min() }

    public mutating func apply(_ rows: [SidebarRow], now: TimeInterval, delay: TimeInterval) -> [SidebarRow] {
        let present = Set(rows.map(\.id))
        captions = captions.filter { present.contains($0.key) }
        return rows.map { raw in
            guard case .pane = raw.kind else { return raw }
            var caption = captions[raw.id] ?? Caption(shown: raw.tail)
            if raw.tail == caption.shown { caption.pending = nil }
            else {
                if caption.pending?.text != raw.tail { caption.pending = (raw.tail, now + delay) }
                if let pending = caption.pending, now >= pending.deadline {
                    caption.shown = pending.text
                    caption.pending = nil
                }
            }
            captions[raw.id] = caption
            var row = raw
            row.tail = caption.shown
            row.height = caption.shown.isEmpty ? 32 : 48
            row.guides = raw.guides.map { guide in
                .init(x: guide.x, top: guide.top, bottom: guide.bottom + row.height - raw.height)
            }
            return row
        }
    }
}
