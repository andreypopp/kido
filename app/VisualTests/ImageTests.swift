import AppKit
import GhosttyKit
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

private let imageClear = "\u{1b}[2J\u{1b}[H\u{1b}[?25l"

extension VisualTests {
    private var imageFixture: String {
        imageClear +
        "\u{1b}_Ga=T,i=7,f=100,c=8,r=4,C=1,q=2;iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR4nGP4zwAE/wEHAAH/4iOeWQAAAABJRU5ErkJggg==\u{1b}\\" +
        "under image\r\nrow two\r\nrow three\r\nrow four\r\nIMAGE-READY"
    }

    private func imageDelivery(_ action: Connection.VisualOutput) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.visualOutput(action) { continuation.resume() }
        }
    }

    private func imageSharedMemory(_ action: String, _ name: String, rgba: [UInt8] = [255, 0, 0, 255]) async throws -> Int32 {
        let script = """
        import ctypes, json, mmap, os, sys, time
        libc = ctypes.CDLL(None)
        libc.shm_open.argtypes = [ctypes.c_char_p, ctypes.c_int]
        if sys.argv[1] in ('create', 'create-batch'):
            images = json.loads(sys.argv[2]) if sys.argv[1] == 'create-batch' else {sys.argv[2]: list(map(int, sys.argv[3].split(',')))}
            for key, rgba in images.items():
                fd = libc.shm_open(key.encode(), os.O_CREAT | os.O_EXCL | os.O_RDWR, ctypes.c_uint(0o600))
                if fd < 0: sys.exit(1)
                os.ftruncate(fd, 16)
                with mmap.mmap(fd, 16) as pixels: pixels[:] = bytes(rgba) * 4
                os.close(fd)
            sys.exit(0)
        name = sys.argv[2].encode()
        if sys.argv[1] == 'remove':
            libc.shm_unlink(name)
            sys.exit(0)
        if sys.argv[1] in ('wait-gone', 'wait-gone-batch'):
            names = json.loads(sys.argv[2]) if sys.argv[1] == 'wait-gone-batch' else [sys.argv[2]]
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                remaining = []
                for key in names:
                    fd = libc.shm_open(key.encode(), os.O_RDONLY)
                    if fd >= 0:
                        os.close(fd)
                        remaining.append(key)
                if not remaining: sys.exit(0)
                names = remaining
                time.sleep(0.01)
            sys.exit(2)
        fd = libc.shm_open(name, os.O_RDONLY)
        if fd < 0: sys.exit(1)
        os.close(fd)
        """
        return try await Child.run("/usr/bin/env", ["python3", "-c", script, action, name, rgba.map(String.init).joined(separator: ",")]).0
    }

    private func imageOutput(_ bytes: String, pane target: PaneView? = nil) async throws {
        let pane = try XCTUnwrap(target ?? terminal?.panes.first)
        try await rawPane(pane)
        try await emit(pane, bytes)
    }

    private func imagePixels(_ pane: PaneView, start: Int64 = 0, end: Int64? = nil) async throws {
        let end = end ?? Int64(ghostty_surface_size(pane.surface).rows)
        try await wait("image pixels filled") {
            !pane.pendingImageRows(start: start, count: max(0, Int(end - start)), alternate: false).contains(true)
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

    func testImagesPlacementRestore() async throws {
        try await start()
        let fixture = imageClear +
            "\u{1b}_Ga=T,i=7,f=24,s=1,v=1,c=22,r=4,C=1,z=-1,q=2;/wAA\u{1b}\\" +
            "TEXT ABOVE RED IMAGE\r\nTEXT BEHIND BLUE IMAGE" +
            "\u{1b}[2;6H\u{1b}_Ga=T,i=8,f=24,s=1,v=1,c=8,r=2,C=1,z=4,q=2;AAD/\u{1b}\\" +
            "\u{1b}[6;1HZ ORDER\u{1b}[1;30H" +
            "\u{1b}_Ga=T,f=24,s=1,v=1,c=12,r=4,C=1,q=2;/wD/\u{1b}\\" +
            "\u{1b}[6;30HNO CLIENT ID\u{1b}[8;1H" +
            "\u{1b}_Ga=T,i=9,f=100,X=3,Y=5,C=1,q=2;iVBORw0KGgoAAAANSUhEUgAAALsAAABJCAIAAADqqMAvAAAAmUlEQVR42u3SQQ0AAAgDsflXgVNmgTdpUgWXy07gTgIcg2NwDI7BMeAYHINjcAyOwTHgGByDY3AMjgHH4Bgcg2NwDI4Bx+AYHINjcAyOUQHH4Bgcg2NwDDgGx+AYHINjcAw4BsfgGByDY8AxOAbH4Bgcg2PAMTgGx+AYHINjwDE4BsfgGBwDjsExOAbH4BgcA47BMTgGx/BVAWdwdphSq8KeAAAAAElFTkSuQmCC\u{1b}\\" +
            "\u{1b}[12;1HNATIVE 187 x 73 PIXELS"
        try await imageOutput(fixture)
        try await snapshot("live")
        try await imageReconnect()
        try await imagePixels(try XCTUnwrap(terminal?.panes.first))
        try await snapshot("restored")

        func imageIDs(_ capture: String) -> [UInt32] {
            capture.components(separatedBy: "\u{1b}_Ga=p,i=").dropFirst().compactMap {
                UInt32($0.prefix(while: \.isNumber))
            }
        }
        let target = try XCTUnwrap(terminal?.panes.first).pane.description
        let capture = try await command(["capture-pane", "-p", "-G", "-t", target])
        let synthetic = try XCTUnwrap(imageIDs(capture).first { $0 >= 0x80000000 })
        try await imageOutput("\u{1b}[13;30H\u{1b}_Ga=T,i=\(synthetic),f=24,s=1,v=1,c=12,r=4,C=1,q=2;AP//\u{1b}\\\u{1b}[18;30HCOLLIDING CLIENT ID")
        try await snapshot("colliding-id")
        let capturedIDs = imageIDs(try await command(["capture-pane", "-p", "-G", "-t", target]))
        XCTAssertTrue(capturedIDs.contains(synthetic))
        XCTAssertTrue(capturedIDs.contains { $0 >= 0x80000000 && $0 != synthetic })

        try await imageOutput("\u{1b}[20;30H\u{1b}_Ga=T,i=10,f=24,s=1,v=1,c=12,r=4,C=1,q=2;AP8A\u{1b}\\\u{1b}[25;30HNORMAL CLIENT ID")
        try await snapshot("normal-id")
    }

    func testImagesSideBySideRestore() async throws {
        let pair = imageClear + "\u{1b}[1;21H" +
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

    func testImagesSharedMemoryRecovery() async throws {
        let pane = try await rawPane()
        let objects = (0..<5).map { _ in "/kr-" + UUID().uuidString.prefix(16) }
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 255, 255], [255, 0, 255, 255], [0, 255, 0, 255], [0, 0, 255, 255]]
        let batch = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: zip(objects, colors)))
        let created = try await imageSharedMemory("create-batch", String(decoding: batch, as: UTF8.self))
        XCTAssertEqual(created, 0)
        for name in objects { addTeardownBlock { @MainActor in _ = try? await self.imageSharedMemory("remove", name) } }
        func resetScene() async throws {
            try await imageOutput("\u{1b}_Ga=d,d=A,q=2\u{1b}\\" + imageClear + "\u{1b}[3J")
            try await restore(pane)
            try await imagePixels(pane)
        }
        try await resetScene()
        try await settle()
        let queries = pane.visualPendingQueries.withLock { $0 }
        try await imageOutput("TEXT ONLY")
        XCTAssertEqual(pane.visualPendingQueries.withLock { $0 }, queries, "plain output must not query image rows")
        for implicit in [false, true] {
            try await resetScene()
            await imageDelivery(.hold)
            let first = objects[implicit ? 2 : 0]
            let firstPayload = Data(first.utf8).base64EncodedString()
            let id = implicit ? "" : "i=7,"
            let action = implicit ? "T" : "t"
            let placement = implicit ? "" : "\u{1b}_Ga=p,i=7,c=8,r=4,C=1,q=2\u{1b}\\"
            try await imageOutput("\u{1b}_Ga=d,d=A,q=2\u{1b}\\" + imageClear + "\u{1b}_Ga=\(action),\(id)t=s,f=32,s=4,v=1,c=8,r=4,C=1,q=2;\(firstPayload)\u{1b}\\" + placement + "\u{1b}[6;1HSHARED MEMORY RECOVERED")
            var originals = [first]
            if !implicit {
                let latest = objects[1]
                originals.append(latest)
                let payload = Data(latest.utf8).base64EncodedString()
                try await imageOutput("\u{1b}[1;1H\u{1b}_Ga=T,i=7,t=s,f=32,s=4,v=1,c=8,r=4,C=1,q=2;\(payload)\u{1b}\\")
            }
            let names = try JSONSerialization.data(withJSONObject: originals)
            let gone = try await imageSharedMemory("wait-gone-batch", String(decoding: names, as: UTF8.self))
            XCTAssertEqual(gone, 0)
            let clients = try await command(["list-clients", "-F", "#{client_flags}"])
            XCTAssertEqual(clients.split(separator: "\n").filter { $0.contains("image-shm") }.count, 2)
            let captures = connection.visualImageCaptures, restores = connection.visualRestores
            let finished = connection.visualPixels.withLock { $0.finished }
            await imageDelivery(.release)
            try await wait("one shared memory fetch completed") { self.connection.visualPixels.withLock { $0.finished } > finished }
            try await imagePixels(pane)
            try await snapshot(implicit ? "implicit-repaired" : "explicit-latest-recovered")
            XCTAssertEqual(connection.visualImageCaptures - captures, 1,
                           "implicit=\(implicit), requests=\(connection.visualPixels.withLock { Array($0.requests.dropFirst(captures)) })")
            XCTAssertEqual(connection.visualRestores - restores, implicit ? 1 : 0)
        }
        try await resetScene()
        await imageDelivery(.hold)
        let deferredName = objects[3]
        let deferredPayload = Data(deferredName.utf8).base64EncodedString()
        try await imageOutput("\u{1b}_Ga=d,d=A,q=2\u{1b}\\" + imageClear + "\u{1b}_Ga=t,i=8,t=s,f=32,s=4,v=1,q=2;\(deferredPayload)\u{1b}\\\u{1b}[6;1HPLACED AFTER THE FAILED TRANSMIT")
        let deferredGone = try await imageSharedMemory("wait-gone", deferredName)
        XCTAssertEqual(deferredGone, 0)
        let deferredCaptures = connection.visualImageCaptures
        await imageDelivery(.release)
        try await roundTrip()
        XCTAssertEqual(connection.visualImageCaptures, deferredCaptures)
        let deferredFinished = connection.visualPixels.withLock { $0.finished }
        try await imageOutput("\u{1b}[1;1H\u{1b}_Ga=p,i=8,c=8,r=4,C=1,q=2\u{1b}\\")
        try await wait("deferred placement filled") { self.connection.visualPixels.withLock { $0.finished } > deferredFinished }
        try await imagePixels(pane)
        try await snapshot("placed-later")
        XCTAssertEqual(connection.visualImageCaptures - deferredCaptures, 1)

        try await resetScene()
        await imageDelivery(.hold)
        let pausedName = objects[4]
        let pausedPayload = Data(pausedName.utf8).base64EncodedString()
        try await imageOutput("\u{1b}_Ga=d,d=A,q=2\u{1b}\\" + imageClear + "\u{1b}_Ga=T,i=9,t=s,f=32,s=4,v=1,c=8,r=4,C=1,q=2;\(pausedPayload)\u{1b}\\\u{1b}[6;1HPAUSE REPAIR")
        let gone = try await imageSharedMemory("wait-gone", pausedName)
        XCTAssertEqual(gone, 0)
        let pauses = connection.visualPauses
        let paused = expectation(description: "control client paused")
        connection.send([Command("refresh-client", "-A", pane.pane.description + ":pause")]) { _ in paused.fulfill() }
        await fulfillment(of: [paused], timeout: 5)
        try await wait("pause notification") { self.connection.visualPauses > pauses }
        let repaired = expectation(description: "pause repair captured")
        connection.sync(pane.pane) { repaired.fulfill() }
        await fulfillment(of: [repaired], timeout: 20)
        await imageDelivery(.drop)
        try await imagePixels(pane)
        try await snapshot("pause-repaired")
    }

    func testImagesAnimationRestore() async throws {
        try await start()
        let pane = try XCTUnwrap(terminal?.panes.first)
        let testName = #function
        func capture(_ name: String, color: Int) async throws {
            let presented = expectation(description: "animation frame presented")
            pane.visualFrame { status in
                XCTAssertEqual(status, GHOSTTY_RENDER_PRESENTATION_PRESENTED)
                presented.fulfill()
            }
            await fulfillment(of: [presented], timeout: 10)
            try await wait("\(name) installed pixels", within: 3) { frameColor() == color }
            let image = try XCTUnwrap(pane.renderedImage)
            let view = NSImageView(frame: pane.bounds)
            view.wantsLayer = true
            view.layer?.backgroundColor = pane.paperColor.cgColor
            view.image = NSImage(cgImage: image, size: pane.bounds.size)
            try await snapshot(name, testName: testName, view: view)
        }
        try await imageOutput(imageClear + "\u{1b}_Ga=T,i=61,f=32,s=1,v=1,c=8,r=4,C=1,q=2;/wAA/w==\u{1b}\\" +
                              "\u{1b}_Ga=f,i=61,f=32,s=1,v=1,X=1,z=200,q=2;AP8A/w==\u{1b}\\" +
                              "\u{1b}_Ga=f,i=61,f=32,s=1,v=1,X=1,z=200,q=2;AAD//w==\u{1b}\\" +
                              "\u{1b}_Ga=a,i=61,r=1,z=200,c=2,s=1,v=1,q=2\u{1b}\\\u{1b}[6;1HANIMATION: FRAME TWO")
        try await capture("parked-live", color: 1)
        try await restore(pane)
        try await imagePixels(pane)
        try await capture("parked-restored", color: 1)
        try await imageOutput("\u{1b}_Ga=f,i=61,r=1,f=32,s=1,v=1,X=1,q=2;AP///w==\u{1b}\\" +
                              "\u{1b}_Ga=a,i=61,c=1,s=1,q=2\u{1b}\\\u{1b}[6;1H\u{1b}[2KEDITED FRAME ONE")
        try await capture("edited-live", color: 0)
        try await restore(pane)
        try await imagePixels(pane)
        try await capture("edited-restored", color: 0)
        func frameColor() -> Int? {
            pane.visualFrame { _ in }
            guard let pixels = pane.renderedPixels else { return nil }
            return pixels.withUnsafeBytes { bytes in
                let data = bytes.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: data.count - 3, by: 4) {
                    if data[offset] > 240 && data[offset + 1] > 240 && data[offset + 2] < 15 { return 0 }
                    if data[offset + 1] > 240 && data[offset] < 15 && data[offset + 2] < 15 { return 1 }
                    if data[offset] > 240 && data[offset + 1] < 15 && data[offset + 2] < 15 { return 2 }
                }
                return nil
            }
        }
        try await imageOutput("\u{1b}_Ga=a,i=61,c=2,s=3,v=1,q=2\u{1b}\\")
        try await wait("live animation reaches green", within: 3) { frameColor() == 1 }
        try await wait("live animation advances to blue", within: 3) { frameColor() == 2 }
        try await restore(pane)
        try await imagePixels(pane)
        try await wait("restored animation reaches green", within: 3) { frameColor() == 1 }
        try await wait("restored animation advances to blue", within: 3) { frameColor() == 2 }
        try await imageOutput("\u{1b}_Ga=a,i=61,c=3,s=1,q=2\u{1b}\\\u{1b}[6;1H\u{1b}[2KANIMATION ADVANCED AFTER RESTORE")
        try await capture("advanced-after-restore", color: 2)
    }

    func testImagesMediaPolicy() async throws {
        try await start()
        let localName = "/kido-" + UUID().uuidString.prefix(16)
        addTeardownBlock { @MainActor in _ = try? await self.imageSharedMemory("remove", localName) }
        let localStatus = try await imageSharedMemory("create", localName)
        XCTAssertEqual(localStatus, 0)
        let localPayload = Data(localName.utf8).base64EncodedString()
        try await imageOutput(imageClear + "\u{1b}_Ga=T,i=7,t=s,f=32,s=1,v=1,c=8,r=4,C=1,q=2;\(localPayload)\u{1b}\\\u{1b}[6;1HLOCAL SHARED MEMORY")
        try await imagePixels(try XCTUnwrap(terminal?.panes.first))
        try await snapshot("local-shm")
        let localExists = try await imageSharedMemory("exists", localName)
        XCTAssertEqual(localExists, 1)


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
        let remoteName = "/kido-" + UUID().uuidString.prefix(16)
        addTeardownBlock { @MainActor in _ = try? await self.imageSharedMemory("remove", remoteName) }
        let file = directory.appendingPathComponent("local-image.rgba")
        try Data([0, 255, 0, 255]).write(to: file)
        let filePayload = Data(file.path.utf8).base64EncodedString()
        let remotePayload = Data(remoteName.utf8).base64EncodedString()
        let captures = connection.visualImageCaptures
        await imageDelivery(.hold)
        try await imageOutput("\u{1b}_Ga=d,d=A,q=2\u{1b}\\" + imageClear + "\u{1b}_Ga=T,i=12,t=s,f=32,s=1,v=1,c=8,r=4,C=1,q=2;\(remotePayload)\u{1b}\\" +
                              "\u{1b}[1;12H\u{1b}_Ga=T,i=13,t=f,f=32,s=1,v=1,c=8,r=4,C=1,q=2;\(filePayload)\u{1b}\\" +
                              "\u{1b}[1;24H\u{1b}_Ga=T,i=14,t=t,f=32,s=1,v=1,c=8,r=4,C=1,q=2;\(filePayload)\u{1b}\\" +
                              "\u{1b}[1;36H\u{1b}_Ga=T,i=15,f=32,s=1,v=1,c=8,r=4,C=1,q=2;AAD//w==\u{1b}\\\u{1b}[6;1HREMOTE: ONLY DIRECT BLUE IMAGE")
        let remoteStatus = try await imageSharedMemory("create", remoteName)
        XCTAssertEqual(remoteStatus, 0)
        await imageDelivery(.release)
        try await imagePixels(try XCTUnwrap(terminal?.panes.first))
        try await snapshot("remote-local-media-blocked")
        let remoteExists = try await imageSharedMemory("exists", remoteName)
        XCTAssertEqual(remoteExists, 0, "remote media must not unlink the local object")
        XCTAssertEqual(connection.visualImageCaptures, captures,
                       "blocked media must not fetch: \(connection.visualPixels.withLock { Array($0.requests.dropFirst(captures)) })")
        XCTAssertEqual(try Data(contentsOf: file), Data([0, 255, 0, 255]))
    }
}
