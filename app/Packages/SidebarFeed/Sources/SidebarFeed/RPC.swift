import Foundation
import TmuxControl

public struct RPCVersion: Decodable, Equatable, Sendable, CustomStringConvertible {
    public static let required = RPCVersion(major: 6, minor: 0)
    public let major: Int
    public let minor: Int
    private init(major: Int, minor: Int) { self.major = major; self.minor = minor }
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }
    public var compatible: Bool { self == Self.required }
    public var description: String { "\(major).\(minor)" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let text = try c.decode(String.self)
        guard let version = Self(text) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid protocol version: \(text)") }
        self = version
    }
}

public struct ServerStamp: Decodable, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ value: String) { description = value }
    public init(from decoder: Decoder) throws { description = try decoder.singleValueContainer().decode(String.self) }
}

public struct PromptCandidate: Decodable, Equatable, Sendable {
    public let pane: PaneID
    public let session: SessionID
    public let window: WindowID
    public let title: String
    public init(pane: PaneID, session: SessionID, window: WindowID, title: String) {
        self.pane = pane
        self.session = session
        self.window = window
        self.title = title
    }
}

extension PromptCandidate {
    public static func preferred(in window: WindowID, among candidates: [PromptCandidate]) -> PromptCandidate? {
        candidates.first { $0.window == window } ?? candidates.first
    }
}

public enum PromptErrorKind: String, Decodable, Sendable {
    case refused, unknown, invalid
}

public enum PromptVia: String, Decodable, Sendable {
    case inbox, paste
}


public struct PromptDelivered: Decodable, Equatable, Sendable {
    public let pane: PaneID
    public let via: PromptVia
    public init(pane: PaneID, via: PromptVia) {
        self.pane = pane
        self.via = via
    }
}

public enum PromptReply: Decodable, Sendable {
    case candidates([PromptCandidate])
    case delivered(PromptDelivered)
    private enum CodingKeys: String, CodingKey { case candidates, delivered }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .candidates, in: c, debugDescription: "invalid prompt reply")
        }
        if c.contains(.candidates) { self = .candidates(try c.decode([PromptCandidate].self, forKey: .candidates)) }
        else { self = .delivered(try c.decode(PromptDelivered.self, forKey: .delivered)) }
    }
}

public enum RPCEvent: Decodable, Sendable {
    public enum Hello: Decodable, Sendable {
        case accepted(RPCVersion)
        case rejected(binary: RPCVersion, server: ServerStamp?, expected: ServerStamp)
        private enum CodingKeys: String, CodingKey { case `protocol`, server, expected }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(RPCVersion.self, forKey: .protocol)
            self = c.contains(.server)
                ? .rejected(binary: version, server: try c.decodeIfPresent(ServerStamp.self, forKey: .server), expected: try c.decode(ServerStamp.self, forKey: .expected))
                : .accepted(version)
        }
    }
    public struct Reply: Decodable, Sendable {
        public struct Target: Decodable, Sendable {
            public let session: SessionID
            public let window: WindowID
        }
        public let id: Int
        public enum Value: Sendable {
            case switched(Target?), jumped(Snapshot.Position), created(Snapshot.Position), selected(Snapshot.Position), released, reordered, prompt(PromptReply)
            case error(String), promptError(String, PromptErrorKind)
        }
        public let value: Value
        private enum CodingKeys: String, CodingKey { case id, switched, jumped, created, selected, released, reordered, prompt, error, kind }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            let payloads = c.allKeys.filter { [.switched, .jumped, .created, .selected, .released, .reordered, .prompt, .error].contains($0) }
            guard payloads.count == 1, !c.contains(.kind) || c.contains(.error) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "invalid RPC reply")
            }
            if c.contains(.error) {
                let message = try c.decode(String.self, forKey: .error)
                if let kind = try c.decodeIfPresent(PromptErrorKind.self, forKey: .kind) { value = .promptError(message, kind) }
                else { value = .error(message) }
            }
            else if c.contains(.prompt) { value = .prompt(try c.decode(PromptReply.self, forKey: .prompt)) }
            else if c.contains(.switched) { value = .switched(try c.decodeIfPresent(Target.self, forKey: .switched)) }
            else if c.contains(.jumped) { value = .jumped(try c.decode(Snapshot.Position.self, forKey: .jumped)) }
            else if c.contains(.created) { value = .created(try c.decode(Snapshot.Position.self, forKey: .created)) }
            else if c.contains(.selected) { value = .selected(try c.decode(Snapshot.Position.self, forKey: .selected)) }
            else {
                let key: CodingKeys = c.contains(.reordered) ? .reordered : .released
                guard try c.decode(Bool.self, forKey: key) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "\(key.stringValue) must be true")
                }
                value = key == .reordered ? .reordered : .released
            }
        }
    }
    case hello(Hello), reply(Reply), snapshot(Snapshot), error(String)
    private enum CodingKeys: String, CodingKey { case hello, reply, error, v }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.hello) { self = .hello(try c.decode(Hello.self, forKey: .hello)) }
        else if c.contains(.reply) { self = .reply(try c.decode(Reply.self, forKey: .reply)) }
        else if c.contains(.v) { self = .snapshot(try Snapshot(from: decoder)) }
        else { self = .error(try c.decode(String.self, forKey: .error)) }
    }
}
