import Foundation

public struct ScrollAnchor: Sendable {
    public let lines: Int

    public init(lines: Int) { self.lines = lines }

    public enum Location: Sendable {
        case found(Int)
        case next(ScrollAnchor, end: Int)
    }

    public func locate(_ replies: [Reply], end: Int? = nil) -> Location? {
        guard let capture = Capture(replies), !capture.lines.isEmpty else { return nil }
        if capture.state.alternate { return .found(0) }
        var remaining = lines
        var suffix = end == nil
        for line in capture.completeLines.reversed() {
            if suffix && line.text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            suffix = false
            remaining -= 1
            if remaining <= 0 { return .found(max(0, -line.start)) }
        }
        guard let next = capture.next else { return .found(capture.state.history) }
        return .next(ScrollAnchor(lines: remaining), end: next)
    }
}
