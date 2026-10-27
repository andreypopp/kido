import AppKit
import GhosttyKit
import SnapshotTesting
import TmuxControl
import XCTest
@testable import Kido

final class ScrollbackUnitTests: XCTestCase {
    private func command(visual: String = "", editor: String = "") -> String {
        let command = ScrollbackEditor.command(.init(visual: visual, editor: editor, path: ""))
        let (head, tail) = ("printf '\\033[2J\\033[H'; ", "; echo $? > \"$KIDO_SCROLLBACK_STATUS\"")
        XCTAssertTrue(command.hasPrefix(head) && command.hasSuffix(tail), command)
        return String(command.dropFirst(head.count).dropLast(tail.count))
    }

    func testEditorCommandPrefersVisualThenEditorThenVi() {
        XCTAssertEqual(command(visual: "emacs", editor: "nano"), "emacs \"$KIDO_SCROLLBACK_FILE\"")
        XCTAssertEqual(command(editor: "nano"), "nano \"$KIDO_SCROLLBACK_FILE\"")
        XCTAssertEqual(command(visual: "  ", editor: "nano"), "nano \"$KIDO_SCROLLBACK_FILE\"")
        XCTAssertEqual(command(), "vi + \"$KIDO_SCROLLBACK_FILE\"")
    }

    func testEditorCommandOpensAtTheEndOnlyForViFamily() {
        for editor in ["vi", "vim", "nvim", "view", "/opt/homebrew/bin/nvim", "nvim -u NONE"] {
            XCTAssertTrue(command(editor: editor).hasSuffix(" + \"$KIDO_SCROLLBACK_FILE\""), editor)
        }
        for editor in ["code -w", "nano", "emacs -nw", "/usr/bin/vimdiff", "hx"] {
            XCTAssertFalse(command(editor: editor).contains(" + "), editor)
        }
        XCTAssertEqual(command(editor: "code -w"), "code -w \"$KIDO_SCROLLBACK_FILE\"")
    }

    func testLoginOutputIsReadPastShellNoise() {
        let login = ScrollbackEditor.parse("banner\u{1b}]0;title\u{7}kido-visual=hx\nkido-editor=\nkido-path=/opt/bin:/usr/bin\ngoodbye\n")
        XCTAssertEqual(login, .init(visual: "hx", editor: "", path: "/opt/bin:/usr/bin"))
    }

    func testFileIsPrivateReadOnlyAndRemovable() throws {
        let base = URL(fileURLWithPath: "/tmp/kido-sb-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try ScrollbackFile.write("one\ntwo\n", pane: PaneID(number: 3), in: base)
        XCTAssertEqual(file.url.lastPathComponent, "pane-3.txt")
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "one\ntwo\n")
        let directory = try FileManager.default.attributesOfItem(atPath: file.directory.path)[.posixPermissions] as? Int
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(directory, 0o700)
        XCTAssertEqual(mode, 0o400)
        file.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
    }

    func testSweepRemovesOnlyOldScrollbackDirectories() throws {
        let base = URL(fileURLWithPath: "/tmp/kido-sb-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = try ScrollbackFile.write("x", pane: PaneID(number: 1), in: base)
        let fresh = try ScrollbackFile.write("x", pane: PaneID(number: 2), in: base)
        let other = base.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: old.directory.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: other.path)
        ScrollbackFile.sweepStale(in: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        fresh.remove()
    }
}

@MainActor final class ScrollbackTests: VisualTestCase {
    private var owner: WindowOwner!
    private var server: Server!
    private var scratch = ""

    private func tmux(_ args: [String]) async throws -> String {
        let result = try await Child.run(server.tmux, ["-u", "-S", server.socket] + args, env: tools.environment)
        XCTAssertEqual(result.status, 0, "\(args): \(result.err)")
        return result.out
    }

