import AppKit
import XCTest
import SnapshotTesting
import SidebarFeed
import TmuxControl
@testable import Kido

@MainActor final class PaletteTests: VisualTestCase {
    func testPaletteFiltersPanesAndCommandsAndRunsTheChoice() throws {
        let snapshot = try sidebarFixture()
        let panes = sidebarRows(snapshot).compactMap { row in row.target.map { (row.title, $0) } }
        let target = try XCTUnwrap(panes.first { $0.0 == "main-watch" }?.1)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("palette-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: config) }
        let board = NSPasteboard(name: .init("palette-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        for (theme, hex) in [("light", "fffaf0"), ("dark", "172029")] {
            try "background = #\(hex)\n".write(to: config, atomically: true, encoding: .utf8)
            let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board)), start: false)
            defer { owner.close() }
            var requests: [RPCRequest] = []
            owner.request = { request, _ in requests.append(request) }
            owner.testReceive(snapshot)
            func image(_ name: String) {
                owner.window.contentView?.superview?.layoutSubtreeIfNeeded()
                if let failure = verifySnapshot(of: owner.sidebar.content, as: .image, named: "\(theme)-\(name)", record: record, testName: "palette"),
                   !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
            }

            func toggle() { owner.togglePalette(PaletteEntry.sessions(owner) + PaletteEntry.commands(try! XCTUnwrap(NSApp.mainMenu))) }
            toggle()
            let palette = try XCTUnwrap(owner.palette)
            let editor = try XCTUnwrap(owner.window.firstResponder as? NSTextView)
            XCTAssertTrue(editor.isDescendant(of: palette), "the search field takes the keyboard")
            let rows = sidebarRows(snapshot).filter { $0.kind == .header || $0.target != nil }
            XCTAssertEqual(palette.shown.prefix(rows.count).map(\.entry.title), rows.map(\.title), "with no text, the sessions and panes come first, in sidebar order")
            XCTAssertEqual(palette.shown.prefix(rows.count).filter { $0.entry.symbol != nil }.map(\.entry.title), ["main", "visa", "pi", "video", "umbrella"])
            XCTAssertEqual(palette.shown.first.map { [$0.entry.detail, $0.entry.symbol] }, ["", "square.stack"], "a local session has no host")
            XCTAssertEqual(palette.shown[1].entry.detail, "main", "a pane shows its session")
            let commands = palette.shown.dropFirst(rows.count).map(\.entry)
            let new = try XCTUnwrap(commands.first { $0.title == "New Session" })
            XCTAssertEqual([new.detail, new.shortcut], ["File", "⌘N"])
            XCTAssertNotNil(commands.first { $0.title == "Connect to Remote Host…" && $0.detail == "File" })
            XCTAssertNil(commands.first { $0.title == "Command Palette…" }, "the palette does not list itself")
            image("all")
            toggle()
            XCTAssertNil(owner.palette, "the palette key closes an open palette")
            XCTAssertNil(palette.superview)

            toggle()
            let empty = try XCTUnwrap(owner.palette)
            let field = try XCTUnwrap(owner.window.firstResponder as? NSTextView)
            field.insertText("main term", replacementRange: field.selectedRange())
            XCTAssertEqual(empty.shown.first.map { [$0.entry.detail, $0.entry.title] }, ["main", "Terminal"], "words match the session and the title")
            XCTAssertEqual(empty.shown.first?.offsets, [[0, 1, 2, 3], [0, 1, 2, 3]])
            image("session")
            field.selectAll(nil)
            field.insertText("visa", replacementRange: field.selectedRange())
            XCTAssertEqual(empty.shown.prefix(2).map { [$0.entry.title, $0.entry.detail] }, [["visa", ""], ["@main", "visa"]], "a session name finds the session, then its panes")
            field.selectAll(nil)
            field.insertText("zzqq", replacementRange: field.selectedRange())
            XCTAssertTrue(empty.shown.isEmpty)
            image("no-match")
            field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertNotNil(owner.palette, "Return with no match keeps the palette open")
            field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertNil(owner.palette, "Escape closes the palette")
            XCTAssertEqual(requests, [])

            toggle()
            let chooser = try XCTUnwrap(owner.palette)
            let text = try XCTUnwrap(owner.window.firstResponder as? NSTextView)
            text.insertText("mwatch", replacementRange: text.selectedRange())
            XCTAssertEqual(chooser.shown.first?.entry.title, "main-watch")
            XCTAssertEqual(chooser.shown.first?.offsets, [[0, 5, 6, 7, 8, 9], []])
            image("filtered")
            text.doCommand(by: #selector(NSResponder.moveDown(_:)))
            text.doCommand(by: #selector(NSResponder.moveUp(_:)))
            text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(requests, [.jump(target)], "Return jumps to the selected pane")
            XCTAssertNil(owner.palette)
            XCTAssertNil(chooser.superview)
        }
    }

    func testPaletteListsTheSessionsOfEveryWindowAndRecentHosts() throws {
        let snapshot = try sidebarFixture()
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("palette-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: config) }
        try "background = #fffaf0\n".write(to: config, atomically: true, encoding: .utf8)
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        let local = try XCTUnwrap(app.open(.local, start: false)), remote = try XCTUnwrap(app.open(.remote("devbox"), start: false))
        defer { local.close(); remote.close() }
        var requests: [String: [RPCRequest]] = [:]
        for owner in [local, remote] {
            owner.request = { request, _ in requests[owner.host.label, default: []].append(request) }
            owner.testReceive(snapshot)
        }
        app.routes.connect(.remote("devbox"))
        app.routes.connect(.remote("devbox-old"))
        app.togglePalette()
        let palette = try XCTUnwrap(local.palette, "the palette opens in the current window")
        let entries = palette.shown.map(\.entry)
        XCTAssertEqual(entries.first.map { [$0.title, $0.detail] }, ["main", ""], "the current window comes first")
        XCTAssertNotNil(entries.first { $0.title == "visa" && $0.detail == "devbox" && $0.symbol == "square.stack" })
        XCTAssertNotNil(entries.first { $0.title == "Terminal" && $0.detail == "devbox › main" })
        XCTAssertEqual(entries.filter { $0.symbol == "network" }.map(\.title), ["devbox-old"], "a recent host with an open window is not listed again")
        let field = try XCTUnwrap(local.window.firstResponder as? NSTextView)
        field.insertText("devbox", replacementRange: field.selectedRange())
        local.window.contentView?.superview?.layoutSubtreeIfNeeded()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: local.sidebar.content, as: .image, named: "hosts", record: record, testName: "palette"),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        field.selectAll(nil)
        field.insertText("devbox visa", replacementRange: field.selectedRange())
        XCTAssertEqual(palette.shown.first.map { [$0.entry.title, $0.entry.detail] }, ["visa", "devbox"])
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let visa = try XCTUnwrap(snapshot.sessions.first { $0.name == "visa" })
        XCTAssertEqual(requests, ["devbox": [.selectSession(visa.id)]], "the remote window selects its session")
        XCTAssertNil(local.palette)
    }

    func testPaletteOpensInAPanelWithoutAWindow() throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        app.routes.connect(.remote("other"))
        app.routes.connect(.remote("devbox"))
        app.togglePalette()
        let panel = try XCTUnwrap(app.palettePanel)
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isDescendant(of: panel.palette), "the search field takes the keyboard")
        let entries = panel.palette.shown.map(\.entry)
        XCTAssertEqual(entries.prefix(2).map(\.title), ["devbox", "other"], "recent hosts come first, newest first")
        XCTAssertNotNil(entries.first { $0.title == "New Session" }, "a new session needs no window")
        let menus = SessionMenus()
        menus.canSend = { false }
        menus.update(SessionModel())
        XCTAssertEqual(PaletteEntry.commands(menus.window).map(\.title), [], "commands for a window are not listed without one")
        editor.insertText("other", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertNil(app.palettePanel, "the choice closes the panel")
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(app.routes.recent.entries.first?.host, "other", "the choice connects to the host")
        app.togglePalette()
        app.togglePalette()
        XCTAssertNil(app.palettePanel, "the palette key closes the panel")
    }

    func testNewSessionWithoutAWindowOpensOneAndMakesTheSession() throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        var requests: [RPCRequest] = []
        app.routes.ready(isDefaultLaunch: false) { host, cause in
            let owner = app.open(host, start: false, cause: cause)
            owner?.request = { request, _ in requests.append(request) }
        }
        XCTAssertNil(app.current)
        app.newSession()
        let owner = try XCTUnwrap(app.owners.first, "a new session with no window opens one")
        defer { owner.close() }
        XCTAssertEqual(owner.host, .local)
        XCTAssertEqual(requests, [], "the session waits for the window's first snapshot")
        owner.testReceive(try sidebarFixture())
        XCTAssertEqual(requests, [.newSession])
        owner.testReceive(try sidebarFixture())
        XCTAssertEqual(requests, [.newSession], "a later snapshot makes no second session")
        app.newSession()
        XCTAssertEqual(app.owners.count, 1, "with a window, a new session uses it")
        XCTAssertEqual(requests, [.newSession, .newSession])
    }
}
