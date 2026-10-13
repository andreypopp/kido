import TmuxControl

public enum ReorderPlacement: String, Sendable { case before, after }

public enum ReorderMove: Equatable, Sendable {
    case session(SessionID, relativeTo: SessionID, ReorderPlacement)
    case window(SessionID, WindowID, relativeTo: WindowID, ReorderPlacement)

    public static func placing<ID: Equatable>(_ source: ID, at slot: Int, in ids: [ID]) -> (anchor: ID, placement: ReorderPlacement)? {
        guard let from = ids.firstIndex(of: source), slot != from, slot != from + 1, slot <= ids.count else { return nil }
        return slot < ids.count ? (ids[slot], .before) : ids.last.map { ($0, .after) }
    }
}

extension Node {
    public var window: WindowID {
        switch self { case .window(let group): group.window; case .item(let item): item.window }
    }
}

extension Snapshot {
    public func reordered(_ move: ReorderMove) -> Snapshot? {
        func moved<T, ID: Equatable>(_ items: [T], _ key: (T) -> ID, _ source: ID, _ anchor: ID, _ placement: ReorderPlacement) -> [T]? {
            guard source != anchor, let from = items.firstIndex(where: { key($0) == source }) else { return nil }
            var items = items
            let item = items.remove(at: from)
            guard let to = items.firstIndex(where: { key($0) == anchor }) else { return nil }
            items.insert(item, at: placement == .after ? to + 1 : to)
            return items
        }
        var result = self
        switch move {
        case .session(let source, let anchor, let placement):
            guard let sessions = moved(sessions, \.id, source, anchor, placement) else { return nil }
            result.sessions = sessions
        case .window(let session, let source, let anchor, let placement):
            guard let index = sessions.firstIndex(where: { $0.id == session }),
                  let nodes = moved(sessions[index].nodes, \.window, source, anchor, placement) else { return nil }
            result.sessions[index].nodes = nodes
        }
        return result
    }
}

public func arranged<T, ID: Hashable>(_ items: [T], by order: [ID], _ key: (T) -> ID) -> [T] {
    let rank = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
    var known = items.filter { rank[key($0)] != nil }.sorted { rank[key($0)]! < rank[key($1)]! }.makeIterator()
    return items.map { rank[key($0)] == nil ? $0 : known.next()! }
}

public struct ReorderState: Equatable, Sendable {
    public struct Pending: Equatable, Sendable {
        public let move: ReorderMove
        public let token: Int
        let instance: ServerInstance
        var replied = false
        var projecting = true
    }
    public private(set) var pending: Pending?
    private var tokens = 0

    public init() {}

    public mutating func submit(_ move: ReorderMove, to snapshot: Snapshot) -> Int? {
        guard pending == nil, let moved = snapshot.reordered(move), moved != snapshot else { return nil }
        tokens += 1
        pending = Pending(move: move, token: tokens, instance: snapshot.serverInstance)
        return tokens
    }

    public func project(_ snapshot: Snapshot) -> Snapshot {
        guard let pending, pending.projecting, pending.instance == snapshot.serverInstance else { return snapshot }
        return snapshot.reordered(pending.move) ?? snapshot
    }

    public mutating func observe(_ snapshot: Snapshot) {
        guard var pending else { return }
        guard pending.instance == snapshot.serverInstance else { return reset() }
        if pending.projecting, snapshot.reordered(pending.move).map({ $0 == snapshot }) ?? true { pending.projecting = false }
        self.pending = pending.projecting || !pending.replied ? pending : nil
    }

    public mutating func complete(_ token: Int, error: String?) -> String? {
        guard var pending, pending.token == token else { return nil }
        if let error { reset(); return error }
        pending.replied = true
        self.pending = pending.projecting ? pending : nil
        return nil
    }

    public mutating func expire(_ token: Int) -> String? {
        guard let pending, pending.token == token else { return nil }
        reset()
        guard pending.projecting else { return nil }
        return pending.replied ? "The server did not apply the new order" : "The server did not answer the reorder request"
    }

    public mutating func reset() { pending = nil }
}
