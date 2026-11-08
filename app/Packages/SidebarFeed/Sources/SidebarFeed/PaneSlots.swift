import KoModel

public struct PaneProjection: Equatable, Sendable {
    public struct Placement: Equatable, Sendable {
        public let position: Snapshot.Position
        public let slot: Snapshot.Position
        let parent: PaneID?
    }
    public struct Entry: Equatable, Sendable {
        let session: SessionID
        public let item: Item
    }
    public private(set) var placements: [PaneID: Placement] = [:]
    public private(set) var items: [PaneID: Entry] = [:]
    public private(set) var rootWindows: [WindowID: WindowID] = [:]
    private(set) var children: [PaneID: [PaneID]] = [:]

    public init(_ snapshot: Snapshot?) {
        func visit(_ node: Node, session: SessionID, slot: Snapshot.Position?, parent: PaneID?) {
            switch node {
            case .window(let window):
                window.children.forEach { visit(.item($0), session: session, slot: slot, parent: parent) }
            case .item(let item):
                let position = Snapshot.Position(session: session, window: item.window, pane: item.id)
                let root = slot ?? position
                placements[item.id] = Placement(position: position, slot: root, parent: parent)
                items[item.id] = Entry(session: session, item: item)
                rootWindows[item.window] = root.window
                if let parent { children[parent, default: []].append(item.id) }
                item.children.forEach { visit($0, session: session, slot: root, parent: item.id) }
            }
        }
        snapshot?.sessions.forEach { session in
            session.nodes.forEach { visit($0, session: session.id, slot: nil, parent: nil) }
        }
    }
}

public enum PaneDirection: Equatable, Sendable { case parent, child }

public struct PaneSlots: Equatable, Sendable {
    private struct Choice: Equatable, Sendable {
        var shown: PaneID
        var lastChild: [PaneID: PaneID] = [:]
    }
    private var choices: [PaneID: Choice] = [:]
    private var focused: [WindowID: PaneID] = [:]
    private var repairs: Set<PaneID> = []
    public init() {}

    public func shown(_ root: PaneID) -> PaneID { choices[root]?.shown ?? root }
    public func selected(in window: WindowID, fallback root: PaneID) -> PaneID { shown(focused[window] ?? root) }
    public mutating func cancelRepair() { repairs = [] }

    @discardableResult public mutating func reconcile(_ projection: PaneProjection, selected: PaneID? = nil) -> [Snapshot.Position] {
        focused = focused.filter { projection.placements[$0.value]?.slot.window == $0.key && projection.placements[$0.value]?.slot.pane == $0.value }
        repairs = repairs.filter { projection.placements[$0]?.slot.pane == $0 }
        var select: [Snapshot.Position] = []
        for root in Array(choices.keys) {
            guard let placement = projection.placements[root], placement.slot.pane == root else { choices.removeValue(forKey: root); continue }
            guard var choice = choices[root] else { continue }
            let placementOfShown = projection.placements[choice.shown]
            if placementOfShown?.slot.pane != root {
                let active = placementOfShown == nil && (choice.shown == selected || selected.flatMap { projection.placements[$0]?.slot.pane } == root)
                choice.shown = root
                if active { repairs.insert(root); select.append(placement.position) }
            }
            choice.lastChild = choice.lastChild.filter { projection.placements[$0.value]?.parent == $0.key }
            choices[root] = choice
        }
        return select
    }

    public mutating func observe(_ pane: PaneID, in projection: PaneProjection) {
        guard let root = projection.placements[pane]?.slot.pane else { return }
        if repairs.contains(root) {
            if pane == root { repairs.remove(root) }
            return
        }
        remember(pane, in: projection)
    }

    public mutating func show(_ pane: PaneID, in projection: PaneProjection) {
        cancelRepair()
        remember(pane, in: projection)
    }

    private mutating func remember(_ pane: PaneID, in projection: PaneProjection) {
        guard let placement = projection.placements[pane] else { return }
        let root = placement.slot.pane
        focused[placement.slot.window] = root
        var choice = choices[root] ?? Choice(shown: root)
        choice.shown = pane
        var child = pane
        while let parent = projection.placements[child]?.parent {
            choice.lastChild[parent] = child
            child = parent
        }
        choices[root] = choice
    }

    public func step(from pane: PaneID, direction: PaneDirection, in projection: PaneProjection) -> PaneID? {
        guard let placement = projection.placements[pane] else { return nil }
        switch direction {
        case .child:
            let children = projection.children[pane] ?? []
            let remembered = choices[placement.slot.pane]?.lastChild[pane]
            return remembered.flatMap { children.contains($0) ? $0 : nil } ?? children.first
        case .parent: return placement.parent
        }
    }
}
