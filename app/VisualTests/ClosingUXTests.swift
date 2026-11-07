import AppKit
import GhosttyKit
import SidebarFeed
import PaneGeometry
import XCTest
import KoModel
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

    func testTabAgentDisplayNameAndWeight() {
        let tabs = WindowTabs()
        for (agent, messageable, name, display) in [(true, true, "agent", "@agent"), (true, true, "@agent", "@agent"), (true, false, "native", "native"), (false, false, "shell", "shell")] {
            let tab = SessionModel.Tab(id: WindowID(number: 7), name: name, active: true, status: .quiet, agent: agent, messageable: messageable)
            XCTAssertEqual(tab.name, name)
            XCTAssertEqual(tab.displayName, display)
            XCTAssertEqual(tabs.labelFont(tab), NSFont.systemFont(ofSize: 11, weight: agent ? .semibold : .regular))
            tabs.entries = [tab]
            tabs.frame = NSRect(x: 0, y: 0, width: 220, height: 36)
            XCTAssertEqual(tabs.labelRect(0).minX, 28)
        }
    }

    func testHoverSwapFixedInsetAndRowDoesNotActivate() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tabs = WindowTabs(frame: NSRect(x: 0, y: 120, width: 400, height: 36))
        window.contentView!.addSubview(tabs)
        tabs.entries = [.init(id: WindowID(number: 7), name: "Working", active: true, status: .waiting)]
        let label = tabs.labelRect(0)
        var selected = 0, closed: [WindowID] = []
        tabs.select = { _ in selected += 1 }
        tabs.close = { closed.append($0.id) }
        tabs.mouseEntered(with: mouse(.mouseEntered, at: tabs.convert(NSPoint(x: 17, y: 18), to: nil), in: window))
        tabs.layoutSubtreeIfNeeded()
        XCTAssertFalse(tabs.closeButton.isHidden)
        XCTAssertEqual(tabs.closeButton.frame.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(tabs.closeButton.frame.midX, 17)
        XCTAssertEqual(tabs.labelRect(0), label)
        XCTAssertEqual(label.minX, 28)
        try click(tabs.closeButton)
        XCTAssertEqual(closed, [WindowID(number: 7)])
        XCTAssertEqual(selected, 0)
        for point in [NSPoint(x: label.midX, y: 18), NSPoint(x: 60, y: 18), NSPoint(x: 17, y: 2)] {
            tabs.mouseMoved(with: mouse(.mouseMoved, at: tabs.convert(point, to: nil), in: window))
            tabs.layoutSubtreeIfNeeded()
            XCTAssertTrue(tabs.closeButton.isHidden)
        }
        tabs.mouseExited(with: mouse(.mouseExited, at: .zero, in: window))
        tabs.layoutSubtreeIfNeeded()
        XCTAssertTrue(tabs.closeButton.isHidden)
        XCTAssertEqual(tabs.labelRect(0), label)
        XCTAssertEqual(tabs.addWindow.frame.maxX, tabs.bounds.maxX)
        XCTAssertEqual(tabs.addWindow.frame.width, 28)

        let snapshot = fixtureSnapshot(window: 7, pane: 4, [("s", [.item(fixtureItem(4, window: 7, "shell", shellLifecycle(.unknown),
                                                                                       records: [.working(.init(id: "child"))]))])])
        let list = SidebarView()
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 110)
        window.contentView!.addSubview(list)
        list.update(snapshot)
        list.layoutSubtreeIfNeeded()
        let index = try XCTUnwrap(list.visualRows.firstIndex { $0.target != nil })
        let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCell)
        var paneCloses: [PaneID] = [], activations = 0
        list.closePane = { if let pane = $0.target?.pane { paneCloses.append(pane) } }
        list.navigate = { _, _ in activations += 1 }
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
        let dir = try await koLaunched()
        let board = NSPasteboard(name: .init("kux-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = dir
        addTeardownBlock { @MainActor in owner.close(); board.releaseGlobally() }
        owner.start()
        try await wait("private owner ready") { owner.testClient != nil && owner.snapshot != nil && owner.testSession?.windows.values.first?.panes.first != nil }
        let original = try XCTUnwrap(owner.stressState.0.window)
        owner.window.display()
        try click(owner.sidebar.tabs.addWindow)
        try await wait("plus creates and selects another window") { owner.stressState.0.windows.count == 2 && owner.stressState.0.window != original }
        let created = try XCTUnwrap(owner.stressState.0.window)
        let pane = try XCTUnwrap(owner.testSession?.windows[created]?.panes.first)
        try await wait("new window receives terminal focus") { owner.window.firstResponder === pane }
        func status(_ running: Bool, pane: PaneView, created: WindowID) async throws {
            try await wait("the snapshot has the pane") { sidebarRows(owner.snapshot).contains { $0.target?.pane == pane.pane } }
            let phase: KoSchema.Phase = running ? .running(.init(fullscreen: false, origin: .command(.init(command: "sleep 60", startedAt: fixtureSince)))) : .idle(.init())
            let snapshot = withLifecycle(try XCTUnwrap(owner.snapshot), pane: pane.pane,
                .live(.host(.init(pane: .terminal(KoSchema.Shell(phase: phase, report: nil))))), mark: running ? .running : .none_)
            owner.testReceive(snapshot)
        }
        try await status(true, pane: pane, created: created)
        let tabs = owner.sidebar.tabs
        let tabIndex = try XCTUnwrap(tabs.entries.firstIndex { $0.id == created })
        let tabPoint = tabs.convert(NSPoint(x: tabs.labelRect(tabIndex).minX - 11, y: 18), to: nil)
        tabs.mouseEntered(with: mouse(.mouseEntered, at: tabPoint, in: owner.window))
        tabs.layoutSubtreeIfNeeded()
        try click(tabs.closeButton)
        XCTAssertEqual(owner.preparedAlert?.alert.informativeText, "Programs are still running in this window. Closing the window will end them.")
        owner.respondToAlert(.alertSecondButtonReturn)
        try await wait("window confirmation dismissed") { owner.window.attachedSheet == nil }
        try await status(true, pane: pane, created: created)
        let list = owner.sidebar.list
        let row = try XCTUnwrap(list.visualRows.firstIndex { $0.target?.pane == pane.pane })
        let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell)
        cell.layoutSubtreeIfNeeded()
        cell.mouseEntered(with: mouse(.mouseEntered, at: cell.convert(NSPoint(x: cell.close.frame.midX, y: cell.close.frame.midY), to: nil), in: owner.window))
        cell.layoutSubtreeIfNeeded()
        try click(cell.close)
        XCTAssertEqual(owner.preparedAlert?.alert.informativeText, "A program is still running in this pane. Closing the pane will end it.")
        owner.respondToAlert(.alertSecondButtonReturn)
        try await wait("pane confirmation dismissed") { owner.window.attachedSheet == nil }
        try await status(true, pane: pane, created: created)
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
        try await status(false, pane: pane, created: created)
        XCTAssertTrue(pane.performKeyEquivalent(with: cmdW))
        try await drain(runtime)
        XCTAssertNil(owner.preparedAlert)
        try await wait("quiet Cmd-W kills originating pane, not original window") { owner.stressState.0.windows.count == 1 }
        XCTAssertEqual(owner.stressState.0.window, original)
        owner.sidebar.tabs.addWindow.performClick(nil)
        try await wait("another close target created") { owner.stressState.0.windows.count == 2 && owner.stressState.0.window != original && owner.stressState.0.window.flatMap { owner.testSession?.windows[$0]?.panes.first } != nil }
        let tab = try XCTUnwrap(owner.sidebar.tabs.entries.first { $0.id != original })
        let nextPane = try XCTUnwrap(owner.testSession?.windows[tab.id]?.panes.first)
        try await status(false, pane: nextPane, created: tab.id)
        let nextIndex = try XCTUnwrap(tabs.entries.firstIndex { $0.id == tab.id })
        tabs.mouseEntered(with: mouse(.mouseEntered, at: tabs.convert(NSPoint(x: tabs.labelRect(nextIndex).minX - 11, y: 18), to: nil), in: owner.window))
        tabs.layoutSubtreeIfNeeded()
        try click(tabs.closeButton)
        try await wait("quiet window close kills right target") { owner.stressState.0.windows.count == 1 }
        XCTAssertEqual(owner.stressState.0.windows.first?.id, original)
        owner.sidebar.tabs.addWindow.performClick(nil)
        try await wait("quiet row target created") { owner.stressState.0.windows.count == 2 && owner.stressState.0.window != original && owner.stressState.0.window.flatMap { owner.testSession?.windows[$0]?.panes.first } != nil }
        let rowWindow = try XCTUnwrap(owner.stressState.0.window)
        let rowPane = try XCTUnwrap(owner.testSession?.windows[rowWindow]?.panes.first)
        try await status(false, pane: rowPane, created: rowWindow)
        let quietRow = try XCTUnwrap(list.visualRows.firstIndex { $0.target?.pane == rowPane.pane })
        let quietCell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: quietRow, makeIfNecessary: true) as? SidebarCell)
        quietCell.layoutSubtreeIfNeeded()
        quietCell.mouseEntered(with: mouse(.mouseEntered, at: quietCell.convert(NSPoint(x: quietCell.close.frame.midX, y: quietCell.close.frame.midY), to: nil), in: owner.window))
        quietCell.layoutSubtreeIfNeeded()
        try click(quietCell.close)
        XCTAssertNil(owner.preparedAlert)
        try await wait("quiet row close kills right pane") { owner.stressState.0.windows.count == 1 }
        XCTAssertEqual(owner.stressState.0.windows.first?.id, original)
        owner.sidebar.tabs.addWindow.performClick(nil)
        try await wait("confirmed window target created") { owner.stressState.0.windows.count == 2 && owner.stressState.0.window != original && owner.stressState.0.window.flatMap { owner.testSession?.windows[$0]?.panes.first } != nil }
        let confirmedWindow = try XCTUnwrap(owner.stressState.0.window)
        let confirmedPane = try XCTUnwrap(owner.testSession?.windows[confirmedWindow]?.panes.first)
        try await status(true, pane: confirmedPane, created: confirmedWindow)
        let confirmedIndex = try XCTUnwrap(tabs.entries.firstIndex { $0.id == confirmedWindow })
        tabs.mouseEntered(with: mouse(.mouseEntered, at: tabs.convert(NSPoint(x: tabs.labelRect(confirmedIndex).minX - 11, y: 18), to: nil), in: owner.window))
        tabs.layoutSubtreeIfNeeded()
        try click(tabs.closeButton)
        XCTAssertNotNil(owner.preparedAlert)
        owner.respondToAlert(.alertFirstButtonReturn)
        try await wait("confirmed window close kills right target") { owner.stressState.0.windows.count == 1 }
        XCTAssertEqual(owner.stressState.0.windows.first?.id, original)
        XCTAssertNil(owner.preparedAlert)
    }


}
