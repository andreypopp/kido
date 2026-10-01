import Foundation

public struct ScrollAnchor: Sendable {
    public let lines: Int

    public init(lines: Int) { self.lines = lines }

    public enum Location: Sendable {
        case found(Int)
        case next(ScrollAnchor, end: Int)
    }

    public func locate(_ replies: [Reply], end: Int? = nil) -> Location? {
        guard let capture = Capture(replies), let first = capture.lines.first else { return nil }
        if capture.state.alternate { return .found(0) }
        let skip = first.start > -capture.state.history && first.start < 0
        var remaining = lines
        var suffix = end == nil
        for index in capture.lines.indices.reversed() where !skip || index > 0 {
            let line = capture.lines[index]
            if suffix && line.text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            suffix = false
            remaining -= 1
            if remaining <= 0 { return .found(max(0, -line.start)) }
        }
        guard first.start > -capture.state.history else { return .found(capture.state.history) }
        return .next(ScrollAnchor(lines: remaining), end: skip ? first.end : first.start - 1)
    }
}
