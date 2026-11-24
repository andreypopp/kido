@testable import KoClientKit
import Synchronization
import XCTest

@MainActor final class PathMonitorTests: XCTestCase {
    func testOnlyASatisfiedUpdateAfterTheBaselineReachesTheLiveClients() async throws {
        let monitor = PathMonitor()
        let live = try KoClient(endpoint: .unix("/tmp/ko-kr-path-none/socket")) { _ in }
        let calls = Mutex(0)
        live.testCallHook { if $0 == .entering { calls.withLock { $0 += 1 } } }
        var gone: KoClient? = try KoClient(endpoint: .unix("/tmp/ko-kr-path-none/socket")) { _ in }
        weak let released = gone
        monitor.register(live)
        monitor.register(live)
        monitor.register(try XCTUnwrap(gone))

        monitor.update(satisfied: true)
        XCTAssertEqual(calls.withLock { $0 }, 0, "the first update is the baseline")
        monitor.update(satisfied: false)
        XCTAssertEqual(calls.withLock { $0 }, 0, "an unsatisfied path reports nothing")
        monitor.update(satisfied: true)
        XCTAssertEqual(calls.withLock { $0 }, 1, "a client registered twice is told once")

        let closed = expectation(description: "the other client closed")
        gone?.close { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 5)
        gone = nil
        XCTAssertNil(released)
        monitor.update(satisfied: true)
        XCTAssertEqual(calls.withLock { $0 }, 2)

        let now = ContinuousClock.now
        monitor.wake(at: now)
        monitor.wake(at: now + .seconds(1))
        monitor.wake(at: now + .milliseconds(1999))
        XCTAssertEqual(calls.withLock { $0 }, 3, "wake hints use the leading edge of the burst")
        monitor.wake(at: now + .seconds(2))
        XCTAssertEqual(calls.withLock { $0 }, 4, "a new burst can start at the throttle boundary")
        monitor.unregister(live)
        monitor.update(satisfied: true)
        monitor.wake(at: now + .seconds(4))
        XCTAssertEqual(calls.withLock { $0 }, 4)
        live.testCallHook(nil)
        let done = expectation(description: "the live client closed")
        live.close { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
    }
}
