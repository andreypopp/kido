import AppKit
import GhosttyKit
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

extension VisualTests {
    private var imageFixture: String {
        "\u{1b}[2J\u{1b}[H\u{1b}[?25l" +
        "\u{1b}_Ga=T,i=7,f=100,c=8,r=4,C=1,q=2;iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR4nGP4zwAE/wEHAAH/4iOeWQAAAABJRU5ErkJggg==\u{1b}\\" +
        "under image\r\nrow two\r\nrow three\r\nrow four\r\nIMAGE-READY"
    }

    private func imageOutput(_ bytes: String, pane target: PaneView? = nil) async throws {
        let pane = try XCTUnwrap(target ?? terminal?.panes.first)
        try await rawPane(pane)
        try await emit(pane, bytes)
    }

    private func imagePixels(_ pane: PaneView, start: Int64 = 0, end: Int64? = nil) async throws {
        let end = end ?? Int64(ghostty_surface_size(pane.surface).rows)
        try await wait("image pixels filled") {
            var rows = [Bool](repeating: false, count: max(0, Int(end - start)))
            rows.withUnsafeMutableBufferPointer { ghostty_surface_pending_image_rows(pane.surface, start, false, $0.baseAddress, $0.count) }
            return !rows.contains(true)
        }
    }

    private func imageReconnect(ssh: SSH? = nil) async throws {
        let session = try XCTUnwrap(terminal?.superview as? SessionView)
        connection.close(cause: .reconnect)
        window.contentView = session
        let server = Server(tmux: tmux, socket: socket,
                            stamp: ServerStamp("visual"), expected: ServerStamp("visual"))
        connection = try Connection(server: server, view: session,
                                    transport: ssh.map { ssh in { launch in ssh.launch([launch.path] + launch.arguments) } },
                                    host: ssh.map { .remote($0.destination) } ?? .local,
                                    onChange: { session.show($0.window) }, onDiagnostic: { XCTFail($0) }, onClose: { _, _ in })
        try await wait("image reconnect panes") { self.terminal?.panes.isEmpty == false }
        try await settle()
    }

    func testImagesSideBySideRestore() async throws {
        let pair = "\u{1b}[2J\u{1b}[H\u{1b}[?25l\u{1b}[1;21H" +
            "\u{1b}_Ga=T,i=8,f=24,s=1,v=1,c=6,r=3,C=1,q=2;AAD/\u{1b}\\" +
            "\u{1b}[1;4H\u{1b}_Ga=T,i=7,f=24,s=1,v=1,c=6,r=3,C=1,q=2;/wAA\u{1b}\\" +
            "\u{1b}[5;1HIMAGE-READY"
        try await start(initialOutput: pair)
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await imagePixels(pane)
        try await snapshot("side-by-side")
    }

