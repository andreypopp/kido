import Testing
@testable import ParagraphTagger

@Test func parsesMarkersNumbersAndBlocks() throws {
    let prompt = "  1: Intro\n  2: \n> 3: Which one?\n  4: 1. Alpha\n  5: \n  6: Outro"
    let context = try ContextPrompt(prompt)
    #expect(context.lines == ["Intro", "", "Which one?", "1. Alpha", "", "Outro"])
    #expect(context.blocks == [0..<1, 2..<4, 5..<6])
    #expect(context.hoveredBlock == 1)
    #expect(context.hoveredRange == 2..<4)
}

@Test func assemblingRenumbersFromOneAndKeepsTheHoverMarker() throws {
    let prompt = "  1: Intro\n  2: \n> 3: Which one?\n  4: 1. Alpha"
    let context = try ContextPrompt(prompt)
    let assembled = context.assemble(low: 1, high: 1)
    #expect(assembled.prompt == "> 1: Which one?\n> 2: 1. Alpha")
    #expect(assembled.rows.map(\.text) == ["Which one?", "1. Alpha"])
    #expect(assembled.ranges == [0..<2])
    #expect(assembled.hovered == 0)
}

@Test func shapePicksTheSmallestFunction() {
    #expect([1, 512, 513, 1024, 1025, 2048, 2049].map(Selection.shape) == [512, 512, 1024, 1024, 2048, 2048, 2048])
}

@Test func droppingRemovesTheOutermostContextParagraph() throws {
    let blocks = [0..<1, 2..<3, 4..<5, 6..<7]
    let chosen = try Selection.choose(blocks, hovered: 1) { low, high in
        high - low == 3 ? 2049 : 100
    }
    #expect(chosen == (low: 0, high: 2))
    let droppedBefore = try Selection.choose(blocks, hovered: 2) { low, high in
        high - low == 3 ? 2049 : 100
    }
    #expect(droppedBefore == (low: 1, high: 3))
}

@Test func droppingPrefersTheHoveredParagraphAndFailsWhenItAloneDoesNotFit() {
    #expect(throws: ParagraphTaggerError.hoveredParagraphTooLong) {
        try Selection.choose([0..<1], hovered: 0) { _, _ in 2049 }
    }
}
