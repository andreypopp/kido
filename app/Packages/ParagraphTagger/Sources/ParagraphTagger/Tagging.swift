import Foundation

struct Tagged {
    let prompt: String
    let offsets: [(Int, Int)]
    let tags: [Tag]
    let answer: TaggerResult
}

public struct TaggerResult: Equatable, Sendable {
    public let isQuestion: Bool
    public let options: [String]
    public let firstLine: Int
    public let lastLine: Int

    public init(isQuestion: Bool, options: [String], firstLine: Int, lastLine: Int) {
        self.isQuestion = isQuestion
        self.options = options
        self.firstLine = firstLine
        self.lastLine = lastLine
    }
}

enum Tag: String {
    case other = "O"
    case beginQuestion = "B-QUESTION"
    case insideQuestion = "I-QUESTION"
    case beginOption = "B-OPTION"
    case insideOption = "I-OPTION"

    init(index: Int) {
        self = [
            .other, .beginQuestion, .insideQuestion, .beginOption, .insideOption,
        ][index]
    }

    var kind: LineClass? {
        switch self {
        case .other: nil
        case .beginQuestion, .insideQuestion: .question
        case .beginOption, .insideOption: .option
        }
    }
}

enum LineClass: String {
    case question
    case option
    case other
}

struct Span: Equatable {
    let start: Int
    let end: Int
    let kind: LineClass
}

enum Tagging {
    static func spans(tags: [Tag], offsets: [(Int, Int)]) -> [Span] {
        var spans: [Span] = []
        var current: Span?
        for (tag, offset) in zip(tags, offsets) {
            guard offset.0 != offset.1, let kind = tag.kind else {
                if let span = current { spans.append(span) }
                current = nil
                continue
            }
            if tag.rawValue.hasPrefix("B-") || current == nil || current?.kind != kind {
                if let span = current { spans.append(span) }
                current = Span(start: offset.0, end: offset.1, kind: kind)
            } else {
                current = Span(start: current!.start, end: offset.1, kind: kind)
            }
        }
        if let span = current { spans.append(span) }
        return spans
    }

    static func lineClasses(rows: [Row], tags: [Tag], offsets: [(Int, Int)]) -> [LineClass] {
        var counts = [(question: Int, option: Int)](repeating: (0, 0), count: rows.count)
        for (tag, offset) in zip(tags, offsets) {
            guard let kind = tag.kind else { continue }
            var best: (overlap: Int, index: Int)?
            for (index, row) in rows.enumerated() {
                let overlap = min(offset.1, row.end) - max(offset.0, row.start)
                if overlap > 0, best == nil || overlap > best!.overlap {
                    best = (overlap, index)
                }
            }
            guard let best else { continue }
            switch kind {
            case .question: counts[best.index].question += 1
            case .option: counts[best.index].option += 1
            case .other: break
            }
        }
        return counts.map { values in
            if values.question > values.option { .question }
            else if values.option > values.question { .option }
            else { .other }
        }
    }

    static func units(_ classes: [LineClass], rows: [Row]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var first: Int?
        var last: Int?
        for (index, value) in classes.enumerated() {
            if value != .other {
                if first == nil { first = index }
                last = index
            } else if first != nil, !Prompt.isBlank(rows[index].text) {
                runs.append(first!..<(last! + 1))
                first = nil
                last = nil
            }
        }
        if let first { runs.append(first..<(last! + 1)) }
        return runs
    }

    static func unit(classes: [LineClass], rows: [Row], ranges: [Range<Int>], hovered: Int) -> Range<Int>? {
        let hoveredRange = ranges[hovered]
        let tagged = hoveredRange.filter { classes[$0] != .other }
        guard let firstTagged = tagged.first,
              let owner = units(classes, rows: rows).first(where: { $0.contains(firstTagged) }) else {
            return nil
        }
        let inRanges = owner.filter { index in
            classes[index] != .other && ranges.contains { $0.contains(index) }
        }
        guard let first = inRanges.first, let last = inRanges.last,
              let low = ranges.firstIndex(where: { $0.contains(first) }),
              let high = ranges.firstIndex(where: { $0.contains(last) }) else {
            return nil
        }
        return ranges[low].lowerBound..<ranges[high].upperBound
    }

    static func trim(_ span: Span, prompt: String) -> Span? {
        let bytes = Array(prompt.utf8)
        var start = span.start
        var end = span.end
        func whitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
        while start < end, whitespace(bytes[start]) || bytes[start] == 0x2A { start += 1 }
        while end > start, whitespace(bytes[end - 1]) || bytes[end - 1] == 0x2A { end -= 1 }
        guard start < end else { return nil }
        return Span(start: start, end: end, kind: span.kind)
    }

    static func text(_ span: Span, prompt: String) -> String {
        let bytes = Array(prompt.utf8)
        return String(decoding: bytes[span.start..<span.end], as: UTF8.self)
    }
}
