import TmuxControl

public struct WindowProjection: Equatable, Sendable {
    public var ancestors: [WindowID: WindowID] = [:]
    public var statuses: [WindowID: SidebarRow.Status] = [:]
    public var titles: [WindowID: String] = [:]
    public init() {}
}

public func sidebarWindows(_ snapshot: Snapshot?, session: SessionID?, surviving: Set<WindowID>, activePanes: [WindowID: PaneID] = [:], seen: SidebarSeen = SidebarSeen()) -> WindowProjection {
    var result = WindowProjection()
    func collect(_ node: Node, ancestor: WindowID?) {
        let window: WindowID = switch node { case .window(let group): group.window; case .item(let item): item.window }
        if case .item(let item) = node, activePanes[window] == item.pane {
            result.titles[window] = item.label
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
