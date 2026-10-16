import AppKit
import GhosttyKit
import TmuxControl
import UniformTypeIdentifiers
import XCTest
@testable import Kido

extension VisualTests {
    private var board: NSPasteboard { runtime.pasteboard }

    private func rawPane(dark: Bool = false) async throws -> PaneView {
        try await start(dark: dark)
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await command(["respawn-pane", "-k", "-t", pane.pane.description, "stty raw -echo; exec /bin/cat"])
        try await restore(pane)
        return pane
    }

    private func restore(_ pane: PaneView) async throws {
        let restored = expectation(description: "pane restored")
        pane.markContentDirty()
        connection.sync(pane.pane) { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 20)
        try await settle()
        window.makeFirstResponder(pane)
    }

    private func emit(_ pane: PaneView, _ text: String, until marker: String) async throws {
        let bytes = text.utf8.map { String(format: "%02x", $0) }
        for start in stride(from: 0, to: bytes.count, by: 300) {
            try await command(["send-keys", "-t", pane.pane.description, "-H"] + bytes[start..<min(start + 300, bytes.count)])
        }
        let deadline = Date() + 5
        while try await !command(["capture-pane", "-p", "-t", pane.pane.description]).contains(marker) {
            guard Date() < deadline else { return XCTFail("tmux never showed \(marker)") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await roundTrip()
    }

    private func roundTrip() async throws {
        let done = expectation(description: "tmux reply")
        connection.send([Command("display-message", "-p", "")]) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
    }

    private func key(_ pane: PaneView, _ characters: String, _ mods: NSEvent.ModifierFlags = [], code: UInt16 = 0,
                     ignoring: String? = nil, type: NSEvent.EventType = .keyDown) {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: pane.window?.windowNumber ?? 0, context: nil,
                                     characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code)!
        if type == .keyUp { pane.keyUp(with: event) } else if !pane.performKeyEquivalent(with: event) { pane.keyDown(with: event) }
    }

    private func keys(_ pane: PaneView, _ sequence: String) {
        for c in sequence {
            key(pane, String(c), c.isUppercase || c == "$" ? .shift : [], code: c == "\r" ? 36 : c == "\u{1b}" ? 53 : 0)
        }
    }

    private func enter(_ pane: PaneView) async throws {
        key(pane, "C", [.command, .shift], ignoring: "C")
        try await wait("copy mode entered", within: 2) { if case .cursor = pane.copyMode { true } else { false } }
    }

    private func cursor(_ pane: PaneView) -> (x: Int, y: Int)? {
        var value = ghostty_selection_s()
        guard ghostty_surface_selection(pane.surface, &value) else { return nil }
        return (Int(value.bottom_right.x), Int(value.bottom_right.y))
    }

    private func label(_ pane: PaneView) -> String? {
        pane.subviews.compactMap { $0.isHidden ? nil : ($0 as? NSBox)?.contentView as? NSTextField }.first?.stringValue
    }

    private func screen(_ pane: PaneView) -> [String] {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                                            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(pane.surface, selection, &text), let bytes = text.text else { return [] }
        defer { ghostty_surface_free_text(pane.surface, &text) }
        return trimmed(String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self))
    }

    private func trimmed(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.reversed().drop { $0 == " " }.reversed()) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private func tmuxScreen(_ pane: PaneView) async throws -> [String] {
        trimmed(try await command(["capture-pane", "-p", "-t", pane.pane.description]))
    }

    private func sends(_ since: Int) -> [Command] { connection.visualCommands.dropFirst(since).filter { $0.line.hasPrefix("send-keys") } }

    private func sentinel(_ pane: PaneView, since: Int) async throws {
        key(pane, "a")
        try await wait("sentinel key reached tmux", within: 2) { !self.sends(since).isEmpty }
        XCTAssertEqual(sends(since).count, 1, "only the sentinel after copy mode sent input: \(sends(since).map(\.line))")
    }

    private func copied(_ pane: PaneView, _ sequence: String, _ finish: (PaneView) -> Void = { _ in }) async throws -> String? {
        try await enter(pane)
        let count = board.changeCount
        keys(pane, sequence)
        finish(pane)
        XCTAssertNil(pane.copyMode, sequence)
        XCTAssertNil(label(pane), sequence)
        return board.changeCount == count ? nil : board.string(forType: .string)
    }

