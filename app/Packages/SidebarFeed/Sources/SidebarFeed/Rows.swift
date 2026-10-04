import Foundation
import TmuxControl

public struct SidebarRow: Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case header(SessionID), pane(SessionID, PaneID), divider(SessionID, String), gap(SessionID)
        public var session: SessionID {
            switch self { case .header(let s), .pane(let s, _), .divider(let s, _), .gap(let s): s }
        }
    }
    public enum PaneKind: Equatable, Sendable { case agent, run(Item.Run), shell, ssh }
    public enum Status: Equatable, Sendable { case quiet, running, attention, error }
    public enum Kind: Equatable, Sendable {
        case header(String), pane(PaneKind, Snapshot.Position), divider, gap
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
    public let attention: Bool
    public let started: Date?
    public let focused: Bool
    public var segments: [Segment] = []
    public var target: Snapshot.Position? {
        if case .pane(_, let target) = kind { return target }; return nil
    }
}

public func sidebarRows(_ snapshot: Snapshot?, folded: Set<SessionID>) -> [SidebarRow] {
    guard let snapshot else { return [] }
    var rows: [SidebarRow] = []
    for session in snapshot.sessions {
        let start = rows.count
        rows.append(SidebarRow(id: .header(session.id), kind: .header(session.name), indent: 0, height: 31,
                               title: session.name, tail: "", status: .quiet, attention: false, started: nil, focused: false))
        func windows(_ nodes: [Node], depth: Int) {
            for (index, node) in nodes.enumerated() {
                if index > 0 {
                    rows.append(SidebarRow(id: .divider(session.id, node.id), kind: .divider, indent: depth, height: 9,
                                           title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
                }
                let begin = rows.count
                let window: WindowID
                let panes: [Item]
                switch node {
                case .window(let group): window = group.window; panes = group.children
                case .item(let item): window = item.window; panes = [item]
                }
                for item in panes {
                    let kind: SidebarRow.PaneKind = item.run.map { .run($0) } ?? (item.kind == .ssh ? .ssh : item.kind == .shell ? .shell : .agent)
                    let status: SidebarRow.Status
                    switch item.indicator {
                    case .failed, .gone(.failed), .gone(.died): status = .error
                    default:
                        status = item.attention || item.indicator == .waiting || item.indicator == .stalled ? .attention
                            : item.indicator == .running || item.indicator == .compacting ? .running : .quiet
                    }
                    let target = Snapshot.Position(session: session.id, window: item.window, pane: item.pane)
                    let tail = item.tail.map(\.text).joined()
                    let started = item.run == nil ? nil : item.started
                    rows.append(SidebarRow(id: .pane(session.id, item.id), kind: .pane(kind, target), indent: depth,
                                           height: (depth == 0 ? 32 : 29) + (tail.isEmpty ? 0 : 16),
                                           title: item.title.map(\.text).joined(), tail: tail, status: status,
                                           attention: item.attention, started: started, focused: target == snapshot.client))
                    windows(item.children, depth: depth + 1)
                }
                let height = rows[begin...].reduce(0) { $0 + $1.height }
                var y = 0.0
                for i in begin..<rows.count {
                    rows[i].segments.insert(.init(kind: .window(active: session.id == snapshot.client.session && window == snapshot.client.window),
                                                  indent: depth, top: -y, height: height,
                                                  topLeft: depth == 0 ? 0 : 6, bottomLeft: depth == 0 ? 0 : 6), at: 0)
                    y += rows[i].height
                }
            }
        }
        if !folded.contains(session.id) { windows(session.nodes, depth: 0) }
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
