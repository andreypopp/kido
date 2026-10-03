import Testing
@testable import TmuxControl

@Test func deepAnchorCannotMatchRepeatedBoundaryText() {
    let replies: [Reply] = [.success(["200000 0"]), .success([
        "-50001 - partial", "-50000 - repeated", "-49999 - repeated", "0 - prompt",
    ])]
    #expect(ScrollAnchor(lines: 100000, text: "repeated").locate(replies) == nil)
}

@Test func trimmedAnchorReturnsLiveBottom() {
    #expect(ScrollAnchor(lines: 100000).locate([
        .success(["2 0"]), .success(["-2 - oldest", "-1 - newer", "0 - prompt"]),
    ]) == nil)
}

@Test func restoreAlwaysRequestsNewestFiftyThousand() {
    let commands = PaneSync.commands(PaneID("%1")!)
    #expect(commands.contains { $0.line.contains("-S -50001") })
}
