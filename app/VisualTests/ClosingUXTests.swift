import AppKit
import GhosttyKit
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class ClosingUXTests: VisualTestCase {
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        }
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
    }
    private func click(_ button: NSButton) throws {
        let window = try XCTUnwrap(button.window)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let root = try XCTUnwrap(window.contentView?.superview)
        let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
        XCTAssertTrue(hit === button)
        // AppKit's button tracking does not dispatch actions in these hidden windows.
        // Hit testing pins the slot; performClick exercises its native target/action.
        button.performClick(nil)
    }

    func testRowHoverSwapFixedInsetAndRowDoesNotActivate() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"client":{"session":"$0","window":"@7","pane":"%4"},"server_instance":{"started_at":1791000000,"pid":4242},"sessions":[{"id":"$0","name":"s","current":true,"nodes":[{"kind":"pane","id":"%4","pane":"%4","window":"@7","title":"shell","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[{"id":"child","state":"working"}]},"run":null,"started":null,"children":[]}]}]}
        """.utf8))
        let list = SidebarView()
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 110)
        window.contentView!.addSubview(list)
        list.update(.running(snapshot))
        list.layoutSubtreeIfNeeded()
        let index = try XCTUnwrap(list.visualRows.firstIndex { $0.target != nil })
        let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCell)
        var paneCloses: [PaneID] = [], activations = 0
        list.closePane = { if let pane = $0.target?.pane { paneCloses.append(pane) } }
        list.navigate = { _ in activations += 1 }
        cell.layoutSubtreeIfNeeded()
        cell.updateTrackingAreas()
        XCTAssertEqual(cell.trackingAreas.first?.rect, cell.close.frame)
        for point in [NSPoint(x: 60, y: cell.close.frame.midY), NSPoint(x: 20, y: cell.bounds.maxY - 1)] {
            cell.mouseEntered(with: mouse(.mouseEntered, at: cell.convert(point, to: nil), in: window))
            XCTAssertTrue(cell.close.isHidden)
        }
        cell.mouseEntered(with: mouse(.mouseEntered, at: cell.convert(NSPoint(x: cell.close.frame.midX, y: cell.close.frame.midY), to: nil), in: window))
        cell.layoutSubtreeIfNeeded()
        XCTAssertFalse(cell.close.isHidden)
        XCTAssertEqual(cell.close.frame.midX, 20)
        try click(cell.close)
        XCTAssertEqual(paneCloses, [PaneID(number: 4)])
        XCTAssertEqual(activations, 0)
        cell.mouseExited(with: mouse(.mouseExited, at: .zero, in: window))
        XCTAssertTrue(cell.close.isHidden)
        let record = try XCTUnwrap(list.visualRows.firstIndex { if case .program = $0.id { true } else { false } })
        let recordCell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: record, makeIfNecessary: true) as? SidebarCell)
        recordCell.layoutSubtreeIfNeeded()
        recordCell.mouseEntered(with: mouse(.mouseEntered, at: recordCell.convert(NSPoint(x: recordCell.close.frame.midX, y: recordCell.close.frame.midY), to: nil), in: window))
        XCTAssertTrue(recordCell.close.isHidden)
    }

    func testKillTargetsConfirmationCmdWAndNewWindowFocus() async throws {
        let dir = "/tmp/kux-" + UUID().uuidString.prefix(8)
        let result = try await Child.run(tools.kido, ["server", "--server", dir], env: tools.environment)
        XCTAssertEqual(result.status, 0, result.err)
        let server = try JSONDecoder().decode(Server.self, from: Data(result.out.utf8))
        let board = NSPasteboard(name: .init("kux-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, accents: HostAccents(preferences: nil), start: false)
        owner.testEndpoint = Endpoint(server: server, kido: tools.kido)
        addTeardownBlock { @MainActor in
            owner.close(); board.releaseGlobally()
            _ = try? await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-session", "-t", "main"], env: tools.environment)
            try? FileManager.default.removeItem(atPath: dir)
        }
        owner.start()
        try await wait("private owner ready") { owner.testConnection != nil && owner.stressState.4 != nil && owner.testSession?.windows.values.first?.panes.first != nil }
        let original = try XCTUnwrap(owner.stressState.0.window)
        owner.window.display()
        func newWindow() throws { owner.sidebar.list.newWindow(try XCTUnwrap(owner.stressState.0.session)) }
        try newWindow()
        try await wait("new window creates and selects another window") { owner.stressState.0.windows.count == 2 && owner.stressState.0.window != original }
        let created = try XCTUnwrap(owner.stressState.0.window)
        let pane = try XCTUnwrap(owner.testSession?.windows[created]?.panes.first)
        try await wait("new window receives terminal focus") { owner.window.firstResponder === pane }
        func status(_ running: Bool, pane: PaneView, created: WindowID) throws {
            let model = owner.stressState.0
            let session = try XCTUnwrap(model.session)
            let phase = running ? "[\"Running\",{\"origin\":[\"Command\",{\"command\":\"sleep 60\",\"started_at\":1791000000}],\"fullscreen\":false}]" : "[\"Unknown\"]"
            let json = """
            {"v":2,"client":{"session":"\(session)","window":"\(created)","pane":"\(pane.pane)"},"server_instance":{"started_at":1791000000,"pid":4242},"sessions":[{"id":"\(session)","name":"s","current":true,"nodes":[{"kind":"pane","id":"\(pane.pane)","pane":"\(pane.pane)","window":"\(created)","title":"job","lifecycle":["Live",["Terminal",{"phase":\(phase),"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[]}]}]}
            """
            owner.testReceive(try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)))
        }
        try status(true, pane: pane, created: created)
        owner.closeCurrentWindow()
        XCTAssertEqual(owner.preparedAlert?.alert.informativeText, "Processes are still running in this window. Closing the window will end them.")
        owner.respondToAlert(.alertSecondButtonReturn)
        try await wait("window confirmation dismissed") { owner.window.attachedSheet == nil }
        try status(true, pane: pane, created: created)
        let list = owner.sidebar.list
        let row = try XCTUnwrap(list.visualRows.firstIndex { $0.target?.pane == pane.pane })
        let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell)
        cell.layoutSubtreeIfNeeded()
        cell.mouseEntered(with: mouse(.mouseEntered, at: cell.convert(NSPoint(x: cell.close.frame.midX, y: cell.close.frame.midY), to: nil), in: owner.window))
        cell.layoutSubtreeIfNeeded()
        try click(cell.close)
        XCTAssertEqual(owner.preparedAlert?.alert.informativeText, "A process is still running in this pane. Closing the pane will end it.")
        owner.respondToAlert(.alertSecondButtonReturn)
        try await wait("pane confirmation dismissed") { owner.window.attachedSheet == nil }
        try status(true, pane: pane, created: created)
        owner.window.makeFirstResponder(pane)
        // A hidden owner cannot be NSApp's main window: its global Close menu
        // would consume Cmd-W without a target. Exercise Ghostty's pane binding.
        let menu = NSApp.mainMenu
        NSApp.mainMenu = nil
        defer { NSApp.mainMenu = menu }
        let cmdW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: owner.window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        XCTAssertTrue(pane.performKeyEquivalent(with: cmdW))
        try await drain(runtime)
        XCTAssertEqual(owner.preparedAlert?.alert.messageText, "Close “sleep 60”?")
        XCTAssertNotNil(owner.testSession?.windows[created])
        owner.respondToAlert(.alertSecondButtonReturn)
        XCTAssertNil(owner.preparedAlert)
        try await wait("Cmd-W confirmation dismissed") { owner.window.attachedSheet == nil }
        try status(false, pane: pane, created: created)
        XCTAssertTrue(pane.performKeyEquivalent(with: cmdW))
        try await drain(runtime)
        XCTAssertNil(owner.preparedAlert)
        try await wait("quiet Cmd-W kills originating pane, not original window") { owner.stressState.0.windows.count == 1 }
        XCTAssertEqual(owner.stressState.0.window, original)
        try newWindow()
        try await wait("another close target created") { owner.stressState.0.windows.count == 2 && owner.stressState.0.window != original && owner.stressState.0.window.flatMap { owner.testSession?.windows[$0]?.panes.first } != nil }
        let nextWindow = try XCTUnwrap(owner.stressState.0.window)
        let nextPane = try XCTUnwrap(owner.testSession?.windows[nextWindow]?.panes.first)
        try status(false, pane: nextPane, created: nextWindow)
        owner.closeCurrentWindow()
        try await wait("quiet window close kills right target") { owner.stressState.0.windows.count == 1 }
        XCTAssertEqual(owner.stressState.0.windows.first?.id, original)
        try newWindow()
        try await wait("quiet row target created") { owner.stressState.0.windows.count == 2 && owner.stressState.0.window != original && owner.stressState.0.window.flatMap { owner.testSession?.windows[$0]?.panes.first } != nil }
        let rowWindow = try XCTUnwrap(owner.stressState.0.window)
        let rowPane = try XCTUnwrap(owner.testSession?.windows[rowWindow]?.panes.first)
        try status(false, pane: rowPane, created: rowWindow)
        let quietRow = try XCTUnwrap(list.visualRows.firstIndex { $0.target?.pane == rowPane.pane })
        let quietCell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: quietRow, makeIfNecessary: true) as? SidebarCell)
        quietCell.layoutSubtreeIfNeeded()
        quietCell.mouseEntered(with: mouse(.mouseEntered, at: quietCell.convert(NSPoint(x: quietCell.close.frame.midX, y: quietCell.close.frame.midY), to: nil), in: owner.window))
        quietCell.layoutSubtreeIfNeeded()
        try click(quietCell.close)
        XCTAssertNil(owner.preparedAlert)
        try await wait("quiet row close kills right pane") { owner.stressState.0.windows.count == 1 }
        XCTAssertEqual(owner.stressState.0.windows.first?.id, original)
        try newWindow()
        try await wait("confirmed window target created") { owner.stressState.0.windows.count == 2 && owner.stressState.0.window != original && owner.stressState.0.window.flatMap { owner.testSession?.windows[$0]?.panes.first } != nil }
        let confirmedWindow = try XCTUnwrap(owner.stressState.0.window)
        let confirmedPane = try XCTUnwrap(owner.testSession?.windows[confirmedWindow]?.panes.first)
        try status(true, pane: confirmedPane, created: confirmedWindow)
        owner.closeCurrentWindow()
        XCTAssertNotNil(owner.preparedAlert)
        owner.respondToAlert(.alertFirstButtonReturn)
        try await wait("confirmed window close kills right target") { owner.stressState.0.windows.count == 1 }
        XCTAssertEqual(owner.stressState.0.windows.first?.id, original)
        XCTAssertNil(owner.preparedAlert)
    }
}
