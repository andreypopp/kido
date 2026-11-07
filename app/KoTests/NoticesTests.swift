import AppKit
import XCTest
@testable import Kido

@MainActor final class NoticesTests: KoTestCase {
    func testClocksStackDedupeAndCap() throws {
        var state = TransientNotices()
        state.show("first", "detail", duration: 5, now: 10)
        let first = try XCTUnwrap(state.entries.first?.id)
        state.show("second", "long", duration: 8, now: 11)
        XCTAssertEqual(state.deadline, 15)
        state.expire(now: 14.999)
        XCTAssertEqual(state.entries.count, 2)
        state.hover(first, inside: true, now: 14)
        XCTAssertEqual(state.entries[0].clock, .paused(remaining: 1))
        state.show("first", "detail", duration: 5, now: 20)
        XCTAssertEqual(state.entries.map(\.title), ["first"])
        XCTAssertEqual(state.entries[0].id, first)
        XCTAssertEqual(state.entries[0].clock, .paused(remaining: 5))
        state.expire(now: 100)
        XCTAssertEqual(state.entries.count, 1)
        state.hover(first, inside: false, now: 100)
        XCTAssertEqual(state.deadline, 105)
        state.show("second", "detail", duration: 8, now: 101)
        state.show("third", "detail", duration: 5, now: 102)
        state.show("fourth", "detail", duration: 5, now: 103)
        XCTAssertEqual(state.entries.map(\.title), ["second", "third", "fourth"])
        state.show("third", "detail", duration: 5, now: 104)
        XCTAssertEqual(state.entries.map(\.title), ["second", "third", "fourth"])
        XCTAssertEqual(state.entries[1].clock, .running(deadline: 109))
        state.expire(now: 108)
        XCTAssertEqual(state.entries.map(\.title), ["second", "third"])
        state.dismiss(state.entries[0].id)
        XCTAssertEqual(state.entries.map(\.title), ["third"])
        state.expire(now: 109)
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertNil(state.deadline)
    }

    func testDisconnectedNewSessionKeepsOnlyTheBanner() throws {
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { owner.close() }
        owner.down("Disconnected", "Retrying", button: nil)
        owner.newSession()
        XCTAssertTrue(owner.notices.testTransients.entries.isEmpty)
        XCTAssertEqual(owner.testBanner.testText.title, "Disconnected")
    }

    func testPersistentConfigDoesNotUseTransientCapacityOrClock() throws {
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let column = Notices(runtime: runtime)
        column.testTime = 10
        column.frame = NSRect(x: 0, y: 0, width: 240, height: 500)
        runtime.testConfigError(.init(path: "/tmp/config.yaml", problem: .init(line: 2, column: 3, message: "bad value")))
        column.showConfig()
        let config = try XCTUnwrap(column.testConfigCard)
        for index in 0..<4 { column.show("Failure \(index)", "detail") }
        XCTAssertEqual(column.testTransients.entries.count, 3)
        XCTAssertEqual(config.frame.width, 208)
        XCTAssertEqual(config.frame.minY, 16)
        column.testTime = 15
        column.testTick()
        XCTAssertTrue(column.testTransients.entries.isEmpty)
        XCTAssertTrue(column.testConfigCard === config)
        XCTAssertEqual(config.frame.minY, 16)
        XCTAssertNil(column.hitTest(NSPoint(x: 2, y: 200)))
    }

    func testDurationUsesWrappedTextAtTheCardWidth() {
        XCTAssertEqual(Notices.testDuration("One short line.", width: 360), 5)
        XCTAssertEqual(Notices.testDuration("One\nTwo\nThree", width: 360), 8)
        let text = "The runtime could not connect to the host. Check its configuration and the key that the agent holds."
        XCTAssertEqual(Notices.testDuration(text, width: 360), 5)
        XCTAssertEqual(Notices.testDuration(text, width: 180), 8)
    }
}
