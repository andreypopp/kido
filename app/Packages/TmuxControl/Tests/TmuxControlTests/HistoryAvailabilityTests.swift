import XCTest
@testable import TmuxControl

final class HistoryAvailabilityTests: XCTestCase {
    func testSettled() {
        XCTAssertEqual(HistoryAvailability.settled(total: 100_000, loaded: 5000), .ready(gap: 95_000))
        XCTAssertEqual(HistoryAvailability.settled(total: 100_000, loaded: 5000, insertionRefused: true), .limited(history: 100_000))
        XCTAssertEqual(HistoryAvailability.settled(total: 5000, loaded: 5000), .ready(gap: 0))
        XCTAssertEqual(HistoryAvailability.settled(total: 5000, loaded: 5000, insertionRefused: true), .ready(gap: 0))
        XCTAssertEqual(HistoryAvailability.settled(total: 0, loaded: 5000, insertionRefused: true), .ready(gap: 0))
    }
}
