import TmuxControl

public enum CloseTarget: Equatable, Sendable {
    case pane(PaneID), window(WindowID)
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
    snapshot?.sessions.forEach { $0.nodes.forEach(find) }
    var running = false, descendants: [WindowID] = []
    func collect(_ node: Node, rootWindow: WindowID) {
        if case .item(let item) = node {
            let status = item.indicator(SidebarSeen()).status
            running = running || status == .running || status == .waiting
                || item.program_status.records.contains { $0.state == .working || $0.state == .blocked }
        }
        node.children.forEach { collect($0, rootWindow: rootWindow) }
        let window: WindowID = switch node { case .item(let item): item.window; case .window(let group): group.window }
        if window != rootWindow, !descendants.contains(window) { descendants.append(window) }
    }
    for root in roots {
        let window: WindowID = switch root { case .item(let item): item.window; case .window(let group): group.window }
        collect(root, rootWindow: window)
    }
    return (running, descendants)
}

public struct WindowProjection: Equatable, Sendable {
    public struct Label: Equatable, Sendable {
        public let title: String
        public let agent: Bool
    }
    public var ancestors: [WindowID: WindowID] = [:]
    public var statuses: [WindowID: SidebarRow.Status] = [:]
    public var labels: [WindowID: Label] = [:]
    public init() {}
}

public func sidebarWindows(_ snapshot: Snapshot?, session: SessionID?, surviving: Set<WindowID>, activePanes: [WindowID: PaneID] = [:], seen: SidebarSeen = SidebarSeen()) -> WindowProjection {
    var result = WindowProjection()
    func collect(_ node: Node, ancestor: WindowID?) {
        let window: WindowID = switch node { case .window(let group): group.window; case .item(let item): item.window }
        if case .item(let item) = node, activePanes[window] == item.pane {
            result.labels[window] = .init(title: item.label, agent: item.isAgent)
        }
        let root = ancestor ?? (surviving.contains(window) ? window : nil)
        if let root {
            result.ancestors[window] = root
            let previous = result.statuses[root] ?? .quiet
            if previous != .error {
                let status: SidebarRow.Status = if case .item(let item) = node { item.indicator(seen).status.tabStatus } else { .quiet }
                result.statuses[root] = status == .error ? .error : previous == .waiting || status == .waiting ? .waiting : .quiet
            }
        }
        node.children.forEach { collect($0, ancestor: root) }
    }
    snapshot?.sessions.first { $0.id == session }?.nodes.forEach { collect($0, ancestor: nil) }
    return result
}
