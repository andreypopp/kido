import Testing
@testable import TmuxControl

@Test func programStatusIsUnrecognized() {
    let line = #"%program-status %3 7 {"serial":7,"records":[{"id":"","state":"blocked"}]}"#
    #expect(parse(Array((line + "\n").utf8), chunk: 1) == [.unrecognized(line)])
}
