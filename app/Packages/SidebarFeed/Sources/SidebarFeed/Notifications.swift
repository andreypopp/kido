import Foundation
import KoModel

public struct NoticeKey: Hashable, Sendable {
    public let owner: String
    public let pane: PaneID
}

public struct NoticeTarget: Codable, Equatable, Sendable {
    public let host: String
    public let instance: ServerInstance
    public let position: Snapshot.Position
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

/// Step each window owner independently. A pane's notice follows the core's mark: it is posted when the
/// mark turns to waiting or failed in a window that the user does not look at, and withdrawn when the mark
/// turns back. `fresh` takes the first marks of an owner, or of a restarted server, as they are.
public struct NotifierState: Equatable, Sendable {
    private enum Reason: Equatable, Sendable { case waiting, failed }
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
                              fresh: Bool, shown: Set<WindowID>, appActive: Bool) -> NotifierEffects {
        let changed = owners[owner]?.instance != snapshot.serverInstance || owners[owner]?.host != host
        var effects = changed ? forget(owner: owner) : NotifierEffects()
        var state = owners[owner] ?? WindowState(host: host, instance: snapshot.serverInstance)
        let baseline = fresh || changed
        var present: Set<PaneID> = []
        // Visit the client's session first so linked panes get its click target and subtitle.
        let sessions = snapshot.sessions.filter { $0.id == snapshot.client.session }
            + snapshot.sessions.filter { $0.id != snapshot.client.session }
        func visit(_ node: Node, session: SessionNodes) {
            defer {
                node.children.forEach { visit($0, session: session) }
            }
            guard case .item(let item) = node, present.insert(item.pane).inserted else { return }
            let key = NoticeKey(owner: owner, pane: item.pane)
            let status = item.indicator.status
            let reason: Reason? = switch (item.lifecycle, item.mark) {
            case (.live, .waiting): .waiting
            case (.live, .failed): item.lastCommand?.code == 130 ? nil : .failed
            default: nil
            }
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
            switch (reason, item.lastCommand) {
            case (.waiting, _): body = caption.isEmpty ? "Waiting" : "Waiting: " + caption
            case (.failed, let exit?): body = "Exit \(exit.code): " + exit.command
            case (.failed, nil): body = caption.isEmpty ? "Failed" : "Failed: " + caption
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
