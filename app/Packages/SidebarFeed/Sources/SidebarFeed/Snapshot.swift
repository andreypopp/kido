import TmuxControl

public struct Snapshot: Decodable, Equatable, Sendable {
    public struct Position: Decodable, Equatable, Sendable {
        public let session: SessionID
        public let window: WindowID
        public let pane: PaneID
    }

    public let v: Int
    public let client: Position
    public let filter: String
    public let error: String?
    public let sessions: [SessionRows]
}

public struct SessionRows: Decodable, Equatable, Sendable {
    public let id: SessionID
    public let name: String
    public let current: Bool
    public let rows: [Row]
}

public struct Row: Decodable, Equatable, Sendable {
    public let pane: PaneID?
    public let window: WindowID?
    public let tree: String
    public let indicator: Indicator?
    public let title: [Span]
    public let tail: [Span]
    public let attention: Bool
}

public struct Indicator: Decodable, Equatable, Sendable {
    public enum Kind: String, Decodable, Equatable, Sendable {
        case running, waiting, compacting, idle, done, failed, unknown, stalled, gone
    }

    public enum Outcome: String, Decodable, Equatable, Sendable {
        case completed, failed, died, stopped
    }

    public let kind: Kind
    public let outcome: Outcome?
}

public struct Span: Decodable, Equatable, Sendable {
    public enum Role: String, Decodable, Equatable, Sendable {
        case plain, current, proc, dim, err, running, waiting, compacting, done, stalled
    }

    public let text: String
    public let role: Role
}
