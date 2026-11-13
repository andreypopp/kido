import KoModel

public struct PaneProjection: Equatable, Sendable {
    public struct Placement: Equatable, Sendable {
        public let position: Snapshot.Position
        let parent: PaneID?
    }
    public struct Entry: Equatable, Sendable {
        let session: SessionID
        public let item: Item
    }
    public private(set) var placements: [PaneID: Placement] = [:]
    public private(set) var items: [PaneID: Entry] = [:]

    public init(_ snapshot: Snapshot?) {
        func visit(_ node: Node, session: SessionID, parent: PaneID?) {
            switch node {
            case .window(let window):
                window.children.forEach { visit(.item($0), session: session, parent: parent) }
            case .item(let item):
                let position = Snapshot.Position(session: session, window: item.window, pane: item.id)
                placements[item.id] = Placement(position: position, parent: parent)
                items[item.id] = Entry(session: session, item: item)
                item.children.forEach { visit($0, session: session, parent: item.id) }
            }
        }
        snapshot?.sessions.forEach { session in
            session.nodes.forEach { visit($0, session: session.id, parent: nil) }
        }
    }
}
