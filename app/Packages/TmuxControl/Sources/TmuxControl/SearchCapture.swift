import Foundation

public struct SearchCapture: Sendable {
    public let history: Int
    public let alternate: Bool
    public let distances: [Int]
    public let next: Int?

    public static func commands(_ pane: PaneID, end: Int? = nil, chunk: Int = 5000) -> [Command] {
        let bottom = end.map(String.init) ?? "-"
        let top = String((end ?? 0) - chunk)
        return [
            Command("display-message", "-p", "-t", pane, "#{history_size} #{alternate_on}"),
            Command("capture-pane", "-p", "-J", "-S", top, "-E", bottom, "-t", pane),
            Command("capture-pane", "-p", "-F", "-L", "-T", "-S", top, "-E", bottom, "-t", pane),
        ]
    }

    public init?(_ replies: [Reply], query: String) {
        let lines = replies.compactMap { if case .success(let lines) = $0 { lines } else { nil } }
        guard lines.count == 3, let state = lines[0].first else { return nil }
        let numbers = state.split(separator: " ").compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        history = numbers[0]
        alternate = numbers[1] != 0
        var groups: [(start: Int, end: Int)] = [], start: Int?
        for line in lines[2] {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2, let row = Int(fields[0]) else { return nil }
            if start == nil { start = row }
            if !fields[1].contains("W") { groups.append((start!, row)); start = nil }
        }
        if let start, let row = lines[2].last?.split(separator: " ").first.flatMap({ Int($0) }) {
            groups.append((start, row))
        }
        guard groups.count == lines[1].count, let first = groups.first else { return nil }
        let skip = first.start > -history && first.start < 0
        next = alternate || first.start <= -history ? nil : (skip ? first.end : first.start - 1)
        let needle = query.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
        guard !needle.isEmpty else { distances = []; return }
        var found: [Int] = []
        for index in groups.indices.reversed() where !skip || index > 0 {
            let bytes = lines[1][index].utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
            var count = 0, offset = 0
            while offset + needle.count <= bytes.count {
                if bytes[offset..<(offset + needle.count)].elementsEqual(needle) {
                    count += 1
                }
                offset += 1
            }
            found.append(contentsOf: repeatElement(-groups[index].start, count: count))
        }
        distances = found
    }
}
