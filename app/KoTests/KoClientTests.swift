import KoClient
import KoModel
import XCTest
@testable import Kido

@MainActor final class KoClientTests: KoTestCase {
    func testWelcomeAndLayoutArriveAsMainQueueCallbacksAndNothingFollowsAClose() throws {
        let dir = try server()
        var events: [KoEvent] = []
        let record: (KoEvent) -> Void = { event in
            dispatchPrecondition(condition: .onQueue(.main))
            XCTAssertTrue(Thread.isMainThread)
            events.append(event)
        }
        let connection = try KoClient(socket: dir + "/socket", sink: record)
        wait("welcome and layout") { events.count >= 2 }
        guard case .welcome(let client, let fresh) = events.first else { return XCTFail("\(events)") }
        XCTAssertTrue(client.hasPrefix("client_"))
        XCTAssertTrue(fresh)
        XCTAssertEqual(events[1], .layout(revision: 0))

        try put(#"{"revision":0,"layout":{"sessions":[{"name":"s","windows":[{"name":"w","tree":{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}}]}]}}"#, dir: dir)
        wait("the created session") { events.count >= 3 }
        XCTAssertEqual(events[2], .layout(revision: 1))
        XCTAssertEqual(try connection.model().layout.layout.windows.flatMap(\.panes), [PaneID(number: 1)])

        connection.close()
        let seen = events.count
        var later: [KoEvent] = []
        let witness = try KoClient(socket: dir + "/socket") { later.append($0) }
        try put(#"{"revision":1,"layout":{"sessions":[{"id":"session_1","name":"s","windows":[{"id":"window_1","name":"renamed","tree":{"pane":"pane_1"}}]}]}}"#, dir: dir)
        wait("the witness sees the edit") { later.contains(.layout(revision: 2)) }
        mainQueueDrained()
        witness.close()
        XCTAssertEqual(events.count, seen, "an event after close")
    }

    // The calls run on another thread while the close runs: each one either ends normally or with
    // KO_ERR_CLOSED, and the close returns after the last of them.
    func testACloseDuringBlockingCallsEndsThemAndReturnsAfterThem() throws {
        let dir = try serverWithPane("exec cat")
        let client = try connect(dir) { _ in }
        let codes = Latch()
        nonisolated(unsafe) var outcomes: [ko_code] = []
        let started = Latch()
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                do { try client.delete(KO_DELETE_PANE, PaneID(number: 99)) } catch let error as KoError {
                    outcomes.append(error.code)
                    if error.code == KO_ERR_CLOSED { break }
                } catch { break }
                started.set()
            }
            codes.set()
        }
        wait("a blocking call answered") { started.isSet }
        var closed = false
        client.close { closed = true }
        wait("the close returned") { closed }
        wait("the calls ended") { codes.isSet }
        XCTAssertEqual(outcomes.last, KO_ERR_CLOSED)
        XCTAssertEqual(Set(outcomes), [KO_ERR_NOT_FOUND, KO_ERR_CLOSED], "a call before the close is answered, every later one is refused")
        XCTAssertThrowsError(try client.model()) { XCTAssertEqual(($0 as? KoError)?.code, KO_ERR_CLOSED) }
    }

    func testAMissingServerEndsInOneFailedEventOnTheMainQueue() throws {
        var events: [KoEvent] = []
        let connection = try KoClient(socket: "/tmp/ko-kp-none/socket") { event in
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
        XCTAssertThrowsError(try KoClient(socket: "") { _ in }) { error in
            XCTAssertEqual((error as? KoError)?.code, KO_ERR_ARGUMENT)
        }
    }

    func testLaunchStartsOneServerStopServerEndsItAndTheCoreNamesTheBundledBuild() throws {
        let dir = try stateDir()
        addTeardownBlock { @MainActor in
            try? KoClient.stopServer(dir: dir)
        }
        let executable = tools.ko
        let socket: String
        do { socket = try offMain("the launch") { try KoClient.launch(dir: dir, executable: executable) } } catch { return XCTFail("\(error)") }
        XCTAssertEqual(socket, dir + "/socket")
        let again = try offMain("the second launch") { try KoClient.launch(dir: dir, executable: "/nonexistent/ko") }
        XCTAssertEqual(again, socket, "a running server is reused and the executable is not started")

        var events: [KoEvent] = []
        let client = try KoClient(socket: socket) { events.append($0) }
        wait("welcome") { events.contains { if case .welcome = $0 { true } else { false } } }
        XCTAssertFalse(events.isEmpty, "\(events)")
        client.close()

        let version = Process()
        let output = Pipe()
        version.executableURL = URL(fileURLWithPath: tools.ko)
        version.arguments = ["version"]
        version.standardOutput = output
        try version.run()
        version.waitUntilExit()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let bundled: [String: String]
        do { bundled = try JSONDecoder().decode([String: String].self, from: printed) } catch { return XCTFail("version: \(String(decoding: printed, as: UTF8.self)) \(error)") }
        XCTAssertEqual([bundled["protocol"], bundled["vt"]], [KoClient.version.protocolVersion, KoClient.version.vt], "the core and the bundled ko share one terminal revision")

        do { try offMain("the stop") { try KoClient.stopServer(dir: dir) } } catch { return XCTFail("stop: \(type(of: error)) \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        XCTAssertThrowsError(try KoClient.stopServer(dir: dir)) { XCTAssertEqual(($0 as? KoError)?.code, KO_ERR_IO) }
    }

    func testAServerOfAnotherProtocolOrTerminalRevisionEndsInOneMismatchEventAndNoRetry() throws {
        let own = KoClient.version
        let cases: [(code: ko_code, version: String)] = [
            (KO_ERR_PROTOCOL_MISMATCH, #"{"protocol":"2.0","vt":"\#(own.vt)","build":"theirs"}"#),
            (KO_ERR_VT_MISMATCH, #"{"protocol":"\#(own.protocolVersion)","vt":"abc","build":"theirs"}"#),
        ]
        for (code, version) in cases {
            let dir = try stateDir()
            let server = try KoFakeServer(directory: dir, version: version)
            addTeardownBlock {
                server.stop()
            }
            var events: [KoEvent] = []
            let client = try KoClient(socket: server.socket) { events.append($0) }
            wait("the mismatch") { !events.isEmpty }
            // The core posts nothing after the mismatch: a late event would be queued before the close returns.
            var closed = false
            client.close { closed = true }
            wait("the close returned") { closed }
            let theirs = try JSONDecoder().decode([String: String].self, from: Data(version.utf8))
            XCTAssertEqual(events, [.mismatch(code: code, server: KoVersion(protocolVersion: theirs["protocol"]!, vt: theirs["vt"]!, build: "theirs"), own: own)])
        }
    }
}
