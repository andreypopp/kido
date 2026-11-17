import Foundation

struct RecentHosts: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let host: Host
        let date: Date
    }
    private(set) var entries: [Entry] = []
    mutating func add(_ host: Host, at date: Date) {
        guard host != .local else { return }
        remove(host)
        entries.append(Entry(host: host, date: date))
        entries.sort { $0.date > $1.date }
    }
    mutating func remove(_ host: Host) { entries.removeAll { $0.host == host } }
    mutating func clear() { entries = [] }
    var isEmpty: Bool { entries.isEmpty }
}
