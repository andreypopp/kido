import Foundation
import SidebarFeed

enum Paragraphs {
    struct Row: Equatable, Sendable {
        let text: String
        let wrapped: Bool
    }

    struct Span: Equatable, Sendable {
        let row: Int
        let columns: ClosedRange<Int>
    }

    struct Option: Equatable, Sendable {
        let text: String
        let spans: [Span]
    }

    struct Line: Equatable, Sendable {
        let rows: ClosedRange<Int>
        let text: String
        let parts: [Part]

        var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    enum Part: Equatable, Sendable {
        case text(Int, String)
        case newline
    }

    struct Block: Equatable, Sendable {
        let lines: [Line]
        let text: String
        let parts: [Part]
        let firstColumn: Int
        let lastColumn: Int

        var rows: ClosedRange<Int> {
            lines[0].rows.lowerBound...lines[lines.count - 1].rows.upperBound
        }
    }

    struct KnownUnit: Equatable, Sendable {
        let paragraphs: [String]
        let options: [String]
    }

    enum Verdict: Equatable, Sendable {
        case plain
        case question(KnownUnit)
    }

    struct Context: Equatable, Sendable {
        let paragraphs: [Block]
        let lines: [Line]
        let ranges: [ClosedRange<Int>]
        let hovered: Int
        let needsBefore: Bool
        let needsAfter: Bool

        var prompt: String {
            lines.enumerated().map { index, line in
                "\(ranges[hovered].contains(index) ? ">" : " ") \(index + 1): \(line.text)"
            }.joined(separator: "\n")
        }

        func block(_ paragraphs: ClosedRange<Int>) -> Block {
            Paragraphs.makeBlock(Array(lines[ranges[paragraphs.lowerBound].lowerBound...ranges[paragraphs.upperBound].upperBound]))
        }
    }

    struct Unit: Equatable, Sendable {
        let block: Block
        let options: [Option]
        let paragraphs: ClosedRange<Int>
    }

    struct Cache {
        private var values: [String: Verdict] = [:]
        private var order: [String] = []
        let limit: Int

        init(limit: Int) {
            self.limit = limit
        }

        subscript(prompt: String) -> Verdict? {
            values[prompt]
        }

        var questions: [KnownUnit] {
            values.values.compactMap { if case .question(let unit) = $0 { unit } else { nil } }
        }

        mutating func insert(_ verdict: Verdict, for prompt: String) {
            if values[prompt] == nil { order.append(prompt) }
            values[prompt] = verdict
            while order.count > limit {
                values[order.removeFirst()] = nil
            }
        }
    }

    static let shortOption = 3
    static let optionLimit = 6
    static let lineLimit = 60
    static let characterLimit = 6000
    static let contextBefore = 2
    static let contextAfter = 2

    static func context(_ rows: [Row], first: Int = 0, row: Int) -> Context? {
        let lines = logicalLines(rows, first: first)
        let blocks = partitionBlocks(lines)
        guard let hovered = blocks.firstIndex(where: { $0.block.rows.contains(row) }) else { return nil }
        var low = hovered
        var high = hovered
        var totalLines = blocks[hovered].block.lines.count
        var totalCharacters = blocks[hovered].block.text.count
        var addedBefore = 0
        var addedAfter = 0
        var blockedBefore = false
        var blockedAfter = false
        func add(_ before: Bool) -> Bool {
            guard before ? addedBefore < contextBefore : addedAfter < contextAfter else { return false }
            let index = before ? low - 1 : high + 1
            guard blocks.indices.contains(index) else { return false }
            let gap = before
                ? blocks[low].range.lowerBound - blocks[index].range.upperBound - 1
                : blocks[index].range.lowerBound - blocks[high].range.upperBound - 1
            let addedLines = blocks[index].block.lines.count + gap
            let addedCharacters = blocks[index].block.text.count + gap
            guard totalLines + addedLines <= lineLimit, totalCharacters + addedCharacters <= characterLimit else {
                if before { blockedBefore = true } else { blockedAfter = true }
                return false
            }
            if before { low = index; addedBefore += 1 } else { high = index; addedAfter += 1 }
            totalLines += addedLines
            totalCharacters += addedCharacters
            return true
        }
        while addedBefore < contextBefore || addedAfter < contextAfter {
            let before = addedBefore <= addedAfter
            if add(before) || add(!before) { continue }
            break
        }
        let start = blocks[low].range.lowerBound
        let end = blocks[high].range.upperBound
        let selected = Array(lines[start...end])
        let ranges = (low...high).map { (blocks[$0].range.lowerBound - start)...(blocks[$0].range.upperBound - start) }
        return Context(paragraphs: blocks[low...high].map(\.block), lines: selected, ranges: ranges,
                       hovered: hovered - low,
                       needsBefore: !blockedBefore && addedBefore < contextBefore,
                       needsAfter: !blockedAfter && addedAfter < contextAfter)
    }

