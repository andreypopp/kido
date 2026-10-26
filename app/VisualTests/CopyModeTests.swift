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
        trimmed(surfaceText(pane, in: GHOSTTY_POINT_VIEWPORT))
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
        XCTAssertNil((NSApp.delegate as? AppDelegate)?.palettePanel, "⌘O while copy mode enters opens no palette")
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
        var forwarded: [String?] = []
        pane.canPrompt = { true }
        pane.onPrompt = { _, quote in forwarded.append(quote) }
        keys(pane, "p")
        XCTAssertTrue(forwarded.isEmpty, "a cursor-only cell does not prompt")
        pane.promptSelectionItem(nil)
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertNil(forwarded[0])
        drag(pane, from: (0, alpha), to: (9, alpha))
        keys(pane, "p")
        XCTAssertEqual(forwarded.last!, "alpha beta")
        keys(pane, "q")
    }

    func testPromptFeedWaitsForADelayedReply() async throws {
        let scratch = directory.appendingPathComponent("prompt-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let gate = scratch.appendingPathComponent("gate")
        let received = scratch.appendingPathComponent("received")
        let script = try fakeFeedScript(scratch, """
        import json, os, sys, time
        print(json.dumps(dict(hello=dict(protocol="6.2"))))
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


}


extension VisualTests {
    private func mouseWindow() async throws {
        window.orderFront(nil)
        try await wait("visual window is on screen", within: 2) { self.window.isVisible && self.window.windowNumber != 0 }
    }

    private func entering(_ pane: PaneView) -> Bool {
        if case .entering = pane.copyMode { return true }
        return false
    }

    private func entered(_ pane: PaneView) async throws {
        try await wait("shift press enters copy mode", within: 2) { pane.copyMode != nil && !self.entering(pane) }
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
        if window.performKeyEquivalent(with: event) { return }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        window.sendEvent(event)
    }

    private func scrollOffset(_ pane: PaneView) -> Int {
        var bar = ghostty_surface_scrollbar_s()
        _ = ghostty_surface_scrollbar(pane.surface, &bar)
        return Int(bar.offset)
    }

    private func row(_ pane: PaneView, containing text: String) throws -> Int {
        try XCTUnwrap(screen(pane).firstIndex { $0.contains(text) }, "row containing \(text)") + scrollOffset(pane)
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
