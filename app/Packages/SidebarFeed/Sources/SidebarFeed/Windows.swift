import TmuxControl

public struct WindowProjection: Equatable, Sendable {
    public var ancestors: [WindowID: WindowID] = [:]
    public var children: [WindowID: [WindowID]] = [:]
    public var statuses: [WindowID: SidebarRow.Status] = [:]
    public var titles: [WindowID: String] = [:]
    public init() {}
}

public func sidebarWindowTarget(_ projection: WindowProjection, selected: WindowID?, windows: [WindowID], next: Bool) -> WindowID? {
    guard !windows.isEmpty else { return nil }
    if let selected, let (parent, siblings) = projection.children.first(where: { $0.value.contains(selected) }),
       let index = siblings.firstIndex(of: selected) {
        let adjacent = index + (next ? 1 : -1)
        if siblings.indices.contains(adjacent) { return siblings[adjacent] }
        if !next { return parent }
    }
    let active = selected.flatMap { projection.ancestors[$0] ?? $0 }
    let current = windows.firstIndex { $0 == active } ?? 0
    return windows[(current + (next ? 1 : windows.count - 1)) % windows.count]
}

public func sidebarWindows(_ snapshot: Snapshot?, session: SessionID?, surviving: Set<WindowID>, activePanes: [WindowID: PaneID] = [:]) -> WindowProjection {
    var result = WindowProjection()
    func collect(_ node: Node, ancestor: WindowID?, parent: WindowID?) {
        let window: WindowID = switch node { case .window(let group): group.window; case .item(let item): item.window }
        if case .item(let item) = node, activePanes[window] == item.pane {
            result.titles[window] = item.label
        }
        if let parent, parent != window, surviving.contains(parent), surviving.contains(window) {
            if !result.children[parent, default: []].contains(window) {
                result.children[parent, default: []].append(window)
            }
        }
        let root = ancestor ?? (surviving.contains(window) ? window : nil)
        if let root {
            result.ancestors[window] = root
            let status: SidebarRow.Status = if case .item(let item) = node { item.status.tabStatus } else { .quiet }
            let previous = result.statuses[root] ?? .quiet
            result.statuses[root] = previous == .error || status == .error ? .error
                : previous == .attention || status == .attention ? .attention : .quiet
        }
        node.children.forEach { collect($0, ancestor: root, parent: window) }
    }
    snapshot?.sessions.first { $0.id == session }?.nodes.forEach { collect($0, ancestor: nil, parent: nil) }
    return result
}
