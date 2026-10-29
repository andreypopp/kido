import Testing
@testable import TmuxControl

@Test func searchCaptureJoinsWrapsAndUsesASCIICase() throws {
    let replies: [Reply] = [
        .success(["12 0"]),
        .success(["-6 W part", "-5 - ial", "-4 W mAr", "-3 - KeR marker", "-2 - MARKER", "-1 - mäRKER"]),
    ]
    let capture = try #require(SearchCapture(replies, query: "MaRkEr"))
    #expect(capture.distances == [2, 4, 4])
    #expect(capture.next == -5)
    #expect(capture.history == 12)
    #expect(!capture.alternate)
    #expect(SearchCapture(replies, query: "missing")?.distances == [])
    #expect(SearchCapture(replies, query: "MÄRKER")?.distances == [])
}

@Test func searchCaptureIncludesOldestAndScreen() throws {
    let replies: [Reply] = [
        .success(["3 0"]),
        .success(["-3 - marker", "-2 - other", "-1 W MaR", "0 - kEr"]),
    ]
    let capture = try #require(SearchCapture(replies, query: "marker"))
    #expect(capture.distances == [1, 3])
    #expect(capture.next == nil)
}

@Test func searchCaptureAlternateNeverContinuesIntoHistory() throws {
    let capture = try #require(SearchCapture([
        .success(["200000 1"]), .success(["0 - marker", "1 - "]),
    ], query: "MARKER"))
    #expect(capture.alternate)
    #expect(capture.distances == [0])
    #expect(capture.next == nil)
}

@Test func searchCaptureIncludesOverlappingMatches() throws {
    let capture = try #require(SearchCapture([
        .success(["0 0"]), .success(["0 - aaa"]),
    ], query: "AA"))
    #expect(capture.distances == [0, 0])
}

@Test func searchCaptureRetriesAnIncompleteTopLine() throws {
    let capture = try #require(SearchCapture([
        .success(["10000 0"]), .success(["-5000 W mar", "-4999 - ker"]),
    ], query: "marker"))
    #expect(capture.distances == [])
    #expect(capture.next == -4999)
}

@Test func searchCapturePreservesBodyWhitespace() throws {
    let replies: [Reply] = [.success(["0 0"]), .success(["0 W   a ", "1 -  b  ", "2 - "])]
    let decoded = try #require(Capture(replies))
    #expect(decoded.lines.map(\.text) == ["  a  b  ", ""])
    #expect(SearchCapture(replies, query: "a  b ")?.distances == [0])
    #expect(SearchCapture.commands(PaneID("%1")!).count == 2)
}

@Test func searchCaptureRejectsBrokenReply() {
    #expect(SearchCapture([.failure(["gone"])], query: "marker") == nil)
    #expect(SearchCapture([.success(["4 0"]), .success(["broken"])], query: "x") == nil)
}
