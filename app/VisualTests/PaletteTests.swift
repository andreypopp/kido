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

            owner.togglePalette()
            let palette = try XCTUnwrap(owner.palette)
            let editor = try XCTUnwrap(owner.window.firstResponder as? NSTextView)
            XCTAssertTrue(editor.isDescendant(of: palette), "the search field takes the keyboard")
            XCTAssertEqual(palette.shown.prefix(panes.count).map(\.entry.title), panes.map(\.0), "with no text, the panes come first, in sidebar order")
            XCTAssertEqual(palette.shown.first?.entry.detail, "main")
            let commands = palette.shown.dropFirst(panes.count).map(\.entry)
            let next = try XCTUnwrap(commands.first { $0.title == "Next Window" })
            XCTAssertEqual([next.detail, next.shortcut], ["Window", "⌘}"])
            XCTAssertNotNil(commands.first { $0.title == "Connect to Remote Host…" && $0.detail == "File" })
            XCTAssertNil(commands.first { $0.title == "Command Palette…" }, "the palette does not list itself")
            image("all")
            owner.togglePalette()
            XCTAssertNil(owner.palette, "the palette key closes an open palette")
            XCTAssertNil(palette.superview)

            owner.togglePalette()
            let empty = try XCTUnwrap(owner.palette)
            let field = try XCTUnwrap(owner.window.firstResponder as? NSTextView)
            field.insertText("main term", replacementRange: field.selectedRange())
            XCTAssertEqual(empty.shown.first.map { [$0.entry.detail, $0.entry.title] }, ["main", "Terminal"], "words match the session and the title")
            XCTAssertEqual(empty.shown.first?.offsets, [[0, 1, 2, 3], [0, 1, 2, 3]])
            image("session")
            field.selectAll(nil)
            field.insertText("visa", replacementRange: field.selectedRange())
            XCTAssertEqual(empty.shown.first?.entry.detail, "visa", "a session name alone finds its panes")
            field.selectAll(nil)
            field.insertText("zzqq", replacementRange: field.selectedRange())
            XCTAssertTrue(empty.shown.isEmpty)
            image("no-match")
            field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertNotNil(owner.palette, "Return with no match keeps the palette open")
            field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertNil(owner.palette, "Escape closes the palette")
            XCTAssertEqual(requests, [])

            owner.togglePalette()
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
}
