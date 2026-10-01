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
        guard let capture = Capture(replies, styled: true) else { return nil }
        history = capture.state.history
        alternate = capture.state.alternate
        var selected: [String] = [], skipped: [String] = []
        var count = 0, wraps = false
        for (index, group) in capture.lines.enumerated() {
            let wholeTop = index > 0 || group.start == -history
            let wholeBottom = initial || (!group.wrapped && group.end < -loaded)
            if history > 0 && wholeTop && wholeBottom {
                selected.append(group.text)
                count += group.end - group.start + 1
                wraps = group.wrapped
            } else if selected.isEmpty { skipped.append(group.text) }
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
