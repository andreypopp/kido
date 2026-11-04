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
    public let status: Status
    public var indicatorDescription = ""
    public let started: Date?
    public let focused: Bool
    public var guides: [Guide] = []
    public var quietShell = false
    public var agent = false
    public var root: WindowID?
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

extension Item {
    var isAgent: Bool { agent != nil }
    var isMessageable: Bool { if case .live(.piAgent) = lifecycle { inbox } else { false } }
    var agent: Report? {
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

    var caption: String {
        if case .ended(let result) = lifecycle { return result == .completed ? "" : result.rawValue }
        guard let report = agent ?? shell?.report else { return "" }
        let progress: Int? = switch report.state {
        case .running(let progress), .waiting(_, let progress): progress
        case .idle: nil
        }
        return [report.msg ?? "", progress.map { "\($0)%" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // The last command of a plain shell, which neither an agent nor a report covers.
    var lastCommand: ShellStatus.Exit? {
        guard agent == nil, shell?.report == nil, run == nil, case .idle(let exit?) = shell?.phase else { return nil }
        return exit
    }

    func rowTitle(status: SidebarRow.Status) -> (title: String, quietShell: Bool) {
        let quiet = if case .live(.terminal(let shell)) = lifecycle, case .idle = shell.phase {
            run == nil && [.quiet, .done, .error].contains(status)
        } else { false }
        return (quiet ? "Terminal" : sidebarTitle(label, messageable: isMessageable), quiet)
    }

    // The core's mark of a live pane; a run's shell is busy while its run lasts.
    var indicator: (status: SidebarRow.Status, description: String) {
        if case .lingering(let cause) = lifecycle {
            return switch cause {
            case .exited(let exited) where exited.code == 0: (.endedClean, "gone, exited")
            case .exited(let exited): (.endedFailed, "gone, exited with code \(exited.code)")
            case .signaled(let signaled): (.endedFailed, "gone, killed by signal \(signaled.signal)")
            case .failed: (.endedFailed, "gone, failed to start")
            }
        }
        if case .ended(let result) = lifecycle {
            let status: SidebarRow.Status = switch result {
            case .completed: .done
            case .failed, .died: .error
            case .stopped: .quiet
            }
            return (status, "gone, " + result.rawValue)
        }
        if run != nil, agent == nil, let shell, shell.report == nil { return (.running, "running") }
        switch mark {
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
        func windows(_ nodes: [Node], depth: Int, root: WindowID?) {
            for node in nodes {
                let root = root ?? node.window
                let start = rows.count
                let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
                let multiPane = panes.count > 1
                for item in panes {
                    let (status, description) = item.indicator
                    let target = Snapshot.Position(session: session.id, window: item.window, pane: item.pane)
                    let tail = item.caption
                    let agent = item.isAgent
                    let (title, quietShell) = item.rowTitle(status: status)
                    let height = tail.isEmpty ? 32.0 : 48.0
                    let parent = rows.count
                    rows.append(SidebarRow(id: .pane(session.id, item.id), kind: .pane(target), indent: depth,
                                           height: height,
                                           title: title,
                                           tail: tail, status: status, indicatorDescription: description,
                                           started: item.started,
                                           focused: target == snapshot.client,
                                           quietShell: quietShell,
                                           agent: agent, root: root))
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
                        case .idle: .quiet
                        }
                        let caption = record.msg ?? ""
                        let height = caption.isEmpty ? 32.0 : 48.0
                        rows.append(SidebarRow(id: .program(session.id, item.pane, Data(record.id.utf8)),
                                               kind: .pane(nil),
                                               indent: depth + record.id.split(separator: "/", omittingEmptySubsequences: false).count, height: height,
                                               title: record.title.flatMap { $0.isEmpty ? nil : $0 } ?? record.id,
                                               tail: caption, status: [.done, .error].contains(status) && item.recordsSeen ? .quiet : status,
                                               indicatorDescription: record.state.rawValue,
                                               started: nil, focused: false, agent: true, root: root))
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
                        windows(item.children, depth: depth + 1, root: root)
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
                               title: "", tail: "", status: .quiet, started: nil, focused: false))
    }
    return rows
}

public func sidebarElapsed(started: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(started)))
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
