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
    public let serverInstance: ServerInstance
    public let error: String?
    public var sessions: [SessionNodes]

    public func sameSidebarContent(as other: Snapshot) -> Bool {
        client == other.client && serverInstance == other.serverInstance && sessions == other.sessions
    }

    private enum CodingKeys: String, CodingKey { case v, client, server_instance, error, sessions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == 2 else { throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "not a v2 snapshot: v \(v)") }
        client = try c.decode(Position.self, forKey: .client)
        serverInstance = try c.decode(ServerInstance.self, forKey: .server_instance)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        sessions = try c.decode([SessionNodes].self, forKey: .sessions)
    }
}

public struct ServerInstance: Decodable, Hashable, Sendable {
    public let startedAt: Int
    public let pid: Int
    private enum CodingKeys: String, CodingKey { case started_at, pid }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Int.self, forKey: .started_at)
        pid = try c.decode(Int.self, forKey: .pid)
        guard startedAt > 0, pid > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .pid, in: c, debugDescription: "server instance must be positive")
        }
    }
}

public struct SessionNodes: Decodable, Equatable, Sendable {
    public let id: SessionID
    public let name: String
    public let current: Bool
    public var nodes: [Node]
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
        switch try c.decode(String.self, forKey: .kind) {
        case "window": self = .window(try Window(from: decoder))
        case "pane": self = .item(try Item(from: decoder))
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown node kind \(kind)")
        }
    }
    public var id: String {
        switch self { case .window(let w): w.id.description; case .item(let i): i.id.description }
    }
    public var children: [Node] {
        switch self { case .window(let w): w.children.map(Node.item); case .item(let i): i.children }
    }
}

public struct Item: Decodable, Equatable, Sendable {
    public let id: PaneID
    public var pane: PaneID { id }
    public let window: WindowID
    public let title: String
    public let lifecycle: Lifecycle
    public let program_status: ProgramStatus
    public let run: String?
    public let started: Date?
    public let children: [Node]
    private enum CodingKeys: String, CodingKey { case id, pane, window, title, lifecycle, program_status, run, started, children }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PaneID.self, forKey: .id)
        let pane = try c.decode(PaneID.self, forKey: .pane)
        guard id == pane else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "id must equal pane") }
        window = try c.decode(WindowID.self, forKey: .window)
        title = try c.decode(String.self, forKey: .title)
        lifecycle = try c.decode(Lifecycle.self, forKey: .lifecycle)
        program_status = try c.decode(ProgramStatus.self, forKey: .program_status)
        run = try c.decode(String?.self, forKey: .run)
        started = try c.decode(Double?.self, forKey: .started).map(Date.init(timeIntervalSince1970:))
        children = try c.decode([Node].self, forKey: .children)
        let live = if case .live = lifecycle { true } else { false }
        guard live || run != nil else { throw DecodingError.dataCorruptedError(forKey: .run, in: c, debugDescription: "an ended pane needs run metadata") }
        guard started == nil || live && run != nil else {
            throw DecodingError.dataCorruptedError(forKey: .started, in: c, debugDescription: "started belongs to a live run")
        }
    }
}

public enum Lifecycle: Decodable, Equatable, Sendable {
    public enum Result: String, UnknownString, Sendable { case unknown, completed, failed, died, stopped }
    case live(PaneKind)
    case ended(Result)
    public init(from decoder: Decoder) throws {
        var v = try Variant(decoder)
        switch v.tag {
        case "Live": self = .live(try v.payload())
        case "Ended": self = .ended(try v.fields { try $0.decode(Result.self, forKey: "result") })
        default: throw v.unknown()
        }
    }
}

public enum PaneKind: Decodable, Equatable, Sendable {
    public struct Destination: Equatable, Sendable, CustomStringConvertible {
        public let user: String
        public let host: String
        public var description: String { user + "@" + host }
    }
    public enum Remote: Equatable, Sendable {
        case terminal(interactive: Bool, ShellStatus)
        case agent(name: String, Report)
    }
    case terminal(ShellStatus)
    case someAgent(name: String, Report)
    case piAgent(session: String, Report)
    case ssh(Destination, Remote)
    public init(from decoder: Decoder) throws {
        var v = try Variant(decoder)
        switch v.tag {
        case "Terminal": self = .terminal(try v.payload())
        case "Some_agent": self = try v.fields { .someAgent(name: try $0.decode(String.self, forKey: "name"), try $0.decode(Report.self, forKey: "status")) }
        case "Pi_agent": self = try v.fields { .piAgent(session: try $0.decode(String.self, forKey: "session"), try $0.decode(Report.self, forKey: "status")) }
        case "Ssh":
            self = try v.fields { c in
                let destination = Destination(user: try c.decode(String.self, forKey: "user"), host: try c.decode(String.self, forKey: "host"))
                var remote = try Variant(c.superDecoder(forKey: "pane"))
                return switch remote.tag {
                case "Remote_terminal": .ssh(destination, try remote.fields { .terminal(interactive: try $0.decode(Bool.self, forKey: "interactive"), try $0.decode(ShellStatus.self, forKey: "status")) })
                case "Remote_agent": .ssh(destination, try remote.fields { .agent(name: try $0.decode(String.self, forKey: "name"), try $0.decode(Report.self, forKey: "status")) })
                default: throw remote.unknown()
                }
            }
        default: throw v.unknown()
        }
    }
}