    func testImagesRestorePaths() async throws {
        try await start(history: 30000, initialOutput: imageFixture)
        var pane = try XCTUnwrap(terminal?.panes.first)
        try await imagePixels(pane)
        try await snapshot("restore-attach")

        try await imageOutput(imageFixture)
        try await snapshot("live")
        window.setContentSize(NSSize(width: 740, height: 560))
        try await settle()
        try await imagePixels(pane)
        try await snapshot("restore-resize")
        window.setContentSize(NSSize(width: 700, height: 560))
        try await settle()

        try await imageReconnect()
        pane = try XCTUnwrap(terminal?.panes.first)
        try await imagePixels(pane)
        try await snapshot("restore-reconnect")

        let paused = expectation(description: "main client paused")
        connection.send([Command("refresh-client", "-A", pane.pane.description + ":pause")]) { _ in paused.fulfill() }
        await fulfillment(of: [paused], timeout: 5)
        try await imageOutput(imageFixture)
        connection.send([Command("refresh-client", "-A", pane.pane.description + ":continue")])
        try await restore(pane)
        try await imagePixels(pane)
        try await snapshot("restore-pause")

        let other = try await command(["new-window", "-P", "-F", "#{window_id}", "exec /bin/sleep 600"])
        try await wait("image pane hidden") { pane.isHiddenOrHasHiddenAncestor }
        try await imageOutput(imageFixture, pane: pane)
        try await command(["select-window", "-t", "@0"])
        try await wait("image pane shown") { !pane.isHiddenOrHasHiddenAncestor }
        try await settle()
        try await imagePixels(pane)
        try await snapshot("restore-dirty")
        try await command(["kill-window", "-t", other])

        try await imageOutput(imageFixture + "\u{1b}[?1049halternate program\u{1b}[?25l")
        try await restore(pane)
        try await imagePixels(pane)
        try await snapshot("alternate")
        try await imageOutput("\u{1b}[?1049l\u{1b}[?25l")
        try await imagePixels(pane)
        try await snapshot("alternate-exit")

        pane.toggleCopyMode(nil)
        try await wait("image copy mode") { pane.copyMode != nil }
        try await snapshot("copy-mode")
        pane.endCopy()
        try await wait("image copy mode ended") { pane.copyMode == nil }
        try await settle()
        try await snapshot("copy-mode-exit")

        connection.visualHoldLoad("pixels")
        try await restore(pane)
        try await wait("screen pixel reply held") { self.connection.visualHeld("pixels") }
        try await snapshot("pixel-phase-text")
        connection.visualReleaseLoad("pixels")
        try await imagePixels(pane)
        try await snapshot("pixel-phase-filled")

        connection.visualHoldLoad("pixels")
        try await restore(pane)
        try await wait("old connection pixel reply held") { self.connection.visualHeld("pixels") }
        let old = connection!
        try await imageReconnect()
        old.visualReleaseLoad("pixels")
        pane = try XCTUnwrap(terminal?.panes.first)
        try await imagePixels(pane)
        try await snapshot("reconnect-during-fetch")

        let floating = try await command(["split-window", "-P", "-F", "#{pane_id}", "exec /bin/sleep 600"])
        try await command(["break-pane", "-W", "-s", floating, "-X", "5", "-Y", "0", "-x", "24", "-y", "8"])
        try await wait("image floating pane") { self.terminal?.visualLayout.contains("float %") == true }
        try await settle()
        try await snapshot("float")
        if let float = terminal?.panes.first(where: { $0 !== pane }) { try await command(["kill-pane", "-t", float.pane.description]) }
        try await wait("image floating pane closed") { self.terminal?.panes.count == 1 }

        try await imageOutput("\u{1b}_Ga=d,d=A,q=2\u{1b}\\")
        try await restore(pane)
        try await snapshot("delete")
    }

