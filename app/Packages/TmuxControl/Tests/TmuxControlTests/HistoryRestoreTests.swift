import Testing
@testable import TmuxControl

@Test func deepAnchorCannotMatchRepeatedBoundaryText() {
    let replies: [Reply] = [.success(["200000 0"]), .success([
        "-10001 - partial", "-10000 - repeated", "-9999 - repeated", "0 - prompt",
    ])]
    #expect(ScrollAnchor(lines: 100000, text: "repeated").locate(replies) == nil)
}

@Test func trimmedAnchorReturnsLiveBottom() {
    #expect(ScrollAnchor(lines: 100000).locate([
        .success(["2 0"]), .success(["-2 - oldest", "-1 - newer", "0 - prompt"]),
    ]) == nil)
}

@Test func captureASCIIFlagsPreserveUnicodeBodies() {
    let capture = Capture([.success(["3 0"]), .success([
        "-3 W 界🙂 ", "-2 - café W", "-1 - ", "0 W 終",
    ])])!
    #expect(capture.lines.map(\.text) == ["界🙂 café W", "", "終"])
    #expect(capture.lines.map(\.start) == [-3, -1, 0])
    #expect(capture.lines.map(\.end) == [-2, -1, 0])
    #expect(capture.lines.map(\.wrapped) == [false, false, true])
    #expect(Capture([.success(["1 0"]), .success(["-1 malformed"])]) == nil)
}

@Test func restoreAlwaysRequestsNewestTenThousand() {
    let commands = PaneSync.commands(PaneID("%1")!)
    #expect(commands.contains { $0.line.contains("-S -10001") })
}
