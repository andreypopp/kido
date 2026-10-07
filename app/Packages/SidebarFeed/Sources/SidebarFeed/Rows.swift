import Foundation
import TmuxControl

public struct SidebarRow: Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case header(SessionID), pane(SessionID, PaneID), divider(SessionID, String), gap(SessionID), spacing(SessionID, String)
        public var session: SessionID {
            switch self { case .header(let s), .pane(let s, _), .divider(let s, _), .gap(let s), .spacing(let s, _): s }
        }
    }
    public enum Status: Equatable, Sendable {
        case quiet, running, attention, error, done, stalled
        public var tabStatus: Self { self == .error || self == .attention ? self : .quiet }
    }
    public enum Kind: Equatable, Sendable {
        case header, pane(Snapshot.Position), divider, gap
    }
    public enum Position: Equatable, Sendable { case single, top, middle, bottom }
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
    public var position: Position = .single
    public var icon: Icon = .terminal
    public var active = false
    public var target: Snapshot.Position? {
        if case .pane(let target) = kind { return target }; return nil
    }
}

extension Item {
    var label: String { title.map(\.text).joined() }

    var status: SidebarRow.Status {
        switch indicator {
        case .failed, .gone(.failed), .gone(.died): .error
        case .waiting: kind == .agent || run == .agent ? .attention : .quiet
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

public func sidebarRows(_ snapshot: Snapshot?) -> [SidebarRow] {
    guard let snapshot else { return [] }
    var rows: [SidebarRow] = []
    for session in snapshot.sessions {
        rows.append(SidebarRow(id: .header(session.id), kind: .header, indent: 0, height: 29,
                               title: session.name, tail: "", status: .quiet, attention: false, started: nil, focused: false))
        func windows(_ nodes: [Node], depth: Int) {
            for (index, node) in nodes.enumerated() {
                if depth > 0 || index > 0 {
                    rows.append(SidebarRow(id: .divider(session.id, node.id), kind: .divider, indent: depth, height: 7,
                                           title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
                }
                let panes: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
                for (index, item) in panes.enumerated() {
                    let description: String = switch item.indicator {
                    case .gone(let outcome): "gone" + (outcome.map { ", " + $0.rawValue } ?? "")
                    case .some(let indicator): String(describing: indicator)
                    case nil: ""
                    }
                    let target = Snapshot.Position(session: session.id, window: item.window, pane: item.pane)
                    let tail = item.tail.map(\.text).joined()
                    let agent = item.kind == .agent || item.run == .agent
                    let label = item.label
                    rows.append(SidebarRow(id: .pane(session.id, item.id), kind: .pane(target), indent: depth,
                                           height: tail.isEmpty ? 32 : 48,
                                           title: agent && !label.hasPrefix("@") ? "@" + label : label,
                                           tail: tail, status: item.status, indicatorDescription: description,
                                           attention: item.attention, started: item.run == nil ? nil : item.started,
                                           focused: target == snapshot.client,
                                           position: panes.count == 1 ? .single : index == 0 ? .top : index == panes.count - 1 ? .bottom : .middle,
                                           icon: agent ? .agent : .terminal,
                                           active: session.id == snapshot.client.session && item.window == snapshot.client.window))
                }
                rows.append(SidebarRow(id: .spacing(session.id, "window:" + node.id), kind: .gap, indent: depth, height: 3,
                                       title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
                for item in panes where !item.children.isEmpty {
                    windows(item.children, depth: depth + 1)
                    rows.append(SidebarRow(id: .spacing(session.id, "children:" + item.id.description), kind: .gap, indent: depth + 1, height: 3,
                                           title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
                }
            }
        }
        windows(session.nodes, depth: 0)
        rows.append(SidebarRow(id: .gap(session.id), kind: .gap, indent: 0, height: 16,
                               title: "", tail: "", status: .quiet, attention: false, started: nil, focused: false))
    }
    return rows
}

public func sidebarElapsed(started: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(started)))
    return s < 60 ? "\(s)s" : s < 3600 ? String(format: "%dm%02ds", s / 60, s % 60)
        : String(format: "%dh%02dm", s / 3600, (s / 60) % 60)
}