    func testCopyRangesAndCursorDoesNotCopy() async throws {
        let pane = try await rawPane()
        try await emit(pane, (0..<38).map { String(format: "line-%02d\r\n", $0) }.joined() + "日本 wide\r\n", until: "日本")
        for (sequence, expected) in [("kk0v$y", "line-37"), ("kkk0vjl\r", "line-36\nli"), ("kk$vk0y", "line-36\nline-37"),
                                     ("k0vly", "日"), ("k0vlly", "日本")] {
            let text = try await copied(pane, sequence)
            XCTAssertEqual(text, expected, sequence)
        }
        let command = try await copied(pane, "kk0v$") { self.key($0, "c", .command) }
        XCTAssertEqual(command, "line-37", "Cmd-C copies as y does")
        for sequence in ["y", "\r", " ky", "vvy", "kv\u{1b}", "kvq"] {
            let text = try await copied(pane, sequence)
            XCTAssertNil(text, sequence)
        }
        let cursorOnly = try await copied(pane, "") { self.key($0, "c", .command) }
        XCTAssertNil(cursorOnly, "Cmd-C without v writes nothing")
        try await enter(pane)
        let start = try XCTUnwrap(cursor(pane))
        var bar = ghostty_surface_scrollbar_s()
        XCTAssertTrue(ghostty_surface_scrollbar(pane.surface, &bar))
        let columns = Int(ghostty_surface_size(pane.surface).columns), last = Int(bar.total) - 1, half = Int(bar.len) / 2
        XCTAssertEqual(start.y, last)
        for (sequence, x, y) in [("h", 0, last), ("$l", columns - 1, last), ("0j", 0, last), ("g", 0, 0), ("k", 0, 0), ("G", 0, last)] {
            keys(pane, sequence)
            XCTAssertEqual(cursor(pane)?.x, x, sequence)
            XCTAssertEqual(cursor(pane)?.y, y, sequence)
        }
        key(pane, "\u{15}", .control, ignoring: "u")
        XCTAssertEqual(cursor(pane)?.y, last - half)
        key(pane, "\u{4}", .control, ignoring: "d")
        XCTAssertEqual(cursor(pane)?.y, last)
        key(pane, String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        key(pane, String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
        XCTAssertEqual(cursor(pane)?.y, last - 1)
        XCTAssertEqual(cursor(pane)?.x, 1)
        keys(pane, "q")
        XCTAssertNil(cursor(pane))
    }

    func testFrozenOutputRestoresOnce() async throws {
        let pane = try await rawPane()
        try await emit(pane, (0..<40).map { "before-\($0)\r\n" }.joined(), until: "before-39")
        try await enter(pane)
        let frozen = screen(pane), restores = connection.visualRestores
        try await emit(pane, (0..<50).map { "during-\($0)\r\n" }.joined(), until: "during-49")
        XCTAssertTrue(pane.resizeDirty)
        XCTAssertEqual(screen(pane), frozen, "the frozen pane parses no output")
        XCTAssertEqual(connection.visualRestores, restores)
        keys(pane, "q")
        try await wait("dirty exit restored", within: 2) { !pane.resizeDirty && self.connection.visualRestores == restores + 1 }
        try await settle()
        let expected = try await tmuxScreen(pane)
        XCTAssertEqual(screen(pane), expected)
        XCTAssertEqual(connection.visualRestores, restores + 1)
    }

    func testPauseAndExplicitSyncDrainOnCleanExit() async throws {
        let pane = try await rawPane()
        try await emit(pane, "ready\r\n", until: "ready")
        try await enter(pane)
        let restores = connection.visualRestores
        connection.send([Command("refresh-client", "-A", "\(pane.pane):pause")])
        try await roundTrip()
        try await emit(pane, "while-paused\r\n", until: "while-paused")
        XCTAssertEqual(connection.visualRestores, restores, "a %pause waits for the exit")
        XCTAssertFalse(pane.resizeDirty)
        keys(pane, "q")
        try await wait("clean exit drained the pause", within: 2) { self.connection.visualRestores == restores + 1 }
        try await settle()
        try await emit(pane, "resumed\r\n", until: "resumed")
        try await wait("resumed output arrives live", within: 2) { self.screen(pane).contains("resumed") }
        XCTAssertTrue(screen(pane).contains("while-paused"))
        try await enter(pane)
        connection.sync(pane.pane)
        try await roundTrip()
        XCTAssertEqual(connection.visualRestores, restores + 1, "an explicit sync waits for the exit")
        keys(pane, "q")
        try await wait("clean exit drained the explicit sync", within: 2) { self.connection.visualRestores == restores + 2 }
        try await settle()
    }

    func testEntryWaitsForAdmittedParse() async throws {
        let pane = try await rawPane()
        try await emit(pane, "ready\r\n", until: "ready")
        func hold(_ bytes: String, for seconds: Double) -> DispatchSemaphore {
            let admitted = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            pane.feedProbe.withLock { $0 = (before: { admitted.signal(); _ = release.wait(timeout: .now() + seconds) }, after: {}) }
            nonisolated(unsafe) let target = pane
            connection.visualCopyCheck = { reply in
                DispatchQueue.global().async { target.feed(Data(bytes.utf8)) }
                XCTAssertEqual(admitted.wait(timeout: .now() + 2), .success)
                reply()
            }
            return release
        }
        let release = hold("held\r\n", for: 2)
        key(pane, "C", [.command, .shift], ignoring: "C")
        try await wait("reader check admitted a batch and main applied it", within: 2) { pane.frozen }
        connection.visualCopyCheck = nil
        pane.feedProbe.withLock { $0 = nil }
        XCTAssertTrue({ if case .entering = pane.copyMode { true } else { false } }(), "entry waits for the admitted parse")
        XCTAssertEqual(label(pane), "COPY…")
        XCTAssertNil(cursor(pane))
        release.signal()
        try await wait("entry completes after the parse", within: 2) { if case .cursor = pane.copyMode { true } else { false } }
        XCTAssertEqual(label(pane), "COPY")
        let rows = screen(pane), at = try XCTUnwrap(cursor(pane))
        var bar = ghostty_surface_scrollbar_s()
        XCTAssertTrue(ghostty_surface_scrollbar(pane.surface, &bar))
        XCTAssertEqual(rows[at.y - Int(bar.offset) - 1], "held", "the cursor is placed after the parse")
        try await emit(pane, "dropped\r\n", until: "dropped")
        XCTAssertFalse(screen(pane).contains("dropped"))
        keys(pane, "q")
        try await wait("dirty exit restored", within: 2) { !pane.resizeDirty }
        try await settle()

        let beeps = pane.visualBeeps
        let late = hold("late\r\n", for: 4)
        key(pane, "C", [.command, .shift], ignoring: "C")
        try await wait("deadline cancels a held entry", within: 3) { pane.copyMode == nil && pane.visualBeeps == beeps + 1 }
        connection.visualCopyCheck = nil
        pane.feedProbe.withLock { $0 = nil }
        XCTAssertFalse(pane.frozen)
        late.signal()
        try await roundTrip()
        XCTAssertNil(pane.copyMode, "a late parse completes no cancelled entry")
        try await settle()

        key(pane, "C", [.command, .shift], ignoring: "C")
        keys(pane, "\u{1b}")
        XCTAssertNil(pane.copyMode)
        try await enter(pane)
        try await roundTrip()
        XCTAssertEqual(pane.visualBeeps, beeps + 1, "the cancelled request's reply completes nothing")
        keys(pane, "q")
    }

    func testEntryKeepsAScreenSwitchParsedBeforeTheReply() async throws {
        let pane = try await rawPane()
        try await emit(pane, "\u{1b}[?1049h\u{1b}[Halternate-ready", until: "alternate-ready")
        nonisolated(unsafe) let target = pane
        let later = "\u{1b}[?1049hback-again"
        let schedules: [(name: String, batch: String, after: @Sendable () -> Void)] = [
            ("one batch", "\u{1b}[?1049lprimary-again\r\n", {}),
            ("an invalidated completion", "\u{1b}[?1049l\u{1b}[?1000hprimary-again\r\n", { target.markContentDirty() }),
            ("a second batch", "\u{1b}[?1049lprimary-again\r\n", {
                later.withCString { ghostty_surface_process_output(target.surface, $0, UInt(later.utf8.count)) }
            }),
        ]
        for schedule in schedules {
            XCTAssertTrue(pane.alternate, schedule.name)
            let restores = connection.visualRestores
            connection.visualCopyCheck = { reply in
                target.postProbe.withLock { $0 = {
                    reply()
                    let deadline = Date() + 2
                    while !target.frozen, Date() < deadline { usleep(1000) }
                    schedule.after()
                } }
                if !target.feed(Data(schedule.batch.utf8)) {
                    reply()
                    XCTFail("batch not admitted: \(schedule.name)")
                }
                target.postProbe.withLock { $0 = nil }
            }
            try await wait("grid ready: \(schedule.name)", within: 2) { pane.gridReady && !pane.resizeDirty }
            key(pane, "C", [.command, .shift], ignoring: "C")
            try await wait("copy mode entered: \(schedule.name)", within: 2) { if case .cursor = pane.copyMode { true } else { false } }
            connection.visualCopyCheck = nil
            XCTAssertEqual(pane.alternate, ghostty_surface_is_alternate_screen(pane.surface), "entry reads the screen: \(schedule.name)")
            XCTAssertEqual(pane.visualCaptured, ghostty_surface_mouse_captured(pane.surface), "entry reads the mouse mode: \(schedule.name)")
            XCTAssertTrue(pane.resizeDirty, "the return to the primary screen keeps its repair: \(schedule.name)")
            try await roundTrip()
            XCTAssertNotNil(pane.copyMode, "no stale screen update ends copy mode: \(schedule.name)")
            keys(pane, "q")
            try await wait("exit repairs the pane: \(schedule.name)", within: 2) { !pane.resizeDirty && self.connection.visualRestores > restores }
            try await settle()
            let expected = try await tmuxScreen(pane)
            XCTAssertEqual(screen(pane), expected, schedule.name)
            XCTAssertEqual(pane.alternate, ghostty_surface_is_alternate_screen(pane.surface), schedule.name)
        }
    }

    private func copyFinalWrappedRow(alternate: Bool) async throws {
        let pane = try await rawPane()
        let rows = Int(ghostty_surface_size(pane.surface).rows), columns = Int(ghostty_surface_size(pane.surface).columns)
        let text = String(repeating: "w", count: columns) + "z"
        try await emit(pane, (alternate ? "\u{1b}[?1049h" : "") + "\u{1b}[1;5r\u{1b}[\(rows);1H" + text, until: "wwwww")
        XCTAssertEqual(pane.alternate, alternate)
        XCTAssertTrue(ghostty_surface_row_wrapped(pane.surface, UInt32(pane.scrollPosition().retainedHistoryRows + rows - 1)), "the final row keeps its wrap flag")
        let last = try XCTUnwrap(screen(pane).last)
        try await enter(pane)
        let count = board.changeCount
        keys(pane, "Vy")
        XCTAssertEqual(board.changeCount, count + 1)
        XCTAssertEqual(board.string(forType: .string), last + "\n")
    }

    func testLineSelectionOfAWrappedFinalRow() async throws { try await copyFinalWrappedRow(alternate: false) }
    func testAlternateLineSelectionOfAWrappedFinalRow() async throws { try await copyFinalWrappedRow(alternate: true) }

    func testAppearanceChangeEndsCopyMode() async throws {
        let pane = try await rawPane()
        try await emit(pane, "appearance\r\n", until: "appearance")
        try await enter(pane)
        keys(pane, "kv$")
        let restores = connection.visualRestores
        ghostty_surface_set_color_scheme(pane.surface, GHOSTTY_COLOR_SCHEME_DARK)
        try await wait("the appearance reload ends copy mode", within: 2) { pane.copyMode == nil }
        XCTAssertNil(cursor(pane))
        XCTAssertNil(label(pane))
        XCTAssertFalse(pane.frozen)
        try await wait("the reflow repair follows", within: 2) { !pane.resizeDirty && self.connection.visualRestores > restores }
    }

    func testCopyOnSelectNeverWritesUntilACopy() async throws {
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        let config = URL(fileURLWithPath: "/tmp/kido-copy-select-\(UUID().uuidString).conf")
        try "copy-on-select = clipboard\n".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { _ in })
        owner.window.contentView = pane
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        owner.window.makeFirstResponder(pane)
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        defer { pane.dispose(); owner.close(); board.releaseGlobally() }
        nonisolated(unsafe) let target = pane
        await withCheckedContinuation { done in DispatchQueue.global().async { target.feed(Data("one\r\ntwo\r\nthree\r\n".utf8)); done.resume() } }
        func mouse(_ type: NSEvent.EventType, _ column: Int) -> NSEvent {
            let point = pane.convert(NSPoint(x: pane.cell.width * (Double(column) + 0.5), y: pane.bounds.height - pane.cell.height / 2), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        board.clearContents()
        board.setString("sentinel", forType: .string)
        pane.mouseDown(with: mouse(.leftMouseDown, 0))
        pane.mouseDragged(with: mouse(.leftMouseDragged, 3))
        pane.mouseUp(with: mouse(.leftMouseUp, 3))
        XCTAssertEqual(board.string(forType: .string), "one", "a mouse selection copies with this configuration")
        board.clearContents()
        board.setString("sentinel", forType: .string)
        let count = board.changeCount
        func unchanged(_ step: String) {
            XCTAssertEqual(board.changeCount, count, step)
            XCTAssertEqual(board.string(forType: .string), "sentinel", step)
        }
        pane.toggleCopyMode(nil)
        try await wait("copy mode entered", within: 2) { if case .cursor = pane.copyMode { true } else { false } }
        unchanged("entry")
        for step in ["k", "l", "v", "j", "$", "v", "V", "k", "j", "V", "v", "V", "\u{1b}"] {
            keys(pane, step)
            unchanged(step)
        }
        XCTAssertNil(pane.copyMode)
        pane.toggleCopyMode(nil)
        try await wait("copy mode entered again", within: 2) { if case .cursor = pane.copyMode { true } else { false } }
        keys(pane, "kVy")
        XCTAssertEqual(board.changeCount, count + 1)
        XCTAssertEqual(board.string(forType: .string), "three\n")
    }

    private func wrappedFixture(_ pane: PaneView) -> String {
        (0..<(2 * Int(ghostty_surface_size(pane.surface).columns) + 5)).map { String($0 % 10) }.joined()
    }

    func testLineSelection() async throws {
        let pane = try await rawPane()
        let wrapped = wrappedFixture(pane)
        try await emit(pane, "alpha\r\nbeta\r\n\(wrapped)\r\ngamma\r\ndelta\r\n", until: "delta")
        for (sequence, expected) in [
            ("kkkkkkkVjy", "alpha\nbeta\n"), ("kVky", "gamma\ndelta\n"), ("kkkkVy", wrapped + "\n"),
            ("kkkkkkVjy", "beta\n\(wrapped)\n"), ("kkVky", "\(wrapped)\ngamma\n"), ("Vy", "\n"),
            ("kV$hy", "delta\n"), ("kvllVy", "delta\n"), ("kVvlly", "del"), ("kkkkvVy", wrapped + "\n"),
        ] {
            let text = try await copied(pane, sequence)
            XCTAssertEqual(text, expected, sequence)
        }
        for sequence in ["kVVy", "kVvvy", "kvVVy"] {
            let text = try await copied(pane, sequence)
            XCTAssertNil(text, sequence)
        }
        try await emit(pane, (0..<60).map { "filler-\($0)\r\n" }.joined(), until: "filler-59")
        XCTAssertGreaterThan(pane.scrollPosition().retainedHistoryRows, 0)
        let history = try await copied(pane, String(repeating: "k", count: 64) + "Vy")
        XCTAssertEqual(history, wrapped + "\n", "a wrapped line in loaded history")
    }

    func testAlternateLineSelection() async throws {
        let pane = try await rawPane()
        let wrapped = wrappedFixture(pane)
        try await emit(pane, "\u{1b}[?1049h\u{1b}[Ha1\r\n\(wrapped)\r\na3", until: "a3")
        try await enter(pane)
        XCTAssertTrue(pane.alternate)
        keys(pane, "kkVy")
        XCTAssertEqual(board.string(forType: .string), wrapped + "\n")
        try await enter(pane)
        keys(pane, "gVjy")
        XCTAssertEqual(board.string(forType: .string), "a1\n\(wrapped)\n")
        try await enter(pane)
        keys(pane, "Vkky")
        XCTAssertEqual(board.string(forType: .string), "\(wrapped)\na3\n")
    }

    func testEntryRefusesEachHistoryLoadPhase() async throws {
        try await start(history: 100000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        let fixture = directory.appendingPathComponent("history.txt"), done = directory.appendingPathComponent("history-done")
        try (0..<3 * historyChunkSize + 2000).map { "row-\($0)\r\n" }.joined().write(to: fixture, atomically: true, encoding: .utf8)
        try await command(["respawn-pane", "-k", "-t", pane.pane.description, "/bin/cat '\(fixture.path)'; /usr/bin/touch '\(done.path)'; exec /bin/sleep 600"])
        try await wait("history fixture written") { FileManager.default.fileExists(atPath: done.path) }
        try await restore(pane)
        let count = board.changeCount
        for (phase, gate) in [("queued", "metadata"), ("metadata", "metadata"), ("capture", "capture"), ("metadata-only", "metadata")] {
            let loaded = pane.scrollPosition().retainedHistoryRows, beeps = pane.visualBeeps
            connection.visualHoldLoad(gate)
            if phase == "metadata-only" { pane.onScrollTop() } else { pane.onLoadMore() }
            if phase != "queued" { try await wait("\(phase) reply held", within: 2) { self.connection.visualHeld(gate) } }
            key(pane, "C", [.command, .shift], ignoring: "C")
            try await wait("\(phase) load refuses entry", within: 2) { pane.visualBeeps == beeps + 1 }
            XCTAssertNil(pane.copyMode, phase)
            XCTAssertNil(label(pane), phase)
            XCTAssertFalse(pane.frozen, phase)
            try await wait("\(phase) reply held", within: 2) { self.connection.visualHeld(gate) }
            connection.visualReleaseLoad(gate)
            if phase != "metadata-only" {
                try await wait("\(phase) load finished", within: 5) { pane.scrollPosition().retainedHistoryRows > loaded }
            }
            try await roundTrip()
            XCTAssertFalse(pane.resizeDirty, phase)
            try await enter(pane)
            keys(pane, "q")
        }
        XCTAssertEqual(board.changeCount, count)
    }

    func testCopyKeysAndIMEAreIsolated() async throws {
        let pane = try await rawPane()
        try await emit(pane, "\u{1b}[>11uready\r\n", until: "ready")
        pane.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(pane.hasMarkedText())
        let start = connection.visualCommands.count
        try await enter(pane)
        XCTAssertFalse(pane.hasMarkedText(), "entry cancels the preedit")
        for c in ["a", "1", " ", "Z"] { key(pane, c, c == "Z" ? .shift : []) }
        key(pane, "\u{3}", .control, ignoring: "c")
        key(pane, String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.shift, .numericPad, .function], code: 123)
        key(pane, String(UnicodeScalar(NSRightArrowFunctionKey)!), [.option, .numericPad, .function], code: 124)
        key(pane, "j", .command)
        key(pane, "e", .command)
        key(pane, "v", .command)
        key(pane, "a", type: .keyUp)
        key(pane, "c", .command, type: .keyUp)
        for flags: CGEventFlags in [.maskShift, []] {
            let cg = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x38, keyDown: true))
            cg.type = .flagsChanged
            cg.flags = flags
            pane.flagsChanged(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        }
        pane.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        pane.setMarkedText("y", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        pane.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertFalse(pane.hasMarkedText())
        XCTAssertNotNil(pane.copyMode)
        keys(pane, "q")
        try await sentinel(pane, since: start)
    }

    func testPendingInputRefusalsAndLateWork() async throws {
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .remote("copy-host"), runtime: runtime, start: false)
        owner.testUploadBase = "/tmp/kc-" + UUID().uuidString.prefix(8)
        var replies: [Data] = []
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13, host: owner.host) { replies.append($0) })
        owner.window.contentView = pane
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        owner.window.makeFirstResponder(pane)
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        defer { PaneView.visualConversion = nil; pane.dispose(); owner.close(); board.releaseGlobally() }
        nonisolated(unsafe) let target = pane
        func feed(_ text: String) async {
            await withCheckedContinuation { done in DispatchQueue.global().async { target.feed(Data(text.utf8)); done.resume() } }
        }
        func refused(_ why: String) {
            let beeps = pane.visualBeeps
            pane.toggleCopyMode(nil)
            XCTAssertEqual(pane.visualBeeps, beeps + 1, why)
            XCTAssertNil(pane.copyMode, why)
        }
        board.clearContents()
        board.setString("one\ntwo", forType: .string)
        XCTAssertTrue(pane.performKeyEquivalent(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: owner.window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))))
        try await wait("paste confirmation sheet", within: 2) { owner.window.attachedSheet != nil }
        refused("paste sheet")
        owner.window.endSheet(try XCTUnwrap(owner.window.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await wait("paste sheet closed", within: 2) { owner.window.attachedSheet == nil }
        await feed("\u{1b}]52;c;?\u{7}")
        try await wait("clipboard consent sheet", within: 2) { owner.preparedAlert != nil }
        refused("clipboard consent sheet")
        owner.respondToAlert(.alertThirdButtonReturn)
        let file = owner.testUploadBase! + "-file"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        owner.upload(Result { () throws(Failure) in try Upload(files: [URL(fileURLWithPath: file)], copying: true) }, to: pane)
        XCTAssertNotNil(owner.preparedAlert)
        refused("upload consent sheet")
        owner.respondToAlert(.alertThirdButtonReturn)
        owner.uploadImage(pngData(width: 2, height: 2), to: pane)
        refused("running upload")
        XCTAssertTrue(owner.cancelUploads(pane))
        let point = pane.convert(NSPoint(x: 20, y: 20), to: nil)
        pane.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        refused("held mouse button")
        pane.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))

        owner.clipboardPermission = [.rich: .allow, .clipboard: .allow]
        let b64 = { (text: String) in Data(text.utf8).base64EncodedString() }
        board.clearContents()
        board.setData(pngData(width: 2, height: 2, type: .tiff), forType: .tiff)
        var convert: CheckedContinuation<Void, Never>?
        PaneView.visualConversion = { await withCheckedContinuation { convert = $0 } }
        await feed("\u{1b}]5522;type=read;\(b64("image/png"))\u{1b}\\")
        try await wait("TIFF conversion started", within: 2) { convert != nil }
        refused("pending TIFF conversion")
        convert?.resume()
        convert = nil
        try await wait("conversion served", within: 2) { String(decoding: replies.joined(), as: UTF8.self).contains("DONE") }
        let drag = SyntheticDrag(board)
        XCTAssertEqual(pane.draggingEntered(drag), .copy)

        replies = []
        let requests = Data("\u{1b}]52;c;?\u{7}\u{1b}]5522;type=read;\(b64("image/png"))\u{1b}\\".utf8)
        pane.onCopyCheck = { done in
            DispatchQueue.global().async {
                target.feed(requests)
                DispatchQueue.main.async { done(true) }
            }
        }
        board.clearContents()
        board.declareTypes([.string, .tiff], owner: nil)
        board.setString("text reply", forType: .string)
        board.setData(pngData(width: 2, height: 2, type: .tiff), forType: .tiff)
        pane.toggleCopyMode(nil)
        try await wait("entry with admitted clipboard requests", within: 2) { if case .cursor = pane.copyMode { true } else { false } }
        XCTAssertNotNil(convert, "the program's image read started a conversion before the freeze")
        try await wait("text reply during copy mode", within: 2) { String(decoding: replies.joined(), as: UTF8.self).contains(b64("text reply")) }
        replies = []
        convert?.resume()
        try await wait("late conversion denied", within: 2) { !replies.isEmpty }
        XCTAssertFalse(String(decoding: replies.joined(), as: UTF8.self).contains("DATA"), String(decoding: replies.joined(), as: UTF8.self))
        XCTAssertFalse(pane.performDragOperation(drag), "a drag accepted before entry drops nothing")
        XCTAssertFalse(owner.cancelUploads(pane))
        XCTAssertNotNil(pane.copyMode)
    }

    func testAlternateFrozenCopy() async throws {
        let pane = try await rawPane()
        let rows = Int(ghostty_surface_size(pane.surface).rows)
        try await emit(pane, "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1007h\u{1b}[H" + (0..<rows - 1).map { "alt-\($0)\r\n" }.joined() + "count-1",
                       until: "count-1")
        try await enter(pane)
        XCTAssertTrue(pane.alternate)
        try await emit(pane, "\r\u{1b}[Kcount-2", until: "count-2")
        let count = board.changeCount
        keys(pane, "G0v$y")
        XCTAssertEqual(board.string(forType: .string), "count-1", "copy mode copies the frozen screen")
        try await wait("dirty exit restored", within: 2) { !pane.resizeDirty }
        try await settle()
        try await enter(pane)
        keys(pane, "g0jvj$y")
        XCTAssertEqual(board.changeCount, count + 2)
        XCTAssertEqual(board.string(forType: .string), "alt-1\nalt-2")
        try await enter(pane)
        keys(pane, "gk")
        XCTAssertEqual(cursor(pane)?.y, 0)
        key(pane, "\u{15}", .control, ignoring: "u")
        XCTAssertEqual(cursor(pane)?.y, 0)
        keys(pane, "G")
        XCTAssertEqual(cursor(pane)?.y, rows - 1)
        key(pane, "\u{4}", .control, ignoring: "d")
        XCTAssertEqual(cursor(pane)?.y, rows - 1)
        XCTAssertEqual(pane.scrollPosition().retainedHistoryRows, 0)
        keys(pane, "q")
    }

    func testAlternateMouseAndWheelIsolation() async throws {
        let pane = try await rawPane()
        try await emit(pane, "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1007hmouse-ready", until: "mouse-ready")
        let start = connection.visualCommands.count
        try await enter(pane)
        let point = pane.convert(NSPoint(x: 30, y: pane.bounds.height / 2), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        pane.mouseEntered(with: mouse(.mouseMoved))
        pane.mouseMoved(with: mouse(.mouseMoved))
        pane.mouseDragged(with: mouse(.leftMouseDragged))
        pane.rightMouseDragged(with: mouse(.rightMouseDragged))
        pane.mouseExited(with: mouse(.mouseMoved))
        for y: Int32 in [40, -40] { pane.scrollWheel(with: try XCTUnwrap(pane.wheelEvent(y: y))) }
        pane.scrollWheel(with: try XCTUnwrap(pane.wheelEvent(y: 2, precise: false)))
        XCTAssertNotNil(pane.copyMode)
        pane.mouseDown(with: mouse(.leftMouseDown))
        XCTAssertNil(pane.copyMode, "a click exits")
        pane.mouseUp(with: mouse(.leftMouseUp))
        try await emit(pane, "\u{1b}[?1000l\u{1b}[?1003l\u{1b}[?1006lwheel-ready", until: "wheel-ready")
        try await enter(pane)
        for y: Int32 in [40, -40] { pane.scrollWheel(with: try XCTUnwrap(pane.wheelEvent(y: y))) }
        pane.scrollWheel(with: try XCTUnwrap(pane.wheelEvent(y: 2, precise: false)))
        keys(pane, "q")
        try await sentinel(pane, since: start)
    }

    func testDroppedScreenSwitchRestoresCurrentScreen() async throws {
        let pane = try await rawPane()
        try await emit(pane, (0..<40).map { "primary-\($0)\r\n" }.joined(), until: "primary-39")
        try await enter(pane)
        try await emit(pane, "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[Halternate-now", until: "alternate-now")
        XCTAssertFalse(pane.alternate)
        keys(pane, "q")
        try await wait("exit restored the alternate screen", within: 2) { !pane.resizeDirty && pane.alternate }
        try await settle()
        var expected = try await tmuxScreen(pane)
        XCTAssertEqual(screen(pane), expected)
        XCTAssertTrue(ghostty_surface_mouse_captured(pane.surface), "the restore replays the program's mouse mode")
        try await enter(pane)
        try await emit(pane, "\u{1b}[?1000l\u{1b}[?1049lprimary-again", until: "primary-again")
        keys(pane, "q")
        XCTAssertNil(pane.resizeAnchor, "an alternate-screen exit stores no anchor")
        try await wait("exit restored the primary screen", within: 2) { !pane.resizeDirty && !pane.alternate }
        try await settle()
        expected = try await tmuxScreen(pane)
        XCTAssertEqual(screen(pane), expected)
    }

    func testLoadedTopNeverLoads() async throws {
        try await start(history: 30000)
        try await paint(lines: 25000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        window.makeFirstResponder(pane)
        XCTAssertEqual(pane.scrollPosition().retainedHistoryRows, historyChunkSize)
        pane.requestScroll(historyChunkSize)
        try await wait("Load more visible") { pane.visualPill }
        let queries = connection.visualMetadataQueries, restores = connection.visualRestores
        connection.visualCommands.removeAll()
        try await enter(pane)
        XCTAssertTrue(connection.visualCommands.isEmpty, "entry sends no command: \(connection.visualCommands.map(\.line))")
        XCTAssertFalse(pane.visualPill)
        keys(pane, "gk")
        key(pane, "\u{15}", .control, ignoring: "u")
        pane.scrollWheel(with: try XCTUnwrap(pane.wheelEvent(y: 400)))
        XCTAssertEqual(cursor(pane)?.y, 0)
        try await roundTrip()
        XCTAssertEqual(connection.visualMetadataQueries, queries)
        XCTAssertFalse(pane.visualPill)
        keys(pane, "q")
        try await roundTrip()
        try await wait("pill returns after a clean exit", within: 2) { pane.visualPill }
        XCTAssertEqual(connection.visualRestores, restores)
        XCTAssertEqual(connection.visualMetadataQueries, queries)
        XCTAssertEqual(pane.scrollPosition().retainedHistoryRows, historyChunkSize)
    }

    func testEveryLifecycleExitAndAnchor() async throws {
        let pane = try await rawPane()
        try await emit(pane, (0..<200).map { "anchor-\($0)\r\n" }.joined(), until: "anchor-199")
        func exits(_ name: String, _ on: PaneView = pane, _ action: () async throws -> Void) async throws {
            if on.window?.firstResponder !== on { window.makeFirstResponder(on) }
            try await enter(on)
            try await action()
            try await wait("\(name) exits copy mode", within: 2) { on.copyMode == nil }
            XCTAssertNil(label(on), name)
            XCTAssertNil(cursor(on), name)
            try await settle()
        }
        let size = ghostty_surface_size(pane.surface)
        try await enter(pane)
        pane.resize(cols: Int(size.columns), rows: Int(size.rows))
        XCTAssertNotNil(pane.copyMode, "an unchanged grid keeps copy mode")
        keys(pane, "q")
        try await exits("resize") { window.setContentSize(NSSize(width: 700, height: 500)) }
        try await exits("font") { _ = ghostty_surface_binding_action(pane.surface, "increase_font_size:1", 20) }
        _ = ghostty_surface_binding_action(pane.surface, "reset_font_size", 15)
        try await settle()
        try await exits("find") { pane.showFind() }
        XCTAssertNotNil(pane.find)
        pane.find?.close()
        try await exits("sidebar focus") { window.makeFirstResponder(nil) }
        try await command(["split-window", "-t", pane.pane.description, "exec /bin/cat"])
        try await wait("split pane") { self.terminal?.panes.count == 2 }
        try await settle()
        let other = try XCTUnwrap(terminal?.panes.first { $0 !== pane })
        try await exits("pane focus") { window.makeFirstResponder(other) }
        try await exits("pane death", other) {
            try await command(["kill-pane", "-t", other.pane.description])
            try await wait("pane closed") { other.disposed }
        }
        try await exits("window switch") {
            try await command(["new-window", "-t", "visual"])
            try await wait("pane hidden") { pane.isHiddenOrHasHiddenAncestor }
        }
        try await command(["select-window", "-t", "visual:0"])
        try await wait("pane shown") { !pane.isHiddenOrHasHiddenAncestor }
        try await settle()
        window.makeFirstResponder(pane)

        pane.requestScroll(20)
        try await settle()
        let top = screen(pane).first
        try await enter(pane)
        try await emit(pane, "late-1\r\nlate-2\r\n", until: "late-2")
        keys(pane, "q")
        try await wait("dirty scrolled exit restored", within: 2) { !pane.resizeDirty }
        try await settle()
        XCTAssertEqual(screen(pane).first, top, "a scrolled exit returns to the same text")
        try await exits("connection close") { connection.close(cause: .quit, keepingView: true) }
    }

    func testRefusedClipboardWriteStillExits() async throws {
        let pane = try await rawPane()
        try await emit(pane, "refused\r\n", until: "refused")
        try await enter(pane)
        let count = board.changeCount
        keys(pane, "k0v$")
        pane.visualRefuseInput()
        keys(pane, "y")
        XCTAssertNil(pane.copyMode)
        XCTAssertEqual(board.changeCount, count)
    }

    private func copySnapshots(dark: Bool, testName: String = #function) async throws {
        let pane = try await rawPane(dark: dark)
        try await emit(pane, (0..<40).map { "snapshot-\($0) text\r\n" }.joined(), until: "snapshot-39")
        try await enter(pane)
        keys(pane, "kkv0k")
        try await snapshot("copy", testName: testName)
        keys(pane, "q")
        try await emit(pane, "\u{1b}[?1049h\u{1b}[H" + (0..<10).map { "alternate-\($0)\r\n" }.joined(), until: "alternate-9")
        try await enter(pane)
        keys(pane, "kkkv$j")
        try await snapshot("copy-alternate", testName: testName)
        keys(pane, "q")
    }

    func testCopyLabelSnapshots() async throws { try await copySnapshots(dark: false) }
    func testCopyLabelSnapshotsDark() async throws { try await copySnapshots(dark: true) }
}
