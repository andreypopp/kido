import Testing
@testable import TmuxControl

@Test func scrollAnchorSurvivesChangedBottomLines() throws {
    for bottom in [["0 - prompt", "1 - "], ["0 - truncated prompt", "1 - prompt", "2 - "],
                   ["0 - new output", "1 - more output", "2 - prompt", "3 - "], ["0 - "]] {
        let replies: [Reply] = [.success(["4 0"]), .success([
            "-4 - [0000001]", "-3 W [0000002] long", "-2 - continuation", "-1 - [0000003]",
        ] + bottom)]
        guard case .found(let distance) = try #require(ScrollAnchor(lines: 3, text: "[0000002] longcontinuation").locate(replies)) else {
            Issue.record("anchor not found"); return
        }
        #expect(distance == 3)
    }
}

@Test func scrollAnchorMatchesAcrossPagesAndFallsBack() throws {
    let replies: [Reply] = [.success(["10000 0"]), .success([
        "-5000 - partial", "-4999 - repeated", "-4998 - nearest", "-4997 - prompt", "0 - ",
    ])]
    for text in ["nearest", "missing"] {
        guard case .next(let anchor, let end) = try #require(ScrollAnchor(lines: 3, text: text).locate(replies)),
              case .found(let distance) = try #require(anchor.locate([
                .success(["10000 0"]), .success(["-10000 - oldest", "-5001 - nearest", "-5000 - partial"]),
              ], end: end)) else { Issue.record("anchor not found"); return }
        #expect(end == -5000)
        #expect(distance == (text == "nearest" ? 4998 : 4999))
    }
}

@Test func scrollAnchorMapsNumberedLogIncludingPrompt() throws {
    let replies: [Reply] = [.success(["6 0"]), .success([
        "-6 - [0000001]", "-5 W [0000002] long", "-4 - continuation",
        "-3 - [0000003]", "-2 - [0000004]", "-1 - [0000005]", "0 - prompt", "1 - ", "2 - ",
    ])]
    for (lines, offset) in [(1, 0), (2, 1), (3, 2), (4, 3), (5, 5), (6, 6)] {
        guard case .found(let distance) = try #require(ScrollAnchor(lines: lines).locate(replies)) else {
            Issue.record("anchor not found"); return
        }
        #expect(distance == offset)
    }
}

@Test func scrollAnchorSurvivesReflowAndScreenPadding() throws {
    let old: [Reply] = [.success(["4 0"]), .success([
        "-4 - first", "-3 W long", "-2 - line", "-1 - last", "0 - prompt", "1 - ", "2 - ",
    ])]
    let reflowed: [Reply] = [.success(["5 0"]), .success([
        "-5 - first", "-4 W lo", "-3 W ng", "-2 - line", "-1 - last", "0 - prompt", "1 - ",
    ])]
    guard case .found(let before) = try #require(ScrollAnchor(lines: 3).locate(old)),
          case .found(let after) = try #require(ScrollAnchor(lines: 3).locate(reflowed)) else {
        Issue.record("anchor not found"); return
    }
    #expect(before == 3)
    #expect(after == 4)
}

@Test func scrollAnchorPagesWithoutCountingPartialTopLine() throws {
    let replies: [Reply] = [.success(["10000 0"]), .success([
        "-5000 W partial", "-4999 - line", "-4998 - second", "-4997 - third",
    ])]
    guard case .next(let anchor, let end) = try #require(ScrollAnchor(lines: 3).locate(replies, end: -4997)) else {
        Issue.record("anchor did not continue"); return
    }
    #expect(anchor.lines == 1)
    #expect(end == -4999)
    guard case .found(let distance) = try #require(anchor.locate([
        .success(["10000 0"]), .success(["-5002 - preceding", "-5001 W whole", "-5000 W partial", "-4999 - line"]),
    ], end: end)) else { Issue.record("anchor not found"); return }
    #expect(distance == 5001)
}

@Test func scrollAnchorClampsTrimmedLineToOldestHistory() throws {
    guard case .found(let distance) = try #require(ScrollAnchor(lines: 10000).locate([
        .success(["2 0"]), .success(["-2 - oldest", "-1 - newer", "0 - prompt"]),
    ])) else { Issue.record("anchor not found"); return }
    #expect(distance == 2)
}

@Test func scrollAnchorLeavesAlternateScreenAlone() throws {
    guard case .found(let distance) = try #require(ScrollAnchor(lines: 100).locate([
        .success(["1000 1"]), .success(["0 - vim"]),
    ])) else { Issue.record("anchor not found"); return }
    #expect(distance == 0)
    #expect(ScrollAnchor(lines: 1).locate([.failure(["gone"])]) == nil)
}
