import Testing
@testable import ParagraphTagger

private func makePrompt(_ lines: [String], hovered: ClosedRange<Int>) -> String {
    lines.enumerated().map { index, text in
        "\(hovered.contains(index) ? ">" : " ") \(index + 1): \(text)"
    }.joined(separator: "\n")
}

private func byteRange(_ row: Row, _ offset: Int, _ length: Int) -> (Int, Int) {
    (row.start + offset, row.start + offset + length)
}

@Test func lineClassesUseTheMajorityTag() {
    let prompt = makePrompt(["Which one?", "1. Alpha", "2. Beta"], hovered: 0...0)
    let rows = Prompt.rows(prompt)
    let offsets = [
        byteRange(rows[0], 0, 6), byteRange(rows[0], 6, 5),
        byteRange(rows[1], 0, 8), byteRange(rows[2], 0, 7),
    ]
    let classes = Tagging.lineClasses(
        rows: rows,
        tags: [.beginQuestion, .insideQuestion, .beginOption, .beginOption],
        offsets: offsets)
    #expect(classes == [.question, .option, .option])
}

@Test func spansJoinInsideTagsAndBreakOnOther() {
    let spanning = Tagging.spans(
        tags: [.other, .beginOption, .insideOption, .other, .insideOption],
        offsets: [(0, 0), (2, 7), (7, 11), (11, 12), (12, 13)])
    #expect(spanning == [
        Span(start: 2, end: 11, kind: .option),
        Span(start: 12, end: 13, kind: .option),
    ])
    #expect(Tagging.spans(tags: [.beginOption, .insideOption],
                          offsets: [(3, 3), (3, 3)]).isEmpty)
}

@Test func unitIsTheRunThatContainsTheHoveredParagraph() {
    let prompt = makePrompt(["Intro", "Which one?", "", "1. Alpha", "2. Beta", "", "Outro"], hovered: 3...4)
    let rows = Prompt.rows(prompt)
    var classes = [LineClass](repeating: .other, count: rows.count)
    classes[1] = .question
    classes[3] = .option
    classes[4] = .option
    let ranges = [0..<1, 1..<2, 3..<5, 6..<7]
    #expect(Tagging.unit(classes: classes, rows: rows, ranges: ranges, hovered: 2) == 1..<5)
    #expect(Tagging.unit(classes: classes, rows: rows, ranges: ranges, hovered: 0) == nil)
}

@Test func trimRemovesWhitespaceAndBoldMarkers() {
    let prompt = "> 1: 1. **Alpha** "
    let span = Span(start: 8, end: prompt.utf8.count, kind: .option)
    #expect(Tagging.trim(span, prompt: prompt).map { Tagging.text($0, prompt: prompt) } == "Alpha")
}
