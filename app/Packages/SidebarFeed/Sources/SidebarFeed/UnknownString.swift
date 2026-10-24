import Foundation

public protocol UnknownString: RawRepresentable, Decodable where RawValue == String {
    static var unknown: Self { get }
}

extension UnknownString {
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}
