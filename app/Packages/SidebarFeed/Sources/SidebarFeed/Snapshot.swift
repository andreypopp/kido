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

    public var promptPanes: [(session: SessionID, pane: PaneID, agent: Bool)] {
        var items: [(SessionID, Item)] = []
        func walk(_ nodes: [Node], session: SessionID) {
            for node in nodes {
                if case .item(let item) = node { items.append((session, item)) }
                walk(node.children, session: session)
            }
        }
        for session in sessions { walk(session.nodes, session: session.id) }
        return items.map { (session: $0.0, pane: $0.1.id, agent: $0.1.isAgent) }
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

public indirect enum Node: Equatable, Sendable {
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
    public var children: [Node] {
        switch self { case .window(let w): w.children.map(Node.item); case .item(let i): i.children }
    }
}

public struct Item: Equatable, Sendable {
    public var pane: KoSchema.PaneJson
    public var id: PaneID { pane.id }
    public var window: WindowID
    let layer: Layer
    public var children: [Node]
    public var runtime: RuntimeMark?

    public enum Layer: Equatable, Sendable { case tiled, floating }

    public init(pane: KoSchema.PaneJson, window: WindowID, layer: Layer, children: [Node], runtime: RuntimeMark? = nil) {
        self.pane = pane
        self.window = window
        self.layer = layer
        self.children = children
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