    static func blankRow(_ rows: [Row], first: Int, row: Int) -> Bool {
        guard row >= first, row < first + rows.count else { return false }
        return logicalLines(rows, first: first).first { $0.rows.contains(row) }?.isBlank ?? false
    }

    static func find(_ unit: KnownUnit, in rows: [Row], first: Int, row: Int, near: Int?) -> Unit? {
        let lines = logicalLines(rows, first: first)
        let blocks = partitionBlocks(lines)
        guard let hovered = blocks.firstIndex(where: { $0.block.rows.contains(row) }) else { return nil }
        let count = unit.paragraphs.count
        guard count > 0, count <= blocks.count else { return nil }
        let matches = (0...(blocks.count - count)).filter { start in
            blocks[start..<start + count].map { $0.block.text } == unit.paragraphs
                && (start...(start + count - 1)).contains(hovered)
        }
        guard let start = matches.min(by: {
            abs(blocks[$0].range.lowerBound - (near ?? row)) < abs(blocks[$1].range.lowerBound - (near ?? row))
        }) else { return nil }
        let low = blocks[start].range.lowerBound
        let high = blocks[start + count - 1].range.upperBound
        let block = makeBlock(Array(lines[low...high]))
        return Unit(block: block, options: unit.options.compactMap { locate($0, in: block) },
                    paragraphs: start...(start + count - 1))
    }

    static func unit(_ context: Context, _ answer: ParagraphAnswer, log: (String) -> Void) -> Unit {
        var first = min(max(answer.firstLine, 1), context.lines.count) - 1
        var last = min(max(answer.lastLine, 1), context.lines.count) - 1
        if first > last { swap(&first, &last) }
        var range = (context.ranges.firstIndex { $0.upperBound >= first })!...(context.ranges.lastIndex { $0.lowerBound <= last })!
        if !range.contains(context.hovered) { range = context.hovered...context.hovered }
        let curated = curate(answer.options)
        var block = context.block(range)
        while true {
            var extended = false
            for text in curated.kept where locate(text, in: block) == nil {
                guard let paragraph = context.paragraphs.indices.first(where: {
                    !range.contains($0) && locate(text, in: context.paragraphs[$0]) != nil
                }) else { continue }
                range = min(range.lowerBound, paragraph)...max(range.upperBound, paragraph)
                block = context.block(range)
                extended = true
                break
            }
            if !extended { break }
        }
        let all = locateAll(curated.kept, in: block)
        let options = Array(all.options.prefix(optionLimit))
        let limited = all.options.dropFirst(optionLimit).map { "\(quoted($0.text)): limit" }
        log("paragraph options kept=\(options.count) \(options.map { quoted($0.text) }) dropped=\(curated.dropped + all.dropped + limited)")
        return Unit(block: block, options: options, paragraphs: range)
    }

    private static func partitionBlocks(_ lines: [Line]) -> [(block: Block, range: ClosedRange<Int>)] {
        var blocks: [(block: Block, range: ClosedRange<Int>)] = []
        var start = 0
        while start < lines.count {
            if lines[start].isBlank {
                start += 1
                continue
            }
            var end = start
            while end + 1 < lines.count, !lines[end + 1].isBlank { end += 1 }
            blocks.append((makeBlock(Array(lines[start...end])), start...end))
            start = end + 1
        }
        return blocks
    }

