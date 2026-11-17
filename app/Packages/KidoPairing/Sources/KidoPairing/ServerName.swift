import Foundation

public struct ServerName: Hashable, Sendable, Codable {
    private let name: String
    public var value: String { name }

    public init(_ value: String) throws {
        guard value.utf8.allSatisfy({ $0 < 128 }) else { throw PairingFailure(message: "Expected a DNS server name") }
        let value = value.lowercased()
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 253,
              !(labels.count == 4 && labels.allSatisfy { label in
                  !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber } && UInt8(label).map { String($0) == label } == true
              }),
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw PairingFailure(message: "Expected a DNS server name") }
        self.name = value
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

