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
        case quiet, running, attention, error, done, stalled
        public var tabStatus: Self { self == .error || self == .attention ? self : .quiet }
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
    public let attention: Bool
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

extension Item {
    var label: String { title.map(\.text).joined() }

    var status: SidebarRow.Status {
        switch indicator {
        case .failed, .gone(.failed), .gone(.died): .error
        case .waiting: .attention
        case .stalled: .stalled
        case .done, .gone(.completed): .done
        case .running, .compacting: .running
        default: .quiet
        }
    }
}

public func sidebarTarget(_ snapshot: Snapshot?, selected: Snapshot.Position? = nil, attention delta: Int? = nil) -> Snapshot.Position? {
    guard let snapshot else { return nil }
    let targets = sidebarRows(snapshot).compactMap { row in row.target.map { ($0, row.attention) } }
    guard let delta else { return targets.first?.0 }
    guard !targets.isEmpty else { return nil }
    var index = targets.firstIndex { $0.0 == selected } ?? (delta > 0 ? -1 : 0)
    for _ in targets {
        index = (index + delta + targets.count) % targets.count
        if targets[index].1 { return targets[index].0 }
    }
    return nil
}

public func sidebarProgramSeen(_ snapshot: Snapshot?, previous: [PaneID: Int]) -> [PaneID: Int] {
    guard let snapshot else { return previous }
    var seen: [PaneID: Int] = [:]
    func visit(_ node: Node, session: SessionID) {
        if case .item(let item) = node {
            if session == snapshot.client.session && item.pane == snapshot.client.pane {
                seen[item.pane] = item.program_status.serial
            } else if seen[item.pane] == nil { seen[item.pane] = previous[item.pane] }
        }
        for child in node.children { visit(child, session: session) }
    }
    for session in snapshot.sessions { for node in session.nodes { visit(node, session: session.id) } }
    return seen
}

public func sidebarRows(_ snapshot: Snapshot?, programSeen: [PaneID: Int] = [:]) -> [SidebarRow] {
    guard let snapshot else { return [] }
    var rows: [SidebarRow] = []
    for session in snapshot.sessions {
        rows.append(SidebarRow(id: .header(session.id), kind: .header, indent: 0, height: 29,
                               title: session.name, tail: "", status: .quiet, attention: false, started: nil, focused: false))
        var y = 0.0
        func windows(_ nodes: [Node], depth: Int) {
            for (index, node) in nodes.enumerated() {
                if depth == 0 && index > 0 {
                    rows.append(SidebarRow(id: .divider(session.id, node.id), kind: .divider, indent: depth, height: 7,
                                           title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
                    y += 7
                }
                let start = rows.count
                let top = y
                let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
                let multiPane = panes.count > 1
                for item in panes {
                    let description: String = switch item.indicator {
                    case .gone(let outcome): "gone" + (outcome.map { ", " + $0.rawValue } ?? "")
                    case .some(let indicator): String(describing: indicator)
                    case nil: ""
                    }
                    let target = Snapshot.Position(session: session.id, window: item.window, pane: item.pane)
                    let tail = item.tail.map(\.text).joined()
                    let agent = item.kind == .agent || item.run == .agent
                    let label = item.label
                    let quietShell = item.kind == .shell && item.run == nil && (item.indicator == .idle || item.indicator == .done || item.indicator == .failed)
                    let height = (tail.isEmpty ? 32.0 : 44.0) - (depth == 0 ? 0 : 4) - (multiPane ? 2 : 0)
                    rows.append(SidebarRow(id: .pane(session.id, item.id), kind: .pane(target), indent: depth,
                                           height: height,
                                           title: quietShell ? "Terminal" : agent && !label.hasPrefix("@") ? "@" + label : label,
                                           tail: tail, status: item.status, indicatorDescription: description,
                                           attention: item.attention, started: item.run == nil ? nil : item.started,
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
                        let seen = (programSeen[item.pane] ?? -1) >= item.program_status.serial
                        let status: SidebarRow.Status = switch record.state {
                        case .working: .running
                        case .blocked: .attention
                        case .done: seen ? .quiet : .done
                        case .error: seen ? .quiet : .error
                        case .idle, .unknown: .quiet
                        }
                        let caption = record.msg ?? ""
                        let height = caption.isEmpty ? 24.0 : 39.0
                        rows.append(SidebarRow(id: .program(session.id, item.pane, Data(record.id.utf8)),
                                               kind: .program(depth: record.id.split(separator: "/", omittingEmptySubsequences: false).count),
                                               indent: depth, height: height,
                                               title: record.title.flatMap { $0.isEmpty ? nil : $0 } ?? record.id,
                                               tail: caption, status: status,
                                               indicatorDescription: seen && (record.state == .done || record.state == .error) ? "idle" : record.state.rawValue,
                                               attention: false, started: nil, focused: false))
                        y += height
                    }
                    if !item.children.isEmpty {
                        windows(item.children, depth: depth + 1)
                        rows.append(SidebarRow(id: .spacing(session.id, "children:" + item.id.description), kind: .gap, indent: depth + 1, height: 3,
                                               title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
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
                                       title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
                y += 3
            }
        }
        windows(session.nodes, depth: 0)
        rows.append(SidebarRow(id: .gap(session.id), kind: .gap, indent: 0, height: 16,
                               title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
    }
    for index in rows.indices { rows[index].windows.reverse() }
    return rows
}

public func sidebarElapsed(started: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(started)))
    return s < 60 ? "\(s)s" : s < 3600 ? String(format: "%dm%02ds", s / 60, s % 60)
        : String(format: "%dh%02dm", s / 3600, (s / 60) % 60)
}