public struct Outcome: Decodable, Equatable, Sendable {
    public enum Result: String, Decodable, Sendable { case success, failure }
    public let serial: Int
    public let result: Result
}

public struct Report: Decodable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running(progress: Int?)
        case waiting(ProgramStatus.Record.Kind?, progress: Int?)
        case idle(Outcome?)
    }
    public let since: Date
    public let msg: String?
    public let state: State
    private enum CodingKeys: String, CodingKey { case since, msg, state }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .since))
        msg = try c.decode(String?.self, forKey: .msg)
        var v = try Variant(c.superDecoder(forKey: .state))
        switch v.tag {
        case "Running": state = try v.fields { .running(progress: try $0.progress()) }
        case "Waiting": state = try v.fields { .waiting(try $0.decode(ProgramStatus.Record.Kind?.self, forKey: "kind"), progress: try $0.progress()) }
        case "Idle": state = try v.fields { .idle(try $0.decode(Outcome?.self, forKey: "outcome")) }
        default: throw v.unknown()
        }
    }
}

public struct ShellStatus: Decodable, Equatable, Sendable {
    public struct Command: Equatable, Sendable {
        public let command: String
        public let startedAt: Date
    }
    public struct Exit: Equatable, Sendable {
        public let code: Int
        public let command: String
        public let startedAt: Date
        public let endedAt: Date
    }
    public enum Phase: Equatable, Sendable {
        case unknown
        case idle(last: Exit?)
        case running(Command?, fullscreen: Bool)
    }
    public let phase: Phase
    public let report: Report?
    private enum CodingKeys: String, CodingKey { case phase, report }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        report = try c.decode(Report?.self, forKey: .report)
        var v = try Variant(c.superDecoder(forKey: .phase))
        func time(_ c: KeyedDecodingContainer<Field>, _ key: Field) throws -> Date { Date(timeIntervalSince1970: try c.decode(Double.self, forKey: key)) }
        switch v.tag {
        case "Unknown": try v.end(); phase = .unknown
        case "Idle":
            phase = try v.fields { c in
                guard try !c.decodeNil(forKey: "last") else { return .idle(last: nil) }
                let e = try c.nestedContainer(keyedBy: Field.self, forKey: "last")
                return .idle(last: Exit(code: try e.decode(Int.self, forKey: "code"), command: try e.decode(String.self, forKey: "command"),
                                        startedAt: try time(e, "started_at"), endedAt: try time(e, "ended_at")))
            }
        case "Running":
            phase = try v.fields { c in
                var origin = try Variant(c.superDecoder(forKey: "origin"))
                let fullscreen = try c.decode(Bool.self, forKey: "fullscreen")
                switch origin.tag {
                case "Command": return .running(try origin.fields { Command(command: try $0.decode(String.self, forKey: "command"), startedAt: try time($0, "started_at")) }, fullscreen: fullscreen)
                case "Unknown":
                    try origin.end()
                    guard fullscreen else { throw DecodingError.dataCorruptedError(forKey: "origin", in: c, debugDescription: "an unknown origin is only fullscreen") }
                    return .running(nil, fullscreen: true)
                default: throw origin.unknown()
                }
            }
        default: throw v.unknown()
        }
    }
}

struct Field: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }
}

extension KeyedDecodingContainer where K == Field {
    func progress() throws -> Int? {
        let key: Field = "progress"
        let progress = try decode(Int?.self, forKey: key)
        guard progress.map({ (0...100).contains($0) }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "progress is a percentage")
        }
        return progress
    }
}

private struct Variant {
    let tag: String
    private var c: UnkeyedDecodingContainer

    init(_ decoder: Decoder) throws {
        c = try decoder.unkeyedContainer()
        tag = try c.decode(String.self)
    }

    mutating func end() throws {
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "\(tag) has an unexpected argument") }
    }

    mutating func payload<T: Decodable>() throws -> T {
        let value = try c.decode(T.self)
        try end()
        return value
    }

    mutating func fields<T>(_ body: (KeyedDecodingContainer<Field>) throws -> T) throws -> T {
        let value = try body(c.nestedContainer(keyedBy: Field.self))
        try end()
        return value
    }

    func unknown() -> DecodingError { .dataCorruptedError(in: c, debugDescription: "unknown variant \(tag)") }
}
