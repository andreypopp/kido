import Foundation
import TmuxControl

public struct Snapshot: Decodable, Equatable, Sendable {
    public struct Position: Decodable, Equatable, Sendable {
        public let session: SessionID
        public let window: WindowID
        public let pane: PaneID

        public init(session: SessionID, window: WindowID, pane: PaneID) {
            self.session = session
            self.window = window
            self.pane = pane
        }
    }

    public let client: Position
    public let asks: [Ask]
    public let error: String?
    public var sessions: [SessionNodes]

    public func sameSidebarContent(as other: Snapshot) -> Bool {
        func item(_ a: Item, _ b: Item) -> Bool {
            a.id == b.id && a.window == b.window && a.kind == b.kind && a.run == b.run
            && a.indicator == b.indicator && a.title == b.title && a.tail == b.tail
            && a.started == b.started && a.attention == b.attention && nodes(a.children, b.children)
        }
        func nodes(_ a: [Node], _ b: [Node]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { left, right in
                switch (left, right) {
                case (.window(let a), .window(let b)):
                    a.id == b.id && a.children.count == b.children.count
                    && zip(a.children, b.children).allSatisfy { item($0, $1) }
                case (.item(let a), .item(let b)):
                    item(a, b)
                default: false
                }
            }
        }
        return client == other.client && sessions.count == other.sessions.count
            && zip(sessions, other.sessions).allSatisfy { a, b in
                a.id == b.id && a.name == b.name && a.current == b.current && nodes(a.nodes, b.nodes)
            }
    }

    private enum CodingKeys: String, CodingKey { case v, client, asks, error, sessions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == 2 else { throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "not a v2 snapshot: v \(v)") }
        client = try c.decode(Position.self, forKey: .client)
        asks = try c.decode([Ask].self, forKey: .asks)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        sessions = try c.decode([SessionNodes].self, forKey: .sessions)
    }
}

public struct SessionNodes: Decodable, Equatable, Sendable {
    public let id: SessionID
    public let name: String
    public let current: Bool
    public let nodes: [Node]
    private enum CodingKeys: String, CodingKey { case id, name, current, nodes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SessionID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        current = try c.decode(Bool.self, forKey: .current)
        nodes = try c.decode([Node].self, forKey: .nodes)
        var ids: Set<String> = []
        func unique(_ nodes: [Node]) -> Bool {
            nodes.allSatisfy { ids.insert($0.id).inserted && unique($0.children) }
        }
        guard unique(nodes) else { throw DecodingError.dataCorruptedError(forKey: .nodes, in: c, debugDescription: "duplicate node id in session") }
    }
}

public indirect enum Node: Decodable, Equatable, Sendable {
    case window(Window)
    case item(Item)

    public struct Window: Decodable, Equatable, Sendable {
        public let id: WindowID
        public var window: WindowID { id }
        public let name: String
        public let children: [Item]
        private enum CodingKeys: String, CodingKey { case id, window, name, children }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(WindowID.self, forKey: .id)
            let window = try c.decode(WindowID.self, forKey: .window)
            name = try c.decode(String.self, forKey: .name)
            children = try c.decode([Item].self, forKey: .children)
            guard id == window, children.count > 1, children.allSatisfy({ $0.window == window }) else {
                throw DecodingError.dataCorruptedError(forKey: .children, in: c, debugDescription: "invalid window group")
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .kind) == "window" { self = .window(try Window(from: decoder)) }
        else { self = .item(try Item(from: decoder)) }
    }
    public var id: String {
        switch self { case .window(let w): w.id.description; case .item(let i): i.id.description }
    }
    public var children: [Node] {
        switch self { case .window(let w): w.children.map(Node.item); case .item(let i): i.children }
    }
}

public struct Item: Decodable, Equatable, Sendable {
    public enum Kind: String, UnknownString, Sendable { case agent, run, ssh, shell, unknown }
    public enum Run: String, UnknownString, Sendable { case agent, bash, stream, unknown }
    public let run: Run?
    public let kind: Kind
    public let id: PaneID
    public var pane: PaneID { id }
    public let window: WindowID
    public let indicator: Indicator?
    public let program_status: ProgramStatus
    public let title: [Span]
    public let tail: [Span]
    public let started: Date?
    public let attention: Bool
    public let children: [Node]
    private enum CodingKeys: String, CodingKey { case kind, id, pane, window, indicator, program_status, title, tail, run, started, attention, children }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        run = try c.decodeIfPresent(Run.self, forKey: .run)
        id = try c.decode(PaneID.self, forKey: .id)
        let pane = try c.decode(PaneID.self, forKey: .pane)
        guard id == pane else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "id must equal pane") }
        window = try c.decode(WindowID.self, forKey: .window)
        indicator = try c.decodeIfPresent(Indicator.self, forKey: .indicator)
        program_status = try c.decode(ProgramStatus.self, forKey: .program_status)
        title = try c.decode([Span].self, forKey: .title)
        tail = try c.decode([Span].self, forKey: .tail)
        started = try c.decodeIfPresent(Double.self, forKey: .started).map { Date(timeIntervalSince1970: $0) }
        attention = try c.decode(Bool.self, forKey: .attention)
        children = try c.decode([Node].self, forKey: .children)
    }
}

public enum Indicator: Decodable, Equatable, Sendable {
    public enum Outcome: String, UnknownString, Equatable, Sendable {
        case completed, failed, died, stopped, unknown
    }

    case running, waiting, compacting, idle, done, failed, unknown, stalled
    case gone(Outcome?)

    private enum CodingKeys: String, CodingKey { case kind, outcome }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self =
            switch try c.decode(String.self, forKey: .kind) {
            case "running": .running
            case "waiting": .waiting
            case "compacting": .compacting
            case "idle": .idle
            case "done": .done
            case "failed": .failed
            case "unknown": .unknown
            case "stalled": .stalled
            case "gone": .gone(try c.decodeIfPresent(Outcome.self, forKey: .outcome))
            default: .unknown
            }
    }
}

public struct Span: Decodable, Equatable, Sendable {
    public enum Role: String, UnknownString, Equatable, Sendable {
        case plain, current, proc, dim, err, running, waiting, compacting, done, stalled, unknown
    }

    public let text: String
    public let role: Role
}
