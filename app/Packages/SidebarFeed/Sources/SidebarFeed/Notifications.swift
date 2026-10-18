import Foundation
import TmuxControl

public struct NoticeKey: Hashable, Sendable {
    public let owner: String
    public let pane: PaneID
}

public struct NoticeTarget: Codable, Equatable, Sendable {
    public let host: String
    public let instance: ServerInstance
    public let position: Snapshot.Position

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(host, forKey: "host")
        var instanceFields = c.nestedContainer(keyedBy: Field.self, forKey: "instance")
        try instanceFields.encode(instance.startedAt, forKey: "started_at")
        try instanceFields.encode(instance.pid, forKey: "pid")
        var positionFields = c.nestedContainer(keyedBy: Field.self, forKey: "position")
        try positionFields.encode(position.session.description, forKey: "session")
        try positionFields.encode(position.window.description, forKey: "window")
        try positionFields.encode(position.pane.description, forKey: "pane")
    }
}

public struct Notice: Equatable, Sendable {
    public enum Kind: String, Sendable { case waiting, failed }
    public let kind: Kind
    public let key: NoticeKey
    public let target: NoticeTarget
    public let title: String
    public let subtitle: String
    public let body: String
}

public struct NotifierEffects: Equatable, Sendable {
    public var post: [Notice] = []
    public var withdraw: [NoticeKey] = []
}

/// Step each window owner independently. Keep `fresh` true through error snapshots,
/// clearing it only after stepping the first error-free snapshot of a restarted feed.
public struct NotifierState: Equatable, Sendable {
    private enum Reason: Equatable, Sendable {
        case waiting
        case failure(OutcomeSource, OutcomeIdentity)
    }
    private enum Entry: Equatable, Sendable {
        case posted(Reason), acknowledged(Reason)
        var reason: Reason {
            switch self { case .posted(let reason), .acknowledged(let reason): reason }
        }
    }
    private struct WindowState: Equatable, Sendable {
        let host: String
        let instance: ServerInstance
        var entries: [PaneID: Entry] = [:]
    }
    private var owners: [String: WindowState] = [:]

    public init() {}

    public var postedCount: Int {
        owners.values.reduce(0) { count, owner in
            count + owner.entries.values.filter { if case .posted = $0 { return true }; return false }.count
        }
    }

    public mutating func forget(owner: String) -> NotifierEffects {
        var effects = NotifierEffects()
        if let state = owners.removeValue(forKey: owner) {
            for pane in state.entries.keys.sorted(by: { $0.number < $1.number }) {
                if case .posted = state.entries[pane] { effects.withdraw.append(NoticeKey(owner: owner, pane: pane)) }
            }
        }
        return effects
    }

    public mutating func step(owner: String, host: String, identity: String? = nil, snapshot: Snapshot,
                              fresh: Bool, seen: SidebarSeen, shown: Set<WindowID>, appActive: Bool) -> NotifierEffects {
        guard snapshot.error == nil else { return NotifierEffects() }
        let changed = owners[owner]?.instance != snapshot.serverInstance || owners[owner]?.host != host
        var effects = changed ? forget(owner: owner) : NotifierEffects()
        var state = owners[owner] ?? WindowState(host: host, instance: snapshot.serverInstance)
        let baseline = fresh || changed
        var present: Set<PaneID> = []
        // Visit the client's session first so linked panes get its click target and subtitle.
        let sessions = snapshot.sessions.filter { $0.id == snapshot.client.session }
            + snapshot.sessions.filter { $0.id != snapshot.client.session }
        func visit(_ node: Node, session: SessionNodes) {
            defer { node.children.forEach { visit($0, session: session) } }
            guard case .item(let item) = node, present.insert(item.pane).inserted else { return }
            let key = NoticeKey(owner: owner, pane: item.pane)
            let status = item.indicator(seen).status
            let reason: Reason?
            if item.run != nil { reason = nil }
            else if case .live = item.lifecycle {
                if status == .waiting { reason = .waiting }
                else if status == .error, let outcome = item.indicatedOutcome {
                    if outcome.source == .command, case .idle(let exit?) = item.shell?.phase, exit.code == 130 { reason = nil }
                    else { reason = .failure(outcome.source, outcome.identity) }
                } else { reason = nil }
            } else { reason = nil }
            let previous = state.entries[item.pane]
            guard let reason else {
                if case .posted = previous { effects.withdraw.append(key) }
                state.entries[item.pane] = nil
                return
            }
            if baseline || shown.contains(item.window) || (appActive && previous?.reason != reason) {
                if case .posted = previous { effects.withdraw.append(key) }
                state.entries[item.pane] = .acknowledged(reason)
                return
            }
            guard previous?.reason != reason else { return }
            let caption = item.caption
            let body: String
            switch reason {
            case .waiting: body = caption.isEmpty ? "Waiting" : "Waiting: " + caption
            case .failure(.command, _):
                if case .idle(let exit?) = item.shell?.phase {
                    body = "Exit \(exit.code): " + exit.command
                } else { body = "Failed" }
            case .failure: body = caption.isEmpty ? "Failed" : "Failed: " + caption
            }
            var subtitle = session.name
            if host != "local" { subtitle = "\(identity ?? String(host.dropFirst(4))) · \(subtitle)" }
            else if case .live(.ssh(let destination, .agent)) = item.lifecycle { subtitle += " · \(destination)" }
            effects.post.append(Notice(kind: status == .waiting ? .waiting : .failed, key: key, target: NoticeTarget(host: host, instance: snapshot.serverInstance,
                position: Snapshot.Position(session: session.id, window: item.window, pane: item.pane)),
                title: item.rowTitle(status: status).title, subtitle: subtitle, body: body))
            state.entries[item.pane] = .posted(reason)
        }
        for session in sessions { session.nodes.forEach { visit($0, session: session) } }
        for pane in state.entries.keys.sorted(by: { $0.number < $1.number }) where !present.contains(pane) {
            if case .posted = state.entries[pane] { effects.withdraw.append(NoticeKey(owner: owner, pane: pane)) }
            state.entries[pane] = nil
        }
        owners[owner] = state
        return effects
    }
}
