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
        return items.map { (session: $0.0, pane: $0.1.pane, agent: $0.1.isAgent) }
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
    public var current: Bool
    public var nodes: [Node]
    public init(id: SessionID, name: String, current: Bool, nodes: [Node]) {
        self.id = id
        self.name = name
        self.current = current
        self.nodes = nodes
    }
}

public indirect enum Node: Equatable, Sendable {
    case window(Window)
    case item(Item)

    public struct Window: Equatable, Sendable {
        public var id: WindowID
        public var window: WindowID { id }
        public var name: String
        public var children: [Item]
        public init(id: WindowID, name: String, children: [Item]) {
            self.id = id
            self.name = name
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
    public var id: PaneID
    public var pane: PaneID { id }
    public var window: WindowID
    public var title: String
    public var started: Int
    public var parent: PaneID?
    public var lifecycle: Lifecycle
    public var program_status: ProgramStatus
    public var children: [Node]
    // The core's mark: an outcome that no attended view showed yet, or the work of the pane.
    public var mark: KoSchema.Mark
    // The core saw the program records as they are: their done and error read as idle.
    public var recordsSeen: Bool
    // The pi agent has an inbox, so a prompt reaches it.
    public var inbox: Bool
    // Where the pane works, when not on the host.
    public var runtime: RuntimeMark?
    public init(id: PaneID, window: WindowID, title: String, started: Int, parent: PaneID?, lifecycle: Lifecycle, program_status: ProgramStatus,
                children: [Node], mark: KoSchema.Mark, recordsSeen: Bool = false, inbox: Bool = false, runtime: RuntimeMark? = nil) {
        self.started = started
        self.parent = parent
        self.id = id
        self.window = window
        self.title = title
        self.lifecycle = lifecycle
        self.program_status = program_status
        self.children = children
        self.mark = mark
        self.recordsSeen = recordsSeen
        self.inbox = inbox
        self.runtime = runtime
    }
}

public enum Lifecycle: Equatable, Sendable {
    case live(PaneKind)
    case ended(KoSchema.Cause)
    case lingering(KoSchema.Cause)
}
public enum PaneKind: Equatable, Sendable {
    public struct Destination: Equatable, Sendable, CustomStringConvertible {
        public let user: String
        public let host: String
        public var description: String { user.isEmpty ? host : user + "@" + host }
        public init(user: String, host: String) {
            self.user = user
            self.host = host
        }
        init(_ text: String) {
            let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            self.init(user: parts.count == 2 ? String(parts[0]) : "", host: String(parts.last ?? ""))
        }
    }
    public enum Remote: Equatable, Sendable {
        case terminal(interactive: Bool, ShellStatus)
        case agent(name: String, Report)
    }
    public enum Local: Equatable, Sendable {
        case terminal(ShellStatus)
        case someAgent(name: String, Report)
        case piAgent(session: String, Report)
    }
    case host(Local)
    case runtime(Local)
    case ssh(Destination, Remote)

    public var local: Local? {
        switch self {
        case .host(let pane), .runtime(let pane): pane
        case .ssh: nil
        }
    }
}

public struct Outcome: Equatable, Sendable {
    public let serial: Int
    public let result: KoSchema.OutcomeResult
    public init(serial: Int, result: KoSchema.OutcomeResult) {
        self.serial = serial
        self.result = result
    }
}

public struct Report: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running(progress: Int?)
        case waiting(KoSchema.ProgramKind?, progress: Int?)
        case idle(Outcome?)
    }
    public let since: Date
    public let msg: String?
    public let state: State
    public init(since: Date, msg: String?, state: State) {
        self.since = since
        self.msg = msg
        self.state = state
    }
}

public struct ShellStatus: Equatable, Sendable {
    public struct Command: Equatable, Sendable {
        public let command: String
        public let startedAt: Date
        public init(command: String, startedAt: Date) {
            self.command = command
            self.startedAt = startedAt
        }
    }
    public struct Exit: Equatable, Sendable {
        public let code: Int
        public let command: String
        public let startedAt: Date
        public let endedAt: Date
        public init(code: Int, command: String, startedAt: Date, endedAt: Date) {
            self.code = code
            self.command = command
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }
    public enum Phase: Equatable, Sendable {
        case unknown
        case idle(last: Exit?)
        case pending(last: Exit?)
        case running(Command?, fullscreen: Bool)
    }
    public let phase: Phase
    public let report: Report?
    public init(phase: Phase, report: Report?) {
        self.phase = phase
        self.report = report
    }
}
