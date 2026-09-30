import TmuxControl

public struct Snapshot: Decodable, Equatable, Sendable {
    public struct Position: Decodable, Equatable, Sendable {
        public let session: SessionID
        public let window: WindowID
        public let pane: PaneID
    }

    public let client: Position
    public let filter: String
    public let error: String?
    public let sessions: [SessionRows]

    private enum CodingKeys: String, CodingKey { case v, client, filter, error, sessions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == 1 else { throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "not a v1 snapshot: v \(v)") }
        client = try c.decode(Position.self, forKey: .client)
        filter = try c.decode(String.self, forKey: .filter)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        sessions = try c.decode([SessionRows].self, forKey: .sessions)
    }
}

public struct SessionRows: Decodable, Equatable, Sendable {
    public let id: SessionID
    public let name: String
    public let current: Bool
    public let rows: [Row]
}

public struct Row: Decodable, Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public let window: WindowID
        public let pane: PaneID
    }

    public let target: Target?
    public let tree: String
    public let indicator: Indicator?
    public let title: [Span]
    public let tail: [Span]
    public let attention: Bool

    private enum CodingKeys: String, CodingKey { case pane, window, tree, indicator, title, tail, attention }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch (try c.decodeIfPresent(WindowID.self, forKey: .window), try c.decodeIfPresent(PaneID.self, forKey: .pane)) {
        case (let window?, let pane?): target = Target(window: window, pane: pane)
        case (nil, nil): target = nil
        default: throw DecodingError.dataCorruptedError(forKey: .pane, in: c, debugDescription: "a row with only one of pane and window")
        }
        tree = try c.decode(String.self, forKey: .tree)
        indicator = try c.decodeIfPresent(Indicator.self, forKey: .indicator)
        title = try c.decode([Span].self, forKey: .title)
        tail = try c.decode([Span].self, forKey: .tail)
        attention = try c.decode(Bool.self, forKey: .attention)
    }
}

public enum Indicator: Decodable, Equatable, Sendable {
    public enum Outcome: String, Decodable, Equatable, Sendable {
        case completed, failed, died, stopped
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
            case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(kind)")
            }
    }
}

public struct Span: Decodable, Equatable, Sendable {
    public enum Role: String, Decodable, Equatable, Sendable {
        case plain, current, proc, dim, err, running, waiting, compacting, done, stalled
    }

    public let text: String
    public let role: Role
}
