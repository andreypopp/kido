import Testing
@testable import TmuxControl

@Test func historyCaptureSelectsPhysicalRowsAtLogicalStart() throws {
    let capture = try #require(Capture([.success(["12000 0"]), .success([
        "-5002 W previous", "-5001 W part", "-5000 - ial", "-4999 W abcd", "-4998 - efgh", "-4997 - last",
    ])]))
    #expect(HistoryCapture.selectedRows(capture, loaded: 4996, chunk: 5, initial: false) == 3)
}

@Test func historyCaptureKeepsRestoreReplayBytes() throws {
    let replies: [Reply] = [
        .success(["3 0"]), .success(["old\r", "wrappedlong"]),
        .success(["-3 - old", "-2 W wrapped", "-1 W long"]),
    ]
    let capture = try #require(HistoryCapture(replies, rows: 3, initial: true))
    #expect(capture.rows == 3)
    #expect(capture.text == "old\r\nwrappedlong")
}

@Test func historyCaptureRemovesOnlyPrependFraming() throws {
    let replies: [Reply] = [
        .success(["2 0"]), .success(["older\r", "last\u{1B}[m\r", ""]),
        .success(["-2 - older", "-1 - last"]),
    ]
    let capture = try #require(HistoryCapture(replies, rows: 2))
    #expect(capture.text == "older\r\nlast\u{1B}[m")
}

@Test func historyCaptureAcceptsHardBoundary() throws {
    let capture = try #require(Capture([.success(["10000 0"]), .success([
        "-5004 - previous", "-5003 - older",
    ])]))
    #expect(HistoryCapture.selectedRows(capture, loaded: 5002, chunk: 1, initial: false) == 1)
}

@Test func historyCaptureOmitsAnIncompleteLine() throws {
    let capture = try #require(Capture([.success(["100000 0"]), .success([
        "-10001 W previous", "-10000 W partial",
    ])]))
    #expect(HistoryCapture.selectedRows(capture, loaded: 0, chunk: 10000, initial: true) == nil)
}
