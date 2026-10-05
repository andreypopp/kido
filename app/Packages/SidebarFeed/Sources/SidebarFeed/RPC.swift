import Foundation
import TmuxControl

public struct RPCVersion: Decodable, Equatable, Sendable, CustomStringConvertible {
    public static let required = RPCVersion(major: 1, minor: 0)
    public let major: Int
    public let minor: Int
    private init(major: Int, minor: Int) { self.major = major; self.minor = minor }
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }
    public var compatible: Bool { major == Self.required.major && minor >= Self.required.minor }
    public var description: String { "\(major).\(minor)" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let text = try c.decode(String.self)
        guard let version = Self(text) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid protocol version: \(text)") }
        self = version
    }
}

public enum RPCEvent: Decodable, Sendable {
    public enum Hello: Decodable, Sendable {
        case accepted(RPCVersion)
        case rejected(binary: RPCVersion, server: RPCVersion?)
        private enum CodingKeys: String, CodingKey { case `protocol`, server }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let version = try c.decode(RPCVersion.self, forKey: .protocol)
            self = c.contains(.server)
                ? .rejected(binary: version, server: try c.decodeIfPresent(String.self, forKey: .server).flatMap(RPCVersion.init))
                : .accepted(version)
        }
    }
    public struct Reply: Decodable, Sendable {
        public struct Target: Decodable, Sendable {
            public let session: SessionID
            public let window: WindowID
        }
        public let id: Int
        public let switched: Target?
        public let error: String?
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
