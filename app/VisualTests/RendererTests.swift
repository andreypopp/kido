import AppKit
import Darwin
import GhosttyKit
import IOSurface
import SnapshotTesting
import Synchronization
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class RendererTests: VisualTestCase {
    private var runtime: GhosttyRuntime!
    private var config: URL!
    private var board: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        config = URL(fileURLWithPath: "/tmp/kido-renderer-\(UUID().uuidString).conf")
        try "cursor-style-blink = false\ncustom-shader-animation = false\nwindow-vsync = true\n".write(to: config, atomically: true, encoding: .utf8)
        board = NSPasteboard(name: .init("kido-renderer-\(UUID().uuidString)"))
        runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        PaneView.renderOffscreen = true
    }

    override func tearDown() async throws {
        runtime = nil
        board?.releaseGlobally()
        PaneView.renderOffscreen = false
        try? FileManager.default.removeItem(at: config)
    }

    private func probe<F>(_ name: String, _ type: F.Type) throws -> F {
        unsafeBitCast(try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)), to: type)
    }

    private func makePane(windowed: Bool = false) throws -> (pane: PaneView, window: NSWindow?) {
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { _ in })
        let window = windowed ? NSWindow(contentRect: pane.bounds, styleMask: .borderless, backing: .buffered, defer: false) : nil
        window?.isReleasedWhenClosed = false
        window?.contentView = pane
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        return (pane, window)
    }

    private func capture(_ client: Client, _ commands: [Command]) async throws -> [Reply] {
        let done = expectation(description: "capture replies")
        let result = Mutex<[Reply]?>(nil)
        client.send(commands) { replies in
            result.withLock { $0 = replies }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        return try XCTUnwrap(result.withLock { $0 })
    }

    private func replay(_ client: Client, _ pane: PaneID, loaded: Int = 0, chunk: Int = historyChunkSize, initial: Bool = false) async throws -> (replies: [Reply], history: HistoryCapture) {
        let done = expectation(description: "replay captured")
        let result = Mutex<(replies: [Reply], history: HistoryCapture?)?>(nil)
        HistoryCapture.capture(client, pane, loaded: loaded, chunk: chunk, initial: initial,
                               last: initial ? PaneSync.commands(pane, chunk: chunk) : []) { captured in
            result.withLock { $0 = captured }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        let captured = try XCTUnwrap(result.withLock { $0 })
        return (captured.replies, try XCTUnwrap(captured.history))
    }

    private func sync(_ client: Client, _ pane: PaneID, chunk: Int = historyChunkSize) async throws -> (PaneSync.Snapshot, HistoryCapture) {
        let captured = try await replay(client, pane, chunk: chunk, initial: true)
        return (try XCTUnwrap(PaneSync.restore(captured.replies, history: captured.history)), captured.history)
    }

    private func replayServer(columns: Int, rows: Int) async throws -> (tmux: String, dir: URL, socket: String, client: Client) {
        let tmux = try XCTUnwrap(serverEnvironment["KIDO_TMUX"])
        let dir = URL(fileURLWithPath: "/tmp/ka-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let socket = dir.appendingPathComponent("socket").path
        let started = try await Child.run(tmux, ["-u", "-S", socket, "-f", "/dev/null", "new-session", "-d", "-x", String(columns), "-y", String(rows), "sleep 60"])
        XCTAssertEqual(started.status, 0, started.err)
        addTeardownBlock {
            _ = try await Child.run(tmux, ["-S", socket, "kill-session"])
            try FileManager.default.removeItem(at: dir)
        }
        let client = Client(launch: .attachImages(tmux, socket: socket, session: SessionID(number: 0), imageShm: false))
        try client.start(onEvent: { _ in }, onClose: { _, _ in })
        addTeardownBlock { client.close() }
        return (tmux, dir, socket, client)
    }

    private func replayPanes(_ fixture: String, snapshot: PaneSync.Snapshot, recent: PaneSync.Snapshot, older: HistoryCapture, columns: Int, rows: Int, windowed: Bool = false) async throws -> [(pane: PaneView, window: NSWindow?)] {
        let surfaces = try (0..<3).map { _ in try makePane(windowed: windowed) }
        await mainQueueFence()
        for (pane, _) in surfaces {
            pane.resize(cols: columns, rows: rows)
            pane.frame.size = CGSize(width: pane.cell.width * CGFloat(columns), height: pane.cell.height * CGFloat(rows))
            XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        }
        let panes = surfaces.map(\.pane)
        XCTAssertTrue(panes[0].feed(Data(fixture.utf8)))
        XCTAssertTrue(panes[1].feed(snapshot.data, kind: .snapshot))
        XCTAssertTrue(panes[2].feed(recent.data, kind: .snapshot))
        XCTAssertTrue(panes[2].commitSnapshot(epoch: panes[2].historyEpoch))
        if older.rows > 0 { XCTAssertGreaterThan(panes[2].prepend(Data(older.text.utf8), epoch: panes[2].historyEpoch), 0) }
        return surfaces
    }

    private func waitAlternate(_ client: Client, active: Bool) async throws {
        let state = Mutex((pending: false, matched: false))
        try await wait("alternate \(active)") {
            let query = state.withLock { state in
                if state.pending || state.matched { return false }
                state.pending = true
                return true
            }
            if query {
                client.send([Command("display-message", "-p", "#{alternate_on}")]) { replies in
                    state.withLock { $0 = (false, replies?.first == .success([active ? "1" : "0"])) }
                }
            }
            return state.withLock { $0.matched }
        }
    }

    private func backgrounds(_ pane: PaneView, columns: Int, rows: Int) async throws -> [NSColor] {
        let done = expectation(description: "background cells rendered")
        pane.visualFrame { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
        let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        var result: [NSColor] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = min(bitmap.pixelsWide - 1, Int((CGFloat(column) + 0.8) * CGFloat(bitmap.pixelsWide) / CGFloat(columns)))
                let y = min(bitmap.pixelsHigh - 1, Int((CGFloat(row) + 0.9) * CGFloat(bitmap.pixelsHigh) / CGFloat(rows)))
                result.append(try XCTUnwrap(bitmap.colorAt(x: x, y: y)))
            }
        }
        return result
    }

    func testRestoreWideWraps() async throws {
        let (tmux, dir, socket, client) = try await replayServer(columns: 5, rows: 3)
        let blank = try makePane().pane
        blank.frame.size = CGSize(width: blank.cell.width * 5, height: blank.cell.height * 3)
        let paper = try await backgrounds(blank, columns: 5, rows: 3)[0]
        for (width, word) in [(5, "abcd界Z"), (2, "a界Z"), (32, String(repeating: "a", count: 31) + "界Z")] {
            for (prefix, suffix) in [("", ""), ("one\r\ntwo\r\n", ""), (String(repeating: "old\r\n", count: 8), String(repeating: "\r\nend", count: 4))] {
                for pen in ["", "\u{1B}[48;2;223;231;236m"] {
                    _ = try await capture(client, [Command("resize-window", "-x", width, "-y", 3), Command("clear-history", "-t", PaneID(number: 0))])
                    let fixture = "\u{1B}c\u{1B}[?25l" + prefix + pen + word + suffix
                    let input = dir.appendingPathComponent("fixture")
                    let ready = dir.appendingPathComponent(UUID().uuidString)
                    try fixture.write(to: input, atomically: true, encoding: .utf8)
                    let output = try await Child.run(tmux, ["-S", socket, "respawn-pane", "-k", "cat \(input.path); touch \(ready.path); exec sleep 60"])
                    XCTAssertEqual(output.status, 0, output.err)
                    try await wait("wide fixture") { FileManager.default.fileExists(atPath: ready.path) }
                    let (snapshot, _) = try await sync(client, PaneID(number: 0))
                    let textReplies = try await capture(client, [Command("capture-pane", "-p", "-J", "-S", "-", "-E", "-", "-t", PaneID(number: 0))])
                    guard case .success(let textRows)? = textReplies.first else { return XCTFail("tmux text capture failed") }
                    let expectedText = textRows.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    let (recent, retained) = try await sync(client, PaneID(number: 0), chunk: 1)
                    let older = try await replay(client, PaneID(number: 0), loaded: retained.rows).history
                    let surfaces = try await replayPanes(fixture, snapshot: snapshot, recent: recent, older: older, columns: width, rows: 3)
                    let panes = surfaces.map(\.pane)
                    let live = panes[0]
                    for pane in panes {
                        XCTAssertEqual(surfaceText(pane).trimmingCharacters(in: .newlines), expectedText, "wide wrap width \(width) prefix \(prefix.debugDescription)")
                        if suffix.isEmpty && pane !== live {
                            let actual = try await backgrounds(pane, columns: width, rows: 3)
                            let row = prefix.isEmpty && width > 2 ? 1 : 2
                            let used = width == 2 ? 1 : 3
                            for column in used..<width { XCTAssertEqual(actual[row * width + column], paper, "tmux default tail width \(width), column \(column)") }
                        }
                    }
                    let resized = try await capture(client, [Command("resize-window", "-x", 7, "-y", 3), Command("capture-pane", "-p", "-J", "-S", "-", "-E", "-", "-t", PaneID(number: 0))])
                    guard case .success(let resizedRows)? = resized.last else { return XCTFail("tmux resized text capture failed") }
                    let expectedReflow = resizedRows.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    for pane in panes { pane.resize(cols: 7, rows: 3) }
                    if pen.isEmpty {
                        for pane in panes.dropFirst() { XCTAssertEqual(surfaceText(pane), surfaceText(live), "wide wrap reflow width \(width)") }
                    } else if !suffix.isEmpty {
                        let reference = surfaceText(live)
                        let start = try XCTUnwrap(reference.range(of: "end")).lowerBound
                        for pane in panes.dropFirst() {
                            let text = surfaceText(pane)
                            let actual = try XCTUnwrap(text.range(of: "end")).lowerBound
                            XCTAssertEqual(text[actual...], reference[start...], "coloured erased-tail reflow")
                        }
                    }
                    let (resynced, _) = try await sync(client, PaneID(number: 0))
                    for pane in panes.dropFirst() {
                        XCTAssertTrue(pane.feed(resynced.data, kind: .snapshot))
                        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
                        XCTAssertEqual(surfaceText(pane).trimmingCharacters(in: .newlines), expectedReflow, "tmux resize resync")
                    }
                }
            }
        }
    }

    func testRestoreBackgroundCells() async throws {
        let (tmux, dir, socket, client) = try await replayServer(columns: 12, rows: 6)
        let fixture = "\u{1B}[?25l\u{1B}[48;2;223;231;236mABCDEFGHIJKLMNOPQRSTUVWX\u{1B}[m\r\n" +
            "\u{1B}[1;3;7;9;4:3;58;2;255;0;80mreverse\u{1B}[m\r\n" +
            "\u{1B}]8;id=wrapped;https://example.com/\u{1B}\\界🙂abcdefghijklmnopqrst\u{1B}]8;;\u{1B}\\\r\n" + (0..<12).map { index in
            "\u{1B}[48;2;223;231;236mBOX\(index)      \u{1B}[m\r\n" +
            "\u{1B}[48;2;223;231;236m\u{1B}[K\u{1B}[m\r\n" +
            "\u{1B}[49mtool\u{1B}[m\r\n"
        }.joined() + "\u{1B}[48;2;223;231;236mabcdefghijklmnopqrstuvwx\u{1B}[m\r\nEND"
        let input = dir.appendingPathComponent("fixture")
        try fixture.write(to: input, atomically: true, encoding: .utf8)
        let started = try await Child.run(tmux, ["-S", socket, "respawn-pane", "-k", "cat \(input.path); touch \(dir.path)/ready; exec sleep 60"])
        XCTAssertEqual(started.status, 0, started.err)
        try await wait("background fixture") { FileManager.default.fileExists(atPath: dir.appendingPathComponent("ready").path) }
        let paneID = PaneID(number: 0)
        let (snapshot, _) = try await sync(client, paneID)
        let (recent, retained) = try await sync(client, paneID, chunk: 4)
        let older = try await replay(client, paneID, loaded: retained.rows).history
        XCTAssertGreaterThan(older.rows, 0)
        let surfaces = try await replayPanes(fixture, snapshot: snapshot, recent: recent, older: older, columns: 12, rows: 6, windowed: true)
        defer { surfaces.forEach { $0.window?.close() } }
        let panes = surfaces.map(\.pane), live = panes[0], restored = panes[1]
        for position in ["scroll_to_bottom", "scroll_to_top"] {
            for pane in panes { XCTAssertTrue(ghostty_surface_binding_action(pane.surface, position, UInt(position.utf8.count))) }
            try await drain(runtime)
            for pane in panes { XCTAssertEqual(ghostty_surface_size(pane.surface).columns, 12) }
            for pane in panes.dropFirst() {
                XCTAssertEqual(surfaceText(pane), surfaceText(live), position)
            }
            let expected = try await backgrounds(live, columns: 12, rows: 6)
            for pane in panes.dropFirst() {
                let actual = try await backgrounds(pane, columns: 12, rows: 6)
                XCTAssertEqual(actual, expected, position)
            }
            let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
            if let failure = verifySnapshot(of: restored, as: .image, named: position, record: record) {
                if !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
            }
        }
        for pane in panes { pane.resize(cols: 8, rows: 6); XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "scroll_to_bottom", 16)) }
        for pane in panes.dropFirst() {
            XCTAssertEqual(surfaceText(pane), surfaceText(live), "restored soft wraps reflow")
        }
    }

    func testRestoreResizedAlternateMain() async throws {
        let (tmux, _, socket, client) = try await replayServer(columns: 12, rows: 3)
        let tty = try await Child.run(tmux, ["-S", socket, "display-message", "-p", "#{pane_tty}"])
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: tty.out.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { try? output.close() }
        for main in ["hello", "abcdefghijkLmnop\r\nsecond", "abcdefghijkLmnop\r\nsecondlongword\r\nthird\r\nfourth\r\nfifth"] {
            _ = try await capture(client, [Command("resize-window", "-x", 12, "-y", 3), Command("clear-history", "-t", PaneID(number: 0))])
            try output.write(contentsOf: Data(("\u{1B}c\u{1B}[?25l" + main + "\u{1B}[?1049hALT").utf8))
            try await waitAlternate(client, active: true)
            _ = try await capture(client, [Command("resize-window", "-x", 7, "-y", 3)])
            let (snapshot, _) = try await sync(client, PaneID(number: 0))
            let restored = try makePane().pane
            restored.resize(cols: 7, rows: 3)
            XCTAssertTrue(restored.feed(snapshot.data, kind: .snapshot))
            XCTAssertTrue(restored.feed(Data("\u{1B}[?1049l".utf8)))
            try output.write(contentsOf: Data("\u{1B}[?1049l".utf8))
            try await waitAlternate(client, active: false)
            let text = try await capture(client, [Command("capture-pane", "-p", "-J", "-S", "-", "-E", "-")])
            guard case .success(let rows)? = text.first else { return XCTFail("main capture failed") }
            XCTAssertEqual(surfaceText(restored).trimmingCharacters(in: .newlines), rows.joined(separator: "\n").trimmingCharacters(in: .newlines), main)
        }
    }

    private func drainAnimation(_ runtime: GhosttyRuntime) async throws {
        for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
    }

    private func assertIdleCPU(_ ids: Set<UInt64>) async throws {
        let before = try rendererCPU(only: ids)
        try await Task.sleep(for: .seconds(3))
        let after = try rendererCPU(only: ids)
        XCTAssertEqual(after.count, before.count)
        XCTAssertLessThanOrEqual(after.cpu - before.cpu, 0.003, "no periodic renderer work (3ms CPU tolerance over 3s)")
    }

    private func rendererCPU(only ids: Set<UInt64>? = nil) throws -> (cpu: Double, count: Int) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        XCTAssertEqual(task_threads(mach_task_self_, &list, &count), KERN_SUCCESS)
        let threads = try XCTUnwrap(list)
        defer {
            for i in 0..<Int(count) { _ = mach_port_deallocate(mach_task_self_, threads[i]) }
            _ = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        var renderers = 0
        for i in 0..<Int(count) {
            guard let pthread = pthread_from_mach_thread_np(threads[i]) else { continue }
            var name = [CChar](repeating: 0, count: 64)
            guard pthread_getname_np(pthread, &name, name.count) == 0,
                  name.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) == "renderer" else { continue }
            if let ids {
                var identifier = thread_identifier_info_data_t()
                var identifierSize = mach_msg_type_number_t(MemoryLayout.size(ofValue: identifier) / MemoryLayout<integer_t>.size)
                let identified = withUnsafeMutablePointer(to: &identifier) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(identifierSize)) { thread_info(threads[i], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierSize) }
                }
                XCTAssertEqual(identified, KERN_SUCCESS)
                if !ids.contains(identifier.thread_id) { continue }
            }
            var info = thread_basic_info_data_t()
            var size = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
            }
            XCTAssertEqual(status, KERN_SUCCESS)
            total += Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
            renderers += 1
        }
        return (total, renderers)
    }

    private func reload(_ text: String) throws {
        let changed = try XCTUnwrap(ghostty_config_clone(runtime.config))
        ghostty_config_load_string(changed, text, UInt(text.utf8.count), "/renderer-test")
        ghostty_config_finalize(changed)
        ghostty_app_update_config(runtime.app, changed)
        ghostty_config_free(changed)
    }

    private func flow(_ panes: [PaneView]) async throws {
        for step in 0..<12 {
            for pane in panes { XCTAssertTrue(pane.feed(Data("\u{1b}[?25lordinary output \(step)\r\n".utf8))) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testFailedSurfaceInitJoinsRendererAndReleasesAllocations() async throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var options = ghostty_surface_config_new()
        options.platform_tag = GHOSTTY_PLATFORM_MACOS
        options.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        options.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        var callbacks = ghostty_runtime_config_s()
        callbacks.wakeup_cb = { _ in }
        callbacks.action_cb = { _, _, _ in false }
        callbacks.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        callbacks.confirm_read_clipboard_cb = { _, _, _, _ in }
        callbacks.write_clipboard_cb = { _, _, _, _, _ in GHOSTTY_CLIPBOARD_WRITE_OK }
        let config = try XCTUnwrap(ghostty_config_clone(runtime.config))
        let initial = "cursor-style-blink = true\nfont-size = 6\n"
        ghostty_config_load_string(config, initial, UInt(initial.utf8.count), "/renderer-test")
        ghostty_config_finalize(config)
        defer { ghostty_config_free(config) }
        let app = try XCTUnwrap(ghostty_app_new(&callbacks, config))
        defer { ghostty_app_free(app) }
        var invalid = options
        invalid.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: nil))
        XCTAssertNil(ghostty_surface_new(app, &invalid))
        let fault = try probe("kido_io_spawn_fault", (@convention(c) (Bool) -> UInt).self)
        invalid.platform = options.platform
        invalid.scale_factor = 0.25
        let allocationBytes = try probe("kido_renderer_allocation_bytes", (@convention(c) (Bool) -> UInt).self)
        let resetAllocations = try probe("kido_renderer_allocation_reset", (@convention(c) () -> Void).self)
        let threadsBeforeFailure = try rendererCPU().count
        let failures = fault(true)
        let rejected = ghostty_surface_new(app, &invalid)
        XCTAssertEqual(fault(false), failures + 1, "IO spawn failed after a live named renderer was started")
        XCTAssertNil(rejected)
        XCTAssertEqual(try rendererCPU().count, threadsBeforeFailure, "failed constructor joins renderer before returning")
        if let rejected { ghostty_surface_free(rejected) }
        XCTAssertGreaterThan(allocationBytes(true), 65536, "renderer performed allocating initial work before IO spawn failed")
        try await wait("renderer allocations released after failed constructor") { allocationBytes(false) <= 65536 }
        XCTAssertLessThanOrEqual(allocationBytes(false), 65536, "largest initial renderer allocation freed (64KiB residual allowance)")
        print("renderer fault: largest allocation=\(allocationBytes(true)), residual=\(allocationBytes(false)) bytes")
        resetAllocations()
    }

    func testWindowDisplayIDReachesNativeLink() async throws {
        let binding = try probe("kido_cv_display_binding", (@convention(c) () -> UInt64).self)
        let before = binding() >> 32
        let (pane, window) = try makePane(windowed: true)
        defer { pane.dispose(); window?.contentView = nil; window?.close() }
        let id = try XCTUnwrap(window?.screen?.displayID)
        try await wait("the window display reaches CoreVideo") { binding() >> 32 > before && UInt32(truncatingIfNeeded: binding()) == id }
    }

    func testOutputAndHiddenDiscardRecovery() async throws {
        let rendererThread = try probe("kido_renderer_thread", (@convention(c) (Bool) -> UInt64).self)
        _ = rendererThread(true)
        let (pane, window) = try makePane(windowed: true)
        defer { pane.dispose(); window?.contentView = nil; window?.close() }
        try await drainAnimation(runtime)
        var frames = 0
        let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { frames += 1 }
        let renderer = rendererThread(false)
        XCTAssertNotEqual(renderer, 0)
        let activeCPU = try rendererCPU(only: [renderer])
        XCTAssertEqual(activeCPU.count, 1, "sampling this pane's renderer thread")
        try await flow([pane])
        try await drainAnimation(runtime)
        XCTAssertGreaterThan(frames, 0, "ordinary output installs IOSurfaces without token requests")
        XCTAssertGreaterThan(try rendererCPU(only: [renderer]).cpu - activeCPU.cpu, 0.003, "active renderer CPU exceeds idle tolerance")
        for enabled in [false, true] {
            try reload("window-vsync = \(enabled)\n")
            let before = frames
            try await flow([pane])
            try await drainAnimation(runtime)
            XCTAssertGreaterThan(frames, before)
        }
        pane.isHidden = true
        let discarded = expectation(description: "hidden final frame discarded")
        pane.visualFrame { XCTAssertEqual($0, GHOSTTY_RENDER_PRESENTATION_DISCARDED); discarded.fulfill() }
        await fulfillment(of: [discarded], timeout: 5)
        pane.isHidden = false
        let recovered = expectation(description: "realization recovery")
        pane.visualFrame { XCTAssertEqual($0, GHOSTTY_RENDER_PRESENTATION_PRESENTED); recovered.fulfill() }
        await fulfillment(of: [recovered], timeout: 5)
        observation.invalidate()
    }

    private func feedKittyAnimation(_ pane: PaneView, z: Int) {
        let packets = ["a=T,i=1,f=24,s=1,v=1,c=8,r=4,q=2;/wAA", "a=f,i=1,f=24,s=1,v=1,z=\(z),q=2;AAD/", "a=a,i=1,r=1,z=\(z),s=3,v=1"]
        XCTAssertTrue(pane.feed(Data(("\u{1b}[?25l" + packets.map { "\u{1b}_G\($0)\u{1b}\\" }.joined()).utf8)))
    }

    private func kittyColour(_ pane: PaneView, layer: CALayer) -> Int? {
        guard let contents = layer.contents else { return nil }
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        XCTAssertEqual(IOSurfaceGetBytesPerElement(surface), 4)
        guard IOSurfaceLock(surface, .readOnly, nil) == 0 else { XCTFail("lock image contents"); return nil }
        defer { _ = IOSurfaceUnlock(surface, .readOnly, nil) }
        let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let grid = ghostty_surface_size(pane.surface)
        var red = 0
        var blue = 0
        for y in stride(from: 0, to: min(IOSurfaceGetHeight(surface), Int(grid.cell_height_px) * 4), by: 8) {
            for x in stride(from: 0, to: min(IOSurfaceGetWidth(surface), Int(grid.cell_width_px) * 8), by: 8) {
                let offset = y * IOSurfaceGetBytesPerRow(surface) + x * 4
                if Int(bytes[offset + 2]) - Int(bytes[offset]) > 100 { red += 1 }
                if Int(bytes[offset]) - Int(bytes[offset + 2]) > 100 { blue += 1 }
            }
        }
        return red + blue > 0 ? (red > blue ? 1 : -1) : nil
    }

    func testAnimatedShaderKeepsKittyDeadlines() async throws {
        let shader = config.appendingPathExtension("glsl")
        try "void mainImage(out vec4 color, in vec2 position) { color = vec4(texture(iChannel0, position / iResolution.xy).rgb * 0.9 + vec3(0.05 + 0.05 * sin(iTime)), 1.0); }".write(to: shader, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: shader) }
        try reload("custom-shader = \(shader.path)\ncustom-shader-animation = always\n")
        let (pane, _) = try makePane()
        defer { pane.dispose() }
        try await drainAnimation(runtime)
        feedKittyAnimation(pane, z: 400)
        try await drainAnimation(runtime)
        var frames = 0
        var changes: [(time: Double, colour: Int)] = []
        let layer = try XCTUnwrap(pane.subviews.first?.layer)
        let observation = observeFrames(layer) {
            frames += 1
            if let colour = self.kittyColour(pane, layer: layer), changes.last?.colour != colour {
                changes.append((CACurrentMediaTime(), colour))
            }
        }
        defer { observation.invalidate() }
        try await wait("animated shader retains Kitty changes") { changes.count >= 4 }
        XCTAssertGreaterThan(frames, 12, "shader continues drawing between sparse Kitty updates")
        for interval in zip(changes.dropFirst(2), changes.dropFirst()).map({ $0.0.time - $0.1.time }) {
            XCTAssertEqual(interval, 0.4, accuracy: 0.18)
        }
    }

    func testSlowKittyAnimationDrawsOnlyAtDeadlines() async throws {
        let (pane, window) = try makePane(windowed: true)
        defer { pane.dispose(); window?.contentView = nil; window?.close() }
        window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window?.orderFront(nil)
        try await drainAnimation(runtime)
        let layer = try XCTUnwrap(pane.subviews.first?.layer)
        var frames = 0
        var changes: [(time: Double, colour: Int)] = []
        let observation = observeFrames(layer) {
            frames += 1
            if let colour = self.kittyColour(pane, layer: layer), changes.last?.colour != colour {
                changes.append((CACurrentMediaTime(), colour))
            }
        }
        defer { observation.invalidate() }
        feedKittyAnimation(pane, z: 250)
        try await wait("first Kitty frame") { !changes.isEmpty }
        let start = CACurrentMediaTime()
        let before = frames
        let changesBefore = changes.count
        try await wait("nine Kitty frame changes", within: 5) { changes.count >= changesBefore + 9 }
        let elapsed = CACurrentMediaTime() - start
        let draws = frames - before
        print("250ms Kitty animation: \(draws) draws in \(elapsed)s (\(Double(draws) / elapsed) draws/s)")
        XCTAssertLessThanOrEqual(draws, changes.count - changesBefore + 3, "no display-rate redraws between Kitty deadlines")
        let refresh = Double(window?.screen?.maximumFramesPerSecond ?? 60)
        for (previous, next) in zip(changes, changes.dropFirst()) {
            XCTAssertEqual(next.time - previous.time, 0.25, accuracy: 2 / refresh)
        }
    }

    func testIdleFocusedPaneWithoutCursorBlinkDoesNotBlink() async throws {
        let (pane, _) = try makePane()
        defer { pane.dispose() }
        ghostty_surface_set_focus(pane.surface, true)
        XCTAssertTrue(pane.feed(Data("\u{1b}[?25hhonk\r\n".utf8)))
        try await drainAnimation(runtime)
        var frames = 0
        let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { frames += 1 }
        defer { observation.invalidate() }
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(frames, 0, "blink off installs no frame over two blink intervals")
    }

    func testScrollerBurstUsesOneFadeDeadlineAndFlipsTheKnob() async throws {
        let delay = PaneScroller.fadeDelay
        PaneScroller.fadeDelay = 0.05
        defer { PaneScroller.fadeDelay = delay }
        let scroller = PaneScroller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 12, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroller
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        scroller.update(history: 1000, rows: 40, offset: 1000, alternate: false)
        let bottom = try knobRows(scroller)
        XCTAssertNil(scroller.layer?.contents, "the knob layer needs no backing store")
        XCTAssertFalse(bottom.isEmpty, "the flipped scroller renders its knob")
        XCTAssertGreaterThan(bottom.min() ?? 0, 360, "the live bottom is at the bottom of the flipped view")
        scroller.update(history: 1000, rows: 40, offset: 0, alternate: false)
        let top = try knobRows(scroller)
        XCTAssertFalse(top.isEmpty)
        XCTAssertLessThan(top.max() ?? 400, 40, "the oldest history is at the top of the flipped view")
        for step in 0..<200 {
            scroller.update(history: 1000, rows: 40, offset: 100 + Double(step) / 10, alternate: false)
            scroller.reveal()
        }
        XCTAssertEqual(scroller.visualFadeArmings, 1, "a scroll burst arms one fade deadline, not one timer per event")
        let knob = try XCTUnwrap(scroller.layer?.sublayers?.first)
        XCTAssertEqual(knob.frame.origin.y, 47.0824, accuracy: 0.001, "the burst leaves the knob at the latest geometry")
        XCTAssertEqual(scroller.alphaValue, 1)
        try await wait("the fade starts after the burst") { scroller.alphaValue == 0 }
        scroller.reveal()
        XCTAssertEqual(scroller.alphaValue, 1, "a reveal during the fade restores the scroller")
        scroller.update(history: 1000, rows: 40, offset: 500, alternate: true)
        XCTAssertEqual(knob.frame.origin.y, 47.0824, accuracy: 0.001, "a hidden scroller does not commit its knob")
        scroller.update(history: 1000, rows: 40, offset: 500, alternate: false)
        XCTAssertEqual(knob.frame.origin.y, 190, accuracy: 0.001, "the shown scroller commits the current knob")
    }

    private func knobRows(_ scroller: PaneScroller) throws -> [Int] {
        let width = Int(scroller.bounds.width), height = Int(scroller.bounds.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if scroller.isFlipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        scroller.layer!.render(in: context)
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        return (0..<height).filter { y in
            (0..<width).contains { x in (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 }
        }
    }

    func testScrollbarActionSkipsRefreshWhileAppOwnsTarget() async throws {
        let (pane, _) = try makePane()
        defer { pane.dispose() }
        let output = (0..<300).map { "line \($0)\r\n" }.joined()
        XCTAssertTrue(pane.feed(Data(output.utf8)))
        try await drain(runtime)
        pane.requestScroll(10)
        try await wait("the app owns the scroll target") { pane.scrollTarget != nil }
        try await drain(runtime)
        let owned = pane.visualScrollerRefreshes
        try await scrollbar(pane)
        XCTAssertEqual(pane.visualScrollerRefreshes, owned,
                       "the app tick does not refresh a scroller whose target the app owns")
        pane.clearScrollTarget()
        XCTAssertNil(pane.scrollTarget)
        try await drain(runtime)
        let released = pane.visualScrollerRefreshes
        try await scrollbar(pane)
        XCTAssertGreaterThan(pane.visualScrollerRefreshes, released,
                             "the app tick still refreshes the scroller when the app owns no target")
    }

    private func scrollbar(_ pane: PaneView) async throws {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = pane.surface
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SCROLLBAR
        XCTAssertTrue(GhosttyRuntime.action(ghostty_surface_app(pane.surface)!, target, action))
        await mainQueueFence()
        await mainQueueFence()
    }

    func testThirtyTwoOffscreenSurfacesStayIdleAfterChurn() async throws {
        let rendererThread = try probe("kido_renderer_thread", (@convention(c) (Bool) -> UInt64).self)
        var fixtures: [(pane: PaneView, renderer: UInt64)] = []
        var frames = 0
        var observations: [NSKeyValueObservation] = []
        for index in 0..<40 {
            _ = rendererThread(true)
            let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: UInt32(index)), font: 13) { _ in })
            observations.append(observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { frames += 1 })
            pane.resize(cols: 20, rows: 5)
            XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
            XCTAssertTrue(pane.feed(Data("\u{1b}[?25lchurn \(index)\r\n".utf8)))
            fixtures.append((pane, rendererThread(false)))
            if fixtures.count > 32 { fixtures.removeFirst().pane.dispose() }
        }
        try await drainAnimation(runtime)
        var panes = fixtures.map(\.pane)
        let ids = Set(fixtures.map(\.renderer))
        XCTAssertEqual(ids.count, 32)
        XCTAssertFalse(ids.contains(0))
        let activeCPU = try rendererCPU(only: ids)
        XCTAssertEqual(activeCPU.count, panes.count)
        let activeFrames = frames
        try await flow(panes)
        try await drainAnimation(runtime)
        XCTAssertGreaterThan(frames, activeFrames)
        XCTAssertGreaterThan(try rendererCPU(only: ids).cpu - activeCPU.cpu, 0.003, "active renderer CPU exceeds idle tolerance")
        // Ghostty's compression delay is 250ms.
        try await Task.sleep(for: .milliseconds(500))
        let idleFrames = frames
        try await assertIdleCPU(ids)
        XCTAssertEqual(frames, idleFrames)
        observations.forEach { $0.invalidate() }
        for pane in panes { pane.dispose() }
        panes.removeAll()
        fixtures.removeAll()
        await mainQueueFence()
    }
}
