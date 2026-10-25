import Foundation

public struct RecentHosts: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let host: String
        public let date: Date
    }
    public private(set) var entries: [Entry] = []
    public init() {}
    public mutating func add(_ host: String, at date: Date) {
        entries.removeAll { $0.host == host }
        entries.append(Entry(host: host, date: date))
        entries.sort { $0.date > $1.date }
    }
    public mutating func clear() { entries = [] }
    public var isEmpty: Bool { entries.isEmpty }
}
