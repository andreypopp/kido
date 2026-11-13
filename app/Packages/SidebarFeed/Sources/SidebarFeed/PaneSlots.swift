import KoModel

public struct PaneProjection: Equatable, Sendable {
    public struct Placement: Equatable, Sendable {
        public let position: Snapshot.Position
        public let slot: Snapshot.Position
        let parent: PaneID?
        public let presentation: Presentation
    }
    // A child in another window replaces its parent in the parent's slot. A child in its parent's own window
    // floats over it or is tiled beside it; a tiled one is a slot of its own.
    public enum Presentation: Equatable, Sendable {
        case replacement
        case floating(owner: Snapshot.Position)
        case tiled
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
        func visit(_ node: Node, session: SessionID, slot: Snapshot.Position?, parent: Snapshot.Position?) {
            switch node {
            case .window(let window):
                window.children.forEach { visit(.item($0), session: session, slot: slot, parent: parent) }
            case .item(let item):
                let position = Snapshot.Position(session: session, window: item.window, pane: item.id)
                let presentation: Presentation = switch parent {
                case let owner? where owner.window == item.window: item.layer == .floating ? .floating(owner: owner) : .tiled
                default: .replacement
                }
                let root = presentation == .tiled ? position : slot ?? position
                placements[item.id] = Placement(position: position, slot: root, parent: parent?.pane, presentation: presentation)
                items[item.id] = Entry(session: session, item: item)
                rootWindows[item.window] = root.window
                if let parent { children[parent.pane, default: []].append(item.id) }
                item.children.forEach { visit($0, session: session, slot: root, parent: position) }
            }
        }
        snapshot?.sessions.forEach { session in
            session.nodes.forEach { visit($0, session: session.id, slot: nil, parent: nil) }
        }
    }
    // The pane that a layout command on `pane` addresses: a replacement addresses its slot, any other pane itself.
    public func addressed(_ pane: PaneID) -> PaneID {
        guard let placement = placements[pane], case .replacement = placement.presentation else { return pane }
        return placement.slot.pane
    }
    // A float of a child window cannot dock: the server keeps a pane whose parent is in another window alone.
    public func canDock(_ pane: PaneID) -> Bool {
        guard case .floating(let owner)? = placements[pane]?.presentation, let host = placements[owner.pane] else { return true }
        if case .replacement = host.presentation { return host.parent == nil }
        return true
    }
    func path(to pane: PaneID) -> [Snapshot.Position] {
        var result: [Snapshot.Position] = []
        var current: PaneID? = pane
        while let id = current, let placement = placements[id] {
            result.append(placement.position)
            current = placement.parent
        }
        return result.reversed()
    }

    public func shown(_ root: PaneID, slots: PaneSlots) -> ShownPane? {
        guard let placement = placements[slots.shown(root)], placement.slot.pane == root,
              let item = items[placement.position.pane]?.item else { return nil }
        let ancestors = path(to: placement.position.pane).drop { $0.pane != root }.dropLast().compactMap { position in
            items[position.pane].map { ShownPane.Entry(position: position, title: $0.item.rowTitle) }
        }
        return ShownPane(shown: .init(position: placement.position, title: item.rowTitle), ancestors: ancestors)
    }
}

public struct ShownPane: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let position: Snapshot.Position
        public let title: String
        public init(position: Snapshot.Position, title: String) { self.position = position; self.title = title }
    }
    public let shown: Entry
    public let ancestors: [Entry]
}

public enum PaneDirection: Equatable, Sendable { case parent, child }

public struct PaneSlots: Equatable, Sendable {
    private struct Choice: Equatable, Sendable {
        var shown: PaneID
        var lastChild: [PaneID: PaneID] = [:]
    }
    private var choices: [PaneID: Choice] = [:]
    private enum Focus: Equatable, Sendable {
        case slot(PaneID)
        case float(PaneID)
    }
    private var focused: [WindowID: Focus] = [:]
    private var repairs: Set<PaneID> = []
    public init() {}

    public func shown(_ root: PaneID) -> PaneID { choices[root]?.shown ?? root }
    public func selected(in window: WindowID, fallback root: PaneID) -> PaneID {
        switch focused[window] {
        case .float(let pane): pane
        case .slot(let slot): shown(slot)
        case nil: shown(root)
        }
    }
    public mutating func cancelRepair() { repairs = [] }

    @discardableResult public mutating func reconcile(_ projection: PaneProjection, selected: PaneID? = nil) -> [Snapshot.Position] {
        focused = focused.filter { window, focus in
            switch focus {
            case .slot(let slot): projection.placements[slot]?.slot.window == window && projection.placements[slot]?.slot.pane == slot
            case .float(let pane):
                if case .floating = projection.placements[pane]?.presentation { projection.placements[pane]?.slot.window == window } else { false }
            }
        }
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
        if case .floating(let owner) = placement.presentation {
            remember(owner.pane, in: projection)
            focused[placement.slot.window] = .float(pane)
            return
        }
        focused[placement.slot.window] = .slot(root)
        var choice = choices[root] ?? Choice(shown: root)
        choice.shown = pane
        var child = pane
        while child != root, let parent = projection.placements[child]?.parent {
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
