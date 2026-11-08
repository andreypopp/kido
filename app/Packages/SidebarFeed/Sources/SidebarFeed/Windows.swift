import KoModel

public enum CloseTarget: Equatable, Sendable {
    case pane(PaneID), window(WindowID), session(SessionID)
}

public struct CloseScope: Equatable, Sendable {
    public let panes: Int
    public let running: Int
    public var ask: Bool { running > 0 }
}

public func closeScope(_ projection: PaneProjection, target: CloseTarget) -> CloseScope {
    let items = projection.items
    var children: [PaneID: [PaneID]] = [:]
    var pending: [PaneID] = []
    for (id, entry) in items {
        if let parent = entry.item.pane.parent { children[parent, default: []].append(id) }
        let matches = switch target {
        case .pane(let pane): id == pane
        case .window(let window): entry.item.window == window
        case .session(let session): entry.session == session
        }
        if matches { pending.append(id) }
    }
    var seen: Set<PaneID> = []
    var running = 0
    while let id = pending.popLast() {
        guard seen.insert(id).inserted, let entry = items[id] else { continue }
        if case .live = entry.item.lifecycle, !entry.item.closesQuietly { running += 1 }
        pending.append(contentsOf: children[id] ?? [])
    }
    return CloseScope(panes: seen.count, running: running)
}

public struct WindowProjection: Equatable, Sendable {
    public struct Label: Equatable, Sendable {
        public let title: String
        public let agent: Bool
        public let messageable: Bool
    }
    public var statuses: [WindowID: SidebarRow.Status] = [:]
    public var labels: [WindowID: Label] = [:]
    public var order: [WindowID] = []
    public init() {}
}

public func sidebarWindows(_ snapshot: Snapshot?, projection: PaneProjection, session: SessionID?, surviving: Set<WindowID>, activePanes: [WindowID: PaneID] = [:]) -> WindowProjection {
    var result = WindowProjection()
    result.order = snapshot?.sessions.first { $0.id == session }?.nodes.map(\.window).filter { surviving.contains($0) } ?? []
    for (id, entry) in projection.items where entry.session == session {
        let item = entry.item
        if activePanes[item.window] == id {
            result.labels[item.window] = .init(title: item.label, agent: item.isAgent, messageable: item.isMessageable)
        }
        guard let root = projection.rootWindows[item.window], surviving.contains(root) else { continue }
        result.statuses[root] = (result.statuses[root] ?? .quiet).mergingTabStatus(item.indicator.status)
    }
    return result
}
