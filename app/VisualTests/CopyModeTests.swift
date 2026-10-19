import AppKit
import GhosttyKit
import SidebarFeed
import SnapshotTesting
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
            key(pane, String(c), c.isUppercase || c == "$" || c == "^" ? .shift : [], code: c == "\r" ? 36 : c == "\u{1b}" ? 53 : 0)
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
        pane.visualCopyLabel
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
                                     ("k0vly", "日本"), ("k0vlly", "日本"), ("k0vllly", "日本 w")] {
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
        XCTAssertEqual(cursor(pane)?.x, 2, "Right steps over a wide character")
        keys(pane, "q")
        XCTAssertNil(cursor(pane))
    }

    func testWordMotions() async throws {
        let pane = try await rawPane()
        let columns = Int(ghostty_surface_size(pane.surface).columns)
        let wrapped = String(repeating: "a", count: columns - 3) + " longword tail"
        try await emit(pane, "one,two  ;; three\r\n   indented\r\n\(wrapped)\r\n日本 wide\r\n", until: "wide")
        try await enter(pane)
        let base = try XCTUnwrap(cursor(pane)).y - 5
        for (sequence, x, row) in [
            ("k", 0, 4), ("l", 2, 4), ("l", 4, 4), ("h", 2, 4), ("h", 0, 4), ("e", 2, 4), ("w", 5, 4), ("b", 0, 4),
            ("b", 7, 3), ("b", columns - 2, 2), ("e", 5, 3), ("w", 7, 3), ("kkk0", 0, 0), ("w", 3, 0), ("w", 4, 0), ("w", 9, 0),
            ("e", 10, 0), ("w", 12, 0), ("w", 3, 1), ("$^", 3, 1), ("j^", 0, 2), ("jl", 1, 3), ("j", 1, 4), ("h", 0, 4),
            ("kl", 1, 3), ("j", 1, 4), ("l", 2, 4), ("kh", 1, 3), ("j", 1, 4), ("e", 2, 4), ("$^", 0, 4),
        ] {
            keys(pane, sequence)
            XCTAssertEqual(cursor(pane)?.x, x, sequence)
            XCTAssertEqual(cursor(pane)?.y, base + row, sequence)
        }
        keys(pane, "q")
        for (sequence, expected) in [
            ("kkkkk0vey", "one"), ("kkkkk0vwey", "one,two"), ("kkkkk0wwwvby", "two  ;"), ("kkk0wvey", "longword"),
            ("kkkk$v^y", "indented"), ("kkkkVby", "one,two  ;; three\n   indented\n"), ("kkkkVey", "   indented\n"),
            ("kkkVwwy", wrapped + "\n"), ("kVby", "\(wrapped)\n日本 wide\n"), ("kVvwy", "日本 w"),
        ] {
            let text = try await copied(pane, sequence)
            XCTAssertEqual(text, expected, sequence)
        }
        for sequence in ["kkkkk0wey", "kkk0wbe\r"] {
            let text = try await copied(pane, sequence)
            XCTAssertNil(text, sequence)
        }
        try await enter(pane)
        try await emit(pane, "\u{1b}[2J\u{1b}[Hreplaced\r\n", until: "replaced")
        keys(pane, "kkkkk0vwey")
        XCTAssertEqual(board.string(forType: .string), "one,two", "motion reads the frozen screen")
        try await wait("dirty exit restored", within: 2) { !pane.resizeDirty }
        try await settle()
        try await emit(pane, String(repeating: "x", count: columns - 1) + "日\r\n", until: "日")
        try await enter(pane)
        let head = try XCTUnwrap(cursor(pane)).y - 2
        for (sequence, x) in [("kk$", columns - 1), ("l", columns - 2), ("$h", columns - 2)] {
            keys(pane, sequence)
            XCTAssertEqual(cursor(pane)?.x, x, sequence)
            XCTAssertEqual(cursor(pane)?.y, head, sequence)
        }
        keys(pane, "q")
    }

    func testWordMotionFollowsTheViewport() async throws {
        let pane = try await rawPane()
        try await emit(pane, "target\r\n" + String(repeating: "  \r\n", count: 60) + "end\r\n", until: "end")
        try await enter(pane)
        let end = try XCTUnwrap(cursor(pane)).y - 1, target = end - 61
        for (sequence, y) in [("b", end), ("b", target), ("w", end)] {
            keys(pane, sequence)
            XCTAssertEqual(cursor(pane)?.x, 0, sequence)
            XCTAssertEqual(cursor(pane)?.y, y, sequence)
            try await wait("the viewport shows \(sequence) at row \(y)", within: 2) {
                var bar = ghostty_surface_scrollbar_s()
                return ghostty_surface_scrollbar(pane.surface, &bar) && Int(bar.offset) <= y && y < Int(bar.offset + bar.len)
            }
            XCTAssertEqual(cursor(pane)?.y, y, sequence)
        }
        keys(pane, "q")
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
        try await wait("resumed output arrives live", within: 2) {
            let screen = self.screen(pane)
            return screen.contains("resumed") && screen.contains("while-paused")
        }
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
        XCTAssertTrue(entering(pane), "entry waits for the admitted parse")
        XCTAssertEqual(label(pane), "COPY…")
        XCTAssertNil(cursor(pane))
        let promptBeeps = pane.visualBeeps
        sendCommandO()
        XCTAssertTrue(promptBoxes.boxes.isEmpty, "⌘O while copy mode enters opens no box")
        XCTAssertEqual(pane.visualBeeps, promptBeeps, "⌘O while copy mode enters does not beep")
        release.signal()
        try await wait("entry completes after the parse", within: 2) { pane.copyMode != nil && !self.entering(pane) }
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
        let entryTimeout = PaneView.copyEntryTimeout
        PaneView.copyEntryTimeout = 0.5
        defer { PaneView.copyEntryTimeout = entryTimeout }
        key(pane, "C", [.command, .shift], ignoring: "C")
        try await wait("held entry admitted", within: 2) { pane.frozen }
        try await wait("deadline cancels a held entry", within: 3) { pane.copyMode == nil && pane.visualBeeps == beeps + 1 }
        PaneView.copyEntryTimeout = entryTimeout
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
            try await wait("alternate screen: \(schedule.name)") { pane.alternate }
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
            self.mouse(pane, type, at: NSPoint(x: pane.cell.width * (Double(column) + 0.5), y: pane.bounds.height - pane.cell.height / 2))
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
        for step in ["k", "l", "v", "j", "$", "v", "w", "b", "e", "^", "V", "k", "j", "V", "v", "V", "w", "b", "e", "^", "\u{1b}"] {
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
        try await wait("alternate screen") { pane.alternate }
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
        for c in ["a", "1", " ", "Z", "w", "b", "e", "^"] { key(pane, c, c == "Z" || c == "^" ? .shift : []) }
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

    func testEntryIgnoresAButtonHeldOutsideThePane() async throws {
        let pane = try await rawPane()
        try await emit(pane, "ready\r\n", until: "ready")
        let held = try XCTUnwrap(class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)))
        let hardware = method_setImplementation(held, imp_implementationWithBlock({ (_: AnyClass) in 1 } as @convention(block) (AnyClass) -> Int))
        defer { method_setImplementation(held, hardware) }
        XCTAssertEqual(NSEvent.pressedMouseButtons, 1)
        try await enter(pane)
        keys(pane, "q")
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
        defer { Upload.visualImagePreparation = nil; pane.dispose(); owner.close(); board.releaseGlobally() }
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
        Upload.visualImagePreparation = { await withCheckedContinuation { convert = $0 } }
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
        try await wait("alternate screen") { pane.alternate }
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
            self.mouse(pane, type, at: pane.convert(point, from: nil))
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
        XCTAssertNotNil(pane.copyMode, "a click stays in copy mode")
        pane.mouseUp(with: mouse(.leftMouseUp))
        keys(pane, "q")
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
        let columns = Int(ghostty_surface_size(pane.surface).columns)
        for (sequence, x) in [("gkb", 0), ("e", columns - 1), ("b", 0)] {
            keys(pane, sequence)
            XCTAssertEqual(cursor(pane)?.x, x, sequence)
            XCTAssertEqual(cursor(pane)?.y, 0, sequence)
        }
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

    private func type(_ pane: PaneView, _ text: String) throws {
        let editor = try XCTUnwrap(pane.window?.firstResponder as? NSTextView), find = try XCTUnwrap(pane.find)
        XCTAssertTrue(editor.isFieldEditor && editor.isDescendant(of: find))
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func field(_ pane: PaneView, _ selector: Selector) throws {
        let editor = try XCTUnwrap(pane.window?.firstResponder as? NSTextView)
        editor.doCommand(by: selector)
    }

    private func found(_ pane: PaneView) -> String? {
        pane.find?.subviews.compactMap { $0 as? NSTextField }.first { $0 !== pane.find?.field }?.stringValue
    }

    private func at(_ pane: PaneView, _ x: Int, _ y: Int, _ step: String) async throws {
        try await wait("cursor at \(x),\(y) after \(step)", within: 2) { self.cursor(pane).map { $0 == (x, y) } == true }
        if case .cursor = pane.copyMode {} else if case .selecting = pane.copyMode {} else if case .lines = pane.copyMode {} else { XCTFail("copy mode kept: \(step)") }
    }

    func testCopySearchMovesTheCursorAndSelectionEnd() async throws {
        let pane = try await rawPane()
        try await emit(pane, "one target\r\ntwo\r\nthree target here\r\nfour\r\ntarget five\r\n", until: "five")
        try await enter(pane)
        let base = try XCTUnwrap(cursor(pane)).y - 5, count = board.changeCount
        key(pane, "?", .shift)
        XCTAssertNotNil(pane.find)
        XCTAssertTrue(PaneView.owner(window.firstResponder) === pane && window.firstResponder !== pane, "? focuses the bar's field")
        XCTAssertEqual(label(pane), "COPY")
        XCTAssertTrue(pane.frozen)
        try type(pane, "target")
        try await at(pane, 0, base + 4, "typing: the newest match")
        try await wait("loaded count", within: 2) { self.found(pane) == "3 matches (loaded)" }
        try field(pane, #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(window.firstResponder === pane, "Return in the field returns focus to the pane")
        XCTAssertNotNil(pane.find, "Return keeps the bar")
        for (step, x, y) in [("n", 6, 2), ("n", 4, 0), ("N", 6, 2)] {
            keys(pane, step)
            try await at(pane, x, base + y, "? then \(step)")
        }
        key(pane, "/")
        XCTAssertTrue(PaneView.owner(window.firstResponder) === pane && window.firstResponder !== pane, "/ focuses the same field")
        XCTAssertEqual(pane.find?.field.stringValue, "target")
        try field(pane, #selector(NSResponder.insertNewline(_:)))
        for (step, x, y) in [("n", 0, 4), ("N", 6, 2)] {
            keys(pane, step)
            try await at(pane, x, base + y, "/ then \(step)")
        }
        keys(pane, "y")
        XCTAssertNil(pane.copyMode)
        XCTAssertEqual(board.changeCount, count, "a cursor moved by search grants no copy")
        XCTAssertNil(pane.find, "copy exit closes the bar")

        try await enter(pane)
        key(pane, "?", .shift)
        try type(pane, "target")
        try await at(pane, 0, base + 4, "second session")
        try field(pane, #selector(NSResponder.insertNewline(_:)))
        keys(pane, "kkv")
        try await at(pane, 0, base + 2, "v anchor")
        keys(pane, "n")
        try await at(pane, 6, base + 2, "v keeps its anchor")
        keys(pane, "n")
        try await at(pane, 4, base, "v end moves")
        keys(pane, "y")
        XCTAssertEqual(board.string(forType: .string), "target\ntwo\nt")

        try await enter(pane)
        key(pane, "?", .shift)
        try type(pane, "target")
        try await at(pane, 0, base + 4, "line session")
        try field(pane, #selector(NSResponder.insertNewline(_:)))
        keys(pane, "Vn")
        try await wait("V re-expands to the match's line", within: 2) {
            var value = ghostty_selection_s()
            return ghostty_surface_selection(pane.surface, &value) && (value.top_left.x, value.top_left.y) == (0, UInt32(base + 2))
        }
        keys(pane, "y")
        XCTAssertEqual(board.string(forType: .string), "three target here\nfour\ntarget five\n")
        XCTAssertEqual(board.changeCount, count + 2)
    }

    func testCopySearchBarFocusAndExits() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha match\r\nbeta\r\nmatch gamma\r\n", until: "gamma")
        pane.showFind()
        try type(pane, "match")
        try await wait("ordinary find lands", within: 5) { self.found(pane) == "1 of 2" }
        let find = try XCTUnwrap(pane.find), captures = connection.visualSearchCaptures
        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(PaneView.toggleCopyMode(_:)), with: nil), "Copy Mode from the field")
        try await wait("copy mode entered", within: 2) { if case .cursor = pane.copyMode { true } else { false } }
        let start = try XCTUnwrap(cursor(pane)), base = start.y - 3
        XCTAssertTrue(pane.find === find, "the open query is kept")
        XCTAssertEqual(find.field.stringValue, "match")
        XCTAssertTrue(window.firstResponder === pane)
        try await wait("loaded count", within: 2) { self.found(pane) == "2 matches (loaded)" }
        try await emit(pane, "late match\r\n", until: "late match")
        try await Task.sleep(for: .milliseconds(400))
        try await roundTrip()
        XCTAssertEqual(found(pane), "2 matches (loaded)", "frozen output restarts no search")
        XCTAssertEqual(connection.visualSearchCaptures, captures, "copy-mode search scans no tmux history")
        XCTAssertTrue(cursor(pane).map { $0 == start } == true, "a carried query moves no cursor until asked")
        keys(pane, "n")
        try await at(pane, 0, base + 2, "n after carry-in")
        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(PaneView.showFind(_:)), with: nil), "Cmd-F in copy mode")
        XCTAssertTrue(window.firstResponder !== pane && PaneView.owner(window.firstResponder) === pane)
        XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(PaneView.findNext(_:)), with: nil), "Cmd-G from the field")
        try await at(pane, 6, base, "Cmd-G")
        try field(pane, #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(pane.find, "Escape in the field closes the bar")
        XCTAssertTrue(window.firstResponder === pane)
        try await at(pane, 6, base, "the first Escape keeps copy mode")
        keys(pane, "G")
        keys(pane, "n")
        XCTAssertNotNil(pane.find, "n reopens the remembered query")
        XCTAssertTrue(window.firstResponder === pane)
        try await at(pane, 0, base + 2, "n after Escape")
        try XCTUnwrap(pane.find?.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Done" }).performClick(nil)
        XCTAssertNil(pane.find, "Done closes the bar")
        try await at(pane, 0, base + 2, "Done keeps copy mode")
        keys(pane, "n")
        try await wait("bar reopened", within: 2) { pane.find != nil }
        keys(pane, "\u{1b}")
        XCTAssertNil(pane.find, "Escape in the pane closes the bar first")
        XCTAssertNotNil(pane.copyMode)
        keys(pane, "\u{1b}")
        XCTAssertNil(pane.copyMode, "a second Escape exits")

        try await wait("dirty exit restored", within: 2) { !pane.resizeDirty }
        try await settle()
        try await enter(pane)
        key(pane, "/")
        window.makeFirstResponder(nil)
        XCTAssertNil(pane.copyMode, "focus leaving the field for another owner exits")
        XCTAssertNil(pane.find)
        XCTAssertTrue(window.firstResponder === window, "the exit does not take focus back")
        window.makeFirstResponder(pane)
        try await sentinel(pane, since: connection.visualCommands.count)
    }

    func testCopySearchOnlyLoadedHistory() async throws {
        try await start(history: 100000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        let fixture = directory.appendingPathComponent("history.txt"), done = directory.appendingPathComponent("history-done")
        let rows = 3 * historyChunkSize + 2000
        try (0..<rows).map { "row-\($0)" + ($0 == 100 ? " old-marker" : $0 == rows - 1000 ? " new-marker" : "") + "\r\n" }.joined()
            .write(to: fixture, atomically: true, encoding: .utf8)
        try await command(["respawn-pane", "-k", "-t", pane.pane.description, "/bin/cat '\(fixture.path)'; /usr/bin/touch '\(done.path)'; exec /bin/sleep 600"])
        try await wait("history fixture written") { FileManager.default.fileExists(atPath: done.path) }
        try await restore(pane)
        try await enter(pane)
        let loaded = pane.scrollPosition().retainedHistoryRows, start = try XCTUnwrap(cursor(pane))
        let captures = connection.visualSearchCaptures, queries = connection.visualMetadataQueries, restores = connection.visualRestores
        connection.visualCommands.removeAll()
        func unchanged(_ step: String) async throws {
            try await roundTrip()
            XCTAssertEqual(connection.visualSearchCaptures, captures, step)
            XCTAssertEqual(connection.visualMetadataQueries, queries, step)
            XCTAssertEqual(connection.visualRestores, restores, step)
            XCTAssertEqual(pane.scrollPosition().retainedHistoryRows, loaded, step)
            XCTAssertEqual(connection.visualCommands.filter { $0.line != Command("display-message", "-p", "").line }.map(\.line), [], step)
        }
        key(pane, "?", .shift)
        try type(pane, "old-marker")
        try await wait("no loaded match", within: 2) { self.found(pane) == "No matches (loaded)" }
        try await unchanged("unloaded query")
        XCTAssertTrue(cursor(pane).map { $0 == start } == true, "no match leaves the cursor")
        try type(pane, "new-marker")
        try await at(pane, String("row-\(rows - 1000) ").count, start.y - 1000, "loaded match")
        try await wait("loaded count") { self.found(pane) == "1 matches (loaded)" }
        try await unchanged("loaded query")
        try field(pane, #selector(NSResponder.cancelOperation(_:)))
        keys(pane, "q")
        try await settle()

        pane.showFind()
        try type(pane, "old-marker")
        try await wait("ordinary find scans tmux and loads the old match", within: 20) {
            self.connection.visualSearchCaptures > captures && pane.scrollPosition().retainedHistoryRows > loaded
        }
        pane.find?.close()
    }

    func testCopySearchAlternateScreen() async throws {
        let pane = try await rawPane()
        try await emit(pane, "primary match\r\n\u{1b}[?1049h\u{1b}[Halt one\r\nalt match two", until: "match two")
        try await enter(pane)
        try await wait("alternate screen") { pane.alternate }
        key(pane, "?", .shift)
        try type(pane, "match")
        try await at(pane, 4, 1, "alternate match")
        try await wait("alternate loaded count") { self.found(pane) == "1 matches (loaded)" }
        try field(pane, #selector(NSResponder.insertNewline(_:)))
        keys(pane, "g0vn")
        try await at(pane, 4, 1, "alternate v end")
        keys(pane, "y")
        XCTAssertEqual(board.string(forType: .string), "alt one\nalt m")
    }

    func testCopySearchIgnoresSupersededQueries() async throws {
        let pane = try await rawPane()
        try await emit(pane, (0..<300).map { "aaa-\($0)\r\n" }.joined() + "bbb-last\r\nend\r\n", until: "end")
        try await enter(pane)
        let base = try XCTUnwrap(cursor(pane)).y
        let start = try XCTUnwrap(cursor(pane))
        var held: (start: (x: Int, y: Int)?, deliver: () -> Void)?
        GhosttyRuntime.visualHoldSelected = { start, deliver in
            if held == nil, start != nil { held = (start, deliver) } else { deliver() }
        }
        defer { GhosttyRuntime.visualHoldSelected = nil }
        key(pane, "?", .shift)
        try type(pane, "aaa")
        try await wait("an aaa selection is held", within: 2) { held != nil }
        XCTAssertTrue(held?.start.map { $0 == (0, base - 3) } == true, "the held event names the newest aaa match")
        XCTAssertTrue(cursor(pane).map { $0 == start } == true, "the held event has not moved the cursor")
        try type(pane, "bbb")
        try await at(pane, 0, base - 2, "the newest query")
        held?.deliver()
        try await Task.sleep(for: .milliseconds(100))
        try await at(pane, 0, base - 2, "the released superseded event moves no cursor")
        try type(pane, "")
        try await wait("empty query clears the label", within: 2) { self.found(pane) == "" }
        try await at(pane, 0, base - 2, "an empty query moves nothing")
        try field(pane, #selector(NSResponder.cancelOperation(_:)))
        keys(pane, "q")
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

    private func findThree(_ pane: PaneView, _ expected: String) async throws {
        pane.showFind()
        try type(pane, "sidebar")
        try await wait("matches", within: 5) { self.found(pane)?.hasPrefix("1") == true }
        pane.find?.next()
        pane.find?.next()
        try await wait("find label \(expected)", within: 2) { self.found(pane) == expected }
        try await drain(pane.runtime)
        pane.layoutSubtreeIfNeeded()
    }

    func testPaneChromeSnapshots() async throws {
        let fade = WindowView.toolbarFadeDuration
        WindowView.toolbarFadeDuration = 0
        defer { WindowView.toolbarFadeDuration = fade }
        let pane = try await rawPane()
        try await emit(pane, ["$ rg -n sidebar App", "App/sidebar.swift:17: sidebar.next", "App/row.swift:25: let close = x",
                              "App/owner.swift:96: sidebar.tabs", "App/tabs.swift:37: labelFont(tab)", "App/feed.swift:39: sidebar.title",
                              "App/sidebar_list.swift: sidebar", "App/view.swift:65: sidebar.recent", "App/main.swift: sidebar, sidebar",
                              "App/keys.swift: let sidebar = 1", "App/done.swift:9: sidebar()", "$ "].joined(separator: "\r\n"), until: "sidebar()")
        let chrome = try XCTUnwrap(terminal?.subviews.compactMap { $0 as? PaneChrome }.first { $0.pane == pane.pane })
        for theme in ["light", "dark"] {
            try await hover(pane, true)
            XCTAssertEqual(chrome.toolbarFrame, NSRect(x: 547, y: 8, width: 145, height: 32))
            try await snapshot("\(theme)-toolbar")
            pane.showFind()
            pane.layoutSubtreeIfNeeded()
            let find = try XCTUnwrap(pane.find)
            XCTAssertEqual(find.frame, NSRect(x: 272, y: 8, width: 420, height: 32))
            XCTAssertEqual(chrome.toolbarFrame, NSRect(x: 547, y: 48, width: 145, height: 32), "the toolbar goes below find")
            XCTAssertEqual(find.accessibilityLabel(), "Find in Terminal")
            XCTAssertTrue(find.field.nextKeyView?.nextKeyView?.nextKeyView?.nextKeyView === pane, "field, Previous, Next, Done, then the pane")
            try await snapshot("\(theme)-find-empty")
            find.close()
            try await findThree(pane, "3 of 12")
            try await snapshot("\(theme)-find-3-of-12")
            XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(PaneView.toggleCopyMode(_:)), with: nil))
            try await wait("loaded count", within: 2) { self.found(pane) == "12 matches (loaded)" }
            XCTAssertTrue(window.firstResponder === pane)
            XCTAssertEqual(label(pane), "COPY")
            try await snapshot("\(theme)-copy-find")
            keys(pane, "\u{1b}")
            XCTAssertNil(pane.find)
            XCTAssertEqual(chrome.toolbarFrame.minY, 8, "the toolbar returns when find closes")
            try await snapshot("\(theme)-copy-toolbar")
            try await hover(pane, false)
            try await snapshot("\(theme)-copy")
            keys(pane, "q")
            try await wait("copy exit restored", within: 2) { !pane.resizeDirty }
            let check = pane.onCopyCheck
            pane.onCopyCheck = { _ in }
            pane.toggleCopyMode(nil)
            if case .entering(let deadline) = pane.copyMode { deadline.cancel() }
            XCTAssertEqual(label(pane), "COPY…")
            try await snapshot("\(theme)-copy-entering")
            pane.endCopy()
            pane.onCopyCheck = check
            window.setContentSize(NSSize(width: 300, height: 560))
            try await settle()
            try await hover(pane, true)
            try await findThree(pane, "3/12")
            XCTAssertEqual(pane.find?.frame, NSRect(x: 8, y: 8, width: 284, height: 32))
            XCTAssertEqual(chrome.toolbarFrame, NSRect(x: 147, y: 48, width: 145, height: 32))
            try await snapshot("\(theme)-narrow")
            XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(#selector(PaneView.toggleCopyMode(_:)), with: nil))
            try await wait("compact loaded count", within: 2) { self.found(pane) == "12 (loaded)" }
            try await snapshot("\(theme)-copy-narrow")
            keys(pane, "\u{1b}\u{1b}")
            XCTAssertNil(pane.copyMode)
            try await wait("copy exit restored", within: 2) { !pane.resizeDirty }
            window.setContentSize(NSSize(width: 700, height: 560))
            try await settle()
            guard theme == "light" else { break }
            try await hover(pane, true)
            try await findThree(pane, "3 of 12")
            try await darken()
            try await snapshot("theme-switch-dark")
            try field(pane, #selector(NSResponder.cancelOperation(_:)))
            XCTAssertNil(pane.find)
        }
    }

    func testCopyLabelSnapshots() async throws { try await copySnapshots(dark: false) }
    func testCopyLabelSnapshotsDark() async throws { try await copySnapshots(dark: true) }

    private func mouse(_ view: NSView, _ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1,
                       mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: mods, timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func mouse(_ pane: PaneView, _ type: NSEvent.EventType, x: Int, y: Int, clickCount: Int = 1,
                       mods: NSEvent.ModifierFlags = []) -> NSEvent {
        var bar = ghostty_surface_scrollbar_s()
        _ = ghostty_surface_scrollbar(pane.surface, &bar)
        return mouse(pane, type, at: NSPoint(x: (CGFloat(x) + 0.5) * pane.cell.width,
                                             y: pane.bounds.height - pane.renderInsets.top - (CGFloat(y - Int(bar.offset)) + 0.5) * pane.cell.height),
                     clickCount: clickCount, mods: mods)
    }

    private func drag(_ pane: PaneView, from: (Int, Int), to: (Int, Int), mods: NSEvent.ModifierFlags = [],
                      clickCount: Int = 1, delivered: Bool = false) {
        if delivered {
            window.sendEvent(mouse(pane, .leftMouseDown, x: from.0, y: from.1, clickCount: clickCount, mods: mods))
            window.sendEvent(mouse(pane, .leftMouseDragged, x: to.0, y: to.1, clickCount: clickCount, mods: mods))
            window.sendEvent(mouse(pane, .leftMouseUp, x: to.0, y: to.1, clickCount: clickCount, mods: mods))
        } else {
            pane.mouseDown(with: mouse(pane, .leftMouseDown, x: from.0, y: from.1, clickCount: clickCount, mods: mods))
            pane.mouseDragged(with: mouse(pane, .leftMouseDragged, x: to.0, y: to.1, clickCount: clickCount, mods: mods))
            pane.mouseUp(with: mouse(pane, .leftMouseUp, x: to.0, y: to.1, clickCount: clickCount, mods: mods))
        }
    }

    func testCopyModeMouseGestures() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        try await enter(pane)
        let row = try XCTUnwrap(cursor(pane)).y - 3
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 6, y: row))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 6, y: row))
        XCTAssertEqual(cursor(pane)?.x, 6, "a click places the cursor")
        XCTAssertEqual(cursor(pane)?.y, row)
        for x in [0, 4] {
            pane.mouseDown(with: mouse(pane, .leftMouseDown, x: x, y: row, clickCount: 2))
            XCTAssertEqual(pane.readSelection(), "alpha", "double-click on a word's first or last cell")
            pane.mouseUp(with: mouse(pane, .leftMouseUp, x: x, y: row, clickCount: 2))
        }
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 6, y: row, clickCount: 2))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 6, y: row, clickCount: 2))
        XCTAssertEqual(pane.readSelection(), "beta")
        keys(pane, "y")
        XCTAssertEqual(board.string(forType: .string), "beta", "y copies a mouse selection and exits")
        XCTAssertNil(pane.copyMode)
        try await enter(pane)
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 0, y: row, clickCount: 3))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 0, y: row, clickCount: 3))
        XCTAssertEqual(pane.readSelection().trimmingCharacters(in: .newlines), "alpha beta", "triple-click selects the line")
        keys(pane, "q")
        try await enter(pane)
        drag(pane, from: (0, row), to: (9, row))
        XCTAssertEqual(pane.readSelection(), "alpha beta", "a drag selects")
        keys(pane, "y")
        XCTAssertEqual(board.string(forType: .string), "alpha beta")
        try await enter(pane)
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 0, y: row))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 0, y: row))
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 6, y: row, mods: [.shift]))
        XCTAssertEqual(pane.readSelection(), "alpha b", "shift-click extends the cursor")
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 6, y: row, mods: [.shift]))
        keys(pane, "q")
        try await enter(pane)
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 6, y: row))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 6, y: row))
        keys(pane, "h")
        XCTAssertEqual(cursor(pane)?.x, 5, "the keyboard continues from a mouse cursor")
        keys(pane, "q")
    }

    func testWordSelectionEdges() async throws {
        let pane = try await rawPane()
        try await emit(pane, "a long\r\n", until: "long")
        try await enter(pane)
        let row = try XCTUnwrap(cursor(pane)).y - 2
        for (x, expected) in [(0, "a"), (2, "long")] {
            pane.mouseDown(with: mouse(pane, .leftMouseDown, x: x, y: row, clickCount: 2))
            XCTAssertEqual(pane.readSelection(), expected, "double-click at \(x)")
            pane.mouseUp(with: mouse(pane, .leftMouseUp, x: x, y: row, clickCount: 2))
        }
        keys(pane, "q")
    }

    func testCopyModeAutoscrollStaysLoaded() async throws {
        let pane = try await rawPane()
        try await emit(pane, (0..<60).map { "row-\($0)\r\n" }.joined(), until: "row-59")
        try await enter(pane)
        nonisolated(unsafe) var loads = 0
        nonisolated(unsafe) var tops = 0
        pane.onLoadMore = { loads += 1 }
        pane.onScrollTop = { tops += 1 }
        let from = try XCTUnwrap(cursor(pane))
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 0, y: from.y))
        let outside = pane.convert(NSPoint(x: 4, y: pane.bounds.height + 12), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: outside, modifierFlags: [], timestamp: 0,
                                       windowNumber: pane.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        pane.mouseDragged(with: event)
        try await wait("autoscroll moved the frozen viewport", within: 2) { (pane.scrollTarget ?? 0) > 0 }
        XCTAssertEqual(loads, 0, "autoscroll never loads older history")
        XCTAssertEqual(tops, 0, "autoscroll never asks for the loaded top")
        XCTAssertNotNil(pane.copyMode)
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 0, y: from.y))
        keys(pane, "q")
    }

    func testContextMenuSelectionRules() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let probe = mouse(pane, .rightMouseDown, x: 0, y: 0)
        XCTAssertNil(pane.menu(for: probe), "no menu with no text and no selection")
        pane.rightMouseDown(with: probe)
        XCTAssertEqual(pane.visualPressed, 0, "the menu path releases Ghostty's right press")
        try await enter(pane)
        let last = try XCTUnwrap(cursor(pane)).y
        let alpha = last - 3
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 0, y: alpha))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 0, y: alpha))
        pane.selectForMenu(mouse(pane, .rightMouseDown, x: 0, y: alpha))
        XCTAssertEqual(pane.readSelection(), "alpha", "a cursor-only cell has no selection to open")
        let menu = try XCTUnwrap(pane.menu(for: mouse(pane, .rightMouseDown, x: 0, y: alpha)))
        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Prompt with Selection…"])
        pane.selectForMenu(mouse(pane, .rightMouseDown, x: 6, y: alpha))
        XCTAssertEqual(pane.readSelection(), "beta", "right-click on a word elsewhere selects it")
        pane.selectForMenu(mouse(pane, .rightMouseDown, x: 5, y: alpha))
        XCTAssertEqual(pane.readSelection(), "beta", "right-click on an empty cell keeps the selection")
        _ = ghostty_surface_set_selection(pane.surface, nil)
        pane.selectForMenu(mouse(pane, .rightMouseDown, x: 6, y: alpha))
        XCTAssertEqual(pane.readSelection(), "beta", "right-click without a selection selects its word")
        XCTAssertEqual(pane.menu(for: mouse(pane, .rightMouseDown, x: 6, y: alpha))?.items.count, 2)
        pane.copySelectionItem(nil)
        XCTAssertNil(pane.copyMode, "Copy in copy mode exits")
        XCTAssertEqual(board.string(forType: .string), "beta")
        let count = board.changeCount
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 0, y: alpha))
        pane.mouseDragged(with: mouse(pane, .leftMouseDragged, x: 5, y: alpha))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 4, y: alpha))
        XCTAssertEqual(pane.menu(for: mouse(pane, .rightMouseDown, x: 0, y: alpha))?.items.count, 2, "an ordinary selection has the menu")
        pane.copySelectionItem(nil)
        XCTAssertNil(pane.copyMode, "Copy outside copy mode keeps the live pane")
        XCTAssertEqual(board.changeCount, count + 1)
        XCTAssertEqual(board.string(forType: .string), "alpha")
        try await enter(pane)
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 0, y: alpha))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: 0, y: alpha))
        keys(pane, "p")
        XCTAssertTrue(promptBoxes.boxes.isEmpty, "a cursor-only cell opens no box")
        pane.promptSelectionItem(nil)
        try await wait("the menu item opens a box for a cursor-only cell", within: 2) { self.promptBoxes.boxes.count == 1 }
        promptBoxes.closeAll()
        drag(pane, from: (0, alpha), to: (9, alpha))
        keys(pane, "p")
        XCTAssertEqual(promptBoxes.boxes.count, 1, "p opens the prompt for a selection")
        promptBoxes.closeAll()
        keys(pane, "q")
    }

    private final class PromptProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [RPCRequest] = []
        var candidates: [PromptCandidate] = []
        var resolveFailure: Failure?
        var holdResolve = false
        var reply: Result<RPCEvent.Reply.Value, Failure>?

        func reset() {
            lock.lock(); defer { lock.unlock() }
            recorded = []
        }
        func record(_ request: RPCRequest) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
        }
        var sends: [RPCRequest] {
            lock.lock(); defer { lock.unlock() }
            return recorded.filter { if case .prompt(_, .some, _) = $0 { true } else { false } }
        }
    }

    private func installPrompt(_ probe: PromptProbe) {
        promptBoxes.request = { [probe] request, done in
            probe.record(request)
            switch request {
            case .prompt(_, nil, _):
                if probe.holdResolve { return }
                if let failure = probe.resolveFailure { done(.failure(failure)) }
                else { done(.success(.prompt(.candidates(probe.candidates)))) }
            case .prompt(_, .some, _):
                if let reply = probe.reply { done(reply) }
            default: break
            }
        }
        PromptBox.linger = 0
    }

    private func candidate(pane: PaneID = PaneID(number: 13), window: WindowID = WindowID(number: 0), title: String = "near") -> PromptCandidate {
        PromptCandidate(pane: pane, session: SessionID(number: 0), window: window, title: title)
    }

    private func scrollOffset(_ pane: PaneView) -> Int {
        var bar = ghostty_surface_scrollbar_s()
        _ = ghostty_surface_scrollbar(pane.surface, &bar)
        return Int(bar.offset)
    }

    private func row(_ pane: PaneView, containing text: String) throws -> Int {
        try XCTUnwrap(screen(pane).firstIndex { $0.contains(text) }, "row containing \(text)") + scrollOffset(pane)
    }

    private func visibleRows(_ pane: PaneView) -> Int {
        max(1, Int((pane.bounds.height - pane.renderInsets.top - pane.renderInsets.bottom) / pane.cell.height))
    }

    private func rowCenter(_ pane: PaneView, _ index: Int) -> NSPoint {
        NSPoint(x: 2, y: pane.bounds.height - pane.renderInsets.top - (CGFloat(index) + 0.5) * pane.cell.height)
    }

    private func selectAt(_ pane: PaneView, _ point: NSPoint, cells: Int = 4) {
        pane.mouseDown(with: mouse(pane, .leftMouseDown, at: point))
        let end = NSPoint(x: point.x + CGFloat(cells) * pane.cell.width, y: point.y)
        pane.mouseDragged(with: mouse(pane, .leftMouseDragged, at: end))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, at: end))
    }

    private func openBox(_ pane: PaneView, waitResolved: Bool = true) async throws -> PromptBox {
        let before = promptBoxes.boxes.count
        pane.openPrompt()
        try await wait("prompt opened", within: 2) { self.promptBoxes.boxes.count == before + 1 }
        let box = try XCTUnwrap(promptBoxes.boxes.last)
        if waitResolved {
            try await wait("prompt resolved", within: 2) {
                let title = box.targetButton.titleOfSelectedItem ?? ""
                return !title.isEmpty && title != "Resolving…"
            }
        }
        return box
    }

    private func openPrompt(_ pane: PaneView, select: String = "alpha beta", waitResolved: Bool = true) async throws -> PromptBox {
        if pane.copyMode == nil { try await enter(pane) }
        let row = try row(pane, containing: select)
        drag(pane, from: (0, row), to: (select.count - 1, row))
        XCTAssertEqual(pane.readSelection(), select, "prompt fixture selection")
        return try await openBox(pane, waitResolved: waitResolved)
    }

    private func sendEnabled(_ prompt: PromptBox) -> Bool { !prompt.send.isHidden && prompt.send.isEnabled }

    private func ordinarySelection(_ pane: PaneView, containing text: String) throws {
        let row = try row(pane, containing: text)
        pane.mouseDown(with: mouse(pane, .leftMouseDown, x: 0, y: row))
        pane.mouseDragged(with: mouse(pane, .leftMouseDragged, x: text.count, y: row))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, x: text.count - 1, y: row))
    }

    private func sendClick(_ view: NSView, at point: NSPoint) {
        window.sendEvent(mouse(view, .leftMouseDown, at: point))
        window.sendEvent(mouse(view, .leftMouseUp, at: point))
    }

    private func click(_ box: PromptBox) {
        let point = NSPoint(x: box.bounds.width - 34, y: box.bounds.height - 4)
        box.mouseDown(with: mouse(box, .leftMouseDown, at: point))
        box.mouseUp(with: mouse(box, .leftMouseUp, at: point))
    }

    private func updatePromptMenu() {
        guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu,
              let app = NSApp.delegate as? AppDelegate
        else { return XCTFail("missing Edit menu or AppDelegate") }
        app.updatePromptMenu(edit, responder: window.firstResponder)
    }

    private func sendCommandO() {
        guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu,
              let item = edit.items.first(where: { $0.action == #selector(PaneView.promptSelectionItem(_:)) })
        else { return XCTFail("missing Prompt with Selection…") }
        let responder = window.firstResponder
        item.target = responder is PaneView || responder is PaneFind ? PaneView.owner(responder) : nil
        defer { item.target = nil }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "o",
                                     charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31)!
        _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
    }

    private func drag(_ box: PromptBox, from point: NSPoint? = nil, by delta: NSPoint) {
        let start = point ?? NSPoint(x: box.bounds.midX, y: box.bounds.height - 4)
        box.mouseDown(with: mouse(box, .leftMouseDown, at: start))
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        box.mouseDragged(with: mouse(box, .leftMouseDragged, at: end))
        box.mouseUp(with: mouse(box, .leftMouseUp, at: end))
    }

    private func assertInside(_ box: PromptBox) {
        XCTAssertGreaterThanOrEqual(box.frame.minX, 8, "left clamp")
        XCTAssertGreaterThanOrEqual(box.frame.minY, 8, "top clamp")
        XCTAssertLessThanOrEqual(box.frame.maxX, promptBoxes.bounds.width - 8, "right clamp")
        XCTAssertLessThanOrEqual(box.frame.maxY, promptBoxes.bounds.height - 8, "bottom clamp")
    }

    func testPromptBox() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let probe = PromptProbe()
        let sourceWindow = try XCTUnwrap(pane.windowID)
        let near = candidate(window: sourceWindow)
        let far = candidate(pane: PaneID(number: 12), window: WindowID(number: sourceWindow.number + 1), title: "far")
        installPrompt(probe)

        probe.candidates = [near, far]
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: far.pane, via: .inbox))))
        var prompt = try await openPrompt(pane)
        XCTAssertEqual(prompt.targetButton.titleOfSelectedItem, "Prompt @near in this window", "the closest same-window agent is preselected")
        XCTAssertEqual(prompt.targetButton.numberOfItems, 2)
        XCTAssertFalse(sendEnabled(prompt), "Send is disabled while the text is empty")
        prompt.newline(shift: false)
        XCTAssertEqual(probe.sends.count, 0, "Return with an empty field sends nothing")
        prompt.textView.insertText("   ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(sendEnabled(prompt), "whitespace does not enable Send")
        prompt.newline(shift: false)
        XCTAssertEqual(probe.sends.count, 0, "Return with a whitespace field sends nothing")
        prompt.textView.selectAll(nil)
        prompt.textView.insertText("Explain", replacementRange: prompt.textView.selectedRange())
        XCTAssertEqual(prompt.quote.stringValue, "alpha beta")
        XCTAssertTrue(sendEnabled(prompt))
        let quote = prompt.quote.stringValue
        _ = ghostty_surface_set_selection(pane.surface, nil)
        XCTAssertEqual(prompt.quote.stringValue, quote, "the quote is captured when the box opens")
        prompt.targetButton.selectItem(at: 1)
        prompt.chooseTarget()
        prompt.newline(shift: false)
        try await wait("delivered status", within: 2) { prompt.status.stringValue == "Sent to far" }
        try await wait("box closes after delivery", within: 3) { self.promptBoxes.boxes.isEmpty }
        XCTAssertNil(pane.copyMode, "delivery exits copy mode")
        XCTAssertEqual(probe.sends.count, 1)
        guard case .prompt(let sentPane, let text, let target) = probe.sends[0] else { return XCTFail("not a prompt") }
        XCTAssertEqual(sentPane, pane.pane, "a live source pane is the request pane")
        XCTAssertEqual(target, far.pane, "the second picked candidate receives the send")
        XCTAssertEqual(text, "Explain:\n> alpha beta")

        probe.reset()
        probe.reply = nil
        prompt = try await openPrompt(pane)
        prompt.textView.insertText("one", replacementRange: NSRange(location: NSNotFound, length: 0))
        prompt.newline(shift: true)
        XCTAssertEqual(prompt.textView.string, "one\n", "Shift-Enter adds a newline")
        XCTAssertEqual(probe.sends.count, 0)
        prompt.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await wait("Escape closes the box", within: 2) { self.promptBoxes.boxes.isEmpty }
        XCTAssertNotNil(pane.copyMode, "Escape keeps copy mode")
        XCTAssertEqual(pane.readSelection(), "alpha beta", "Escape keeps the selection")
        XCTAssertTrue(window.firstResponder === pane, "Escape returns focus to the source pane")

        probe.candidates = []
        probe.reply = nil
        prompt = try await openPrompt(pane)
        XCTAssertEqual(prompt.targetButton.titleOfSelectedItem, "No agent in this window or session")
        XCTAssertFalse(sendEnabled(prompt))
        XCTAssertFalse(prompt.textView.isEditable)
        prompt.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === prompt.cancelButton, "Tab skips disabled controls")
        prompt.cancel()
        try await wait("box cancelled", within: 2) { self.promptBoxes.boxes.isEmpty }

        probe.candidates = [near]
        probe.reply = .success(.promptError("near did not accept the prompt", .refused))
        probe.reset()
        prompt = try await openPrompt(pane)
        prompt.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        prompt.newline(shift: false)
        try await wait("refused message", within: 2) { prompt.status.stringValue == "near did not accept the prompt" }
        XCTAssertFalse(prompt.retry.isHidden)
        XCTAssertFalse(sendEnabled(prompt))
        prompt.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(sendEnabled(prompt), "editing re-enables Send")
        XCTAssertTrue(prompt.retry.isHidden)
        prompt.cancel()
        try await wait("box cancelled", within: 2) { self.promptBoxes.boxes.isEmpty }

        probe.candidates = [near, far]
        probe.reply = .success(.promptError("no such pane", .invalid))
        prompt = try await openPrompt(pane)
        prompt.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        prompt.newline(shift: false)
        try await wait("invalid message", within: 2) { prompt.status.stringValue == "no such pane" }
        XCTAssertFalse(sendEnabled(prompt), "invalid leaves Send disabled")
        prompt.targetButton.selectItem(at: 1)
        prompt.chooseTarget()
        XCTAssertEqual(prompt.status.stringValue, "")
        XCTAssertTrue(sendEnabled(prompt), "a new pick re-enables Send after invalid")
        prompt.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(sendEnabled(prompt), "editing re-enables Send after invalid")
        prompt.cancel()
        try await wait("box cancelled", within: 2) { self.promptBoxes.boxes.isEmpty }

        probe.reply = .success(.promptError("Could not send", .unknown))
        probe.reset()
        prompt = try await openPrompt(pane)
        prompt.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        prompt.newline(shift: false)
        try await wait("unknown message", within: 2) { prompt.status.stringValue.contains("may have arrived; not resent") }
        XCTAssertFalse(prompt.copyPrompt.isHidden)
        XCTAssertFalse(sendEnabled(prompt))
        await mainQueueFence()
        XCTAssertEqual(probe.sends.count, 1, "an unknown outcome never resends")
        prompt.cancel()
        try await wait("box cancelled", within: 2) { self.promptBoxes.boxes.isEmpty }

        probe.reply = .failure(.terminal("RPC connection ended before the request completed"))
        probe.reset()
        prompt = try await openPrompt(pane)
        prompt.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        prompt.newline(shift: false)
        try await wait("lost reply is unknown", within: 2) { prompt.status.stringValue.contains("may have arrived; not resent") }
        XCTAssertFalse(prompt.copyPrompt.isHidden)
        XCTAssertFalse(sendEnabled(prompt))
        prompt.cancel()
        try await wait("box cancelled", within: 2) { self.promptBoxes.boxes.isEmpty }

        probe.reply = .failure(.terminal("the RPC feed is not ready"))
        prompt = try await openPrompt(pane)
        prompt.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        prompt.newline(shift: false)
        try await wait("not-ready message", within: 2) { prompt.status.stringValue == "the RPC feed is not ready" }
        XCTAssertFalse(sendEnabled(prompt))
        prompt.cancel()
        try await wait("box cancelled", within: 2) { self.promptBoxes.boxes.isEmpty }

        probe.resolveFailure = .terminal("no such pane")
        probe.candidates = []
        prompt = try await openPrompt(pane, waitResolved: false)
        try await wait("resolve failure message", within: 2) { prompt.status.stringValue == "no such pane" }
        XCTAssertEqual(prompt.targetButton.titleOfSelectedItem, "Prompt unavailable")
        XCTAssertFalse(prompt.textView.isEditable)
        XCTAssertFalse(prompt.retry.isHidden)
        probe.resolveFailure = nil
        probe.candidates = [near]
        probe.reply = nil
        prompt.retry.invoke()
        try await wait("resolve retry ready", within: 2) { prompt.targetButton.titleOfSelectedItem == "Prompt @near in this window" && prompt.textView.isEditable }
        prompt.cancel()
        try await wait("box cancelled", within: 2) { self.promptBoxes.boxes.isEmpty }
        keys(pane, "q")
    }

    func testPromptPlacement() async throws {
        let pane = try await rawPane()
        try await emit(pane, (0..<40).map { _ in String(repeating: "x", count: 60) }.joined(separator: "\r\n") + "\r\n", until: "xxxx")
        let probe = PromptProbe()
        probe.candidates = [candidate()]
        installPrompt(probe)
        try await enter(pane)

        var point = rowCenter(pane, 5)
        selectAt(pane, point)
        var box = try await openBox(pane)
        var press = promptBoxes.convert(point, from: pane)
        XCTAssertEqual(box.frame.minY, press.y + pane.cell.height / 2 + 6, accuracy: 0.5, "the box opens below the selected row")
        XCTAssertEqual(box.frame.minX, promptBoxes.convert(.zero, from: pane).x, accuracy: 0.5, "the box starts at the first selected cell")
        XCTAssertEqual(box.frame.width, min(560, promptBoxes.bounds.width - 16))
        assertInside(box)
        box.cancel()
        try await wait("box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        point = rowCenter(pane, visibleRows(pane) - 3)
        selectAt(pane, point)
        box = try await openBox(pane)
        press = promptBoxes.convert(point, from: pane)
        XCTAssertEqual(box.frame.maxY, press.y - pane.cell.height / 2 - 6, accuracy: 0.5, "the box opens above when it does not fit below")
        assertInside(box)
        box.cancel()
        try await wait("box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        let top = rowCenter(pane, 0), bottom = rowCenter(pane, visibleRows(pane) - 1)
        pane.mouseDown(with: mouse(pane, .leftMouseDown, at: top))
        pane.mouseDragged(with: mouse(pane, .leftMouseDragged, at: bottom))
        pane.mouseUp(with: mouse(pane, .leftMouseUp, at: bottom))
        box = try await openBox(pane, waitResolved: false)
        XCTAssertEqual(box.frame.maxY, promptBoxes.bounds.height - 8, accuracy: 0.5, "a tall selection falls back to the bottom edge")
        assertInside(box)
        box.cancel()
        try await wait("box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        window.setContentSize(NSSize(width: 600, height: 560))
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        window.makeFirstResponder(pane)
        try await enter(pane)

        let middle = rowCenter(pane, visibleRows(pane) / 2)
        XCTAssertLessThan(promptBoxes.convert(.zero, from: pane).x, 8, "the fixture starts left of the margin")
        selectAt(pane, NSPoint(x: 0, y: middle.y))
        box = try await openBox(pane)
        XCTAssertEqual(box.frame.minX, 8, accuracy: 0.5, "a selection at the left edge clamps to 8pt")
        box.cancel()
        try await wait("box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        let right = NSPoint(x: 40 * pane.cell.width, y: middle.y)
        selectAt(pane, right)
        box = try await openBox(pane)
        XCTAssertEqual(box.frame.minX, promptBoxes.bounds.width - 8 - box.frame.width, accuracy: 0.5, "a selection at the right edge clamps to 8pt")
        XCTAssertGreaterThan(promptBoxes.convert(.zero, from: pane).x + right.x, box.frame.minX, "the fixture needs the right clamp")
        box.cancel()
        try await wait("box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        _ = try await command(["split-window", "-h", "-l", "12", "-t", pane.pane.description, "exec /bin/cat"])
        try await wait("split pane", within: 2) { self.terminal?.panes.count == 2 }
        try await settle()
        window.makeFirstResponder(pane)
        try await enter(pane)
        selectAt(pane, rowCenter(pane, visibleRows(pane) / 2))
        box = try await openBox(pane)
        let paneMaxX = promptBoxes.convert(pane.bounds, from: pane).maxX
        XCTAssertGreaterThan(box.frame.maxX, paneMaxX, "the box crosses the pane border")
        assertInside(box)
        box.cancel()
        keys(pane, "q")
    }

    func testSeveralPromptBoxes() async throws {
        let pane = try await rawPane()
        let long = String(repeating: "x", count: 60)
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n" + long + "\r\n", until: "xxxx")
        let probe = PromptProbe()
        probe.candidates = [candidate()]
        installPrompt(probe)
        let first = try await openPrompt(pane)
        XCTAssertEqual(first.toolTip, "alpha beta", "the box carries the full quote tooltip")
        let firstFrame = first.frame
        let second = try await openPrompt(pane)
        XCTAssertEqual(promptBoxes.boxes.count, 2, "opening a box never closes another")
        XCTAssertEqual(second.frame.minX, firstFrame.minX + 16, accuracy: 0.5, "a taken anchor offsets by 16")
        XCTAssertEqual(second.frame.minY, firstFrame.minY + 16, accuracy: 0.5, "a taken anchor offsets by 16")
        XCTAssertTrue(window.firstResponder === second.textView, "the newest box is key")
        XCTAssertTrue(promptBoxes.subviews.last === second, "the newest box is on top")

        first.textView.insertText("one", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(first.textView.string, "one")
        XCTAssertEqual(second.textView.string, "", "each box keeps its own text")

        click(first)
        XCTAssertTrue(window.firstResponder === first.textView, "a click moves focus to the box field")
        XCTAssertTrue(promptBoxes.subviews.last === first, "a click raises the box")

        window.orderFrontRegardless()
        sendClick(pane, at: NSPoint(x: 20, y: 20))
        XCTAssertTrue(window.firstResponder === pane)
        XCTAssertEqual(promptBoxes.boxes.count, 2, "clicking the terminal leaves the boxes open")

        let quoteStart = NSPoint(x: first.quote.frame.midX, y: first.quote.frame.midY)
        XCTAssertTrue(first.hitTest(first.convert(quoteStart, to: promptBoxes)) === first, "the box handles a quote hit")
        let beforeQuoteDrag = first.frame
        drag(first, from: quoteStart, by: NSPoint(x: 20, y: 20))
        XCTAssertEqual(first.frame, beforeQuoteDrag, "the quote area is not a drag region")

        drag(first, by: NSPoint(x: -2000, y: -2000))
        assertInside(first)
        drag(first, by: NSPoint(x: 4000, y: 4000))
        assertInside(first)

        let edgeRow = try row(pane, containing: "xxxx")
        drag(pane, from: (30, edgeRow), to: (40, edgeRow))
        let edge = try await openBox(pane)
        let edgeFrame = edge.frame
        XCTAssertEqual(edge.frame.minX, promptBoxes.bounds.width - 8 - edge.frame.width, accuracy: 0.5, "the edge fixture clamps first")
        let edge2 = try await openBox(pane)
        XCTAssertEqual(edge2.frame.minX, edgeFrame.minX, accuracy: 0.5, "the right clamp keeps the x edge")
        XCTAssertEqual(edge2.frame.minY, edgeFrame.minY + 16, accuracy: 0.5, "an edge anchor still offsets")

        window.setContentSize(NSSize(width: 420, height: 360))
        window.contentView?.layoutSubtreeIfNeeded()
        for box in promptBoxes.boxes { assertInside(box) }
        promptBoxes.closeAll()
        keys(pane, "q")
    }

    func testPromptBoxDragFollowsThePointer() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let probe = PromptProbe()
        probe.candidates = [candidate()]
        installPrompt(probe)
        let box = try await openPrompt(pane)
        box.textView.insertText("one", replacementRange: NSRange(location: NSNotFound, length: 0))
        box.textView.setSelectedRange(NSRange(location: 3, length: 0))

        let layer = promptBoxes
        var point = NSPoint(x: box.frame.minX + 8, y: box.frame.minY + 4)
        let down = mouse(layer, .leftMouseDown, at: point)
        box.mouseDown(with: down)
        XCTAssertTrue(window.firstResponder === box.textView, "a header press focuses the field")
        XCTAssertEqual(box.textView.selectedRange(), NSRange(location: 3, length: 0), "a header press moves no caret")
        var previous = down.locationInWindow
        var previousTop = box.convert(NSPoint(x: 0, y: box.bounds.height), to: nil)

        func step(_ delta: NSPoint) {
            point.x += delta.x
            point.y += delta.y
            let event = mouse(layer, .leftMouseDragged, at: point)
            let pointer = NSPoint(x: event.locationInWindow.x - previous.x, y: event.locationInWindow.y - previous.y)
            box.mouseDragged(with: event)
            let top = box.convert(NSPoint(x: 0, y: box.bounds.height), to: nil)
            XCTAssertEqual(top.x - previousTop.x, pointer.x, accuracy: 0.5, "the box follows the pointer in x")
            XCTAssertEqual(top.y - previousTop.y, pointer.y, accuracy: 0.5, "the box follows the pointer in y")
            previous = event.locationInWindow
            previousTop = top
        }

        step(NSPoint(x: 40, y: 30))
        step(NSPoint(x: 20, y: 10))
        step(NSPoint(x: -45, y: -25))

        point = NSPoint(x: -2000, y: -2000)
        box.mouseDragged(with: mouse(layer, .leftMouseDragged, at: point))
        XCTAssertEqual(box.frame.minX, 8, accuracy: 0.5, "the drag clamps on the left")
        XCTAssertEqual(box.frame.minY, 8, accuracy: 0.5, "the drag clamps on the top")
        box.mouseUp(with: mouse(layer, .leftMouseUp, at: point))
    }

    func testPromptBoxControlsRaiseAndFocus() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let probe = PromptProbe()
        probe.candidates = [candidate()]
        installPrompt(probe)
        let first = try await openPrompt(pane)
        first.textView.insertText("one", replacementRange: NSRange(location: NSNotFound, length: 0))
        drag(first, by: NSPoint(x: 0, y: -180))
        let second = try await openPrompt(pane)
        XCTAssertTrue(promptBoxes.subviews.last === second)

        window.orderFrontRegardless()
        sendClick(pane, at: NSPoint(x: 20, y: 20))
        XCTAssertTrue(window.firstResponder === pane)
        XCTAssertFalse(first.focused)
        XCTAssertFalse(second.focused)

        probe.reply = nil
        let sends = probe.sends.count
        sendClick(first.send, at: NSPoint(x: first.send.bounds.midX, y: first.send.bounds.midY))
        XCTAssertTrue(promptBoxes.subviews.last === first, "a control press raises its box")
        XCTAssertTrue(window.firstResponder === first.textView, "a control press focuses its field")
        XCTAssertEqual(probe.sends.count, sends + 1, "the control still acts on the press")
        first.cancel()
        second.cancel()
        keys(pane, "q")
    }

    private func controlCenter(_ box: PromptBox, _ control: NSView) -> NSPoint {
        box.layoutSubtreeIfNeeded()
        return promptBoxes.convert(control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil), from: nil)
    }

    private func pressDragDirect(_ control: NSView, in box: PromptBox, by delta: NSPoint) {
        let start = controlCenter(box, control)
        let mid = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        window.sendEvent(mouse(promptBoxes, .leftMouseDown, at: start))
        window.sendEvent(mouse(promptBoxes, .leftMouseDragged, at: mid))
        window.sendEvent(mouse(promptBoxes, .leftMouseUp, at: mid))
    }

    private func drain(_ mask: NSEvent.EventTypeMask) {
        while let event = NSApp.nextEvent(matching: mask, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(event)
        }
    }

    private func press(_ control: NSView, in box: PromptBox) {
        let point = controlCenter(box, control)
        NSApp.postEvent(mouse(promptBoxes, .leftMouseUp, at: point), atStart: false)
        window.sendEvent(mouse(promptBoxes, .leftMouseDown, at: point))
        drain(.leftMouseUp)
    }

    private func pressDrag(_ control: NSView, in box: PromptBox, by delta: NSPoint) {
        let start = controlCenter(box, control)
        let mid = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        NSApp.postEvent(mouse(promptBoxes, .leftMouseDragged, at: mid), atStart: false)
        NSApp.postEvent(mouse(promptBoxes, .leftMouseUp, at: mid), atStart: false)
        window.sendEvent(mouse(promptBoxes, .leftMouseDown, at: start))
        drain([.leftMouseDragged, .leftMouseUp])
    }

    private func controlUnder(_ control: NSView, in box: PromptBox) -> Bool {
        let point = controlCenter(box, control)
        guard let superview = promptBoxes.superview,
              let hit = superview.hitTest(promptBoxes.convert(point, to: superview))
        else { return false }
        return hit === control || hit.isDescendant(of: control)
    }

    func testPromptBoxControlsDoNotDrag() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let probe = PromptProbe()
        let near = candidate()
        let long = candidate(pane: PaneID(number: 14), window: WindowID(number: 2), title: String(repeating: "a long agent title ", count: 12))
        probe.candidates = [near, long]
        installPrompt(probe)
        let first = try await openPrompt(pane)
        first.layoutSubtreeIfNeeded()
        let targetMax = first.bounds.width - 35
        let nearWidth = first.targetButton.frame.width
        XCTAssertLessThan(nearWidth, targetMax, "the picker fits a short title")
        XCTAssertEqual(nearWidth, min(targetMax, first.targetButton.fittingSize.width), accuracy: 0.5)
        XCTAssertEqual(first.targetButton.cell?.lineBreakMode, .byTruncatingTail)
        first.targetButton.selectItem(at: 1)
        first.chooseTarget()
        first.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.targetButton.frame.width, targetMax, accuracy: 0.5, "a long title caps at the available width")
        XCTAssertGreaterThan(first.targetButton.fittingSize.width, targetMax)
        first.targetButton.selectItem(at: 0)
        first.chooseTarget()
        first.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.targetButton.frame.width, nearWidth, accuracy: 0.5, "a new selection refits the picker")
        first.textView.insertText("one", replacementRange: NSRange(location: NSNotFound, length: 0))
        drag(first, by: NSPoint(x: 0, y: -180))
        probe.candidates = []
        let second = try await openBox(pane)
        window.orderFrontRegardless()
        sendClick(pane, at: NSPoint(x: 20, y: 20))
        XCTAssertTrue(promptBoxes.subviews.last === second)
        XCTAssertFalse(second.send.isEnabled)
        XCTAssertFalse(second.targetButton.isEnabled)
        let secondFrame = second.frame
        let sends = probe.sends.count
        XCTAssertTrue(controlUnder(second.targetButton, in: second), "a disabled picker is the hit view")
        pressDragDirect(second.targetButton, in: second, by: NSPoint(x: 3, y: 2))
        XCTAssertEqual(second.frame, secondFrame, "a disabled picker does not drag its box")
        pressDragDirect(second.send, in: second, by: NSPoint(x: 5, y: 3))
        XCTAssertEqual(second.frame, secondFrame, "a disabled Send does not drag its box")
        XCTAssertEqual(probe.sends.count, sends, "a disabled Send sends nothing")

        press(second.cancelButton, in: second)
        try await wait("cancel closes its box", within: 2) { self.promptBoxes.boxes.count == 1 }
        XCTAssertTrue(promptBoxes.boxes.first === first)

        XCTAssertTrue(controlUnder(first.targetButton, in: first), "the picker is the hit view")
        let pickerEvent = mouse(promptBoxes, .leftMouseDown, at: controlCenter(first, first.targetButton))
        let tracked = first.targetButton.cell?.hitTest(for: pickerEvent, in: first.targetButton.bounds, of: first.targetButton) ?? []
        XCTAssertFalse(tracked.isEmpty, "the picker tracks its press")

        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: near.pane, via: .inbox))))
        let firstFrame = first.frame
        let firstSends = probe.sends.count
        pressDragDirect(first.send, in: first, by: NSPoint(x: 4, y: 2))
        XCTAssertEqual(first.frame, firstFrame, "Send does not drag its box")
        XCTAssertEqual(probe.sends.count, firstSends + 1, "Send sends on mouseUp")
        try await wait("send closes its box", within: 2) { self.promptBoxes.boxes.isEmpty }

        probe.candidates = [near]
        probe.reply = .success(.promptError("near did not accept the prompt", .refused))
        let retryBox = try await openPrompt(pane)
        retryBox.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        retryBox.newline(shift: false)
        try await wait("retry shown", within: 2) { !retryBox.retry.isHidden }
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: near.pane, via: .inbox))))
        probe.reset()
        let retryFrame = retryBox.frame
        XCTAssertTrue(controlUnder(retryBox.retry, in: retryBox), "Retry is the hit view")
        pressDrag(retryBox.retry, in: retryBox, by: NSPoint(x: 3, y: 2))
        XCTAssertEqual(retryBox.frame, retryFrame, "Retry does not drag its box")
        XCTAssertEqual(probe.sends.count, 1, "Retry resends")
        try await wait("retry closes its box", within: 2) { self.promptBoxes.boxes.isEmpty }

        probe.reply = .success(.promptError("Could not send", .unknown))
        let copyBox = try await openPrompt(pane)
        copyBox.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        copyBox.newline(shift: false)
        try await wait("copy shown", within: 2) { !copyBox.copyPrompt.isHidden }
        board.clearContents()
        let copyFrame = copyBox.frame
        XCTAssertTrue(controlUnder(copyBox.copyPrompt, in: copyBox), "Copy Prompt is the hit view")
        pressDrag(copyBox.copyPrompt, in: copyBox, by: NSPoint(x: 3, y: 2))
        XCTAssertEqual(copyBox.frame, copyFrame, "Copy Prompt does not drag its box")
        XCTAssertEqual(board.string(forType: .string), "Explain:\n> alpha beta")
        copyBox.cancel()
        try await wait("copy box cancelled", within: 2) { self.promptBoxes.boxes.isEmpty }
        keys(pane, "q")
    }

    private func cursorName(_ cursor: NSCursor) -> String {
        if cursor === NSCursor.arrow { return "arrow" }
        if cursor === NSCursor.openHand { return "open hand" }
        if cursor === NSCursor.iBeam { return "I-beam" }
        if cursor === NSCursor.pointingHand { return "pointing hand" }
        return "other"
    }

    private func assertCursor(_ box: PromptBox, at point: NSPoint, is expected: NSCursor, _ name: String) {
        let actual = cursor(box, at: point)
        XCTAssertTrue(actual === expected, "\(name): expected \(cursorName(expected)), got \(cursorName(actual))")
    }

    private func cursor(_ box: PromptBox, at point: NSPoint) -> NSCursor {
        if let hit = box.promptCursorRects.reversed().first(where: { $0.0.contains(point) }) { return hit.1 }
        guard let terminal else { return .arrow }
        let terminalPoint = terminal.convert(box.convert(point, to: nil), from: nil)
        if let hit = terminal.paneCursorRects.reversed().first(where: { $0.0.contains(terminalPoint) }) { return hit.1 }
        return .arrow
    }

    func testPromptCursorRects() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let probe = PromptProbe()
        probe.candidates = [candidate()]
        installPrompt(probe)
        let box = try await openPrompt(pane)
        pane.setMouseShape(GHOSTTY_MOUSE_SHAPE_GRAB)
        box.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        box.layoutSubtreeIfNeeded()
        let controls: [(String, NSView, NSCursor)] = [
            ("Send", box.send, NSCursor.arrow),
            ("Cancel", box.cancelButton, NSCursor.arrow),
            ("picker", box.targetButton, NSCursor.arrow),
        ]
        for (name, control, expected) in controls {
            assertCursor(box, at: NSPoint(x: control.frame.midX, y: control.frame.midY), is: expected, name)
        }
        let field = box.textView
        let fieldPoint = box.convert(field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil), from: nil)
        assertCursor(box, at: fieldPoint, is: NSCursor.iBeam, "field")
        assertCursor(box, at: NSPoint(x: 5, y: 20), is: NSCursor.openHand, "drag area")

        probe.reply = .success(.promptError("near did not accept the prompt", .refused))
        box.newline(shift: false)
        try await wait("retry visible", within: 2) { !box.retry.isHidden }
        box.layoutSubtreeIfNeeded()
        assertCursor(box, at: NSPoint(x: box.retry.frame.midX, y: box.retry.frame.midY), is: NSCursor.arrow, "Retry")

        probe.reply = .success(.promptError("Could not send", .unknown))
        box.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        box.newline(shift: false)
        try await wait("copy visible", within: 2) { !box.copyPrompt.isHidden }
        box.layoutSubtreeIfNeeded()
        assertCursor(box, at: NSPoint(x: box.copyPrompt.frame.midX, y: box.copyPrompt.frame.midY), is: NSCursor.arrow, "Copy Prompt")
        box.cancel()
        keys(pane, "q")
    }

    func testPromptBoxesFollowTheSession() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let probe = PromptProbe()
        probe.candidates = [candidate()]
        installPrompt(probe)
        let box = try await openPrompt(pane)
        let frame = box.frame
        let originalWindow = try XCTUnwrap(currentModel.window)
        let originalSession = try XCTUnwrap(currentModel.session)

        _ = try await command(["new-window", "-t", "visual", "exec /bin/cat"])
        try await wait("window switched", within: 3) { self.currentModel.window != originalWindow }
        XCTAssertFalse(box.isHidden, "a window switch keeps the boxes visible")
        XCTAssertEqual(box.frame, frame, "a window switch keeps the boxes in place")

        _ = try await command(["select-window", "-t", originalWindow.description])
        try await wait("window back", within: 3) { self.currentModel.window == originalWindow }
        XCTAssertEqual(box.frame, frame)

        try await rpcRequest(.newSession)
        try await wait("session created", within: 5) { self.currentModel.sessions.count == 2 }
        let other = try XCTUnwrap(currentModel.sessions.first { $0.id != originalSession }?.id)
        try await rpcRequest(.selectSession(other))
        try await wait("other session shown", within: 5) { self.currentModel.session == other }
        try await wait("boxes hidden", within: 2) { box.isHidden }
        XCTAssertFalse(box.focused, "a hidden box does not keep focus")
        XCTAssertTrue(window.firstResponder is PaneView, "the shown session's pane gets focus")

        try await rpcRequest(.selectSession(originalSession))
        try await wait("session back", within: 5) { self.currentModel.session == originalSession }
        try await wait("boxes shown", within: 2) { !box.isHidden }
        XCTAssertEqual(box.frame, frame, "a returning session shows the box in place")

        try await rpcRequest(.selectSession(other))
        try await wait("other session shown", within: 5) { self.currentModel.session == other }
        _ = try await command(["kill-session", "-t", "visual"])
        try await wait("killing the session closes its boxes", within: 5) { self.promptBoxes.boxes.isEmpty }
    }

    func testPromptBoxSourcePaneAndFocus() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let alpha = try row(pane, containing: "alpha beta")
        _ = try await command(["split-window", "-h", "-l", "12", "-t", pane.pane.description, "exec /bin/cat"])
        try await wait("split pane", within: 2) { self.terminal?.panes.count == 2 }
        try await settle()
        try await wait("split restored", within: 2) { self.terminal?.panes.allSatisfy { !$0.resizeDirty } == true }
        let other = try XCTUnwrap(terminal?.panes.first { $0 !== pane })
        try await emit(other, "other line\r\n", until: "other line")
        let sourceWindow = try XCTUnwrap(pane.windowID)
        let probe = PromptProbe()
        probe.candidates = [candidate(pane: other.pane, window: sourceWindow)]
        installPrompt(probe)

        window.makeFirstResponder(pane)
        try await enter(pane)
        drag(pane, from: (0, alpha), to: (9, alpha))
        XCTAssertEqual(pane.readSelection(), "alpha beta")
        let boxA = try await openBox(pane)
        let frame = boxA.frame
        let quote = boxA.quote.stringValue
        _ = ghostty_surface_set_selection(pane.surface, nil)
        XCTAssertEqual(boxA.quote.stringValue, quote)
        XCTAssertEqual(boxA.frame, frame)
        window.makeFirstResponder(pane)
        keys(pane, "q")
        XCTAssertNil(pane.copyMode)
        XCTAssertEqual(boxA.quote.stringValue, quote, "leaving copy mode keeps the captured quote")
        XCTAssertEqual(boxA.frame, frame, "leaving copy mode keeps the box")

        window.makeFirstResponder(other)
        let boxB = try await openPrompt(other, select: "other line")
        window.makeFirstResponder(pane)
        try await enter(pane)
        XCTAssertNotNil(pane.copyMode)
        click(boxB)
        XCTAssertNil(pane.copyMode, "focus moving to another pane's box ends this pane's copy mode")

        window.makeFirstResponder(pane)
        try await enter(pane)
        click(boxA)
        XCTAssertNotNil(pane.copyMode, "focus moving to its own box keeps copy mode")

        _ = try await command(["kill-pane", "-t", pane.pane.description])
        try await wait("source pane closed", within: 3) { pane.disposed }
        try await wait("source closed status", within: 3) {
            boxA.status.stringValue == "Source pane closed; agents resolved earlier stay available."
        }
        XCTAssertEqual(boxA.targetButton.titleOfSelectedItem, "Prompt @near in window zsh (pane closed)")

        probe.reply = .success(.promptError("no such pane", .invalid))
        probe.reset()
        boxA.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        boxA.newline(shift: false)
        try await wait("gone target is invalid", within: 2) { boxA.status.stringValue == "no such pane" }
        XCTAssertEqual(boxA.textView.string, "Explain", "an invalid send keeps the text")
        XCTAssertEqual(promptBoxes.boxes.count, 2, "an invalid send keeps the box")
        guard case .prompt(let sentPane, _, let target) = probe.sends.last else { return XCTFail("not a prompt") }
        XCTAssertEqual(sentPane, other.pane, "a gone source sends through the target pane")
        XCTAssertEqual(target, other.pane)

        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: other.pane, via: .inbox))))
        boxA.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        boxA.newline(shift: false)
        try await wait("source-gone send closes the box", within: 3) { self.promptBoxes.boxes.count == 1 }
        boxB.cancel()
        try await wait("last box closed", within: 2) { self.promptBoxes.boxes.isEmpty }
    }

    func testPromptBoxDeliveryFocus() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        let sourceWindow = try XCTUnwrap(currentModel.window)
        let probe = PromptProbe()
        probe.candidates = [candidate(pane: PaneID(number: 99), window: try XCTUnwrap(pane.windowID))]
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: PaneID(number: 99), via: .inbox))))
        installPrompt(probe)

        let hidden = try await openPrompt(pane)
        _ = try await command(["new-window", "-t", "visual", "exec /bin/cat"])
        try await wait("second window", within: 3) { self.currentModel.window != sourceWindow }
        let secondWindow = try XCTUnwrap(currentModel.window)
        let header = NSPoint(x: hidden.bounds.width - 34, y: hidden.bounds.height - 4)
        sendClick(hidden, at: header)
        hidden.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        hidden.newline(shift: false)
        try await wait("hidden-source box delivered", within: 3) { self.promptBoxes.boxes.isEmpty }
        let active = try XCTUnwrap(window.firstResponder as? PaneView)
        XCTAssertFalse(active === pane, "a hidden source is not focused")
        XCTAssertFalse(active.isHiddenOrHasHiddenAncestor, "the shown window's pane is focused")

        _ = try await command(["select-window", "-t", sourceWindow.description])
        try await wait("source window back", within: 3) { self.currentModel.window == sourceWindow }
        window.makeFirstResponder(pane)
        let removed = try await openPrompt(pane)
        _ = try await command(["select-window", "-t", secondWindow.description])
        try await wait("second window back", within: 3) { self.currentModel.window == secondWindow }
        _ = try await command(["kill-window", "-t", sourceWindow.description])
        try await wait("source pane disposed", within: 3) { pane.disposed }
        sendClick(removed, at: NSPoint(x: removed.bounds.width - 34, y: removed.bounds.height - 4))
        removed.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        removed.newline(shift: false)
        try await wait("removed-source box delivered", within: 3) { self.promptBoxes.boxes.isEmpty }
        let shown = try XCTUnwrap(window.firstResponder as? PaneView)
        XCTAssertFalse(shown.isHiddenOrHasHiddenAncestor, "a removed source focuses the shown window's active pane")
    }

    func testPromptShortcutMenuAndQuote() async throws {
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let item = try XCTUnwrap(edit.items.first { $0.action == #selector(PaneView.promptSelectionItem(_:)) })
        XCTAssertEqual(item.keyEquivalent, "o")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)

        let pane = try await rawPane()
        try await emit(pane, (1...6).map { "line-\($0)" }.joined(separator: "\r\n") + "\r\n", until: "line-6")
        let probe = PromptProbe()
        probe.candidates = [candidate()]
        installPrompt(probe)

        _ = ghostty_surface_set_selection(pane.surface, nil)
        pane.promptSelectionItem(nil)
        try await wait("no selection opens at the cursor", within: 2) { self.promptBoxes.boxes.count == 1 }
        let cursorBox = try XCTUnwrap(promptBoxes.boxes.last)
        XCTAssertTrue(cursorBox.quote.isHidden, "the no-selection box has no quote")
        cursorBox.cancel()
        try await wait("cursor box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        try await enter(pane)
        let first = try row(pane, containing: "line-1")
        drag(pane, from: (0, first), to: (5, first))
        sendCommandO()
        try await wait("copy-mode shortcut opens the box", within: 2) { self.promptBoxes.boxes.count == 1 }
        var box = try XCTUnwrap(promptBoxes.boxes.last)
        try await wait("prompt resolved", within: 2) { box.targetButton.titleOfSelectedItem != "Resolving…" }
        XCTAssertEqual(box.quote.stringValue, "line-1", "one line is shown whole")
        XCTAssertEqual(box.quote.toolTip, pane.readSelection())
        XCTAssertEqual(box.quote.accessibilityLabel(), "Selected text, 1 lines")
        sendCommandO()
        XCTAssertEqual(promptBoxes.boxes.count, 1, "⌘O in a box field opens no new box")
        box.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        box.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === box.targetButton, "Tab moves to the popup")
        box.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === box.cancelButton, "Tab moves to Cancel")
        box.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === box.send, "Tab moves to Send")
        box.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === box.textView, "Tab wraps to the field")
        box.textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertTrue(window.firstResponder === box.send, "Shift-Tab moves backward")
        box.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === box.textView)
        box.cancel()
        try await wait("box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        drag(pane, from: (0, first), to: (5, first + 2))
        box = try await openBox(pane)
        XCTAssertEqual(box.quote.stringValue, "line-1\nline-2\nline-3", "three lines are shown whole")
        XCTAssertEqual(box.quote.accessibilityLabel(), "Selected text, 3 lines")
        box.cancel()
        try await wait("box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        drag(pane, from: (0, first), to: (5, first + 4))
        box = try await openBox(pane)
        XCTAssertEqual(box.quote.stringValue, "line-1\n⋯ 3 lines\nline-5", "five lines show their first, a middle count and their last")
        XCTAssertEqual(box.quote.toolTip, pane.readSelection(), "the tooltip keeps the full selection")
        XCTAssertEqual(box.quote.accessibilityLabel(), "Selected text, 5 lines")
        box.cancel()
        try await wait("box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        keys(pane, "q")
        XCTAssertNil(pane.copyMode)
        try ordinarySelection(pane, containing: "line-2")
        XCTAssertEqual(pane.readSelection(), "line-2", "an ordinary Ghostty selection")
        pane.promptSelectionItem(nil)
        try await wait("ordinary-selection shortcut opens the box", within: 2) { self.promptBoxes.boxes.count == 1 }
        promptBoxes.closeAll()
    }

    func testPromptMenuTitles() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\n", until: "alpha beta")
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let item = try XCTUnwrap(edit.items.first { $0.action == #selector(PaneView.promptSelectionItem(_:)) })

        window.makeFirstResponder(pane)
        updatePromptMenu()
        XCTAssertEqual(item.title, "Prompt…")
        XCTAssertTrue(item.isEnabled)

        try ordinarySelection(pane, containing: "alpha beta")
        XCTAssertEqual(pane.readSelection(), "alpha beta")
        window.makeFirstResponder(pane)
        updatePromptMenu()
        XCTAssertEqual(item.title, "Prompt with Selection…")
        XCTAssertTrue(item.isEnabled)

        let probe = PromptProbe()
        probe.candidates = [candidate()]
        installPrompt(probe)
        let box = try await openPrompt(pane, select: "alpha beta")
        window.makeFirstResponder(box.textView)
        updatePromptMenu()
        XCTAssertEqual(item.title, "Prompt with Selection…", "a box field shows its source pane's state")
        XCTAssertTrue(item.target === pane, "the box field's menu item targets its source pane")
        box.cancel()
        try await wait("menu title box closed", within: 2) { self.promptBoxes.boxes.isEmpty }
        keys(pane, "q")

        window.makeFirstResponder(nil)
        updatePromptMenu()
        XCTAssertEqual(item.title, "Prompt…")
        XCTAssertFalse(item.isEnabled, "no focused pane disables the item")
        XCTAssertNil(item.target)
    }

    func testPromptAtCursor() async throws {
        let pane = try await rawPane()
        let probe = PromptProbe()
        probe.candidates = [candidate()]
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: candidate().pane, via: .inbox))))
        installPrompt(probe)
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let item = try XCTUnwrap(edit.items.first { $0.action == #selector(PaneView.promptSelectionItem(_:)) })
        let column = 4

        func place(cursorRow row: Int, indent: Int = 0) async throws {
            let prefix = String(repeating: "\r\n", count: row) + String(repeating: " ", count: indent) + "mark"
            try await emit(pane, "\u{1b}[H\u{1b}[2J" + prefix, until: "mark")
        }
        func cellBottom(_ row: Int) -> CGFloat {
            pane.bounds.height - pane.renderInsets.top - CGFloat(row + 1) * pane.cell.height
        }
        func point(_ row: Int, _ column: Int) -> NSPoint {
            promptBoxes.convert(NSPoint(x: CGFloat(column) * pane.cell.width, y: cellBottom(row)), from: pane)
        }
        func cellX(_ column: Int) -> CGFloat {
            promptBoxes.convert(NSPoint(x: CGFloat(column) * pane.cell.width, y: 0), from: pane).x
        }

        try await place(cursorRow: 6)
        window.makeFirstResponder(pane)
        updatePromptMenu()
        XCTAssertEqual(item.title, "Prompt…", "the menu item names no selection")
        XCTAssertTrue(item.isEnabled, "a focused pane with no selection has an enabled item")

        sendCommandO()
        try await wait("cursor shortcut opens the box", within: 2) { self.promptBoxes.boxes.count == 1 }
        var box = try XCTUnwrap(promptBoxes.boxes.last)
        try await wait("cursor box resolved", within: 2) { box.targetButton.titleOfSelectedItem != "Resolving…" }
        XCTAssertEqual(box.frame.minY, point(6, column).y + 6, accuracy: 0.5, "the box opens below the live cursor cell")
        XCTAssertEqual(box.frame.minX, cellX(column), accuracy: 0.5, "the box starts at the cursor cell")
        XCTAssertEqual(box.frame.height, 90, accuracy: 0.5, "the one-line no-quote box is 90pt tall")
        XCTAssertTrue(box.quote.isHidden, "the no-selection box has no quote")

        box.textView.insertText("Explain", replacementRange: NSRange(location: NSNotFound, length: 0))
        box.newline(shift: true)
        box.textView.insertText("two lines", replacementRange: NSRange(location: NSNotFound, length: 0))
        box.newline(shift: false)
        try await wait("cursor prompt delivered", within: 2) { self.promptBoxes.boxes.isEmpty }
        guard case .prompt(_, let text, _) = probe.sends.last else { return XCTFail("not a prompt") }
        XCTAssertEqual(text, "Explain\ntwo lines", "no selection sends exactly the typed text")

        try await enter(pane)
        keys(pane, "k")
        sendCommandO()
        try await wait("copy-mode cursor shortcut opens the box", within: 2) { self.promptBoxes.boxes.count == 1 }
        box = try XCTUnwrap(promptBoxes.boxes.last)
        try await wait("copy-mode cursor box resolved", within: 2) { box.targetButton.titleOfSelectedItem != "Resolving…" }
        XCTAssertEqual(box.frame.minY, point(5, column).y + 6, accuracy: 0.5, "the box follows the copy cursor, not the live cursor")
        XCTAssertTrue(box.quote.isHidden, "a copy cursor alone has no quote")
        box.cancel()
        try await wait("copy cursor box closed", within: 2) { self.promptBoxes.boxes.isEmpty }
        keys(pane, "q")

        let nearBottom = visibleRows(pane) - 5
        try await place(cursorRow: nearBottom)
        sendCommandO()
        try await wait("near-bottom cursor opens the box", within: 2) { self.promptBoxes.boxes.count == 1 }
        box = try XCTUnwrap(promptBoxes.boxes.last)
        let cellTop = promptBoxes.convert(NSPoint(x: 0, y: cellBottom(nearBottom) + pane.cell.height), from: pane).y
        XCTAssertEqual(box.frame.maxY, cellTop - 6, accuracy: 0.5, "a box with no room below opens above the cursor cell")
        XCTAssertGreaterThan(box.frame.minY, 8, "the box is not the bottom fallback")
        box.cancel()
        try await wait("near-bottom box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        let columns = Int(ghostty_surface_size(pane.surface).columns)
        let indent = max(0, columns - 12)
        try await place(cursorRow: 6, indent: indent)
        sendCommandO()
        try await wait("right-edge cursor opens the box", within: 2) { self.promptBoxes.boxes.count == 1 }
        box = try XCTUnwrap(promptBoxes.boxes.last)
        let cursorX = promptBoxes.convert(NSPoint(x: CGFloat(indent + 4) * pane.cell.width, y: 0), from: pane).x
        XCTAssertGreaterThan(cursorX, promptBoxes.bounds.width - 8 - box.frame.width, "the fixture needs the right clamp")
        XCTAssertEqual(box.frame.minX, promptBoxes.bounds.width - 8 - box.frame.width, accuracy: 0.5,
                       "a cursor at the right edge clamps the box 8pt inside")
        box.cancel()
        try await wait("right-edge box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        try await emit(pane, (0..<60).map { "history-\($0)\r\n" }.joined(), until: "history-59")
        try await settle()
        pane.requestScroll(10)
        try await wait("viewport scrolled back", within: 2) {
            pane.scrollPosition().offset < pane.scrollPosition().retainedHistoryRows
        }
        var scrolled = ghostty_surface_scrollbar_s()
        XCTAssertTrue(ghostty_surface_scrollbar(pane.surface, &scrolled))
        window.makeFirstResponder(pane)
        sendCommandO()
        try await wait("scrolled cursor opens the box", within: 2) { self.promptBoxes.boxes.count == 1 }
        box = try XCTUnwrap(promptBoxes.boxes.last)
        let lastRowTop = pane.bounds.height - pane.renderInsets.top - CGFloat(scrolled.len) * pane.cell.height + pane.cell.height
        let expectedMaxY = promptBoxes.convert(NSPoint(x: 0, y: lastRowTop), from: pane).y - 6
        XCTAssertEqual(box.frame.maxY, expectedMaxY, accuracy: 0.5,
                       "a cursor below the viewport clamps to the last visible row")
        box.cancel()
        try await wait("scrolled box closed", within: 2) { self.promptBoxes.boxes.isEmpty }

        pane.requestScroll(0)
        try await wait("viewport at the bottom", within: 2) {
            pane.scrollPosition().offset == pane.scrollPosition().retainedHistoryRows
        }
        try await settle()
        try ordinarySelection(pane, containing: "history-59")
        XCTAssertEqual(pane.readSelection(), "history-59")
        window.makeFirstResponder(pane)
        updatePromptMenu()
        XCTAssertEqual(item.title, "Prompt with Selection…", "the menu item names the selection")
        _ = ghostty_surface_set_selection(pane.surface, nil)
    }

    func testPromptFeedWaitsForADelayedReply() async throws {
        let scratch = directory.appendingPathComponent("prompt-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let gate = scratch.appendingPathComponent("gate")
        let received = scratch.appendingPathComponent("received")
        let script = try fakeFeedScript(scratch, """
        import json, os, sys, time
        print(json.dumps(dict(hello=dict(protocol="6.0"))))
        snapshot = {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},
                    "server_instance":{"started_at":1,"pid":2},"error":None,"sessions":[]}
        print(json.dumps(snapshot))
        for line in sys.stdin:
            request = json.loads(line)
            if "prompt" not in request: continue
            open("\(received.path)", "w").close()
            while not os.path.exists("\(gate.path)"): time.sleep(0.01)
            reply = dict(id=request["id"], prompt=dict(delivered=dict(pane=request["prompt"].get("target", request["prompt"]["pane"]), via="inbox")))
            print(json.dumps(dict(reply=reply)))
            print(json.dumps(snapshot))
        """)
        nonisolated(unsafe) var starts = 0
        nonisolated(unsafe) var snapshots = 0
        let feed = Feed(serverDir: scratch.path, locate: { $0(.success("private-client")) }, onChange: { status in
            if case .starting = status { starts += 1 }
            if case .running = status { snapshots += 1 }
        })
        feed.testKido = script.path
        defer { feed.stop() }
        try await wait("fake feed ready", within: 5) { snapshots == 1 }
        let delivered = expectation(description: "delayed prompt reply")
        feed.request(.prompt(pane: PaneID(number: 2), text: "hello", target: PaneID(number: 2))) { result in
            guard case .success(.prompt(.delivered(let value))) = result else { return XCTFail("missing delivered reply") }
            XCTAssertEqual(value.pane, PaneID(number: 2))
            XCTAssertEqual(value.via, .inbox)
            delivered.fulfill()
        }
        try await wait("the fake received the prompt", within: 5) { FileManager.default.fileExists(atPath: received.path) }
        XCTAssertEqual(starts, 1, "a slow request does not restart the helper")
        if case .running = feed.status {} else { XCTFail("a slow request does not leave the feed unsettled") }
        try Data().write(to: gate)
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(starts, 1, "the delayed reply did not restart the helper")
    }

    private var stateQuote: String { """
        File "lib/prompt.ml", line 41, characters 12-19:
        Error: This expression has type string but an expression was expected of type
                Tmux.pane_id option
        """ }
    private var stateText: String { "Why does make verify fail here? Fix the type error in lib/prompt.ml and rerun it." }
    private var typingQuote: String { """
        dune build ......................... ok
        dune test --force .................. ok
        git status ......................... clean
        make fmt ........................... ok
        make lint .......................... ok
        make: *** [verify] Error 1
        """ }

    private func openState(_ pane: PaneView, text: String? = nil, noQuote: Bool = false, waitResolved: Bool = true) async throws -> PromptBox {
        let before = promptBoxes.boxes.count
        let anchor = PromptAnchor(selection: noQuote ? nil : text ?? stateQuote,
                                  rect: NSRect(x: 30, y: pane.bounds.height - 100, width: 30, height: 18))
        promptBoxes.open(pane, anchor)
        try await wait("state box opened", within: 2) { self.promptBoxes.boxes.count == before + 1 }
        let box = try XCTUnwrap(promptBoxes.boxes.last)
        if waitResolved {
            try await wait("state box resolved", within: 2) { box.targetButton.titleOfSelectedItem != "Resolving…" }
        }
        return box
    }

    private func stateSnapshot(_ name: String, box: PromptBox, inset: NSSize = NSSize(width: 24, height: 24)) async throws {
        try await settle()
        window.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        try await snapshot(name, testName: "testPromptStates", view: window.contentView)
        guard record else { return }
        let directory = "/tmp/kido-promptbox-compare"
        let view = window.contentView!
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let scale = CGFloat(representation.pixelsWide) / view.bounds.width
        let rect = promptBoxes.convert(box.frame, to: view).insetBy(dx: -inset.width, dy: -inset.height)
        let pixels = CGRect(x: rect.minX * scale, y: (view.bounds.height - rect.maxY) * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        let image = try XCTUnwrap(representation.cgImage?.cropping(to: pixels))
        let output = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(output.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-app.png"))
    }

    private func closeState() async throws {
        promptBoxes.closeAll()
        try await wait("state boxes closed", within: 2) { self.promptBoxes.boxes.isEmpty }
    }

    private func runStates(_ theme: String, pane: PaneView, probe: PromptProbe) async throws {
        let sourceWindow = try XCTUnwrap(pane.windowID)
        probe.candidates = [candidate(window: sourceWindow, title: "kido-app")]
        var box = try await openState(pane)
        window.makeFirstResponder(box.textView)
        try await stateSnapshot("\(theme)-empty", box: box)
        try await closeState()

        box = try await openState(pane, text: typingQuote)
        window.makeFirstResponder(box.textView)
        box.textView.insertText(stateText, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await stateSnapshot("\(theme)-typing", box: box)
        try await closeState()

        box = try await openState(pane, noQuote: true)
        window.makeFirstResponder(box.textView)
        try await stateSnapshot("\(theme)-noquote-empty", box: box)
        try await closeState()

        box = try await openState(pane, noQuote: true)
        window.makeFirstResponder(box.textView)
        box.textView.insertText(stateText, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await stateSnapshot("\(theme)-noquote-typing", box: box)
        try await closeState()

        probe.holdResolve = true
        box = try await openState(pane, waitResolved: false)
        window.makeFirstResponder(nil)
        try await stateSnapshot("\(theme)-resolving", box: box)
        probe.holdResolve = false
        try await closeState()

        probe.candidates = []
        box = try await openState(pane)
        window.makeFirstResponder(nil)
        try await stateSnapshot("\(theme)-no-agent", box: box)
        try await closeState()
        probe.candidates = [candidate(window: sourceWindow, title: "kido-app")]

        box = try await openState(pane)
        box.textView.insertText(stateText, replacementRange: NSRange(location: NSNotFound, length: 0))
        probe.reply = nil
        box.newline(shift: false)
        try await wait("sending state", within: 2) { box.status.stringValue.hasPrefix("Sending to @kido-app") }
        window.makeFirstResponder(nil)
        try await stateSnapshot("\(theme)-sending", box: box)
        try await closeState()

        box = try await openState(pane)
        box.textView.insertText(stateText, replacementRange: NSRange(location: NSNotFound, length: 0))
        probe.reply = .success(.promptError("@kido-app is not accepting messages", .refused))
        box.newline(shift: false)
        try await wait("refused state", within: 2) { box.status.stringValue == "@kido-app is not accepting messages" }
        window.makeFirstResponder(nil)
        try await stateSnapshot("\(theme)-refused", box: box)
        try await closeState()

        box = try await openState(pane)
        box.textView.insertText(stateText, replacementRange: NSRange(location: NSNotFound, length: 0))
        probe.reply = .success(.promptError("Could not send: connection reset.", .unknown))
        box.newline(shift: false)
        try await wait("unknown state", within: 2) { box.status.stringValue.contains("may have arrived; not resent") }
        window.makeFirstResponder(nil)
        try await stateSnapshot("\(theme)-unknown", box: box)
        try await closeState()

        box = try await openState(pane)
        box.textView.insertText(stateText, replacementRange: NSRange(location: NSNotFound, length: 0))
        probe.reply = .success(.promptError("no such pane", .invalid))
        box.newline(shift: false)
        try await wait("invalid state", within: 2) { box.status.stringValue == "no such pane" }
        window.makeFirstResponder(nil)
        try await stateSnapshot("\(theme)-invalid", box: box)
        try await closeState()

        let overlapQuote = typingQuote.split(separator: "\n").prefix(2).joined(separator: "\n")
        let first = try await openState(pane, text: overlapQuote)
        first.textView.insertText("Is the build step still green after the fix?", replacementRange: NSRange(location: NSNotFound, length: 0))
        let second = try await openState(pane, text: overlapQuote)
        second.textView.insertText("Is the build step still green after the fix?", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(second.textView)
        try await stateSnapshot("\(theme)-overlap", box: second)
        try await closeState()
    }

    private func cursorSnapshot(_ theme: String, pane: PaneView, probe: PromptProbe) async throws {
        probe.candidates = [candidate(window: try XCTUnwrap(pane.windowID), title: "kido-app")]
        _ = try await command(["split-window", "-h", "-l", "12", "-t", pane.pane.description, "exec /bin/cat"])
        try await wait("pane for at-cursor state", within: 2) { self.terminal?.panes.count == 2 }
        try await settle()
        window.makeFirstResponder(pane)
        try await emit(pane, "        mark", until: "mark")
        pane.openPrompt()
        try await wait("at-cursor box", within: 2) { self.promptBoxes.boxes.count == 1 }
        let box = try XCTUnwrap(promptBoxes.boxes.last)
        try await wait("at-cursor resolved", within: 2) { box.targetButton.titleOfSelectedItem != "Resolving…" }
        window.makeFirstResponder(box.textView)
        try await stateSnapshot("\(theme)-at-cursor", box: box, inset: NSSize(width: 37, height: 55))
        try await closeState()
        let other = try XCTUnwrap(terminal?.panes.first { $0 !== pane })
        _ = try await command(["kill-pane", "-t", other.pane.description])
        try await wait("at-cursor split closed", within: 2) { self.terminal?.panes.count == 1 }
    }

    func testPromptStates() async throws {
        let pane = try await rawPane()
        let probe = PromptProbe()
        installPrompt(probe)
        try await runStates("light", pane: pane, probe: probe)

        let lightWindow = try XCTUnwrap(currentModel.window)
        _ = try await command(["new-window", "-t", "visual", "exec /bin/cat"])
        try await wait("light closed window", within: 3) { self.currentModel.window != lightWindow }
        try await settle()
        let lightClosedPane = try XCTUnwrap(terminal?.panes.first)
        _ = try await command(["rename-window", "-t", try XCTUnwrap(lightClosedPane.windowID).description, "app"])
        _ = try await command(["split-window", "-h", "-t", lightClosedPane.pane.description, "exec /bin/cat"])
        try await wait("pane for light closed state", within: 2) { self.terminal?.panes.count == 2 }
        probe.candidates = [candidate(window: try XCTUnwrap(lightClosedPane.windowID), title: "kido-app")]
        let closed = try await openState(lightClosedPane)
        closed.textView.insertText(stateText, replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = try await command(["kill-pane", "-t", lightClosedPane.pane.description])
        try await wait("source pane closed state", within: 3) {
            closed.status.stringValue == "Source pane closed; agents resolved earlier stay available."
        }
        window.makeFirstResponder(nil)
        try await stateSnapshot("light-pane-closed", box: closed)
        try await closeState()
        _ = try await command(["select-window", "-t", lightWindow.description])
        try await wait("light cursor window", within: 3) { self.currentModel.window == lightWindow }
        try await settle()
        try await cursorSnapshot("light", pane: pane, probe: probe)

        let beforeDark = try XCTUnwrap(currentModel.window)
        _ = try await command(["new-window", "-t", "visual", "exec /bin/cat"])
        try await wait("dark window", within: 3) { self.currentModel.window != beforeDark }
        try await settle()
        let darkPane = try XCTUnwrap(terminal?.panes.first)
        try await darken()
        try await runStates("dark", pane: darkPane, probe: probe)

        let darkWindow = try XCTUnwrap(currentModel.window)
        _ = try await command(["new-window", "-t", "visual", "exec /bin/cat"])
        try await wait("dark closed window", within: 3) { self.currentModel.window != darkWindow }
        try await settle()
        let darkClosedPane = try XCTUnwrap(terminal?.panes.first)
        _ = try await command(["rename-window", "-t", try XCTUnwrap(darkClosedPane.windowID).description, "app"])
        _ = try await command(["split-window", "-h", "-t", darkClosedPane.pane.description, "exec /bin/cat"])
        try await wait("pane for dark closed state", within: 2) { self.terminal?.panes.count == 2 }
        probe.candidates = [candidate(window: try XCTUnwrap(darkClosedPane.windowID), title: "kido-app")]
        let darkClosed = try await openState(darkClosedPane)
        darkClosed.textView.insertText(stateText, replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = try await command(["kill-pane", "-t", darkClosedPane.pane.description])
        try await wait("dark source pane closed state", within: 3) {
            darkClosed.status.stringValue == "Source pane closed; agents resolved earlier stay available."
        }
        window.makeFirstResponder(nil)
        try await stateSnapshot("dark-pane-closed", box: darkClosed)
        try await closeState()
        _ = try await command(["select-window", "-t", darkWindow.description])
        try await wait("dark cursor window", within: 3) { self.currentModel.window == darkWindow }
        try await settle()
        try await cursorSnapshot("dark", pane: darkPane, probe: probe)
    }

    func testPromptSnapshots() async throws {
        let pane = try await rawPane()
        try await emit(pane, "alpha beta\r\ngamma delta\r\nthird line\r\n", until: "third line")
        _ = try await command(["split-window", "-h", "-t", "visual", "exec /bin/cat"])
        try await wait("split pane", within: 2) { self.terminal?.panes.count == 2 }
        try await settle()
        try await wait("split restored", within: 2) { self.terminal?.panes.allSatisfy { !$0.resizeDirty } == true }
        let other = try XCTUnwrap(terminal?.panes.first { $0 !== pane })
        try await emit(other, (0..<40).map { "row-\($0)" }.joined(separator: "\r\n") + "\r\n", until: "row-39")
        let windowID = try XCTUnwrap(pane.windowID)
        let probe = PromptProbe()
        probe.candidates = [candidate(pane: PaneID(number: 12), window: windowID),
                            candidate(pane: PaneID(number: 14), window: WindowID(number: 1), title: "far")]
        installPrompt(probe)
        try await settle()
        window.makeFirstResponder(pane)
        for dark in [false, true] {
            if dark {
                try await darken()
                window.makeFirstResponder(pane)
            }
            let first = try await openPrompt(pane)
            first.textView.insertText("Explain this change", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(other)
            let second = try await openPrompt(other, select: "row-30")
            second.textView.insertText("And this one", replacementRange: NSRange(location: NSNotFound, length: 0))
            click(first)
            try await snapshot(dark ? "prompt-dark" : "prompt-light", view: window.contentView)
            promptBoxes.closeAll()
            pane.endCopy()
            other.endCopy()
            try await wait("copy exit restored") { !pane.resizeDirty && !other.resizeDirty }
        }
    }
}


extension VisualTests {
    private func mouseWindow() async throws {
        NSApp.setActivationPolicy(.regular)
        addTeardownBlock { @MainActor in NSApp.setActivationPolicy(.prohibited) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("visual window is key", within: 2) { self.window.isKeyWindow && self.window.isMainWindow }
    }

    private func entering(_ pane: PaneView) -> Bool {
        if case .entering = pane.copyMode { return true }
        return false
    }

    private func entered(_ pane: PaneView) async throws {
        try await wait("shift press enters copy mode", within: 2) { pane.copyMode != nil && !self.entering(pane) }
    }

    private func mouseFixture(_ pane: PaneView, reporting: Bool = true, shiftCapture: Bool = true) async throws -> Int {
        let modes = reporting ? "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h" : ""
        let capture = shiftCapture ? "\u{1b}[>1s" : ""
        try await emit(pane, modes + capture + "\u{1b}[2J\u{1b}[H" + (0..<8).map { "row-\($0)\r\n" }.joined()
                       + "alpha beta\r\ngamma delta\r\nready", until: "ready")
        try await settle()
        return try row(pane, containing: "alpha beta")
    }

    private func restored(_ pane: PaneView) async throws {
        try await wait("copy exit restored", within: 2) { !pane.resizeDirty }
        try await settle()
    }

    private func waitForZ(_ pane: String, _ expected: String) async throws {
        let deadline = Date() + 2
        while Date() < deadline {
            if try await command(["display-message", "-p", "-t", pane, "#{pane_z}"]) == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("pane \(pane) never reached z-index \(expected)")
    }

    func testShiftDragOutsideCopyModeSelectsWithoutReporting() async throws {
        let pane = try await rawPane()
        let row = try await mouseFixture(pane)
        try await mouseWindow()
        let plain = connection.visualCommands.count
        drag(pane, from: (0, row), to: (4, row), delivered: true)
        try await wait("the plain drag reaches the program", within: 2) { !self.sends(plain).isEmpty }
        XCTAssertNil(pane.copyMode, "a plain drag does not enter copy mode")

        let since = connection.visualCommands.count
        window.sendEvent(mouse(pane, .leftMouseDown, x: 0, y: row, mods: [.shift]))
        try await entered(pane)
        XCTAssertEqual(pane.readSelection(), "a", "the press starts the selection at its cell")
        for (x, expected) in [(4, "alpha"), (6, "alpha b"), (9, "alpha beta")] {
            window.sendEvent(mouse(pane, .leftMouseDragged, x: x, y: row, mods: [.shift]))
            XCTAssertEqual(pane.readSelection(), expected, "the drag grows the selection to column \(x)")
        }
        window.sendEvent(mouse(pane, .leftMouseUp, x: 9, y: row, mods: [.shift]))
        XCTAssertEqual(pane.readSelection(), "alpha beta", "the release keeps the selection")
        XCTAssertNotNil(pane.copyMode, "the release keeps copy mode")
        XCTAssertTrue(sends(since).isEmpty, "the shift gesture sends nothing to the program")
        let frozen = screen(pane)
        try await emit(pane, "tick", until: "tick")
        XCTAssertEqual(screen(pane), frozen, "copy mode freezes the program's redraw")
        XCTAssertEqual(pane.readSelection(), "alpha beta", "the redraw keeps the selection")
        keys(pane, "q")
        try await wait("copy mode exits", within: 2) { pane.copyMode == nil }
        try await restored(pane)

        let after = connection.visualCommands.count
        drag(pane, from: (0, row), to: (4, row), delivered: true)
        try await wait("a plain drag after copy mode reaches the program", within: 2) { !self.sends(after).isEmpty }
        XCTAssertNil(pane.copyMode, "the gesture after copy mode is not swallowed")

        let release = connection.visualCommands.count
        window.sendEvent(mouse(pane, .leftMouseDown, x: 0, y: row, mods: [.shift]))
        try await entered(pane)
        window.sendEvent(mouse(pane, .leftMouseDragged, x: 4, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseDragged, x: 6, y: row, mods: []))
        XCTAssertEqual(pane.readSelection(), "alpha b", "a drag without shift keeps extending")
        window.sendEvent(mouse(pane, .leftMouseDragged, x: 9, y: row, mods: []))
        window.sendEvent(mouse(pane, .leftMouseUp, x: 9, y: row, mods: []))
        XCTAssertEqual(pane.readSelection(), "alpha beta", "a release without shift ends the gesture")
        XCTAssertNotNil(pane.copyMode)
        XCTAssertTrue(sends(release).isEmpty, "the shifted gesture never reports")
        keys(pane, "q")
        try await wait("copy mode exits", within: 2) { pane.copyMode == nil }
        try await restored(pane)

        let chord = connection.visualCommands.count
        window.sendEvent(mouse(pane, .leftMouseDown, x: 9, y: row, mods: [.shift, .command]))
        XCTAssertEqual(pane.visualPressed, 1, "shift-command reaches Ghostty")
        window.sendEvent(mouse(pane, .leftMouseDragged, x: 9, y: row, mods: [.shift, .command]))
        window.sendEvent(mouse(pane, .leftMouseUp, x: 9, y: row, mods: [.shift, .command]))
        try await wait("shift capture reports through the same path", within: 2) { !self.sends(chord).isEmpty }
        XCTAssertNil(pane.copyMode, "shift-command is not captured")

        window.sendEvent(mouse(pane, .leftMouseDown, x: 9, y: row, mods: [.shift, .option]))
        XCTAssertEqual(pane.visualPressed, 1, "shift-option reaches Ghostty")
        XCTAssertNil(pane.copyMode, "shift-option is not captured")
        window.sendEvent(mouse(pane, .leftMouseUp, x: 9, y: row, mods: [.shift, .option]))
        XCTAssertEqual(pane.visualPressed, 0)

        for (clickCount, expected) in [(2, "beta"), (3, "alpha beta")] {
            _ = ghostty_surface_set_selection(pane.surface, nil)
            let start = connection.visualCommands.count
            window.sendEvent(mouse(pane, .leftMouseDown, x: 6, y: row, clickCount: clickCount, mods: [.shift]))
            try await entered(pane)
            XCTAssertEqual(pane.readSelection().trimmingCharacters(in: .newlines), expected, "shift click count \(clickCount)")
            window.sendEvent(mouse(pane, .leftMouseUp, x: 6, y: row, clickCount: clickCount, mods: [.shift]))
            XCTAssertTrue(sends(start).isEmpty)
            keys(pane, "q")
            try await wait("copy mode exits", within: 2) { pane.copyMode == nil }
            try await restored(pane)
        }

        window.sendEvent(mouse(pane, .leftMouseDown, x: 9, y: row, mods: [.shift, .control]))
        XCTAssertNil(pane.copyMode, "shift-control is not captured")
        window.sendEvent(mouse(pane, .leftMouseUp, x: 9, y: row, mods: [.shift, .control]))
        XCTAssertEqual(pane.visualPressed, 0)
    }

    func testShiftClickExtendsAGhosttySelection() async throws {
        let pane = try await rawPane()
        let row = try await mouseFixture(pane, reporting: false, shiftCapture: false)
        try await mouseWindow()
        drag(pane, from: (0, row), to: (5, row), delivered: true)
        XCTAssertEqual(pane.readSelection(), "alpha", "a plain drag makes a Ghostty selection")
        window.sendEvent(mouse(pane, .leftMouseDown, x: 9, y: row, mods: [.shift]))
        try await entered(pane)
        XCTAssertEqual(pane.readSelection(), "alpha beta", "the shift click extends the Ghostty selection")
        window.sendEvent(mouse(pane, .leftMouseUp, x: 9, y: row, mods: [.shift]))
        XCTAssertNotNil(pane.copyMode)
        XCTAssertEqual(pane.readSelection(), "alpha beta")
        keys(pane, "q")
    }

    func testShiftDragDuringCopyEntrySelectsFromThePress() async throws {
        let pane = try await rawPane()
        let row = try await mouseFixture(pane)
        try await mouseWindow()
        nonisolated(unsafe) var release: (@Sendable () -> Void)?
        connection.visualCopyCheck = { release = $0 }
        let since = connection.visualCommands.count

        window.sendEvent(mouse(pane, .leftMouseDown, x: 0, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseDragged, x: 4, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseDragged, x: 9, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseUp, x: 9, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseDown, x: 2, y: row, mods: []))
        window.sendEvent(mouse(pane, .leftMouseUp, x: 2, y: row, mods: []))
        try await wait("entry is held", within: 2) { release != nil }
        XCTAssertTrue(entering(pane), "the gesture arrives before entry completes")
        XCTAssertTrue(sends(since).isEmpty, "the held gesture sends nothing to the program")
        release?()
        try await entered(pane)
        XCTAssertEqual(pane.readSelection(), "alpha beta", "the replayed gesture selects from the pressed cell to the release cell")
        XCTAssertEqual(pane.visualPressed, 0, "a held press leaves no pressed button behind")
        XCTAssertTrue(sends(since).isEmpty)
        keys(pane, "q")
        try await wait("copy mode exits", within: 2) { pane.copyMode == nil }
        try await restored(pane)

        nonisolated(unsafe) var cancelled: (@Sendable () -> Void)?
        connection.visualCopyCheck = { cancelled = $0 }
        defer { connection.visualCopyCheck = nil }
        let second = connection.visualCommands.count
        window.sendEvent(mouse(pane, .leftMouseDown, x: 0, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseUp, x: 0, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseDown, x: 0, y: row, mods: [.shift]))
        try await wait("the second press holds entry", within: 2) { cancelled != nil }
        XCTAssertTrue(entering(pane))
        let swallowed = pane.visualSwallowedDrags
        pane.endCopy()
        cancelled?()
        window.sendEvent(mouse(pane, .leftMouseDragged, x: 4, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseDragged, x: 9, y: row, mods: [.shift]))
        window.sendEvent(mouse(pane, .leftMouseUp, x: 9, y: row, mods: [.shift]))
        XCTAssertEqual(pane.visualSwallowedDrags, swallowed + 2, "a cancelled entry swallows the re-armed gesture")
        XCTAssertTrue(sends(second).isEmpty, "a cancelled entry reports nothing")
        XCTAssertNil(pane.copyMode)
    }

    func testShiftClickActivatesAndRaisesThePane() async throws {
        let pane = try await rawPane()
        let row = try await mouseFixture(pane)
        _ = try await command(["split-window", "-h", "-t", "visual", "exec /bin/cat"])
        try await wait("split pane", within: 2) { self.terminal?.panes.count == 2 }
        try await settle()
        try await wait("split restored", within: 2) { self.terminal?.panes.allSatisfy { !$0.resizeDirty } == true }
        let other = try XCTUnwrap(terminal?.panes.first { $0 !== pane })
        _ = try await command(["select-pane", "-t", other.pane.description])
        try await wait("the other pane is active", within: 2) { self.terminal?.active == other.pane }
        try await mouseWindow()
        window.sendEvent(mouse(pane, .leftMouseDown, x: 0, y: row, mods: [.shift]))
        try await entered(pane)
        try await wait("the shift press activates its pane", within: 2) { self.terminal?.active == pane.pane }
        window.sendEvent(mouse(pane, .leftMouseUp, x: 0, y: row, mods: [.shift]))
        keys(pane, "q")
        try await wait("copy mode exits", within: 2) { pane.copyMode == nil }
        try await restored(pane)

        _ = try await command(["split-window", "-h", "-t", pane.pane.description, "exec /bin/cat"])
        try await wait("third pane", within: 2) { self.terminal?.panes.count == 3 }
        try await settle()
        try await wait("third pane restored", within: 2) { self.terminal?.panes.allSatisfy { !$0.resizeDirty } == true }
        let third = try XCTUnwrap(terminal?.panes.first { $0 !== pane && $0 !== other })
        let lower = other.pane.description, upper = third.pane.description
        _ = try await command(["break-pane", "-W", "-s", lower, "-X", "5", "-Y", "2", "-x", "35", "-y", "10"])
        try await wait("lower floating pane", within: 2) { self.terminal?.visualLayout.contains("float \(lower)") == true }
        _ = try await command(["break-pane", "-W", "-s", upper, "-X", "45", "-Y", "2", "-x", "35", "-y", "10"])
        try await wait("upper floating pane", within: 2) { self.terminal?.visualLayout.contains("float \(upper)") == true }
        try await settle()
        try await wait("floats restored", within: 2) { self.terminal?.panes.allSatisfy { !$0.resizeDirty } == true }
        _ = try await command(["select-pane", "-t", pane.pane.description])
        try await waitForZ(lower, "1")
        let lowerPane = try XCTUnwrap(terminal?.panes.first { $0.pane.description == lower })
        window.sendEvent(mouse(lowerPane, .leftMouseDown, x: 2, y: 2, mods: [.shift]))
        try await entered(lowerPane)
        try await waitForZ(lower, "0")
        window.sendEvent(mouse(lowerPane, .leftMouseUp, x: 2, y: 2, mods: [.shift]))
        keys(lowerPane, "q")
    }
}