    func testImagesLazyHistory() async throws {
        try await start(history: 30000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await imageOutput(imageFixture + String(repeating: "\r\nhistory row", count: 100) + "\r\nHISTORY-READY")
        try await restore(pane)
        try await snapshot("lazy-fetch-before")
        pane.requestScroll(100)
        try await wait("history image visible") { pane.scrollPosition().offset < 10 }
        try await imagePixels(pane, start: -110, end: 0)
        try await snapshot("scrollback")
        try await snapshot("lazy-fetch-filled")
        pane.requestScroll(pane.scrollPosition().retainedHistoryRows - 1)
        try await wait("image starts above the grid") { pane.scrollPosition().offset == 1 }
        try await snapshot("top-padding")
        let captures = connection.visualImageCaptures
        pane.requestScroll(0)
        try await wait("image scroll bottom") { pane.scrollPosition().offset == pane.scrollPosition().retainedHistoryRows }
        pane.requestScroll(100)
        try await wait("image scroll back") { pane.scrollPosition().offset < 10 }
        try await snapshot("lazy-fetch-repeat")
        XCTAssertEqual(connection.visualImageCaptures, captures, "fetched rows are not requested twice")

        try await command(["clear-history", "-t", pane.pane.description])
        let deepHistory = imageFixture + String(repeating: "\r\nold history", count: 10100) + "\r\nPREPEND-READY"
        try await imageOutput(deepHistory)
        try await restore(pane)
        pane.requestScroll(historyChunkSize)
        try await wait("load more image pill") { pane.visualPill }
        pane.onLoadMore()
        try await wait("image history prepended") { pane.scrollPosition().retainedHistoryRows > historyChunkSize }
        let distance = deepHistory.utf8.filter { $0 == 10 }.count + 1 - pane.scrollPosition().rows
        pane.requestScroll(distance)
        try await wait("prepended image viewport") {
            let position = pane.scrollPosition()
            return position.retainedHistoryRows - position.offset == distance
        }
        let top = -Int64(distance)
        try await imagePixels(pane, start: top, end: top + Int64(pane.scrollPosition().rows * 3))
        try await snapshot("history-prepend", pill: false)
    }

    func testImagesZeroBoundsDoesNotResizeClient() async throws {
        try await start()
        let zero = SessionView(runtime: runtime)
        let probe = try Connection(server: Server(tmux: tmux, socket: socket, stamp: ServerStamp("visual"), expected: ServerStamp("visual")),
                                   view: zero, onChange: { _ in }, onDiagnostic: { _ in }, onClose: { _, _ in })
        defer { probe.close(cause: .windowClosed) }
        let name: String = try await withCheckedThrowingContinuation { continuation in
            probe.locateFeed { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
        let size = try await command(["list-clients", "-F", "#{client_name} #{client_width} #{client_height}"])
            .split(separator: "\n").map { $0.split(separator: " ") }.first { $0.first == Substring(name) }
        let fields = try XCTUnwrap(size)
        XCTAssertNotEqual(fields.dropFirst().map(String.init), ["1", "1"], "zero bounds must not publish a 1x1 size")
    }

    func testImagesChangedRetryBudget() async throws {
        try await start(initialOutput: imageFixture)
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await imagePixels(pane)
        let finished = connection.visualPixels.withLock { probe in
            probe.replies = [[.failure(["image changed"])], [.success(["more test-token"])], [.failure(["image changed"])],
                             [.success(["more test-token"])], [.failure(["stop test"])]]
            return probe.finished
        }
        let before = connection.visualImageCaptures
        try await restore(pane)
        try await wait("image range stopped") { self.connection.visualPixels.withLock { $0.finished > finished } }
        XCTAssertEqual(connection.visualImageCaptures - before, 3, "one restart must cover the whole paged range")
    }

    func testImagesParserReplies() async throws {
        try await start()
        let pane = try XCTUnwrap(terminal?.panes.first)
        let query = Data(("\u{1b}[c\u{1b}[16t\u{1b}[14t" +
                          "\u{1b}_Ga=q,i=31,s=1,v=1,t=d,f=24;AAAA\u{1b}\\" +
                          "\u{1b}_Ga=T,i=32,s=1,v=1,t=d,f=24;AAAA\u{1b}\\").utf8)
        func record(_ id: String, partial: Bool) async throws -> (Data, URL) {
            let root = directory.appendingPathComponent(UUID().uuidString)
            let script = root.appendingPathExtension("py"), ready = root.appendingPathExtension("ready")
            let release = root.appendingPathExtension("release"), result = root.appendingPathExtension("result")
            let typed = root.appendingPathExtension("typed")
            try """
            import base64, os, select, time, tty
            tty.setraw(0)
            query = base64.b64decode('\(query.base64EncodedString())')
            if \(partial ? "True" : "False"):
                os.write(1, query[:2])
                open(\(String(reflecting: ready.path)), 'w').close()
                end = time.monotonic() + 5
                while not os.path.exists(\(String(reflecting: release.path))) and time.monotonic() < end: time.sleep(0.01)
                os.write(1, query[2:])
            else: os.write(1, query)
            data = b''
            end = time.monotonic() + 3
            while time.monotonic() < end:
                readable, _, _ = select.select([0], [], [], 0.15 if data else 0.1)
                if readable: data += os.read(0, 65536)
                elif data: break
            open(\(String(reflecting: result.path)), 'wb').write(data)
            data = b''
            end = time.monotonic() + 3
            while time.monotonic() < end and b'typed-key' not in data:
                readable, _, _ = select.select([0], [], [], 0.1)
                if readable: data += os.read(0, 65536)
            open(\(String(reflecting: typed.path)), 'wb').write(data)
            time.sleep(30)
            """.write(to: script, atomically: true, encoding: .utf8)
            try await command(["respawn-pane", "-k", "-t", id, "python3 -u " + SSH.quote(script.path)])
            if partial {
                try await wait("query prefix is pending") { FileManager.default.fileExists(atPath: ready.path) }
                try await restore(pane)
                FileManager.default.createFile(atPath: release.path, contents: Data())
            }
            try await wait("parser replies recorded", within: 5) { FileManager.default.fileExists(atPath: result.path) }
            return (try Data(contentsOf: result), typed)
        }
        let hidden = try await command(["new-window", "-d", "-P", "-F", "#{pane_id}", "exec /bin/sleep 600"])
        let (expected, _) = try await record(hidden, partial: false)
        XCTAssertFalse(expected.isEmpty)
        let (live, typed) = try await record(pane.pane.description, partial: false)
        XCTAssertEqual(live, expected, "live input must contain only tmux's replies: \(String(reflecting: String(decoding: live, as: UTF8.self)))")
        connection.sendKeys(pane.pane, Data("typed-key".utf8))
        try await wait("typed input recorded", within: 5) { FileManager.default.fileExists(atPath: typed.path) }
        XCTAssertEqual(try Data(contentsOf: typed), Data("typed-key".utf8))
        let (restored, _) = try await record(pane.pane.description, partial: true)
        XCTAssertEqual(restored, expected, "restore input must contain only tmux's replies")
    }

    func testImagesFocusEvents() async throws {
        try await start(initialOutput: imageFixture)
        rpc?.stop()
        rpc = nil
        let deadline = Date().addingTimeInterval(5)
        while try await command(["list-clients", "-F", "#{client_name}"]).split(separator: "\n").count != 2 {
            guard Date() < deadline else { return XCTFail("main and image client count did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await command(["set-option", "-g", "focus-events", "on"])
        let ready = directory.appendingPathComponent("focus-ready")
        let armed = directory.appendingPathComponent("focus-armed")
        let result = directory.appendingPathComponent("focus-result")
        let script = directory.appendingPathComponent("focus.py")
        try """
        import os, select, time, tty
        tty.setraw(0)
        os.write(1, b'\\x1b[?1004h')
        open(\(String(reflecting: armed.path)), 'w').close()
        end = time.monotonic() + 3
        data = b''
        while time.monotonic() < end and b'\\x1b[I' not in data:
            readable, _, _ = select.select([0], [], [], 0.1)
            if readable: data += os.read(0, 4096)
        open(\(String(reflecting: ready.path)), 'wb').write(data)
        end = time.monotonic() + 10
        data = b''
        open(\(String(reflecting: result.path)), 'wb').write(data)
        while time.monotonic() < end:
            readable, _, _ = select.select([0], [], [], 0.1)
            if readable:
                data += os.read(0, 4096)
                open(\(String(reflecting: result.path)), 'wb').write(data)
        time.sleep(60)
        """.write(to: script, atomically: true, encoding: .utf8)
        try await command(["respawn-pane", "-k", "-t", pane.pane.description, "python3 " + SSH.quote(script.path)])
        try await wait("focus recorder armed") { FileManager.default.fileExists(atPath: armed.path) }
        let original = try XCTUnwrap(currentModel.session)
        let session = try await command(["new-session", "-d", "-s", "image-focus-other", "-P", "-F", "#{session_id}", "exec /bin/sleep 600"])
        connection.send([Command("switch-client", "-t", session)])
        try await wait("main client leaves recorder") { self.currentModel.session?.description == session }
        connection.send([Command("switch-client", "-t", original)])
        try await wait("main client returns to recorder") { self.currentModel.session == original }
        try await wait("focus recorder ready") { FileManager.default.fileExists(atPath: ready.path) }
        XCTAssertTrue(try Data(contentsOf: ready).range(of: Data("\u{1b}[I".utf8)) != nil, "the pane must receive focus-in when the main client returns")
        connection.visualHoldLoad("image-follow")
        defer { connection.visualReleaseLoad("image-follow") }
        connection.send([Command("switch-client", "-t", session)])
        try await wait("image client follow held") { self.connection.visualHeld("image-follow") }
        let before = try await command(["list-clients", "-F", "#{session_id}"]).split(separator: "\n").map(String.init).sorted()
        XCTAssertEqual(before, [original.description, session].sorted(), "the image client must still be on A")
        let focusOut = Data("\u{1b}[O".utf8)
        let beforeDeadline = Date().addingTimeInterval(1)
        while (try? Data(contentsOf: result).range(of: focusOut)) == nil && Date() < beforeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try Data(contentsOf: result).suffix(focusOut.count), focusOut,
                       "P must receive final focus-out BEFORE the image client follows to B")
        connection.visualReleaseLoad("image-follow")
        let afterDeadline = Date().addingTimeInterval(2)
        while try await command(["list-clients", "-F", "#{session_id}"]).split(separator: "\n").map(String.init) != [session, session] {
            guard Date() < afterDeadline else { return XCTFail("image client did not follow to B") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await wait("focus-out after image follow", within: 2) { (try? Data(contentsOf: result).range(of: focusOut)) != nil }
        XCTAssertEqual(try Data(contentsOf: result).suffix(focusOut.count), focusOut,
                       "P must retain final focus-out AFTER the image client follows to B")
    }

    func testImagesRemote() async throws {
        try await start(initialOutput: imageFixture)
        let ssh = try SSH("localhost")
        addTeardownBlock { @MainActor in ssh.stop() }
        _ = try await ssh.start(onLoss: { XCTFail($0.message) })
        try await imageReconnect(ssh: ssh)
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await imagePixels(pane)
        try await snapshot("remote-restore")
        try await imageOutput(imageFixture)
        try await snapshot("remote-live")
    }
}
