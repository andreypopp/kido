import XCTest
@testable import Kido

final class ParagraphsTests: XCTestCase {
    private func rows(_ lines: [String], wrapped: Set<Int> = []) -> [Paragraphs.Row] {
        lines.enumerated().map { Paragraphs.Row(text: $1, wrapped: wrapped.contains($0)) }
    }

    private func block(_ lines: [String], wrapped: Set<Int> = [], first: Int = 0) -> Paragraphs.Block {
        Paragraphs.testBlocks(rows(lines, wrapped: wrapped), first: first)[0]
    }

    func testPartitionJoinsWrappedRowsAndTrimsTrailingWhitespace() {
        let block = block(["The quick", " brown fox   "], wrapped: [0])
        XCTAssertEqual(block.lines.count, 1)
        XCTAssertEqual(block.lines[0].rows, 0...1)
        XCTAssertEqual(block.lines[0].text, "The quick brown fox")
        XCTAssertEqual(block.text, "The quick brown fox")
        XCTAssertEqual(block.firstColumn, 0)
        XCTAssertEqual(block.lastColumn, 18)
    }

    func testPartitionSplitsOnBlankLogicalLines() {
        let blocks = Paragraphs.testBlocks(rows(["one", "", "two", "  ", "three"]))
        XCTAssertEqual(blocks.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(blocks.map(\.rows), [0...0, 2...2, 4...4])
    }

    func testPartitionKeepsNumberedQuestionsApart() {
        let lines = [
            "1. What do you want me to review?",
            "   - a) A design document in docs/. Which one?",
            "   - b) The uncommitted changes in app/, compared with",
            "     docs/design-app.md and docs/design-rpc.md.",
            "   - c) A design that is not written yet. You tell me about it, and",
            "     I ask questions about it.",
            "   - d) A plan in a different location. Where is it?",
            "",
            "2. What type of review do you want?",
            "   - Correctness: does the design break invariants from AGENTS.md",
            "     (one source of truth, no backward compatibility, no display",
            "     logic in lib/)?",
            "   - Completeness: does it have gaps or cases that it does not",
            "     specify?",
            "   - Simplicity: can it be smaller?",
            "   - Agreement with the code: is the prose still true?",
            "",
            "3. Output: Do you want only a list of findings, or must I also edit",
            "   the document?",
        ]
        let blocks = Paragraphs.testBlocks(rows(lines))
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map { $0.rows.count }, [7, 8, 2])
        XCTAssertTrue(blocks[0].text.hasPrefix("1. What do you want me to review?\n   - a)"))
        XCTAssertTrue(blocks[1].text.hasPrefix("2. What type of review do you want?\n   - Correctness"))
        XCTAssertEqual(blocks[2].text, "3. Output: Do you want only a list of findings, or must I also edit\n   the document?")
    }

