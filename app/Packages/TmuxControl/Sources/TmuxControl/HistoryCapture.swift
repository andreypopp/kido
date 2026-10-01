import Foundation

public struct HistoryCapture: Sendable {
    public let history: Int
    public let alternate: Bool
    public let rows: Int
    public let text: String
    public let wrapsIntoScreen: Bool

    public static func commands(_ pane: PaneID, loaded: Int, chunk: Int = 5000) -> [Command] {
        let start = "-\(loaded + chunk + 1)", end = "-\(loaded + 1)"
        return [
            Command("display-message", "-p", "-t", pane, "#{history_size} #{alternate_on}"),
            Command("capture-pane", "-p", "-e", "-J", "-S", start, "-E", end, "-t", pane),
            Command("capture-pane", "-p", "-F", "-L", "-T", "-S", start, "-E", end, "-t", pane),
        ]
    }

    public init?(_ replies: some Collection<Reply>, loaded: Int, initial: Bool = false) {
        let lines = replies.compactMap { if case .success(let lines) = $0 { lines } else { nil } }
        guard lines.count == 3, let state = lines[0].first else { return nil }
        let numbers = state.split(separator: " ").compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        history = numbers[0]
        alternate = numbers[1] != 0
        var groups: [(start: Int, end: Int, wrapped: Bool)] = []
        var start: Int?
        for line in lines[2] {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2, let row = Int(fields[0]) else { return nil }
            if start == nil { start = row }
            let wrapped = fields[1].contains("W")
            if !wrapped { groups.append((start!, row, false)); start = nil }
        }
        if let start, let last = lines[2].last?.split(separator: " ").first.flatMap({ Int($0) }) {
            groups.append((start, last, true))
        }
        guard groups.count == lines[1].count else { return nil }
        var selected: [String] = [], skipped: [String] = []
        var count = 0, wraps = false
        for (index, group) in groups.enumerated() {
            let wholeTop = index > 0 || group.start == -history
            let wholeBottom = initial || (!group.wrapped && group.end < -loaded)
            if history > 0 && wholeTop && wholeBottom {
                selected.append(lines[1][index])
                count += group.end - group.start + 1
                wraps = group.wrapped
            } else if selected.isEmpty { skipped.append(lines[1][index]) }
        }
        rows = count
        wrapsIntoScreen = wraps
        let sgr = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;:]*m")
        let prefix = skipped.joined()
        let styles = sgr.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
            .compactMap { Range($0.range, in: prefix).map { String(prefix[$0]) } }.joined()
        text = "\u{1B}[m" + styles + selected.joined(separator: "\r\n")
    }
}
