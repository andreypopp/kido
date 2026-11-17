import KoClient
@testable import KoClientKit
import KoModel
import XCTest
import Synchronization
@testable import Kido

@MainActor final class KoClientTests: KoTestCase {
    func testCancelKeepsTheHandleOwnedAndRefusesLaterCalls() async throws {
        let dir = try serverWithPane("exec cat")
        let client = try connect(dir) { _ in }
        XCTAssertEqual(try client.withHandle { ko_client_cancel($0) }, KO_OK)
        XCTAssertEqual(try client.withHandle { ko_client_cancel($0) }, KO_ERR_CLOSED)
        XCTAssertThrowsError(try client.model()) { XCTAssertEqual(($0 as? KoError)?.code, KO_ERR_CLOSED) }
        do { try await Task.detached { try client.delete(KO_DELETE_PANE, PaneID(number: 99)) }.value; XCTFail("cancelled client sent a delete") }
        catch { XCTAssertEqual((error as? KoError)?.code, KO_ERR_CLOSED) }
        let closed = expectation(description: "cancelled handle is closed once")
        client.close { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 2)
    }

    func testCloseRefusesAnAdmittedCallThatHasNotEnteredC() async throws {
        let dir = try serverWithPane("exec cat")
        let client = try connect(dir) { _ in }
        let admitted = Latch(), entered = Latch(), proceed = DispatchSemaphore(value: 0)
        client.testCallHook { phase in
            switch phase {
            case .admitted: admitted.set(); _ = proceed.wait(timeout: .now() + 5)
            case .entering: entered.set()
            }
        }
        defer { client.testCallHook(nil); proceed.signal() }
        let call = Task.detached { try client.delete(KO_DELETE_PANE, PaneID(number: 99)) }
        await Task.yield()
        wait("the call is admitted before C entry") { admitted.isSet }
        let closed = expectation(description: "close returned")
        client.close { closed.fulfill() }
        client.testCallHook(nil)
        proceed.signal()
        do { try await call.value; XCTFail("admitted call succeeded after close") }
        catch { XCTAssertEqual((error as? KoError)?.code, KO_ERR_CLOSED) }
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertFalse(entered.isSet)
    }

