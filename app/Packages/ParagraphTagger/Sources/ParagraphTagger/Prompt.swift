import Foundation

public enum ParagraphTaggerError: Error, Equatable {
    case missingModel
    case missingTokenizer
    case loadFailed
    case noHoveredLine
    case hoveredParagraphTooLong

    public var isLoadFailure: Bool {
        switch self {
        case .missingModel, .missingTokenizer, .loadFailed: true
        case .noHoveredLine, .hoveredParagraphTooLong: false
        }
    }
}

struct Row {
    let marked: Bool
    let text: String
    let start: Int
    let end: Int
}

struct ContextPrompt {
    let lines: [String]
    let blocks: [Range<Int>]
    let hoveredBlock: Int
    let hoveredRange: Range<Int>

    init(_ prompt: String) throws {
        let parsed = Prompt.rows(prompt)
        let marked = parsed.firstIndex(where: \.marked)
        guard let marked else { throw ParagraphTaggerError.noHoveredLine }
        lines = parsed.map { $0.text.replacingOccurrences(of: "**", with: "") }
        var blocks: [Range<Int>] = []
        var index = 0
        while index < lines.count {
            while index < lines.count, Prompt.isBlank(lines[index]) { index += 1 }
            guard index < lines.count else { break }
            let start = index
            while index < lines.count, !Prompt.isBlank(lines[index]) { index += 1 }
            blocks.append(start..<index)
        }
        self.blocks = blocks
        guard let hoveredBlock = blocks.firstIndex(where: { $0.contains(marked) }) else {
            throw ParagraphTaggerError.noHoveredLine
        }
        self.hoveredBlock = hoveredBlock
        hoveredRange = blocks[hoveredBlock]
    }

    func assemble(low: Int, high: Int) -> (prompt: String, rows: [Row], ranges: [Range<Int>], hovered: Int) {
        let first = blocks[low].lowerBound
        var text = ""
        var ranges: [Range<Int>] = []
        for index in low...high {
            ranges.append((blocks[index].lowerBound - first)..<(blocks[index].upperBound - first))
        }
        let last = blocks[high].upperBound
        for index in first..<last {
            if index > first { text += "\n" }
            let marker = hoveredRange.contains(index) ? ">" : " "
            text += "\(marker) \(index - first + 1): \(lines[index])"
        }
        return (text, Prompt.rows(text), ranges, hoveredBlock - low)
    }
}

enum Prompt {
    static func isBlank(_ text: String) -> Bool {
        text.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func rows(_ prompt: String) -> [Row] {
        var rows: [Row] = []
        var offset = 0
        for raw in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            var index = line.startIndex
            guard index < line.endIndex, line[index] == " " || line[index] == ">" else {
                return []
            }
            let marked = line[index] == ">"
            index = line.index(after: index)
            guard index < line.endIndex, line[index] == " " else { return [] }
            index = line.index(after: index)
            let digits = index
            while index < line.endIndex, line[index].isNumber { index = line.index(after: index) }
            guard digits < index, line[index...].hasPrefix(": ") else { return [] }
            let text = String(line[line.index(index, offsetBy: 2)...])
            let start = offset + line.utf8.count - text.utf8.count
            rows.append(Row(marked: marked, text: text,
                            start: start, end: start + text.utf8.count))
            offset += line.utf8.count + 1
        }
        return rows
    }
}
