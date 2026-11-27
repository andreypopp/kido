import Foundation
import KoModel

public struct Snapshot: Equatable, Sendable {
    public struct Position: Codable, Equatable, Sendable {
        public let session: SessionID
        public let window: WindowID
        public let pane: PaneID

        public init(session: SessionID, window: WindowID, pane: PaneID) {
            self.session = session
            self.window = window
            self.pane = pane
        }
    }

    public struct Clock: Equatable, Sendable {
        public let now: Int
        public let local: Int
        public init(now: Int, local: Int) { self.now = now; self.local = local }
    }

    public var clock: Clock
    public var client: Position
    public var serverInstance: ServerInstance
    public var sessions: [SessionNodes]
    public init(clock: Clock, client: Position, serverInstance: ServerInstance, sessions: [SessionNodes]) {
        self.clock = clock
        self.client = client
        self.serverInstance = serverInstance
        self.sessions = sessions
    }

    public var tiledSessions: [SessionNodes] {
        sessions.map { session in
            var nodes: [Node] = []
            for node in session.nodes {
                let items: [Item] = switch node { case .window(let group): group.children; case .item(let item): [item] }
                for item in items where item.placement == .tiled { nodes.appendGrouped(item) }
            }
            return SessionNodes(id: session.id, name: session.name, nodes: nodes)
        }
    }

    public var promptPanes: [(session: SessionID, pane: PaneID, agent: Bool)] {
        sessions.flatMap { session in
            session.nodes.flatMap(\.items).map { (session: session.id, pane: $0.id, agent: $0.isAgent) }
        }
    }
}

public struct ServerInstance: Codable, Hashable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) {
        self.description = description
    }
    public init(from decoder: Decoder) throws {
        description = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct SessionNodes: Equatable, Sendable {
    public var id: SessionID
    public var name: String
    public var nodes: [Node]
    public init(id: SessionID, name: String, nodes: [Node]) {
        self.id = id
        self.name = name
        self.nodes = nodes
    }
}

public enum Node: Equatable, Sendable {
    case window(Window)
    case item(Item)

    public struct Window: Equatable, Sendable {
        public var id: WindowID
        public var window: WindowID { id }
        public var children: [Item]
        public init(id: WindowID, children: [Item]) {
            self.id = id
            self.children = children
        }
    }
    public var id: String {
        switch self { case .window(let w): w.id.description; case .item(let i): i.id.description }
    }
    public var items: [Item] {
        switch self { case .window(let w): w.children; case .item(let i): [i] }
    }
}

extension Array where Element == Node {
    mutating func appendGrouped(_ item: Item) {
        switch last {
        case .item(let previous) where previous.window == item.window:
            self[count - 1] = .window(.init(id: item.window, children: [previous, item]))
        case .window(var group) where group.id == item.window:
            group.children.append(item)
            self[count - 1] = .window(group)
        default: append(.item(item))
        }
    }
}

public struct Item: Equatable, Sendable {
    public enum Placement: Equatable, Sendable { case tiled, floating }
    public var placement: Placement
    public var pane: KoSchema.PaneJson
    public var id: PaneID { pane.id }
    public var window: WindowID
    public var runtime: RuntimeMark?

    public init(pane: KoSchema.PaneJson, window: WindowID, runtime: RuntimeMark? = nil, placement: Placement = .tiled) {
        self.placement = placement
        self.pane = pane
        self.window = window
        self.runtime = runtime
    }

    public var lifecycle: Lifecycle {
        if let dead = pane.dead {
            return pane.close == .onExit ? .lingering(dead.cause) : .ended(dead.cause)
        }
        return .live(pane.status?.kind ?? .host(.init(pane: .terminal(.init(phase: .unknown, report: nil)))))
    }
}

public enum Lifecycle: Equatable, Sendable {
    case live(KoSchema.Live)
    case ended(KoSchema.Cause)
    case lingering(KoSchema.Cause)
}
