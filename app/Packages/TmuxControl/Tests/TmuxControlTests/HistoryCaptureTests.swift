import Testing
@testable import TmuxControl

@Test func historyCaptureAlignsLogicalLines() throws {
    let replies: [Reply] = [
        .success(["12000 0"]),
        .success(["\u{1B}[31mpartial", "abcdefgh", "last"]),
        .success(["-5001 W part", "-5000 - ial", "-4999 W abcd", "-4998 - efgh", "-4997 - last"]),
    ]
    let capture = try #require(HistoryCapture(replies, loaded: 4996))
    #expect(capture.rows == 3)
    #expect(capture.text == "\u{1B}[m\u{1B}[31mabcdefgh\r\nlast")
    #expect(capture.history == 12000)
}

@Test func historyCaptureExcludesOutputOverlap() throws {
    let replies: [Reply] = [
        .success(["10000 0"]), .success(["boundary", "older", "loaded", "recent"]),
        .success(["-5004 - boundary", "-5003 - older", "-5002 - loaded", "-5001 - recent"]),
    ]
    let capture = try #require(HistoryCapture(replies, loaded: 5002))
    #expect(capture.rows == 1)
    #expect(capture.text == "\u{1B}[molder")
}

@Test func historyCaptureKeepsTrimmedTopAndScreenWrap() throws {
    let replies: [Reply] = [
        .success(["3 0"]), .success(["old", "wrappedlong"]),
        .success(["-3 - old", "-2 W wrapped", "-1 W long"]),
    ]
    let capture = try #require(HistoryCapture(replies, loaded: 0, initial: true))
    #expect(capture.rows == 3)
    #expect(capture.wrapsIntoScreen)
    #expect(capture.text == "\u{1B}[mold\r\nwrappedlong")
}

@Test func historyCaptureRejectsMalformedMetadata() {
    #expect(HistoryCapture([.success(["4 0"]), .success(["x"]), .success(["broken"])], loaded: 0) == nil)
}
