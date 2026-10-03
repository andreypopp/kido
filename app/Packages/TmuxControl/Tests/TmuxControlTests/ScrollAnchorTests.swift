import Testing
@testable import TmuxControl

@Test func scrollAnchorSurvivesChangedBottomLines() throws {
    for bottom in [["0 - prompt", "1 - "], ["0 - truncated prompt", "1 - prompt", "2 - "],
                   ["0 - new output", "1 - more output", "2 - prompt", "3 - "], ["0 - "]] {
        let replies: [Reply] = [.success(["4 0"]), .success([
            "-4 - [0000001]", "-3 W [0000002] long", "-2 - continuation", "-1 - [0000003]",
        ] + bottom)]
        #expect(try #require(ScrollAnchor(lines: 3, text: "[0000002] longcontinuation").locate(replies)) == 3)
    }
}

@Test func scrollAnchorMapsNumberedLogIncludingPrompt() throws {
    let replies: [Reply] = [.success(["6 0"]), .success([
        "-6 - [0000001]", "-5 W [0000002] long", "-4 - continuation",
        "-3 - [0000003]", "-2 - [0000004]", "-1 - [0000005]", "0 - prompt", "1 - ", "2 - ",
    ])]
    for (lines, offset) in [(1, 0), (2, 1), (3, 2), (4, 3), (5, 5), (6, 6)] {
        #expect(try #require(ScrollAnchor(lines: lines).locate(replies)) == offset)
    }
}

@Test func scrollAnchorSurvivesReflowAndScreenPadding() throws {
    let old: [Reply] = [.success(["4 0"]), .success([
        "-4 - first", "-3 W long", "-2 - line", "-1 - last", "0 - prompt", "1 - ", "2 - ",
    ])]
    let reflowed: [Reply] = [.success(["5 0"]), .success([
        "-5 - first", "-4 W lo", "-3 W ng", "-2 - line", "-1 - last", "0 - prompt", "1 - ",
    ])]
    #expect(try #require(ScrollAnchor(lines: 3).locate(old)) == 3)
    #expect(try #require(ScrollAnchor(lines: 3).locate(reflowed)) == 4)
}

@Test func scrollAnchorDoesNotCountPartialTopLine() {
    let replies: [Reply] = [.success(["10000 0"]), .success([
        "-5000 W partial", "-4999 - line", "-4998 - second", "-4997 - third",
    ])]
    #expect(ScrollAnchor(lines: 3).locate(replies) == nil)
    #expect(ScrollAnchor(lines: 2).locate(replies) == 4998)
}

@Test func scrollAnchorLeavesAlternateScreenAlone() {
    #expect(ScrollAnchor(lines: 100).locate([
        .success(["1000 1"]), .success(["0 - vim"]),
    ]) == 0)
    #expect(ScrollAnchor(lines: 1).locate([.failure(["gone"])]) == nil)
}

@Test func anchorNearestTieGoesNewerAndMissingUsesCount() {
    let replies: [Reply] = [.success(["4 0"]), .success([
        "-4 - old", "-3 - repeated", "-2 - absent", "-1 - repeated", "0 - prompt",
    ])]
    #expect(ScrollAnchor(lines: 3, text: "repeated").locate(replies) == 1)
    #expect(ScrollAnchor(lines: 3, text: "missing").locate(replies) == 2)
}
