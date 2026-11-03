public protocol IDKind: Sendable {
    static var prefix: String { get }
}

public struct ID<Kind: IDKind>: Hashable, Sendable, CustomStringConvertible, Codable {
    public let number: UInt32

    public init(number: UInt32) {
        self.number = number
    }

    public init?(ko text: String) {
        guard text.hasPrefix(Kind.prefix), let number = UInt32(text.dropFirst(Kind.prefix.count)) else { return nil }
        self.number = number
    }

    public var description: String { "\(Kind.prefix)\(number)" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = ID(ko: text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a \(Kind.prefix)N id: \(text)") }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum PaneKind: IDKind {
    public static let prefix = "pane_"
}
public enum WindowKind: IDKind {
    public static let prefix = "window_"
}
public enum SessionKind: IDKind {
    public static let prefix = "session_"
}

public typealias PaneID = ID<PaneKind>
public typealias WindowID = ID<WindowKind>
public typealias SessionID = ID<SessionKind>