    func testCloseInterruptsAnUploadWhoseServerStoppedReading() async throws {
        let config = try stateDir()
        try FileManager.default.createDirectory(atPath: config + "/ko", withIntermediateDirectories: false)
        let gate = config + "/gate", ready = config + "/ready"
        XCTAssertEqual(mkfifo(gate, 0o600), 0)
        let release = try XCTUnwrap(FileHandle(forUpdatingAtPath: gate))
        defer { try? release.close() }
        let script = "if [ \"$3\" = --exec ]; then : > \(SSH.quote(ready)); read answer < \(SSH.quote(gate)); fi; exec \"$@\""
        let configuration: [String: Any] = ["runtimes": ["blocked": ["command": ["prefix": ["/bin/sh", "-c", script, "upload-gate"]]]]]
        try JSONSerialization.data(withJSONObject: configuration).write(to: URL(fileURLWithPath: config + "/ko/config.yaml"))
        let dir = try server(environment: ["XDG_CONFIG_HOME": config, "KO_RUNTIME_COMMAND_KIND": "1"])
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"s","windows":[{"name":"w","tree":{"pane":{"new":{"runtime":"blocked","command":{"type":"argv","argv":["/bin/cat"]}}}}}]}]}}"#, dir: dir)
        let client = try connect(dir) { _ in }
        let reads = Mutex(0)
        let upload = Task {
            try await client.upload(pane: PaneID(number: 1), name: "blocked", size: 64 << 20) { buffer in
                reads.withLock { $0 += 1 }
                _ = buffer.initializeMemory(as: UInt8.self, repeating: 0x61)
                return buffer.count
            }
        }
        await Task.yield()
        wait("the upload helper blocks before reading") { FileManager.default.fileExists(atPath: ready) && reads.withLock { $0 > 0 } }
        let closed = Latch(), finished = expectation(description: "close cancels the blocked upload")
        client.close { closed.set(); finished.fulfill() }
        XCTAssertThrowsError(try client.model()) { XCTAssertEqual(($0 as? KoError)?.code, KO_ERR_CLOSED) }
        await fulfillment(of: [finished], timeout: 2)
        let interrupted = closed.isSet
        if !interrupted { upload.cancel() }
        try release.write(contentsOf: Data("go\n".utf8))
        do { _ = try await upload.value; XCTFail("closed upload succeeded") }
        catch { XCTAssertEqual((error as? KoError)?.code, KO_ERR_CLOSED) }
        XCTAssertTrue(interrupted)
    }

    func testUploadStreamsTheDeclaredBytesAndReturnsTheServerPath() async throws {
        let dir = try serverWithPane("exec cat")
        let client = try connect(dir) { _ in }
        let size = (2 << 20) + 17
        let path = try await client.upload(pane: PaneID(number: 1), name: "bytes.bin", size: UInt64(size)) { buffer in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertLessThanOrEqual(buffer.count, 65536)
            _ = buffer.initializeMemory(as: UInt8.self, repeating: 0x61)
            return buffer.count
        }
        XCTAssertTrue(path.hasPrefix(dir + "/drops/"), path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(repeating: 0x61, count: size))
        do {
            _ = try await client.upload(pane: PaneID(number: 99), name: "missing", size: 0) { _ in XCTFail("zero-byte upload read its reader"); return nil }
            XCTFail("missing pane upload succeeded")
        } catch {
            XCTAssertEqual((error as? KoError)?.code, KO_ERR_REFUSED)
            XCTAssertEqual((error as? KoError)?.detail, "pane not found")
        }
    }

    func testZeroByteUploadAndInvalidReaderCounts() async throws {
        let dir = try serverWithPane("exec cat")
        let client = try connect(dir) { _ in }
        let empty = try await client.upload(pane: PaneID(number: 1), name: "empty", size: 0) { _ in XCTFail("empty upload invoked reader"); return nil }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: empty)), Data())
        let drops = dir + "/drops"
        let partials = { ((try? FileManager.default.contentsOfDirectory(atPath: drops)) ?? []).filter { $0.hasPrefix(".") } }
        for tooLarge in [false, true] {
            let proceed = DispatchSemaphore(value: 0)
            let upload = Task {
                try await client.upload(pane: PaneID(number: 1), name: "bad-count", size: 1) { buffer in
                    guard proceed.wait(timeout: .now() + 5) == .success else { return nil }
                    return tooLarge ? buffer.count + 1 : 0
                }
            }
            await Task.yield()
            wait("invalid-count upload created a partial") { !partials().isEmpty }
            proceed.signal()
            do { _ = try await upload.value; XCTFail("invalid reader count succeeded") }
            catch { XCTAssertEqual((error as? KoError)?.code, KO_ERR_IO) }
            wait("invalid-count upload removed its partial") { partials().isEmpty }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drops).count, 1)
        }
    }

    func testUploadPreservesAnEarlyQuotaRefusalWhileTheBodyIsStillBeingWritten() async throws {
        let dir = try serverWithPane("exec cat")
        let client = try connect(dir) { _ in }
        let supplied = Mutex(0)
        let size: UInt64 = (2 << 30) + 1
        do {
            _ = try await client.upload(pane: PaneID(number: 1), name: "quota", size: size) { buffer in
                supplied.withLock { $0 += buffer.count }
                _ = buffer.initializeMemory(as: UInt8.self, repeating: 0x71)
                return buffer.count
            }
            XCTFail("oversized upload succeeded")
        } catch {
            XCTAssertEqual((error as? KoError)?.code, KO_ERR_REFUSED)
            XCTAssertEqual((error as? KoError)?.detail, "ko drop: drops exceed 2 GiB")
        }
        XCTAssertLessThan(UInt64(supplied.withLock { $0 }), size)
    }

    func testUploadReaderRefusalAndTaskCancellationRemovePartialFiles() async throws {
        let dir = try serverWithPane("exec cat")
        let client = try connect(dir) { _ in }
        let drops = dir + "/drops"
        for cancelTask in [false, true] {
            let calls = Mutex(0)
            let proceed = DispatchSemaphore(value: 0)
            let upload = Task {
                try await client.upload(pane: PaneID(number: 1), name: "cancel.bin", size: 2 << 20) { buffer in
                    let call = calls.withLock { value in defer { value += 1 }; return value }
                    if call > 0 {
                        guard proceed.wait(timeout: .now() + 5) == .success else { return nil }
                        return cancelTask ? buffer.count : nil
                    }
                    _ = buffer.initializeMemory(as: UInt8.self, repeating: 0x62)
                    return buffer.count
                }
            }
            await Task.yield()
            wait("the upload wrote its first chunk") {
                ((try? FileManager.default.contentsOfDirectory(atPath: drops)) ?? []).contains { name in
                    guard name.hasPrefix("."), let file = try? FileManager.default.attributesOfItem(atPath: drops + "/" + name + "/cancel.bin") else { return false }
                    return (file[.size] as? NSNumber)?.intValue == 65536
                }
            }
            if cancelTask { upload.cancel() }
            proceed.signal()
            do { _ = try await upload.value; XCTFail("cancelled upload succeeded") }
            catch { XCTAssertEqual((error as? KoError)?.code, KO_ERR_CLOSED) }
            wait("the partial upload was removed") { (try? FileManager.default.contentsOfDirectory(atPath: drops))?.isEmpty == true }
        }
    }

    func testWelcomeAndLayoutArriveAsMainQueueCallbacksAndNothingFollowsAClose() throws {
        let dir = try server()
        var events: [KoEvent] = []
        let record: (KoEvent) -> Void = { event in
            dispatchPrecondition(condition: .onQueue(.main))
            XCTAssertTrue(Thread.isMainThread)
            events.append(event)
        }
        let connection = try KoClient.connect(endpoint: .unix(dir + "/socket"), sink: record)
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
        let witness = try KoClient.connect(endpoint: .unix(dir + "/socket")) { later.append($0) }
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
        let connection = try KoClient.connect(endpoint: .unix("/tmp/ko-kp-none/socket")) { event in
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
        XCTAssertThrowsError(try KoClient.connect(endpoint: .unix("")) { _ in }) { error in
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
        do { socket = try offMain("the launch") { try KoClient.launch(dir: dir, executable: executable, path: nil, cwd: nil) } } catch { return XCTFail("\(error)") }
        XCTAssertEqual(socket, dir + "/socket")
        let again = try offMain("the second launch") { try KoClient.launch(dir: dir, executable: "/nonexistent/ko", path: nil, cwd: nil) }
        XCTAssertEqual(again, socket, "a running server is reused and the executable is not started")

        var events: [KoEvent] = []
        let client = try KoClient.connect(endpoint: .unix(socket)) { events.append($0) }
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
        XCTAssertEqual([bundled["protocol"], bundled["vt"]], [KoClient.version.`protocol`, KoClient.version.vt], "the core and the bundled ko share one terminal revision")

        do { try offMain("the stop") { try KoClient.stopServer(dir: dir) } } catch { return XCTFail("stop: \(type(of: error)) \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        XCTAssertThrowsError(try KoClient.stopServer(dir: dir)) { XCTAssertEqual(($0 as? KoError)?.code, KO_ERR_IO) }
    }

    func testAServerOfAnotherProtocolOrTerminalRevisionEndsInOneMismatchEventAndNoRetry() throws {
        let own = KoClient.version
        let cases: [(code: ko_code, version: String)] = [
            (KO_ERR_PROTOCOL_MISMATCH, #"{"protocol":"2.0","vt":"\#(own.vt)","build":"theirs"}"#),
            (KO_ERR_VT_MISMATCH, #"{"protocol":"\#(own.`protocol`)","vt":"abc","build":"theirs"}"#),
        ]
        for (code, version) in cases {
            let dir = try stateDir()
            let server = try KoFakeServer(directory: dir, version: version)
            addTeardownBlock {
                server.stop()
            }
            var events: [KoEvent] = []
            let client = try KoClient.connect(endpoint: .unix(server.socket)) { events.append($0) }
            wait("the mismatch") { !events.isEmpty }
            // The core posts nothing after the mismatch: a late event would be queued before the close returns.
            var closed = false
            client.close { closed = true }
            wait("the close returned") { closed }
            let theirs = try JSONDecoder().decode([String: String].self, from: Data(version.utf8))
            XCTAssertEqual(events, [.mismatch(code: code, server: KoSchema.Version(build: "theirs", protocol: theirs["protocol"]!, vt: theirs["vt"]!), own: own)])
        }
    }
}
