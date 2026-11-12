import AppKit
import GhosttyKit
import KoClient
import KoModel
import SidebarFeed
import SnapshotTesting
import XCTest
import WebKit
@testable import Kido

@MainActor final class NavigationHistoryTests: AppWindowCase {
    private func launch(_ windows: String) async throws -> WindowOwner {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":\#(windows)}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path
        addTeardownBlock { @MainActor in owner.close() }
        owner.start()
        try await wait("tabs") { owner.sidebar.tabs.entries.count == 3 }
        return owner
    }

    private func selected(_ owner: WindowOwner) -> PaneID? { owner.testModel?.selection.pane }

    private func mouse(button: Int, down: Bool) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp,
                                       mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    func testUserJumpsFillTheHistoryAndGoingMovesTheCursor() async throws {
        let one = koPane(), split = #"{"split":"h","children":[\#(koPane()),\#(koPane())]}"#
        let owner = try await launch(#"[{"name":"A","tree":\#(one)},{"name":"B","tree":\#(split)},{"name":"C","tree":\#(one)}]"#)
        let layout = try XCTUnwrap(owner.testModel?.layout.layout)
        let session = try XCTUnwrap(owner.navigation.session)
        let (a, b, c) = (layout.windows[0], layout.windows[1], layout.windows[2])
        let bPanes = try XCTUnwrap(owner.testModel?.layout.layout.window(b.id)?.panes)
        try await wait("first window selected") { self.selected(owner) == a.focus }
        XCTAssertFalse(owner.canGo(.back) || owner.canGo(.forward))

        owner.perform(.selectWindow(session, b.id))
        try await wait("a tab jump lands") { owner.canGo(.back) && self.selected(owner) == b.focus }
        XCTAssertFalse(owner.canGo(.forward))
        owner.go(.back)
        try await wait("back lands on the source") { self.selected(owner) == a.focus && owner.canGo(.forward) }
        XCTAssertFalse(owner.canGo(.back))
        owner.go(.forward)
        try await wait("forward lands again") { self.selected(owner) == b.focus && owner.canGo(.back) }

        let other = try XCTUnwrap(bPanes.first { $0 != b.focus })
        owner.paneCommand(.select(b.focus == bPanes[0] ? .right : .left), b.focus)
        try await wait("a directional move lands") { self.selected(owner) == other }
        owner.go(.back)
        try await wait("back from a directional move") { self.selected(owner) == b.focus }

        owner.perform(.selectWindow(session, c.id))
        try await wait("branch") { self.selected(owner) == c.focus && !owner.canGo(.forward) }
        try owner.testClient?.select(KO_SELECT_WINDOW, a.id)
        try await wait("the server moved the selection") { self.selected(owner) == a.focus }
        owner.go(.back)
        try await wait("an unsolicited selection is no entry") { self.selected(owner) == b.focus }

        owner.newWindow()
        try await wait("the new window is selected") { owner.navigation.windows.count == 4 && owner.canGo(.back) && !owner.canGo(.forward) && self.selected(owner) != b.focus }
        let created = try XCTUnwrap(selected(owner))
        owner.go(.back)
        try await wait("back from a new window") { self.selected(owner) == b.focus && owner.canGo(.forward) }
        owner.go(.forward)
        try await wait("forward to the new window") { self.selected(owner) == created }

        owner.paneCommand(.split(.right), created)
        try await wait("a split pane is an entry") {
            guard let now = self.selected(owner) else { return false }
            return now != created && owner.canGo(.back) && !owner.canGo(.forward)
        }
        let splitPane = try XCTUnwrap(selected(owner))
        owner.go(.back)
        try await wait("back from a split") { self.selected(owner) == created }
        owner.go(.forward)
        try await wait("forward to the split") { self.selected(owner) == splitPane }

        let client = try XCTUnwrap(owner.testClient)
        _ = try await Task.detached { try client.delete(KO_DELETE_WINDOW, b.id) }.value
        try await wait("windows closed") { owner.navigation.windows.count == 3 }
        owner.go(.back)
        try await wait("a closed window leaves no entry") { self.selected(owner) == created }
        owner.go(.back)
        try await wait("back skips the closed window") { self.selected(owner) == a.focus }

        let second = WindowOwner(host: .local, runtime: runtime, start: false)
        second.testServerDir = directory.path
        addTeardownBlock { @MainActor in second.close() }
        second.start()
        try await wait("a second window") { second.sidebar.tabs.entries.count == 3 }
        XCTAssertFalse(second.canGo(.back) || second.canGo(.forward))
    }

    func testMouseButtonsAndMenuItemsGo() async throws {
        let one = koPane()
        let owner = try await launch(#"[{"name":"A","tree":\#(one)},{"name":"B","tree":\#(one)},{"name":"C","tree":\#(one)}]"#)
        let windows = try XCTUnwrap(owner.testModel?.layout.layout.windows)
        let session = try XCTUnwrap(owner.navigation.session)
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Shell" }?.submenu)
        let items = menu.items.filter { ["Back", "Forward"].contains($0.title) }
        XCTAssertEqual(items.map(\.title), ["Back", "Forward"])
        XCTAssertEqual(items.map(\.keyEquivalent), ["[", "]"])
        XCTAssertEqual(items.map(\.keyEquivalentModifierMask), [[.command, .control], [.command, .control]])
        XCTAssertEqual(items.map(\.action), [#selector(WindowOwner.navigateHistoryBack(_:)), #selector(WindowOwner.navigateHistoryForward(_:))])
        XCTAssertFalse(owner.validateMenuItem(items[0]))
        XCTAssertFalse(owner.validateMenuItem(items[1]))
        try await wait("first window selected") { self.selected(owner) == windows[0].focus }
        owner.perform(.selectWindow(session, windows[1].id))
        try await wait("a jump") { owner.canGo(.back) }
        XCTAssertTrue(owner.validateMenuItem(items[0]))
        XCTAssertFalse(owner.validateMenuItem(items[1]))
        XCTAssertTrue(owner.window.tryToPerform(items[0].action!, with: items[0]))
        try await wait("the menu item goes back") { self.selected(owner) == windows[0].focus && owner.canGo(.forward) }

        owner.window.sendEvent(try mouse(button: 4, down: true))
        owner.window.sendEvent(try mouse(button: 4, down: false))
        try await wait("mouse button 5 goes forward") { self.selected(owner) == windows[1].focus && owner.canGo(.back) }
        owner.window.sendEvent(try mouse(button: 3, down: false))
        XCTAssertEqual(selected(owner), windows[1].focus, "only a press acts")
        owner.window.sendEvent(try mouse(button: 3, down: true))
        try await wait("mouse button 4 goes back") { self.selected(owner) == windows[0].focus }
    }

    func testToolbarBackReceivesAWindowMouseClick() async throws {
        let one = koPane()
        let owner = try await launch(#"[{"name":"A","tree":\#(one)},{"name":"B","tree":\#(one)},{"name":"C","tree":\#(one)}]"#)
        let windows = try XCTUnwrap(owner.testModel?.layout.layout.windows)
        let session = try XCTUnwrap(owner.navigation.session)
        try await wait("A") { self.selected(owner) == windows[0].focus }
        owner.perform(.selectWindow(session, windows[1].id))
        try await wait("B") { self.selected(owner) == windows[1].focus && owner.canGo(.back) }
        try clickToolbarBack(owner)
        let forward = try XCTUnwrap(historyButtons(owner).last)
        try await wait("toolbar Back selects A and enables Forward") { self.selected(owner) == windows[0].focus && forward.isEnabled }
    }

    func testHistoryBackWithWebviewFirstResponder() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("history-webview.sock").path)
        try await toy.start()
        defer { toy.stop() }
        let page = koPane("'\(tools.ko)' webview enter --path '/'; exec '\(tools.ko)' webview serve --socket '\(toy.path)'")
        let owner = try await launch(#"[{"name":"A","tree":\#(koPane())},{"name":"B","tree":\#(page)},{"name":"C","tree":\#(koPane())}]"#)
        let windows = try XCTUnwrap(owner.testModel?.layout.layout.windows)
        let session = try XCTUnwrap(owner.navigation.session)
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(policy) }
        NSApp.activate(ignoringOtherApps: true)
        owner.window.makeKeyAndOrderFront(nil)
        try await wait("the key command reaches the test window", within: 5) { NSApp.keyWindow === owner.window && NSApp.isActive }
        try await wait("A") { self.selected(owner) == windows[0].focus }
        for input in ["toolbar", "key"] {
            owner.perform(.selectWindow(session, windows[1].id))
            try await wait("B webview") {
                self.selected(owner) == windows[1].focus && owner.testSession?.activePane?.webviewView?.browser.isLoading == false && owner.testSession?.activePane?.webviewView?.browser.url != nil
            }
            let web = try XCTUnwrap(owner.testSession?.activePane?.webviewView?.browser)
            XCTAssertTrue(owner.window.makeFirstResponder(web))
            XCTAssertTrue(owner.canGo(.back))
            if input == "toolbar" {
                try clickToolbarBack(owner)
            } else {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.control, .command], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: owner.window.windowNumber, context: nil, characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33))
                    NSApp.postEvent(event, atStart: true)
                    let queued = try XCTUnwrap(NSApp.nextEvent(matching: type == .keyDown ? .keyDown : .keyUp, until: Date().addingTimeInterval(1), inMode: .default, dequeue: true))
                    NSApp.sendEvent(queued)
                }
            }
            try await wait("\(input) Back from webview selects A", within: 5) { self.selected(owner) == windows[0].focus && owner.canGo(.forward) }
        }
    }

    private func historyButtons(_ owner: WindowOwner) throws -> [NSButton] {
        let host = try XCTUnwrap(owner.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "history" }?.view)
        return host.subviews.compactMap { $0 as? NSButton }
    }

    private func clickToolbarBack(_ owner: WindowOwner) throws {
        let back = try XCTUnwrap(historyButtons(owner).first)
        XCTAssertTrue(back.isEnabled)
        owner.window.makeKeyAndOrderFront(nil)
        owner.window.display()
        let screen = owner.window.convertPoint(toScreen: back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil))
        let point = owner.window.convertPoint(fromScreen: screen)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: owner.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.postEvent(up, atStart: true)
        owner.window.sendEvent(down)
    }

    func testQueuedWindowSwitchSupersedesAPendingHistoryMove() async throws {
        let one = koPane()
        let owner = try await launch(#"[{"name":"A","tree":\#(one)},{"name":"B","tree":\#(one)},{"name":"C","tree":\#(one)}]"#)
        let windows = try XCTUnwrap(owner.testModel?.layout.layout.windows)
        let session = try XCTUnwrap(owner.navigation.session)
        try await wait("first window selected") { self.selected(owner) == windows[0].focus }
        owner.perform(.selectWindow(session, windows[1].id))
        try await wait("B") { self.selected(owner) == windows[1].focus && owner.canGo(.back) }
        owner.perform(.selectWindow(session, windows[2].id))
        try await wait("C") { self.selected(owner) == windows[2].focus && owner.canGo(.back) }
        owner.go(.back)
        owner.selectWindow(.next)
        try await wait("the later gestures land on C") { owner.testNavigationIdle && self.selected(owner) == windows[2].focus }
        XCTAssertFalse(owner.canGo(.forward), "the history move was superseded, not committed")
        owner.go(.back)
        try await wait("back from C") { self.selected(owner) == windows[1].focus }
    }

    func testMouseButtonsAreConsumedButIgnoredWhileAPaletteOrSheetHasTheInput() async throws {
        let one = koPane()
        let owner = try await launch(#"[{"name":"A","tree":\#(one)},{"name":"B","tree":\#(one)},{"name":"C","tree":\#(one)}]"#)
        let windows = try XCTUnwrap(owner.testModel?.layout.layout.windows)
        let session = try XCTUnwrap(owner.navigation.session)
        try await wait("first window selected") { self.selected(owner) == windows[0].focus }
        owner.perform(.selectWindow(session, windows[1].id))
        try await wait("B") { self.selected(owner) == windows[1].focus && owner.canGo(.back) }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        owner.window.beginSheet(sheet) { _ in }
        XCTAssertNotNil(owner.window.attachedSheet)
        owner.window.sendEvent(try mouse(button: 3, down: true))
        await mainQueueFence()
        XCTAssertTrue(owner.testNavigationIdle, "a sheet takes the input")
        XCTAssertEqual(selected(owner), windows[1].focus)
        owner.window.endSheet(sheet)
        delegate.togglePalette()
        defer { delegate.closePalette() }
        XCTAssertFalse((owner.window as? OwnerWindow)?.allowsPaneInput ?? true)
        owner.window.sendEvent(try mouse(button: 3, down: true))
        await mainQueueFence()
        XCTAssertTrue(owner.testNavigationIdle, "a palette takes the input")
        XCTAssertEqual(selected(owner), windows[1].focus)
    }

    func testHeaderFitsAtTheMinimumSidebarWidth() async throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: config) }
        let board = NSPasteboard(name: .init("history-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        for (theme, hex) in [("light", "fffaf0"), ("dark", "172029")] {
        try configYAML(at: config, background: hex).write(to: config, atomically: true, encoding: .utf8)
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board)), start: false)
        defer { owner.close() }
        let root = try XCTUnwrap(owner.window.contentView?.superview)
        owner.window.orderFront(nil)
        defer { owner.window.orderOut(nil) }
        func item(_ id: String) throws -> NSView { try XCTUnwrap(owner.window.toolbar?.items.first { $0.itemIdentifier.rawValue == id }?.view) }
        func frame(_ id: String) throws -> NSRect {
            let view = try item(id)
            XCTAssertTrue(view.window === owner.window, "\(id) is in the toolbar, not its overflow menu")
            return view.convert(view.bounds, to: nil)
        }
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        for mode in ["docked", "collapsed", "floating"] {
            owner.sidebar.dismissFloating()
            owner.sidebar.isCollapsed = mode != "docked"
            if mode == "docked" { owner.sidebar.splitView.setPosition(Sidebar.minSidebarWidth, ofDividerAt: 0) }
            root.layoutSubtreeIfNeeded()
            if mode == "floating" { owner.sidebar.focusSidebar(nil) }
            root.layoutSubtreeIfNeeded()
            owner.sidebar.viewDidLayout()
            owner.window.display()
            await mainQueueFence()
            let tabsX = { owner.sidebar.tabs.convert(owner.sidebar.tabs.bounds, to: nil).minX }
            try await wait("the toolbar follows the sidebar") { mode != "docked" || tabsX() >= Sidebar.minSidebarWidth }
            let history = try frame("history"), toggle = try frame("toggleSidebar")
            let lights = try XCTUnwrap(owner.window.standardWindowButton(.zoomButton)).convert(try XCTUnwrap(owner.window.standardWindowButton(.zoomButton)).bounds, to: nil)
            XCTAssertGreaterThanOrEqual(history.minX, lights.maxX, mode)
            XCTAssertLessThanOrEqual(history.minX - lights.maxX, 16, mode)
            XCTAssertEqual(history.width, 64, mode)
            XCTAssertGreaterThanOrEqual(toggle.minX, history.maxX, mode)
            if mode != "docked" {
                XCTAssertGreaterThanOrEqual(owner.sidebar.tabs.convert(owner.sidebar.tabs.bounds, to: nil).minX, toggle.maxX, mode)
            }
            if mode == "docked" {
                let session = try frame("newSession")
                XCTAssertGreaterThanOrEqual(session.minX, history.maxX, mode)
                XCTAssertGreaterThanOrEqual(toggle.minX, session.maxX, mode)
                XCTAssertGreaterThanOrEqual(owner.sidebar.tabs.convert(owner.sidebar.tabs.bounds, to: nil).minX, Sidebar.minSidebarWidth, mode)
                XCTAssertLessThanOrEqual(toggle.maxX, Sidebar.minSidebarWidth + 1, mode)
            }
            let buttons = try item("history").subviews.compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.map(\.toolTip), ["Back ⌃⌘[", "Forward ⌃⌘]"])
            XCTAssertEqual(buttons.map(\.alphaValue), [0.35, 0.35])
            XCTAssertEqual(buttons.map(\.isEnabled), [false, false])
            for button in buttons {
                let center = root.convert(button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), from: nil)
                XCTAssertTrue(root.hitTest(center) === button || button.isEnabled == false, mode)
            }
            owner.sidebar.canGo = { $0 == .back }
            owner.sidebar.refreshHistory()
            XCTAssertEqual(buttons.map(\.alphaValue), [1, 0.35])
            XCTAssertEqual(buttons.map(\.isEnabled), [true, false])
            owner.sidebar.canGo = { _ in true }
            owner.sidebar.refreshHistory()
            XCTAssertEqual(buttons.map(\.alphaValue), [1, 1])
            let strip = root.convert(NSRect(x: 0, y: history.minY - 4, width: owner.window.frame.width, height: 36), from: nil)
            if let failure = verifySnapshot(of: try croppedImage(root, to: strip), as: .pixels, named: "enabled-\(theme)-" + mode, record: record),
               !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
            owner.sidebar.canGo = { $0 == .forward }
            owner.sidebar.refreshHistory()
            await mainQueueFence()
            if let failure = verifySnapshot(of: try croppedImage(root, to: strip), as: .pixels, named: "back-disabled-\(theme)-" + mode, record: record),
               !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
            owner.sidebar.canGo = { _ in false }
            owner.sidebar.refreshHistory()
            }
        }
    }
}
