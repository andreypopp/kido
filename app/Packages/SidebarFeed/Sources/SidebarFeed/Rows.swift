import Foundation
import KoModel

public struct SidebarRow: Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case divider(SessionID, WindowID), header(SessionID), pane(SessionID, PaneID), program(SessionID, PaneID, Data), gap(SessionID)
        public var session: SessionID {
            switch self { case .divider(let s, _), .header(let s), .pane(let s, _), .program(let s, _, _), .gap(let s): s }
        }
    }
    public enum Status: Comparable, Sendable {
        case error, waiting, running, done, quiet, endedFailed, endedClean
        var folded: Self {
            switch self {
            case .error, .endedFailed: .error
            case .waiting: .waiting
            case .running: .running
            case .done, .quiet, .endedClean: .quiet
            }
        }
        func mergingTabStatus(_ other: Self) -> Self { min(self, other) }
    }
    public struct HiddenChild: Equatable, Sendable {
        public let title: String
        public let status: Status
    }
    public enum Children: Equatable, Sendable {
        case leaf, folded([HiddenChild]), expanded
    }
    public enum Kind: Equatable, Sendable {
        case header, pane(Snapshot.Position, Children), program(Children), divider, gap
    }
    public let id: ID
    public internal(set) var kind: Kind
    public let indent: Int
    public var height: Double { switch kind { case .header: 26; case .divider: 9; case .gap: 10; case .pane, .program: contentHeight } }
    public let title: String
    public var tail: String
    // The runtime after the title; a nested row omits the one of the pane row above it.
    public var runtime: RuntimeMark?
    public let status: Status
    public var indicatorDescription = ""
    public let focused: Bool
    public enum Block: Equatable, Sendable { case single, first, middle, last }
    public var block: Block?
    public var quietShell = false
    public var agent = false
    public var root: WindowID?
    public var started: Int?
    public var padding: Double { 5 }
    public var leading: Double { 23 + Double(indent) * 15 }
    public var tailY: Double { 23 }
    public var children: Children {
        switch kind { case .pane(_, let children), .program(let children): children; default: .leaf }
    }
    var contentHeight: Double {
        if !tail.isEmpty { return 42 }
        if case .folded(let hidden) = children, !hidden.isEmpty { return 42 }
        return 28
    }
    public var topLevel: Snapshot.Position? { indent == 0 ? target : nil }
    public var target: Snapshot.Position? {
        if case .pane(let target, _) = kind { return target }; return nil
    }
}

public struct SidebarExpansion: Equatable, Sendable {
    public private(set) var expanded: Set<SidebarRow.ID> = []
    public init() {}
    public mutating func set(_ id: SidebarRow.ID, expanded: Bool) {
        if expanded { self.expanded.insert(id) } else { self.expanded.remove(id) }
    }
    public mutating func reconcile(_ ids: Set<SidebarRow.ID>) { expanded.formIntersection(ids) }
    public mutating func expandAll(_ outline: SidebarOutline) { expanded.formUnion(outline.expandable) }
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

