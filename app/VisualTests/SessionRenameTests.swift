import AppKit
import GhosttyKit
import SidebarFeed
import SnapshotTesting
import KoModel
import PaneGeometry
import XCTest
@testable import Kido

@MainActor final class SessionRenameTests: VisualTestCase {
    private func startEditing(_ cell: SidebarCell) throws {
        let window = try XCTUnwrap(cell.window)
        let point = cell.convert(NSPoint(x: 20, y: 12), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 0))
        cell.mouseDown(with: event)
    }

    func testRenameOnAPrivateServer() async throws {
        let dir = try koServerDir()
        let board = NSPasteboard(name: .init("kr-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = dir
        addTeardownBlock { @MainActor in owner.close(); board.releaseGlobally() }
        _ = try await KoServer.launch(dir: dir)
        try await koMain(dir)
        owner.start()
        try await wait("rename owner ready") { owner.testClient != nil && owner.snapshot != nil }
        let client = try XCTUnwrap(owner.testClient)
        let list = owner.sidebar.list
        owner.window.display()
        list.layoutSubtreeIfNeeded()
        let table = list.visualTable
        var cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        cell.layoutSubtreeIfNeeded()
        let plus = cell.addWindow.frame
        let below = table.rect(ofRow: 1)
        let previousFocus = owner.window.firstResponder
        XCTAssertTrue(previousFocus is PaneView)
        let original = cell.accessibilityLabel()!
        let realRename = list.renameSession
        var sent: [(SessionID, String)] = []
        list.renameSession = { id, name, done in sent.append((id, name)); realRename(id, name, done) }
        try startEditing(cell)
        XCTAssertFalse(cell.nameField.isHidden)
        let editor = try XCTUnwrap(cell.nameField.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: cell.nameField.stringValue.utf16.count))
        XCTAssertEqual(cell.addWindow.frame, plus)
        XCTAssertEqual(table.rect(ofRow: 1), below)
        cell.nameField.stringValue = "cancelled"
        XCTAssertTrue(cell.control(cell.nameField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(cell.nameField.isHidden)
        XCTAssertTrue(owner.window.firstResponder === previousFocus)
        XCTAssertTrue(sent.isEmpty)
        try startEditing(cell)
        cell.finishRename(true)
        XCTAssertTrue(sent.isEmpty)
        _ = try await Task.detached { try client.edit(.addSession(KoSchema.EditAddSession(name: "work", new: KoSchema.CreatePane()))) }.value
        try await wait("duplicate session visible") { owner.snapshot?.sessions.contains { $0.name == "work" } == true }
        cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        cell.layoutSubtreeIfNeeded()
        try startEditing(cell)
        cell.nameField.stringValue = "work"
        cell.finishRename(true)
        XCTAssertFalse(cell.nameField.isHidden)
        XCTAssertEqual(cell.renameError.stringValue, "A session named “work” already exists.")
        XCTAssertEqual((cell.nameField.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 4))
        XCTAssertTrue(sent.isEmpty)
        cell.nameField.stringValue = "typing"
        cell.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: cell.nameField))
        XCTAssertTrue(cell.renameError.isHidden)
        cell.finishRename(false)
        try startEditing(cell)
        cell.nameField.stringValue = "work"
        cell.finishRename(true)
        XCTAssertFalse(cell.nameField.isHidden)
        XCTAssertFalse(cell.renameError.isHidden)
        XCTAssertTrue(sent.isEmpty)
        cell.nameField.stringValue = "changed text"
        cell.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: cell.nameField))
        XCTAssertTrue(cell.renameError.isHidden)
        let selection = NSRange(location: 2, length: 3)
        (cell.nameField.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        let snapshot = try XCTUnwrap(owner.snapshot)
        _ = try await Task.detached { try client.edit(.addWindow(KoSchema.EditAddWindow(after: WindowID(number: 1), new: KoSchema.CreatePane(), session: SessionID(number: 1)))) }.value
        try await wait("snapshot changes mid edit") { owner.snapshot != snapshot }
        XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: true) === cell)
        XCTAssertEqual(cell.nameField.stringValue, "changed text")
        XCTAssertEqual((cell.nameField.currentEditor() as? NSTextView)?.selectedRange(), selection)
        cell.nameField.stringValue = "renamed 'quoted' name"
        let enterEditor = try XCTUnwrap(cell.nameField.currentEditor() as? NSTextView)
        XCTAssertTrue(cell.control(cell.nameField, textView: enterEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        cell.finishRename(true)
        try await wait("snapshot names renamed session") { owner.snapshot?.sessions.contains { $0.id == snapshot.sessions.first?.id && $0.name == "renamed 'quoted' name" } == true }
        XCTAssertTrue(owner.window.firstResponder === previousFocus)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, snapshot.sessions.first?.id)
        XCTAssertTrue(cell.nameField.isHidden)
        XCTAssertNotEqual(original, list.visualRows.first?.title)
        let renamedCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        try startEditing(renamedCell)
        XCTAssertEqual(renamedCell.nameField.stringValue, "renamed 'quoted' name")
        owner.window.makeFirstResponder(previousFocus)
        try await wait("focus leaving commits unchanged text") { renamedCell.nameField.isHidden }
        XCTAssertEqual(sent.count, 1)
        list.renameSession = { _, _, done in done("server refusal") }
        try startEditing(renamedCell)
        renamedCell.nameField.stringValue = "another name"
        renamedCell.finishRename(true)
        XCTAssertFalse(renamedCell.nameField.isHidden)
        XCTAssertEqual(renamedCell.renameError.stringValue, "server refusal")
        XCTAssertEqual((renamedCell.nameField.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 12))
        renamedCell.finishRename(false)
    }

    func testRenameDrawingTracksWindowSplits() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarView()
        window.contentView = list
        let single = fixtureSnapshot(window: 0, pane: 0, [("main", [fixtureNode(0, "Shell", shellLifecycle())])])
        let split = fixtureSnapshot(window: 0, pane: 0, [("main", [.window(.init(id: WindowID(number: 0), children: [
            fixtureItem(0, window: 0, "Shell", shellLifecycle()), fixtureItem(1, window: 0, "Other", shellLifecycle())
        ]))])])
        list.show(single)
        window.layoutIfNeeded()
        let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarCell)
        cell.beginRename()
        let editor = try XCTUnwrap(cell.nameField.currentEditor() as? NSTextView)
        editor.string = "typed name"
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        func drawing() throws -> Data {
            window.layoutIfNeeded()
            cell.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
            cell.cacheDisplay(in: cell.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.tiffRepresentation)
        }
        for snapshot in [split, single] {
            list.show(snapshot)
            let actual = try drawing()
            let row = try XCTUnwrap(sidebarRows(snapshot).first { $0.target?.pane == PaneID(number: 0) })
            cell.configure(row, now: 0)
            XCTAssertEqual(actual, try drawing(), "Edited cell must draw the current window block")
            XCTAssertTrue(cell.nameField.currentEditor() === editor)
            XCTAssertEqual(editor.string, "typed name")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        }
        cell.finishRename(false)
    }

    func testRenameEditingAndErrorImages() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarView()
        window.contentView = list
        let snapshot = fixtureSnapshot(window: 0, pane: 0, [("main", []), ("work", [])])
        list.show(snapshot)
        window.layoutIfNeeded()
        list.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        var sent = 0
        list.renameSession = { _, _, _ in sent += 1 }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try startEditing(cell)
            for error in [false, true] {
                if error {
                    cell.nameField.stringValue = "work"
                    cell.finishRename(true)
                    XCTAssertEqual(cell.renameError.stringValue, "A session named “work” already exists.")
                    XCTAssertFalse(cell.nameField.isHidden)
                    XCTAssertEqual(cell.accessibilityLabel(), "main")
                    XCTAssertEqual(cell.frame.height, 26 + cell.errorHeight)
                    XCTAssertEqual((cell.nameField.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 4))
                }
                window.layoutIfNeeded()
                list.layoutSubtreeIfNeeded()
                list.visualTable.tile()
                cell.layoutSubtreeIfNeeded()
                cell.display()
                list.displayIfNeeded()
                CATransaction.flush()
                XCTAssertFalse(window.isVisible || NSApp.isActive)
                let name = "\(error ? "error" : "editing")-\(dark ? "dark" : "light")"
                let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                if let failure = verifySnapshot(of: list, as: .pixels, named: name, record: record),
                   !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
            }
            cell.nameField.stringValue = "typing"
            cell.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: cell.nameField))
            XCTAssertTrue(cell.renameError.isHidden)
            cell.finishRename(false)
        }
        XCTAssertEqual(sent, 0)
    }
}
