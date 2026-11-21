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
            var preorder: [(Item, PaneID?)] = []
            func visit(_ nodes: [Node], parent: PaneID?) {
                for node in nodes {
                    switch node {
                    case .window(let group): group.children.forEach { visit([.item($0)], parent: parent) }
                    case .item(let item):
                        preorder.append((item, parent))
                        visit(item.children, parent: item.id)
                    }
                }
            }
            visit(session.nodes, parent: nil)
            let tiled: Set<PaneID> = Set(preorder.compactMap { item, _ in
                switch item.placement { case .tiled: item.id; case .floating: nil }
            })
            var children: [PaneID?: [Item]] = [:]
            for (item, parent) in preorder {
                switch item.placement {
                case .tiled: children[parent.flatMap { tiled.contains($0) ? $0 : nil }, default: []].append(item)
                case .floating: break
                }
            }
            func build(_ parent: PaneID?) -> [Node] {
                var result: [Node] = []
                for var item in children[parent] ?? [] {
                    item.children = build(item.id)
                    result.appendGrouped(item)
                }
                return result
            }
            return SessionNodes(id: session.id, name: session.name, nodes: build(nil))
        }
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
    public var children: [Node]
    public var runtime: RuntimeMark?

    public init(pane: KoSchema.PaneJson, window: WindowID, children: [Node], runtime: RuntimeMark? = nil, placement: Placement = .tiled) {
        self.placement = placement
        self.pane = pane
        self.window = window
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