    func testPartitionKeepsListItems() {
        let blocks = Paragraphs.testBlocks(rows(["Choose:", "1. A", "- B"]))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "Choose:\n1. A\n- B")
    }

    func testPartitionSplitsAQuestionAndAListParagraph() {
        let blocks = Paragraphs.testBlocks(rows(["Which approach?", "", "1. A", "2. B"]))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.text), ["Which approach?", "1. A\n2. B"])
        XCTAssertEqual(blocks.map(\.rows), [0...0, 2...3])
        for marker in ["- A", "* A", "• A", "a) A", "  - A"] {
            XCTAssertEqual(Paragraphs.testBlocks(rows(["Which?", "", marker])).count, 2, marker)
        }
    }

    func testPartitionUsesTheFirstRowOffset() {
        let blocks = Paragraphs.testBlocks(rows(["one", "", "two"]), first: 40)
        XCTAssertEqual(blocks.map(\.rows), [40...40, 42...42])
    }

    func testLocateExactCaseAndWhitespace() {
        let block = block(["Should I also update The docs?"])
        XCTAssertEqual(Paragraphs.locate("update The docs", in: block)?.text, "update The docs")
        XCTAssertEqual(Paragraphs.locate("UPDATE   the   DOCS", in: block)?.text, "update The docs")
        XCTAssertNil(Paragraphs.locate("update README", in: block))
    }

    func testLocateSkipsAListMarker() {
        let block = block(["How do you want it?", "a) Shift-hover an option here", "b) Remove it"])
        let option = Paragraphs.locate("a) Shift-hover an option here", in: block)
        XCTAssertEqual(option?.text, "Shift-hover an option here")
        XCTAssertEqual(option?.spans.first?.row, 1)
        XCTAssertEqual(option?.spans.first?.columns, 3...28)
        XCTAssertEqual(Paragraphs.locate("Remove it", in: block)?.text, "Remove it")
    }

    func testLocateSpansAWrapSeam() {
        let block = block(["Which reading of the", "  format should run?"], wrapped: [0])
        let option = Paragraphs.locate("reading of the format", in: block)
        XCTAssertEqual(option?.spans.count, 2)
        XCTAssertEqual(option?.spans[0].row, 0)
        XCTAssertEqual(option?.spans[0].columns, 6...19)
        XCTAssertEqual(option?.spans[1].row, 1)
        XCTAssertEqual(option?.spans[1].columns, 0...7)
    }

    func testLocateMeasuresWideCharacters() {
        let block = block(["日本 wide 😀 café"])
        XCTAssertEqual(Paragraphs.locate("日本", in: block)?.spans.first?.columns, 0...3)
        XCTAssertEqual(Paragraphs.locate("wide", in: block)?.spans.first?.columns, 5...8)
        XCTAssertEqual(Paragraphs.locate("😀", in: block)?.spans.first?.columns, 10...11)
        XCTAssertEqual(Paragraphs.locate("cafe\u{301}", in: block)?.spans.first?.columns, 13...16)
    }

    func testUnitExtendsForEveryLocatableOption() {
        let context = Paragraphs.context(rows(["Pick one:", "", "1. First option", "", "2. Second option"]), row: 0)!
        var log = ""
        let unit = Paragraphs.unit(context, ParagraphAnswer(
            isQuestion: true, options: ["missing words", "First option", "Second option"], firstLine: 1, lastLine: 1),
            log: { log = $0 })
        XCTAssertEqual(unit.paragraphs, 0...2)
        XCTAssertEqual(unit.options.map(\.text), ["First option", "Second option"])
        XCTAssertTrue(log.contains("not located"), log)
    }

    func testUnitLocatesAllOptionsBeforeKeepingSix() {
        let lines = ["Pick one:"] + (1...7).map { "\($0). option number \($0)" }
        let context = Paragraphs.context(rows(lines), row: 0)!
        var log = ""
        let unit = Paragraphs.unit(context, ParagraphAnswer(
            isQuestion: true, options: ["not there", "option number 1", "option number 2", "option number 3",
                                        "option number 4", "option number 5", "option number 6", "option number 7"],
            firstLine: 1, lastLine: 8), log: { log = $0 })
        XCTAssertEqual(unit.options.map(\.text), (1...6).map { "option number \($0)" })
        XCTAssertTrue(log.contains("not located"), log)
        XCTAssertTrue(log.contains("limit"), log)
    }

    func testPayloadQuotesEveryLineAndAppendsTheOption() {
        let context = Paragraphs.context(rows(["Which?", "", "1. One"]), row: 0)!
        let unit = Paragraphs.unit(context, ParagraphAnswer(isQuestion: true, options: [], firstLine: 1, lastLine: 3)) { _ in }
        let option = Paragraphs.locate("One", in: unit.block)!
        XCTAssertEqual(Paragraphs.payload(unit.block, option), "> Which?\n> \n> 1. One\n\nOne")
    }

    func testCacheKeysByPromptText() {
        var cache = Paragraphs.Cache(limit: 2)
        let first = "1: first"
        let second = "2: second"
        cache.insert(.plain, for: first)
        cache.insert(.question(Paragraphs.KnownUnit(paragraphs: ["one"], options: ["A"])), for: second)
        XCTAssertEqual(cache[first], .plain)
        XCTAssertEqual(cache[second], .question(Paragraphs.KnownUnit(paragraphs: ["one"], options: ["A"])))
        XCTAssertEqual(cache.questions, [Paragraphs.KnownUnit(paragraphs: ["one"], options: ["A"])])
        cache.insert(.plain, for: "3: third")
        XCTAssertNil(cache[first])
        XCTAssertNotNil(cache[second])
        XCTAssertNotNil(cache["3: third"])
    }

    func testContextKeepsTwoParagraphsPerSide() {
        let lines = ["p0", "", "p1", "", "p2", "", "p3", "", "p4", "", "p5"]
        let first = Paragraphs.context(rows(lines), row: 0)!
        XCTAssertEqual(first.paragraphs.map(\.text), ["p0", "p1", "p2"])
        XCTAssertEqual(first.hovered, 0)
        let last = Paragraphs.context(rows(lines), row: 10)!
        XCTAssertEqual(last.paragraphs.map(\.text), ["p3", "p4", "p5"])
        XCTAssertEqual(last.hovered, 2)
    }

    func testFindPrefersTheNearestDuplicateAndContainsTheHoveredParagraph() {
        let lines = ["dup", "", "end", "", "dup", "", "end"]
        let unit = Paragraphs.KnownUnit(paragraphs: ["dup", "end"], options: [])
        let first = Paragraphs.find(unit, in: rows(lines), first: 0, row: 2, near: 6)
        XCTAssertEqual(first?.block.rows, 0...2)
        let second = Paragraphs.find(unit, in: rows(lines), first: 0, row: 6, near: 0)
        XCTAssertEqual(second?.block.rows, 4...6)
        let middle = Paragraphs.find(unit, in: rows(lines), first: 0, row: 4, near: nil)
        XCTAssertEqual(middle?.block.rows, 4...6)
        XCTAssertNil(Paragraphs.find(Paragraphs.KnownUnit(paragraphs: ["missing"], options: []),
                                     in: rows(lines), first: 0, row: 0, near: nil))
    }

    func testContextSelectsTwoParagraphsEachWayAndNumbersThePrompt() {
        let lines = ["before", "", "hovered one", "hovered two", "", "after"]
        let context = Paragraphs.context(rows(lines), row: 2)!
        XCTAssertEqual(context.paragraphs.map(\.text), ["before", "hovered one\nhovered two", "after"])
        XCTAssertEqual(context.hovered, 1)
        XCTAssertEqual(context.prompt, "  1: before\n  2: \n> 3: hovered one\n> 4: hovered two\n  5: \n  6: after")
        XCTAssertEqual(context.lineNumbers(1), 3...4)
        XCTAssertEqual(context.lines.map(\.text).joined(separator: "\n"), lines.joined(separator: "\n"))
    }

    func testContextStopsAtTheLineBudget() {
        var lines: [String] = []
        for paragraph in 0..<5 {
            if !lines.isEmpty { lines.append("") }
            lines += (0..<25).map { "paragraph \(paragraph) line \($0)" }
        }
        let hoveredRow = 25 + 1 + 25 + 1 + 2
        let context = Paragraphs.context(rows(lines), row: hoveredRow)!
        XCTAssertEqual(context.paragraphs[context.hovered].text, (0..<25).map { "paragraph 2 line \($0)" }.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(context.lines.count, Paragraphs.lineLimit)
        XCTAssertEqual(context.paragraphs.count, 2)
    }

    func testUnitValidationClampsSnapsExtendsAndKeepsTheHoveredParagraph() {
        let context = Paragraphs.context(rows(["Intro", "", "Which approach?", "", "1. First", "2. Second", "", "tail"]), row: 2)!
        XCTAssertEqual(context.hovered, 1)
        let whole = Paragraphs.unit(context, ParagraphAnswer(isQuestion: true, options: [], firstLine: 0, lastLine: 99)) { _ in }
        XCTAssertEqual(whole.paragraphs, 0...3)
        let outside = Paragraphs.unit(context, ParagraphAnswer(isQuestion: true, options: [], firstLine: 1, lastLine: 2)) { _ in }
        XCTAssertEqual(outside.paragraphs, 1...1)
        XCTAssertEqual(outside.block.text, "Which approach?")
        let snapped = Paragraphs.unit(context, ParagraphAnswer(isQuestion: true, options: [], firstLine: 3, lastLine: 3)) { _ in }
        XCTAssertEqual(snapped.paragraphs, 1...1)
        let extended = Paragraphs.unit(context, ParagraphAnswer(isQuestion: true, options: ["First", "Second"], firstLine: 3, lastLine: 3)) { _ in }
        XCTAssertEqual(extended.paragraphs, 1...2)
        XCTAssertEqual(extended.block.text, "Which approach?\n\n1. First\n2. Second")
        XCTAssertEqual(extended.options.map(\.text), ["First", "Second"])
        let tail = Paragraphs.unit(context, ParagraphAnswer(isQuestion: true, options: ["tail"], firstLine: 3, lastLine: 3)) { _ in }
        XCTAssertEqual(tail.paragraphs, 1...3)
        XCTAssertEqual(tail.options.map(\.text), ["tail"])
    }

    func testUnitPayloadQuotesBlankLines() {
        let context = Paragraphs.context(rows(["Which approach?", "", "1. One", "2. Two"]), row: 0)!
        let unit = Paragraphs.unit(context, ParagraphAnswer(isQuestion: true, options: ["One"], firstLine: 1, lastLine: 3)) { _ in }
        let option = Paragraphs.locate("One", in: unit.block)!
        XCTAssertEqual(Paragraphs.payload(unit.block, option), "> Which approach?\n> \n> 1. One\n> 2. Two\n\nOne")
    }

    func testTooLongThresholds() {
        XCTAssertFalse(Paragraphs.isTooLong(block(Array(repeating: "line", count: 60))))
        XCTAssertTrue(Paragraphs.isTooLong(block(Array(repeating: "line", count: 61))))
        XCTAssertFalse(Paragraphs.isTooLong(block([String(repeating: "a", count: 6000)])))
        XCTAssertTrue(Paragraphs.isTooLong(block([String(repeating: "a", count: 6001)])))
    }
}

extension Paragraphs {
    static func testBlocks(_ rows: [Row], first: Int = 0) -> [Block] {
        var blocks: [Block] = []
        var row = first
        while row < first + rows.count {
            guard let context = context(rows, first: first, row: row),
                  let block = context.paragraphs.first(where: { $0.rows.contains(row) }) else {
                row += 1
                continue
            }
            blocks.append(block)
            row = block.rows.upperBound + 1
        }
        return blocks
    }
}

extension Paragraphs.Context {
    func lineNumbers(_ paragraph: Int) -> ClosedRange<Int> {
        (ranges[paragraph].lowerBound + 1)...(ranges[paragraph].upperBound + 1)
    }
}

extension ParagraphAnswer {
    init(isQuestion: Bool, options: [String]) {
        self.init(isQuestion: isQuestion, options: options, firstLine: 1, lastLine: 1)
    }
}
