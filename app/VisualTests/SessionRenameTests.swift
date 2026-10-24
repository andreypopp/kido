import AppKit
import GhosttyKit
import SidebarFeed
import SnapshotTesting
import TmuxControl
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

    func testRenameOnPrivateControlClient() async throws {
        let dir = "/tmp/kr-" + UUID().uuidString.prefix(8)
        let result = try await Child.run(tools.kido, ["server", "--server", dir], env: tools.environment)
        XCTAssertEqual(result.status, 0, result.err)
        let server = try JSONDecoder().decode(Server.self, from: Data(result.out.utf8))
        let board = NSPasteboard(name: .init("kr-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testEndpoint = Endpoint(server: server, kido: tools.kido)
        addTeardownBlock { @MainActor in
            owner.close(); board.releaseGlobally()
            for id in ["$0", "$1"] {
                _ = try? await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-session", "-t", id], env: tools.environment)
            }
            try? FileManager.default.removeItem(atPath: dir)
        }
        owner.start()
        try await wait("rename owner ready") { owner.testConnection != nil && owner.stressState.4 != nil }
        let list = owner.sidebar.list
        owner.window.display()
        list.layoutSubtreeIfNeeded()
        let table = list.visualTable
        var cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        cell.layoutSubtreeIfNeeded()
        let plus = cell.addWindow.frame
        let below = table.rect(ofRow: 1)
        let previousFocus = owner.window.firstResponder
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
        owner.send([Command("new-session", "-d", "-s", "work")])
        try await wait("duplicate session visible") { owner.stressState.4?.sessions.contains { $0.name == "work" } == true }
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
        cell.nameField.stringValue = "a.b"
        cell.finishRename(true)
        XCTAssertFalse(cell.nameField.isHidden)
        XCTAssertFalse(cell.renameError.isHidden)
        XCTAssertTrue(sent.isEmpty)
        cell.nameField.stringValue = "changed text"
        cell.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: cell.nameField))
        XCTAssertTrue(cell.renameError.isHidden)
        let selection = NSRange(location: 2, length: 3)
        (cell.nameField.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        let snapshot = try XCTUnwrap(owner.stressState.4)
        let data = try await Child.run(server.tmux, ["-u", "-S", server.socket, "new-window", "-d", "-t", "$0", "-n", "changed"], env: tools.environment)
        XCTAssertEqual(data.status, 0)
        try await wait("snapshot changes mid edit") { owner.stressState.4 != snapshot }
        XCTAssertTrue(table.view(atColumn: 0, row: 0, makeIfNecessary: true) === cell)
        XCTAssertEqual(cell.nameField.stringValue, "changed text")
        XCTAssertEqual((cell.nameField.currentEditor() as? NSTextView)?.selectedRange(), selection)
        cell.nameField.stringValue = "renamed 'quoted' name"
        let enterEditor = try XCTUnwrap(cell.nameField.currentEditor() as? NSTextView)
        XCTAssertTrue(cell.control(cell.nameField, textView: enterEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        cell.finishRename(true)
        try await wait("snapshot names renamed session") { owner.stressState.4?.sessions.contains { $0.id == snapshot.sessions.first?.id && $0.name == "renamed 'quoted' name" } == true }
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
        list.renameSession = { _, _, done in done("tmux refusal") }
        try startEditing(renamedCell)
        renamedCell.nameField.stringValue = "another name"
        renamedCell.finishRename(true)
        XCTAssertFalse(renamedCell.nameField.isHidden)
        XCTAssertEqual(renamedCell.renameError.stringValue, "tmux refusal")
        XCTAssertEqual((renamedCell.nameField.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 12))
        renamedCell.finishRename(false)
    }

    func testRenameEditingAndErrorImages() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarView()
        window.contentView = list
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},"server_instance":{"started_at":1791000000,"pid":4242},"sessions":[{"id":"$0","name":"main","current":true,"nodes":[]},{"id":"$1","name":"work","current":false,"nodes":[]}]}
        """.utf8))
        list.update(.running(snapshot))
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
                    XCTAssertEqual(cell.frame.height, 29 + cell.errorHeight)
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
                if let failure = verifySnapshot(of: list, as: .image, named: name, record: record),
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