    public var rowTitle: String {
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

public struct SidebarOutline: Equatable, Sendable {
    public let rows: [SidebarRow]
    public let ids: Set<SidebarRow.ID>
    let expandable: Set<SidebarRow.ID>
}

public func sidebarRows(_ snapshot: Snapshot?, expanded: Set<SidebarRow.ID> = []) -> SidebarOutline {
    guard let snapshot else { return SidebarOutline(rows: [], ids: [], expandable: []) }
    typealias Branch = (row: SidebarRow, following: [SidebarRow], waiting: Bool, summary: SidebarRow.Status)
    var ids: Set<SidebarRow.ID> = []
    var expandable: Set<SidebarRow.ID> = []
    func finish(_ raw: SidebarRow, children: [Branch]) -> Branch {
        ids.insert(raw.id)
        if !children.isEmpty { expandable.insert(raw.id) }
        var row = raw
        let open = expanded.contains(row.id)
        let hidden = open ? [] : children.filter { !$0.waiting }
        let disclosure: SidebarRow.Children = children.isEmpty ? .leaf
            : open ? .expanded : .folded(hidden.enumerated().sorted {
                ($0.element.summary, $0.offset) < ($1.element.summary, $1.offset)
            }.map { .init(title: $0.element.row.title, status: $0.element.summary) })
        switch row.kind {
        case .pane(let position, _): row.kind = .pane(position, disclosure)
        case .program: row.kind = .program(disclosure)
        default: break
        }
        let following = children.filter { open || $0.waiting }.flatMap { [$0.row] + $0.following }
        let summary = children.reduce(row.status.folded) { min($0, $1.summary) }
        return (row, following, row.status == .waiting || children.contains { $0.waiting }, summary)
    }
    func windows(_ nodes: [Node], session: SessionID, depth: Int, root: WindowID?, above: String? = nil) -> [Branch] {
        nodes.flatMap { node -> [Branch] in
            let root = root ?? node.window
            let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
            return panes.map { item -> Branch in
                let (status, description) = item.indicator
                let target = Snapshot.Position(session: session, window: item.window, pane: item.id)
                let row = SidebarRow(id: .pane(session, item.id), kind: .pane(target, .leaf), indent: depth,
                                     title: item.rowTitle, tail: item.caption,
                                     runtime: item.runtime.flatMap { $0.name == above ? nil : $0 },
                                     status: status, indicatorDescription: description, focused: target == snapshot.client,
                                     quietShell: item.quietShell, agent: item.isAgent, root: root,
                                     started: { if case .live = item.lifecycle, item.pane.parent != nil { item.pane.started } else { nil } }())
                let records = (item.pane.status?.programStatus.records ?? []).filter { !$0.id.isEmpty }.sorted { a, b in
                    let left = a.id.split(separator: "/", omittingEmptySubsequences: false)
                    let right = b.id.split(separator: "/", omittingEmptySubsequences: false)
                    for (a, b) in zip(left, right) {
                        if !a.utf8.elementsEqual(b.utf8) { return a.utf8.lexicographicallyPrecedes(b.utf8) }
                    }
                    return left.count < right.count
                }
                let recordIDs = Set(records.map { Data($0.id.utf8) })
                var byParent: [Data?: [KoSchema.ProgramRecord]] = [:]
                for record in records {
                    var prefix = Data(record.id.utf8)
                    var parent: Data?
                    while let slash = prefix.lastIndex(of: UInt8(ascii: "/")) {
                        prefix = prefix.prefix(upTo: slash)
                        if recordIDs.contains(prefix) { parent = prefix; break }
                    }
                    byParent[parent, default: []].append(record)
                }
                func recordRows(_ parent: Data?, depth: Int) -> [Branch] {
                    (byParent[parent] ?? []).map { record in
                        let (status, description, title, msg, started): (SidebarRow.Status, String, String?, String?, Int?) = switch record {
                        case .working(let r): (.running, "working", r.title, r.msg, r.started)
                        case .blocked(let r): (.waiting, "blocked", r.title, r.msg, r.started)
                        case .done(let r): (.done, "done", r.title, r.msg, nil)
                        case .error(let r): (.error, "error", r.title, r.msg, nil)
                        case .idle(let r): (.quiet, "idle", r.title, r.msg, nil)
                        }
                        let id = Data(record.id.utf8)
                        let row = SidebarRow(id: .program(session, item.id, id), kind: .program(.leaf), indent: depth,
                                             title: title.flatMap { $0.isEmpty ? nil : $0 } ?? record.id,
                                             tail: msg ?? "", status: [.done, .error].contains(status) && item.pane.recordsSeen ? .quiet : status,
                                             indicatorDescription: description, focused: false, agent: true, root: root, started: started)
                        return finish(row, children: recordRows(id, depth: depth + 1))
                    }
                }
                return finish(row, children: recordRows(nil, depth: depth + 1)
                    + windows(item.children, session: session, depth: depth + 1, root: root, above: item.runtime?.name))
            }
        }
    }
    var rows: [SidebarRow] = []
    for session in snapshot.sessions {
        let header = SidebarRow(id: .header(session.id), kind: .header, indent: 0, title: session.name, tail: "", status: .quiet, focused: false)
        let gap = SidebarRow(id: .gap(session.id), kind: .gap, indent: 0, title: "", tail: "", status: .quiet, focused: false)
        rows.append(header)
        for node in session.nodes {
            rows.append(contentsOf: windows([node], session: session.id, depth: 0, root: nil).flatMap { [$0.row] + $0.following })
        }
        rows.append(gap)
    }
    let root = PaneProjection(snapshot).rootWindows[snapshot.client.window]
    let block = rows.indices.filter { rows[$0].id.session == snapshot.client.session && root != nil && rows[$0].root == root }
    for (offset, index) in block.enumerated() {
        rows[index].block = block.count == 1 ? .single : offset == 0 ? .first : offset == block.count - 1 ? .last : .middle
    }
    return SidebarOutline(rows: rows, ids: ids, expandable: expandable)
}

public func sidebarDividers(_ rows: [SidebarRow]) -> [SidebarRow] {
    var result: [SidebarRow] = []
    var previous: (SessionID, WindowID)?
    for row in rows {
        if let root = row.root {
            if let prior = previous, prior.0 == row.id.session, prior.1 != root {
                result.append(SidebarRow(id: .divider(row.id.session, root), kind: .divider, indent: 0, title: "", tail: "", status: .quiet, focused: false))
            }
            previous = (row.id.session, root)
        } else { previous = nil }
        result.append(row)
    }
    return result
}

public func visibleSidebarRow(for pane: PaneID, in rows: [SidebarRow], projection: PaneProjection) -> Int? {
    var current: PaneID? = pane
    while let id = current {
        if let index = rows.firstIndex(where: { $0.target?.pane == id }) { return index }
        current = projection.placements[id]?.parent
    }
    return nil
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
        let updated = rows.map { raw in
            switch raw.kind { case .pane, .program: break; default: return raw }
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
            return row
        }
        return updated
    }
}