    private static func makeBlock(_ lines: [Line]) -> Block {
        let parts = lines.flatMap { $0.parts + [.newline] }.dropLast()
        let content = lines.filter { !$0.isBlank }
        let first = content.map { leadingWidth($0.text) }.min() ?? 0
        let last = content.map { max(first, width($0.text) - 1) }.max() ?? first
        return Block(lines: lines, text: lines.map(\.text).joined(separator: "\n"),
                     parts: Array(parts), firstColumn: first, lastColumn: last)
    }

    static func isTooLong(_ block: Block) -> Bool {
        block.lines.count > lineLimit || block.text.count > characterLimit
    }

    static func locate(_ text: String, in block: Block) -> Option? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, var range = match(value, in: block.text) else { return nil }
        range = stripMarker(range, in: block.text)
        guard range.lowerBound < range.upperBound else { return nil }
        let lower = block.text.distance(from: block.text.startIndex, to: range.lowerBound)
        let upper = block.text.distance(from: block.text.startIndex, to: range.upperBound)
        let spans = segments(block, lower..<upper)
        guard !spans.isEmpty else { return nil }
        return Option(text: String(block.text[range]), spans: spans)
    }

    private static func curate(_ raw: [String]) -> (kept: [String], dropped: [String]) {
        var seen: Set<String> = []
        var kept: [String] = []
        var dropped: [String] = []
        for value in raw {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= shortOption else {
                dropped.append("\(quoted(text)): short")
                continue
            }
            let normalized = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard seen.insert(normalized).inserted else {
                dropped.append("\(quoted(text)): duplicate")
                continue
            }
            kept.append(text)
        }
        return (kept, dropped)
    }

    private static func locateAll(_ texts: [String], in block: Block) -> (options: [Option], dropped: [String]) {
        var options: [Option] = []
        var dropped: [String] = []
        for text in texts {
            guard let option = locate(text, in: block) else {
                dropped.append("\(quoted(text)): not located")
                continue
            }
            options.append(option)
        }
        return (options, dropped)
    }

    static func payload(_ block: Block, _ option: Option) -> String {
        RPCRequest.quote(block.text) + "\n\n" + option.text
    }

