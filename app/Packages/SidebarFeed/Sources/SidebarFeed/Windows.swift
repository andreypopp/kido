import TmuxControl

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
            let status = item.indicator(SidebarSeen()).status
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
    public var ancestors: [WindowID: WindowID] = [:]
    public var order: [WindowID] = []
    public init() {}
}

public func sidebarWindows(_ snapshot: Snapshot?, session: SessionID?, surviving: Set<WindowID>) -> WindowProjection {
    var result = WindowProjection()
    func collect(_ node: Node, ancestor: WindowID?) {
        let window = node.window
        let root = ancestor ?? (surviving.contains(window) ? window : nil)
        if ancestor == nil, root != nil { result.order.append(window) }
        if let root { result.ancestors[window] = root }
        node.children.forEach { collect($0, ancestor: root) }
    }
    snapshot?.sessions.first { $0.id == session }?.nodes.forEach { collect($0, ancestor: nil) }
    return result
}
