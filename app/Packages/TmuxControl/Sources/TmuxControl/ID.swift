public protocol IDKind: Sendable {
    static var sigil: Character { get }
}

public struct ID<Kind: IDKind>: Hashable, Sendable, CustomStringConvertible {
    public let number: UInt32

    public init(number: UInt32) {
        self.number = number
    }

    public init?<S: StringProtocol>(_ text: S) {
        guard text.first == Kind.sigil, let number = UInt32(text.dropFirst()) else { return nil }
        self.number = number
    }

    public var description: String { "\(Kind.sigil)\(number)" }
}

public enum PaneKind: IDKind { public static let sigil: Character = "%" }
public enum WindowKind: IDKind { public static let sigil: Character = "@" }
public enum SessionKind: IDKind { public static let sigil: Character = "$" }

public typealias PaneID = ID<PaneKind>
public typealias WindowID = ID<WindowKind>
public typealias SessionID = ID<SessionKind>
