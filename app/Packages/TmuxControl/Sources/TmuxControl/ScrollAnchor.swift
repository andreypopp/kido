import Foundation

public struct ScrollAnchor: Sendable {
    public let lines: Int
    public let text: String?

    public init(lines: Int, text: String? = nil) { self.lines = lines; self.text = text }

    public func locate(_ replies: [Reply]) -> Int? {
        guard let capture = Capture(replies) else { return nil }
        if capture.state.alternate { return 0 }
        let rows = Array(capture.completeLines.reversed().drop(while: {
            $0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }))
        guard lines > 0, lines <= rows.count else { return nil }
        let guess = lines - 1
        let range = max(0, guess - 32)...min(rows.count - 1, guess + 32)
        let match = range.filter { rows[$0].text == text }.min {
            abs($0 - guess) == abs($1 - guess) ? $0 < $1 : abs($0 - guess) < abs($1 - guess)
        }
        return max(0, -rows[match ?? guess].start)
    }
}
