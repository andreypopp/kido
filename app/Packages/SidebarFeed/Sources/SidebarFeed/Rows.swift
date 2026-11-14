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
        public let title: String?
        public let status: Status
    }
    public enum SecondLine: Equatable, Sendable {
        case none
        case activity(String)
        case record(msg: String?)
    }
    public struct Pick: Equatable, Sendable {
        struct Actions: OptionSet, Sendable {
            let rawValue: Int
            static let select = Actions(rawValue: 1)
            static let close = Actions(rawValue: 2)
        }
        public let pane: Snapshot.Position
        public let record: String
        let actions: Actions
        init(pane: Snapshot.Position, record: String, actions: Actions = .select) {
            self.pane = pane
            self.record = record
            self.actions = actions
        }
    }
    public enum Showing: Equatable, Sendable {
        case pane, record
    }
    public enum Kind: Equatable, Sendable {
        case header, pane(Snapshot.Position, Showing, [HiddenChild]), program(Pick?, [HiddenChild]), divider, gap
    }
    public let id: ID
    public internal(set) var kind: Kind
    public let indent: Int
    public var height: Double { switch kind { case .header: 26; case .divider: 9; case .gap: 10; case .pane, .program: 43 } }
    public let title: String
    public fileprivate(set) var second: SecondLine
    // The runtime after the title; a nested row omits the one of the pane row above it.
    public var runtime: RuntimeMark?
    public let status: Status
    public var indicatorDescription = ""
    public let focused: Bool
    public enum Block: Equatable, Sendable { case first, middle, last }
    public var block: Block?
    public var quietShell = false
    public var showsTitleWhenFolded = false
    public var root: WindowID?
    public var started: Int?
    public var padding: Double { 5 }
    public var leading: Double { 5 + Double(indent) * 15 }
    public var tailY: Double { 24 }
    public var hidden: [HiddenChild] {
        switch kind { case .pane(_, _, let hidden), .program(_, let hidden): hidden; default: [] }
    }
    public var topLevel: Snapshot.Position? { indent == 0 ? target : nil }
    public var target: Snapshot.Position? {
        if case .pane(let target, _, _) = kind { return target }; return nil
    }
    public var pick: Pick? { if case .program(let pick?, _) = kind, pick.actions.contains(.select) { pick } else { nil } }
    public var closing: Pick? { if case .program(let pick?, _) = kind, pick.actions.contains(.close) { pick } else { nil } }
    public var rootPick: Pick? { if case .pane(let target, .record, _) = kind { Pick(pane: target, record: "") } else { nil } }
    public var clickTarget: Snapshot.Position? { target ?? pick?.pane }
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
    fileprivate var selection: KoSchema.RecordSelection? {
        switch self {
        case .idle(let r): r.selection
        case .working(let r): r.selection
        case .done(let r): r.selection
        case .blocked(let r): r.selection
        case .error(let r): r.selection
        }
    }
    fileprivate var closeable: Bool {
        switch self {
        case .idle(let r): r.closeable == true
        case .working(let r): r.closeable == true
        case .done(let r): r.closeable == true
        case .blocked(let r): r.closeable == true
        case .error(let r): r.closeable == true
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
        guard pane.fixedTitle == nil, case .live(let kind) = lifecycle else { return pane.label }
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

    var second: SidebarRow.SecondLine {
        let shown: String = switch lifecycle {
        case .live:
            if agent != nil { caption } else if pane.fixedTitle != nil { pane.foreground?.name ?? "" } else { "" }
        case .ended: caption
        case .lingering: ""
        }
        return shown.isEmpty ? .none : .activity(shown)
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
        if pane.closeConfirm == .never { return true }
        guard case .live(let kind) = lifecycle, case .idle = shell?.phase,
              [.quiet, .done, .error].contains(indicator.status) else { return false }
        if case .terminal = kind.local { return true }
        if case .ssh(let ssh) = kind, case .terminal(let terminal) = ssh.pane { return terminal.interactive }
        return false
    }

    public var rowTitle: String {
        quietShell && pane.fixedTitle == nil ? "Terminal" : sidebarTitle(label, messageable: isMessageable)
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
    typealias Branch = (row: SidebarRow, following: [SidebarRow], waiting: Bool, summary: SidebarRow.Status, containsFocus: Bool)
    func finish(_ raw: SidebarRow, children: [Branch], open: Bool) -> Branch {
        var row = raw
        let hidden: [SidebarRow.HiddenChild] = open ? [] : children.filter { !$0.waiting }.enumerated().sorted {
            ($0.element.summary, $0.offset) < ($1.element.summary, $1.offset)
        }.map { .init(title: $0.element.row.showsTitleWhenFolded ? $0.element.row.title : nil, status: $0.element.summary) }
        switch row.kind {
        case .pane(let position, let showing, _): row.kind = .pane(position, showing, hidden)
        case .program(let pick, _): row.kind = .program(pick, hidden)
        default: break
        }
        let following = children.filter { open || $0.waiting }.flatMap { [$0.row] + $0.following }
        let summary = children.reduce(row.status.folded) { min($0, $1.summary) }
        return (row, following, row.status == .waiting || children.contains { $0.waiting }, summary,
                row.focused || children.contains { $0.containsFocus })
    }
    func windows(_ nodes: [Node], session: SessionID, depth: Int, root: WindowID?, above: String? = nil) -> [Branch] {
        nodes.flatMap { node -> [Branch] in
            let root = root ?? node.window
            let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
            return panes.map { item -> Branch in
                let (status, description) = item.indicator
                let target = Snapshot.Position(session: session, window: item.window, pane: item.id)
                let isClient = target == snapshot.client
                let records = (item.pane.status?.programStatus.records ?? []).filter { !$0.id.isEmpty }.sorted { a, b in
                    let left = a.id.split(separator: "/", omittingEmptySubsequences: false)
                    let right = b.id.split(separator: "/", omittingEmptySubsequences: false)
                    for (a, b) in zip(left, right) {
                        if !a.utf8.elementsEqual(b.utf8) { return a.utf8.lexicographicallyPrecedes(b.utf8) }
                    }
                    return left.count < right.count
                }
                let shownRecord = records.first { $0.selection == .selected }?.id
                let markedRecord = isClient ? shownRecord : nil
                let row = SidebarRow(id: .pane(session, item.id), kind: .pane(target, shownRecord != nil && item.pane.inbox == true ? .record : .pane, []), indent: depth,
                                     title: item.rowTitle, second: item.second,
                                     runtime: item.runtime.flatMap { $0.name == above ? nil : $0 },
                                     status: status, indicatorDescription: description, focused: isClient && markedRecord == nil,
                                     quietShell: item.quietShell, showsTitleWhenFolded: item.isAgent, root: root,
                                     started: { if case .live = item.lifecycle, item.pane.parent != nil { item.pane.started } else { nil } }())
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
                func offered(_ record: KoSchema.ProgramRecord, on pane: Snapshot.Position) -> SidebarRow.Pick? {
                    var actions: SidebarRow.Pick.Actions = []
                    if record.selection != nil { actions.insert(.select) }
                    if record.closeable { actions.insert(.close) }
                    return actions.isEmpty ? nil : .init(pane: pane, record: record.id, actions: actions)
                }
                func recordRows(_ parent: Data?, depth: Int, open: Bool) -> [Branch] {
                    (byParent[parent] ?? []).map { record in
                        let (status, description, title, msg, started): (SidebarRow.Status, String, String?, String?, Int?) = switch record {
                        case .working(let r): (.running, "working", r.title, r.msg, r.started)
                        case .blocked(let r): (.waiting, "blocked", r.title, r.msg, r.started)
                        case .done(let r): (.done, "done", r.title, r.msg, nil)
                        case .error(let r): (.error, "error", r.title, r.msg, nil)
                        case .idle(let r): (.quiet, "idle", r.title, r.msg, nil)
                        }
                        let id = Data(record.id.utf8)
                        let row = SidebarRow(id: .program(session, item.id, id), kind: .program(item.pane.inbox == true ? offered(record, on: target) : nil, []), indent: depth,
                                             title: title.flatMap { $0.isEmpty ? nil : $0 } ?? record.id,
                                             second: .record(msg: msg), status: [.done, .error].contains(status) && item.pane.recordsSeen ? .quiet : status,
                                             indicatorDescription: description, focused: record.id == markedRecord, showsTitleWhenFolded: true, root: root, started: started)
                        return finish(row, children: recordRows(id, depth: depth + 1, open: open), open: open)
                    }
                }
                let panes = windows(item.children, session: session, depth: depth + 1, root: root, above: item.runtime?.name)
                let open = isClient || panes.contains { $0.containsFocus }
                return finish(row, children: recordRows(nil, depth: depth + 1, open: open) + panes, open: open)
            }
        }
    }
    var rows: [SidebarRow] = []
    for session in snapshot.sessions {
        let header = SidebarRow(id: .header(session.id), kind: .header, indent: 0, title: session.name, second: .none, status: .quiet, focused: false)
        let gap = SidebarRow(id: .gap(session.id), kind: .gap, indent: 0, title: "", second: .none, status: .quiet, focused: false)
        rows.append(header)
        for node in session.nodes {
            rows.append(contentsOf: windows([node], session: session.id, depth: 0, root: nil).flatMap { [$0.row] + $0.following })
        }
        rows.append(gap)
    }
    let root = snapshot.client.window
    let block = rows.indices.filter { rows[$0].id.session == snapshot.client.session && rows[$0].root == root }
    let rootNode = snapshot.sessions.first { $0.id == snapshot.client.session }?.nodes.first { $0.window == root }
    if case .window(let window) = rootNode, window.children.count > 1 {
        for (offset, index) in block.enumerated() {
            rows[index].block = offset == 0 ? .first : offset == block.count - 1 ? .last : .middle
        }
    }
    return rows
}

public func sidebarDividers(_ rows: [SidebarRow]) -> [SidebarRow] {
    var result: [SidebarRow] = []
    var previous: (SessionID, WindowID)?
    for row in rows {
        if let root = row.root {
            if let prior = previous, prior.0 == row.id.session, prior.1 != root {
                result.append(SidebarRow(id: .divider(row.id.session, root), kind: .divider, indent: 0, title: "", second: .none, status: .quiet, focused: false))
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
        var shown: SidebarRow.SecondLine
        var pending: (text: SidebarRow.SecondLine, deadline: TimeInterval)?
    }
    private var captions: [SidebarRow.ID: Caption] = [:]
    public init() {}
    public var deadline: TimeInterval? { captions.values.compactMap { $0.pending?.deadline }.min() }

    public mutating func apply(_ rows: [SidebarRow], now: TimeInterval, delay: TimeInterval) -> [SidebarRow] {
        let present = Set(rows.map(\.id))
        captions = captions.filter { present.contains($0.key) }
        let updated = rows.map { raw in
            switch raw.kind { case .pane, .program: break; default: return raw }
            var caption = captions[raw.id] ?? Caption(shown: raw.second)
            if raw.second == caption.shown { caption.pending = nil }
            else {
                if caption.pending?.text != raw.second { caption.pending = (raw.second, now + delay) }
                if let pending = caption.pending, now >= pending.deadline {
                    caption.shown = pending.text
                    caption.pending = nil
                }
            }
            captions[raw.id] = caption
            var row = raw
            row.second = caption.shown
            return row
        }
        return updated
    }
}