    private func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func text(_ view: ScrollbackView) -> String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                                            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(view.surface, selection, &text), let bytes = text.text else { return "" }
        defer { ghostty_surface_free_text(view.surface, &text) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    private func scrollbackDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix(ScrollbackFile.prefix) })
    }

    private func chrome(of pane: PaneView) throws -> PaneChrome {
        try XCTUnwrap((pane.superview as? WindowView)?.subviews.compactMap { $0 as? PaneChrome }.first { $0.pane == pane.pane })
    }

    // A private owner whose first window is a pane with `seq` output in its history.
    private func start(editor: String, history: Int = 3000) async throws -> PaneView {
        scratch = "/tmp/ksb-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = scratch + "/editor.sh"
        try """
        #!/bin/sh
        printf 'EDITOR-OK %s\\n' "$(basename "$1")"
        grep -x -e 2 -e 3000 "$1"
        read answer
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["HOME"])
        guard home.hasSuffix("/build/bundle/visual/home") else { throw XCTSkip("HOME is not the visual scheme's private home") }
        try "export EDITOR=\(editor.isEmpty ? script : editor)\n".write(toFile: home + "/.zshenv", atomically: true, encoding: .utf8)
        ScrollbackEditor.forget()
        let dir = scratch + "/server"
        let result = try await Child.run(tools.kido, ["server", "--server", dir], env: tools.environment)
        XCTAssertEqual(result.status, 0, result.err)
        server = try JSONDecoder().decode(Server.self, from: Data(result.out.utf8))
        let board = NSPasteboard(name: .init("ksb-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, accents: HostAccents(preferences: nil), start: false)
        self.owner = owner
        owner.testEndpoint = Endpoint(server: server, kido: tools.kido)
        let server = server!, scratch = scratch
        addTeardownBlock { @MainActor in
            owner.close(); board.releaseGlobally()
            _ = try? await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-session", "-t", "main"], env: tools.environment)
            try? FileManager.default.removeItem(atPath: scratch)
            try? FileManager.default.removeItem(atPath: home + "/.zshenv")
            ScrollbackEditor.forget()
        }
        _ = try await tmux(["set-option", "-g", "history-limit", String(history + 500)])
        owner.start()
        try await wait("private owner ready") { owner.testConnection != nil && owner.stressState.4 != nil && owner.testSession?.windows.values.first?.panes.first != nil }
        owner.window.display()
        let pane = try XCTUnwrap(owner.testSession?.windows.values.first?.panes.first)
        try await wait("pane focused") { owner.window.firstResponder === pane }
        _ = try await tmux(["send-keys", "-t", pane.pane.description, "seq 1 \(history)", "Enter"])
        try await wait("history printed") { self.surfaceText(pane).contains("\n\(history)\n") }
        return pane
    }

    func testOverlayCoversTheCardAndClosesWithTheEditor() async throws {
        let pane = try await start(editor: "")
        let windowFormat = ["-F", "#{window_id} #{window_panes} #{window_layout}"], paneFormat = ["-F", "#{pane_id} #{pane_width}x#{pane_height}"]
        let windows = try await tmux(["list-windows", "-a"] + windowFormat), panes = try await tmux(["list-panes", "-a"] + paneFormat)
        pane.openScrollbackItem(nil)
        try await wait("overlay opens") { pane.scrollbackView != nil }
        let overlay = try XCTUnwrap(pane.scrollbackView)
        guard case .open(_, let file) = pane.scrollback else { return XCTFail("not open") }
        try await wait("editor runs") { self.text(overlay).contains("EDITOR-OK pane-0.txt") }
        let card = try chrome(of: pane)
        XCTAssertTrue(overlay.superview === card)
        XCTAssertEqual(overlay.frame, card.content)
        let size = ghostty_surface_size(overlay.surface), paneSize = ghostty_surface_size(pane.surface)
        XCTAssertEqual(Int(size.columns), Int(paneSize.columns))
        XCTAssertEqual(Int(size.rows), Int(paneSize.rows))
        XCTAssertTrue(owner.window.firstResponder === overlay)
        let contents = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertTrue(contents.contains("\n1\n"), String(contents.prefix(40)))
        XCTAssertTrue(contents.contains("\n3000\n"))
        XCTAssertFalse(text(overlay).contains("Process exited"))
        let item = NSMenuItem(title: "", action: #selector(PaneView.openScrollbackItem(_:)), keyEquivalent: "")
        XCTAssertFalse(pane.canPerformMenuItem(item))
        _ = try await tmux(["send-keys", "-t", pane.pane.description, "echo BELOW-MARKER", "Enter"])
        let windowsDuring = try await tmux(["list-windows", "-a"] + windowFormat), panesDuring = try await tmux(["list-panes", "-a"] + paneFormat)
        XCTAssertEqual(windowsDuring, windows)
        XCTAssertEqual(panesDuring, panes)
        overlay.keyDown(with: try press(36, "\r", in: owner.window))
        try await wait("overlay closes with the editor") { pane.scrollbackView == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
        XCTAssertNil(overlay.superview)
        try await wait("focus returns to the pane") { self.owner.window.firstResponder === pane }
        XCTAssertTrue(pane.canPerformMenuItem(item))
        XCTAssertNil(owner.preparedAlert)
        try await wait("the pane kept receiving output") { self.surfaceText(pane).contains("BELOW-MARKER") }
    }

    func testEditorThatCannotStartShowsItsError() async throws {
        let pane = try await start(editor: "/nonexistent/editor", history: 100)
        let before = try scrollbackDirectories()
        pane.openScrollbackItem(nil)
        try await wait("the failure is reported") { self.owner.preparedAlert != nil }
        XCTAssertEqual(owner.preparedAlert?.alert.messageText, "The editor exited with status 127")
        XCTAssertTrue(owner.preparedAlert?.alert.informativeText.contains("/nonexistent/editor") == true, owner.preparedAlert?.alert.informativeText ?? "")
        XCTAssertNil(pane.scrollbackView)
        guard case .none = pane.scrollback else { return XCTFail("still open") }
        XCTAssertEqual(try scrollbackDirectories(), before)
    }

    private func open(_ pane: PaneView) async throws -> ScrollbackView {
        pane.openScrollbackItem(nil)
        try await wait("overlay opens") { pane.scrollbackView != nil }
        let overlay = try XCTUnwrap(pane.scrollbackView)
        try await wait("editor runs") { self.text(overlay).contains("EDITOR-OK") }
        return overlay
    }

    func testOverlayFollowsAZoomAndSurvivesAWindowSwitch() async throws {
        let pane = try await start(editor: "", history: 200)
        let id = pane.pane.description
        let other = try await tmux(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", id, "exec /bin/cat"])
        let card = try chrome(of: pane)
        try await wait("two tiled panes") { self.owner.testSession?.windows.values.first?.panes.count == 2 && card.content.width > 0 }
        let overlay = try await open(pane)
        func agrees() -> Bool {
            let size = ghostty_surface_size(overlay.surface), paneSize = ghostty_surface_size(pane.surface)
            return overlay.frame == card.content && size.columns == paneSize.columns && size.rows == paneSize.rows
        }
        try await wait("overlay matches the tiled pane") { agrees() }
        let tiled = card.content
        _ = try await tmux(["resize-pane", "-Z", "-t", id])
        try await wait("overlay matches the zoomed pane") { card.content != tiled && agrees() }
        XCTAssertGreaterThan(overlay.frame.height, tiled.height)
        _ = try await tmux(["resize-pane", "-Z", "-t", id])
        try await wait("overlay matches the unzoomed pane") { card.content == tiled && agrees() }
        let window = try await tmux(["new-window", "-P", "-F", "#{window_id}"])
        try await wait("the other window is shown") { overlay.isHiddenOrHasHiddenAncestor }
        XCTAssertFalse(overlay.disposed)
        _ = try await tmux(["select-window", "-t", "main:0"])
        try await wait("the first window is back") { !overlay.isHiddenOrHasHiddenAncestor }
        XCTAssertTrue(text(overlay).contains("EDITOR-OK"))
        _ = try await tmux(["kill-pane", "-t", other])
        _ = try await tmux(["kill-window", "-t", window])
        guard case .open(_, let file) = pane.scrollback else { return XCTFail("closed by the window switch") }
        _ = try await tmux(["kill-pane", "-t", id])
        try await wait("a pane that closes takes its overlay along") { pane.disposed && overlay.disposed }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
    }

    func testMenuItemKeysAndCommandWStayInTheOverlay() async throws {
        let pane = try await start(editor: "", history: 200)
        let entry = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == #selector(PaneView.openScrollbackItem(_:)) })
        XCTAssertEqual(entry.title, "Open Scrollback in Editor")
        XCTAssertEqual(entry.keyEquivalent, "e")
        XCTAssertEqual(entry.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(pane.validateMenuItem(entry))
        let overlay = try await open(pane)
        guard case .open(_, let file) = pane.scrollback else { return XCTFail("not open") }
        XCTAssertFalse(pane.validateMenuItem(entry))
        XCTAssertNil(PaneView.owner(owner.window.firstResponder))
        pane.openScrollbackItem(nil)
        XCTAssertTrue(pane.scrollbackView === overlay)
        let menu = NSApp.mainMenu
        NSApp.mainMenu = nil
        defer { NSApp.mainMenu = menu }
        let panes = try await tmux(["list-panes", "-a", "-F", "#{pane_id}"])
        let commandW = try press(13, "w", .command, in: owner.window)
        XCTAssertTrue(overlay.performKeyEquivalent(with: commandW))
        try await wait("Command-W closes the overlay") { pane.scrollbackView == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
        let after = try await tmux(["list-panes", "-a", "-F", "#{pane_id}"])
        XCTAssertEqual(after, panes)
        XCTAssertNil(owner.preparedAlert)
    }

    func testHistoryOverTheCapKeepsTheNewestRows() async throws {
        PaneView.scrollbackRows = 100
        defer { PaneView.scrollbackRows = ScrollbackCapture.maxRows }
        let pane = try await start(editor: "", history: 400)
        pane.openScrollbackItem(nil)
        try await wait("the cap is reported") { self.owner.preparedAlert != nil }
        XCTAssertEqual(owner.preparedAlert?.alert.messageText, "Showing the newest 100 lines")
        guard case .open(_, let file) = pane.scrollback else { return XCTFail("not open") }
        let contents = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertTrue(contents.contains("\n400\n"))
        XCTAssertFalse(contents.contains("\n2\n"))
        XCTAssertLessThan(contents.split(separator: "\n").count, 100 + Int(ghostty_surface_size(pane.surface).rows) + 1)
    }

    private func overlayImage(dark: Bool) async throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        PaneView.renderOffscreen = true
        defer { PaneView.renderOffscreen = false }
        let pane = try await start(editor: "", history: 3000)
        let overlay = try await open(pane)
        let canvas = try XCTUnwrap(overlay.subviews.first)
        var frames = 0
        let observation = observeFrames(try XCTUnwrap(canvas.layer)) { frames += 1 }
        defer { observation.invalidate() }
        try await wait("the editor printed its lines") { self.text(overlay).contains("3000") }
        frames = 0
        ghostty_surface_refresh(overlay.surface)
        try await wait("a frame with the editor text is shown") { frames > 0 }
        overlay.layoutSubtreeIfNeeded()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: overlay, as: .image, named: dark ? "dark" : "light", record: record, testName: "overlay"),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    func testOverlayImageLight() async throws { try await overlayImage(dark: false) }
    func testOverlayImageDark() async throws { try await overlayImage(dark: true) }

    private func loneFailure(_ replies: [[Reply]?]) async throws -> (title: String, state: PaneView.Scrollback) {
        let board = NSPasteboard(name: .init("ksb-" + UUID().uuidString))
        addTeardownBlock { @MainActor in board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 0, onInput: { _ in }))
        var asked = 0, titles: [String] = []
        pane.onSend = { _, done in
            asked += 1
            let reply = replies[asked - 1]
            DispatchQueue.main.async { done?(reply) }
        }
        pane.onNotice = { title, _ in titles.append(title) }
        pane.openScrollbackItem(nil)
        try await wait("the failure is reported") { !titles.isEmpty }
        pane.dispose()
        return (titles[0], pane.scrollback)
    }

    func testLostConnectionAndEmptyPaneOpenNothing() async throws {
        for replies: [[Reply]?] in [[nil], [[.success(["5"])], nil], [[.success(["5"])], [.success(["", ""])]]] {
            let result = try await loneFailure(replies)
            XCTAssertEqual(result.title, "Kido could not open the scrollback")
            guard case .none = result.state else { return XCTFail("still loading") }
        }
    }
}
