import Testing
@testable import TmuxControl

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
