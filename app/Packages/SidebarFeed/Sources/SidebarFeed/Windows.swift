import KoModel

public enum CloseTarget: Equatable, Sendable {
    case pane(PaneID), window(WindowID), session(SessionID)
}

public func closeScope(_ snapshot: Snapshot?, target: CloseTarget) -> (running: Bool, descendants: [WindowID]) {
    var roots: [Node] = []
    func find(_ node: Node) {
        let matches: Bool = switch (target, node) {
        case (.pane(let id), .item(let item)): id == item.pane
        case (.window(let id), .item(let item)): id == item.window
        case (.window(let id), .window(let window)): id == window.window
        default: false
        }
        if matches { roots.append(node) } else { node.children.forEach(find) }
    }
    snapshot?.sessions.forEach {
        if case .session(let id) = target, $0.id == id { roots += $0.nodes }
        else { $0.nodes.forEach(find) }
    }
    var running = false, descendants: [WindowID] = []
    func collect(_ node: Node, rootWindow: WindowID) {
        if case .item(let item) = node {
            let status = item.indicator.status
            running = running || status == .running || status == .waiting
                || item.program_status.records.contains { $0.state == .working || $0.state == .blocked }
        }
        node.children.forEach { collect($0, rootWindow: rootWindow) }
        if node.window != rootWindow, !descendants.contains(node.window) { descendants.append(node.window) }
    }
    for root in roots { collect(root, rootWindow: root.window) }
    if case .session = target { descendants = [] }
    return (running, descendants)
}

public struct WindowProjection: Equatable, Sendable {
    public struct Label: Equatable, Sendable {
        public let title: String
        public let agent: Bool
        public let messageable: Bool
    }
    public var ancestors: [WindowID: WindowID] = [:]
    public var statuses: [WindowID: SidebarRow.Status] = [:]
    public var labels: [WindowID: Label] = [:]
    public var order: [WindowID] = []
    public var children: [WindowID: [WindowID]] = [:]
    public init() {}
}

public func sidebarWindows(_ snapshot: Snapshot?, session: SessionID?, surviving: Set<WindowID>, activePanes: [WindowID: PaneID] = [:]) -> WindowProjection {
    var result = WindowProjection()
    func collect(_ node: Node, ancestor: WindowID?, enclosing: WindowID?) {
        let window = node.window
        if case .item(let item) = node, activePanes[window] == item.pane {
            result.labels[window] = .init(title: item.label, agent: item.isAgent, messageable: item.isMessageable)
        }
        let root = ancestor ?? (surviving.contains(window) ? window : nil)
        if ancestor == nil, root != nil, !result.order.contains(window) { result.order.append(window) }
        if ancestor != nil, let enclosing, enclosing != window, !result.children.values.contains(where: { $0.contains(window) }) {
            result.children[enclosing, default: []].append(window)
        }
        if let root {
            result.ancestors[window] = root
            let previous = result.statuses[root] ?? .quiet
            if previous != .error {
                let status: SidebarRow.Status = if case .item(let item) = node { item.indicator.status } else { .quiet }
                result.statuses[root] = previous.mergingTabStatus(status)
            }
        }
        node.children.forEach { collect($0, ancestor: root, enclosing: window) }
    }
    snapshot?.sessions.first { $0.id == session }?.nodes.forEach { collect($0, ancestor: nil, enclosing: nil) }
    return result
}

extension KoSchema.Layout {
    public var survivingWindows: [SessionID: Set<WindowID>] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, Set($0.windows.map(\.id))) })
    }
}

public func adjacentWindow(_ snapshot: Snapshot?, surviving: [SessionID: Set<WindowID>], from current: WindowID, next: Bool) -> WindowID? {
    let projections = (snapshot?.sessions ?? []).map { sidebarWindows(snapshot, session: $0.id, surviving: surviving[$0.id] ?? []) }
    let step = next ? 1 : -1
    guard let top = projections.lazy.compactMap({ $0.ancestors[current] }).first else { return nil }
    let children = projections.reduce(into: [WindowID: [WindowID]]()) { $0.merge($1.children) { first, _ in first } }
    if let (parent, siblings) = children.first(where: { $0.value.contains(current) }), let at = siblings.firstIndex(of: current) {
        if siblings.indices.contains(at + step) { return siblings[at + step] }
        if !next { return parent }
    }
    let roots = projections.flatMap(\.order)
    guard let at = roots.firstIndex(of: top) else { return nil }
    let target = roots[(at + step + roots.count) % roots.count]
    return target == current ? nil : target
}
