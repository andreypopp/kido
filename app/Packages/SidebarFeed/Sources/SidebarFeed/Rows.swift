import Foundation
import TmuxControl

public struct SidebarRow: Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case header(SessionID), pane(SessionID, PaneID), divider(SessionID, String), gap(SessionID)
        public var session: SessionID {
            switch self { case .header(let s), .pane(let s, _), .divider(let s, _), .gap(let s): s }
        }
    }
    public enum Status: Equatable, Sendable { case quiet, running, attention, error }
    public enum Kind: Equatable, Sendable {
        case header, pane(Snapshot.Position), divider, gap
    }
    public struct Segment: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case card, window(active: Bool) }
        public let kind: Kind
        public let indent: Int
        public var top: Double
        public let height: Double
        public let topLeft: Double
        public let bottomLeft: Double
    }
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
    public var segments: [Segment] = []
    public var target: Snapshot.Position? {
        if case .pane(let target) = kind { return target }; return nil
    }
}

extension Item {
    var label: String { title.map(\.text).joined() }

    var status: SidebarRow.Status {
        switch indicator {
        case .failed, .gone(.failed), .gone(.died): .error
        default: attention || indicator == .waiting || indicator == .stalled ? .attention
            : indicator == .running || indicator == .compacting ? .running : .quiet
        }
    }
}

private func walkNodes(_ nodes: [Node], depth: Int, before: (Node, Int, Int) -> Void,
                       pane: (Item, Int) -> Void, after: (Node, Int) -> Void) {
    for (index, node) in nodes.enumerated() {
        before(node, depth, index)
        let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
        for item in panes {
            pane(item, depth)
            walkNodes(item.children, depth: depth + 1, before: before, pane: pane, after: after)
        }
        after(node, depth)
    }
}

public func sidebarTarget(_ snapshot: Snapshot?, selected: Snapshot.Position? = nil, attention delta: Int? = nil) -> Snapshot.Position? {
    guard let snapshot else { return nil }
    var targets: [(Snapshot.Position, Bool)] = []
    for session in snapshot.sessions {
        walkNodes(session.nodes, depth: 0, before: { _, _, _ in }, pane: { item, _ in
            targets.append((.init(session: session.id, window: item.window, pane: item.pane), item.attention))
        }, after: { _, _ in })
    }
    guard let delta else { return targets.first?.0 }
    guard !targets.isEmpty else { return nil }
    var index = targets.firstIndex { $0.0 == selected } ?? (delta > 0 ? -1 : 0)
    for _ in targets {
        index = (index + delta + targets.count) % targets.count
        if targets[index].1 { return targets[index].0 }
    }
    return nil
}

public func sidebarRows(_ snapshot: Snapshot?, folded: Set<SessionID>) -> [SidebarRow] {
    guard let snapshot else { return [] }
    var rows: [SidebarRow] = []
    for session in snapshot.sessions {
        let start = rows.count
        rows.append(SidebarRow(id: .header(session.id), kind: .header, indent: 0, height: 31,
                               title: session.name, tail: "", status: .quiet, attention: false, started: nil, focused: false))
        var begins: [Int] = []
        if !folded.contains(session.id) {
            walkNodes(session.nodes, depth: 0, before: { node, depth, index in
                if index > 0 {
                    rows.append(SidebarRow(id: .divider(session.id, node.id), kind: .divider, indent: depth, height: 9,
                                           title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
                }
                begins.append(rows.count)
            }, pane: { item, depth in
                    let description: String = switch item.indicator {
                    case .gone(let outcome): "gone" + (outcome.map { ", " + $0.rawValue } ?? "")
                    case .some(let indicator): String(describing: indicator)
                    case nil: ""
                    }
                    let target = Snapshot.Position(session: session.id, window: item.window, pane: item.pane)
                    let tail = item.tail.map(\.text).joined()
                    let started = item.run == nil ? nil : item.started
                    rows.append(SidebarRow(id: .pane(session.id, item.id), kind: .pane(target), indent: depth,
                                           height: (depth == 0 ? 28 : 25) + (tail.isEmpty ? 0 : 16),
                                           title: item.label, tail: tail, status: item.status, indicatorDescription: description,
                                           attention: item.attention, started: started, focused: target == snapshot.client))
            }, after: { node, depth in
                let begin = begins.removeLast()
                let window: WindowID = switch node { case .window(let group): group.window; case .item(let item): item.window }
                let height = rows[begin...].reduce(0) { $0 + $1.height }
                var y = 0.0
                for i in begin..<rows.count {
                    rows[i].segments.insert(.init(kind: .window(active: session.id == snapshot.client.session && window == snapshot.client.window),
                                                  indent: depth, top: -y, height: height,
                                                  topLeft: depth == 0 ? 0 : 6, bottomLeft: depth == 0 ? 0 : 6), at: 0)
                    y += rows[i].height
                }
            })
        }
        let height = rows[start...].reduce(0) { $0 + $1.height }
        var y = 0.0
        for i in start..<rows.count {
            rows[i].segments = rows[i].segments.map { segment in
                let last = y + segment.top + segment.height == height
                return .init(kind: segment.kind, indent: segment.indent, top: segment.top, height: segment.height,
                             topLeft: segment.topLeft, bottomLeft: last ? 0 : segment.bottomLeft)
            }
            rows[i].segments.insert(.init(kind: .card, indent: 0, top: -y, height: height, topLeft: 10, bottomLeft: 10), at: 0)
            y += rows[i].height
        }
        rows.append(SidebarRow(id: .gap(session.id), kind: .gap, indent: 0, height: 9,
                               title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
    }
    return rows
}

public func sidebarElapsed(started: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(started)))
    return s < 60 ? "\(s)s" : s < 3600 ? String(format: "%dm%02ds", s / 60, s % 60)
        : String(format: "%dh%02dm", s / 3600, (s / 60) % 60)
}
