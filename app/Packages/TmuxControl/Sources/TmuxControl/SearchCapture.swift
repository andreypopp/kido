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
            Command("capture-pane", "-p", "-F", "-L", "-T", "-N", "-S", top, "-E", bottom, "-t", pane),
        ]
    }

    public init?(_ replies: [Reply], query: String) {
        guard let capture = Capture(replies), !capture.lines.isEmpty else { return nil }
        history = capture.state.history
        alternate = capture.state.alternate
        next = capture.next
        let needle = query.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
        guard !needle.isEmpty else { distances = []; return }
        var found: [Int] = []
        for line in capture.completeLines.reversed() {
            let bytes = line.text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
            var count = 0, offset = 0
            while offset + needle.count <= bytes.count {
                if bytes[offset..<(offset + needle.count)].elementsEqual(needle) {
                    count += 1
                }
                offset += 1
            }
            found.append(contentsOf: repeatElement(-line.start, count: count))
        }
        distances = found
    }
}
