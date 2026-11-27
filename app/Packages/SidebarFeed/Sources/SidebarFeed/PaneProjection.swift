import KoModel

public struct PaneProjection: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        let session: SessionID
        public let item: Item
    }
    public private(set) var placements: [PaneID: Snapshot.Position] = [:]
    public private(set) var items: [PaneID: Entry] = [:]

    public init(_ snapshot: Snapshot?) {
        for session in snapshot?.sessions ?? [] {
            for item in session.nodes.flatMap(\.items) {
                placements[item.id] = Snapshot.Position(session: session.id, window: item.window, pane: item.id)
                items[item.id] = Entry(session: session.id, item: item)
            }
        }
    }
}
