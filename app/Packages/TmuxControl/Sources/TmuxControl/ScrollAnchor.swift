import Foundation

public struct ScrollAnchor: Sendable {
    public private(set) var lines: Int
    public let text: String?
    private var guessed: Int?
    private var matched: (distance: Int, delta: Int)?

    public init(lines: Int, text: String? = nil) { self.lines = lines; self.text = text }

    public enum Location: Sendable {
        case found(Int)
        case next(ScrollAnchor, end: Int)
    }

    public func locate(_ replies: [Reply], end: Int? = nil) -> Location? {
        guard let capture = Capture(replies), !capture.lines.isEmpty else { return nil }
        if capture.state.alternate { return .found(0) }
        var anchor = self
        var suffix = end == nil
        for line in capture.completeLines.reversed() {
            if suffix && line.text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            suffix = false
            anchor.lines -= 1
            let distance = max(0, -line.start)
            if anchor.lines == 0 { anchor.guessed = distance }
            if text == nil, anchor.lines <= 0 { return .found(distance) }
            let delta = abs(anchor.lines)
            if delta <= 32, line.text == text, delta < (anchor.matched?.delta ?? Int.max) {
                if delta == 0 { return .found(distance) }
                anchor.matched = (distance, delta)
            }
            if anchor.lines <= -32 { return .found(anchor.matched?.distance ?? anchor.guessed ?? distance) }
        }
        guard let next = capture.next else {
            return .found(anchor.matched?.distance ?? anchor.guessed ?? capture.state.history)
        }
        return .next(anchor, end: next)
    }
}
