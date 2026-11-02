import KoClient
import XCTest

@MainActor final class KoProbeTests: KoTestCase {
    func testWelcomeAndLayoutArriveAsMainQueueCallbacksAndNothingFollowsAClose() throws {
        let dir = try server()
        var events: [KoEvent] = []
        let record: (KoEvent) -> Void = { event in
            dispatchPrecondition(condition: .onQueue(.main))
            XCTAssertTrue(Thread.isMainThread)
            events.append(event)
        }
        let connection = try KoConnection(socket: dir + "/socket", sink: record)
        wait("welcome and layout") { events.count >= 2 }
        guard case .welcome(let client, let instance, _, let fresh) = events.first else { return XCTFail("\(events)") }
        XCTAssertTrue(client.hasPrefix("client_"))
        XCTAssertEqual(instance.count, 32)
        XCTAssertTrue(fresh)
        XCTAssertEqual(events[1], .layout(revision: 0, sessions: 0, windows: 0, panes: 0))

        try put(#"{"revision":0,"layout":{"sessions":[{"name":"s","windows":[{"name":"w","tree":{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}}]}]}}"#, dir: dir)
        wait("the created session") { events.count >= 3 }
        XCTAssertEqual(events[2], .layout(revision: 1, sessions: 1, windows: 1, panes: 1))

        connection.close()
        let seen = events.count
        var later: [KoEvent] = []
        let witness = try KoConnection(socket: dir + "/socket") { later.append($0) }
        try put(#"{"revision":1,"layout":{"sessions":[{"id":"session_1","name":"s","windows":[{"id":"window_1","name":"renamed","tree":{"pane":"pane_1"}}]}]}}"#, dir: dir)
        wait("the witness sees the edit") { later.contains(.layout(revision: 2, sessions: 1, windows: 1, panes: 1)) }
        mainQueueDrained()
        witness.close()
        XCTAssertEqual(events.count, seen, "an event after close")
    }

    func testAMissingServerEndsInOneFailedEventOnTheMainQueue() throws {
        var events: [KoEvent] = []
        let connection = try KoConnection(socket: "/tmp/ko-kp-none/socket") { event in
            dispatchPrecondition(condition: .onQueue(.main))
            events.append(event)
        }
        wait("the failure") { !events.isEmpty }
        connection.close()
        guard case .failed(let code, let message) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(code, KO_ERR_NO_SERVER)
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(events.count, 1)
    }

    func testAnEmptySocketPathIsRefusedWithACode() {
        XCTAssertThrowsError(try KoConnection(socket: "") { _ in }) { error in
            XCTAssertEqual((error as? KoError)?.code, KO_ERR_ARGUMENT)
        }
    }
}