    static func cellWidth(_ character: Character) -> Int {
        var wide = false
        for scalar in character.unicodeScalars {
            let value = scalar.value
            if value == 0x200D || (0xFE00...0xFE0F).contains(value)
                || (0x0300...0x036F).contains(value)
                || (0x1AB0...0x1AFF).contains(value)
                || (0x1DC0...0x1DFF).contains(value)
                || (0x20D0...0x20FF).contains(value)
                || (0xFE20...0xFE2F).contains(value) {
                continue
            }
            if (0x1100...0x115F).contains(value)
                || (0x2329...0x232A).contains(value)
                || (0x2E80...0xA4CF).contains(value)
                || (0xAC00...0xD7A3).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0xFE10...0xFE19).contains(value)
                || (0xFE30...0xFE6F).contains(value)
                || (0xFF00...0xFF60).contains(value)
                || (0xFFE0...0xFFE6).contains(value)
                || (0x1F300...0x1F64F).contains(value)
                || (0x1F900...0x1F9FF).contains(value)
                || (0x20000...0x3FFFD).contains(value) {
                wide = true
            }
        }
        return wide ? 2 : 1
    }

    private struct Cell {
        let row: Int
        let column: Int
        let width: Int
    }

    private static func logicalLines(_ rows: [Row], first: Int) -> [Line] {
        var lines: [Line] = []
        var start = 0
        while start < rows.count {
            var end = start
            while end + 1 < rows.count, rows[end].wrapped { end += 1 }
            var texts = rows[start...end].map(\.text)
            texts[texts.count - 1] = trimTrailing(texts[texts.count - 1])
            let text = texts.joined()
            let parts = text.isEmpty ? [] : (start...end).map { Part.text(first + $0, texts[$0 - start]) }
            lines.append(Line(rows: (first + start)...(first + end), text: trimTrailing(text), parts: parts))
            start = end + 1
        }
        return lines
    }

    private static func trimTrailing(_ text: String) -> String {
        var value = text
        while let last = value.last, last == " " || last == "\t" { value.removeLast() }
        return value
    }

    private static func match(_ option: String, in text: String) -> Range<String.Index>? {
        if let exact = text.range(of: option) { return exact }
        if let match = pattern(option, in: text) { return match }
        let stripped = String(stripMarker(Substring(option)))
        guard stripped != option else { return nil }
        if let exact = text.range(of: stripped) { return exact }
        return pattern(stripped, in: text)
    }

    private static func pattern(_ option: String, in text: String) -> Range<String.Index>? {
        let pattern = option.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return range
    }

    private static func stripMarker(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        let stripped = stripMarker(text[range])
        return stripped.startIndex..<stripped.endIndex
    }

    private static func stripMarker(_ value: Substring) -> Substring {
        var start = value.startIndex
        for _ in 0..<2 {
            var index = start
            while index < value.endIndex, value[index] == " " || value[index] == "\t" {
                index = value.index(after: index)
            }
            guard index < value.endIndex else { return value[start...] }
            guard let end = markerEnd(value, at: index) else { return value[start...] }
            start = end
        }
        return value[start...]
    }

    private static func markerEnd(_ value: Substring, at start: String.Index) -> String.Index? {
        let first = value[start]
        if first == "-" || first == "*" || first == "•" {
            let after = value.index(after: start)
            guard after < value.endIndex, value[after] == " " || value[after] == "\t" else { return nil }
            return value.index(after: after)
        }
        if first.isNumber {
            var index = start
            while index < value.endIndex, value[index].isNumber { index = value.index(after: index) }
            guard index < value.endIndex, value[index] == "." || value[index] == ")" else { return nil }
            let after = value.index(after: index)
            guard after < value.endIndex, value[after] == " " || value[after] == "\t" else { return nil }
            return value.index(after: after)
        }
        if first.isLetter {
            let punctuation = value.index(after: start)
            guard punctuation < value.endIndex, value[punctuation] == ")" else { return nil }
            let after = value.index(after: punctuation)
            guard after < value.endIndex, value[after] == " " || value[after] == "\t" else { return nil }
            return value.index(after: after)
        }
        return nil
    }

    private static func segments(_ block: Block, _ range: Range<Int>) -> [Span] {
        var cells: [Cell] = []
        for part in block.parts {
            switch part {
            case .newline:
                cells.append(Cell(row: -1, column: 0, width: 0))
            case .text(let row, let text):
                var column = 0
                for character in text {
                    let width = cellWidth(character)
                    cells.append(Cell(row: row, column: column, width: width))
                    column += width
                }
            }
        }
        var spans: [Span] = []
        var current: (row: Int, start: Int, end: Int)?
        for offset in range where offset >= 0 && offset < cells.count {
            let cell = cells[offset]
            guard cell.row >= 0, cell.width > 0 else { continue }
            if var group = current, group.row == cell.row {
                group.end = max(group.end, cell.column + cell.width - 1)
                current = group
            } else {
                if let group = current {
                    spans.append(Span(row: group.row, columns: group.start...group.end))
                }
                current = (cell.row, cell.column, cell.column + cell.width - 1)
            }
        }
        if let group = current {
            spans.append(Span(row: group.row, columns: group.start...group.end))
        }
        return spans
    }

    private static func leadingWidth(_ text: String) -> Int {
        var width = 0
        for character in text {
            guard character == " " || character == "\t" else { break }
            width += cellWidth(character)
        }
        return width
    }

    private static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + cellWidth($1) }
    }

    private static func quoted(_ text: String) -> String {
        "\"\(text)\""
    }
}
