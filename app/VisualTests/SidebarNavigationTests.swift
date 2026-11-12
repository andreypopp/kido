import AppKit
import GhosttyKit
import KoClient
import KoModel
import SnapshotTesting
import SidebarFeed
import PaneGeometry
import XCTest
@testable import Kido

@MainActor final class SidebarNavigationTests: AppWindowCase {

    func testWindowTabs() async throws {
        try loadRuntime()
        let feed = directory.path + "/child-feed"
        FileManager.default.createFile(atPath: feed, contents: nil)
        let status = try FileHandle(forWritingTo: URL(fileURLWithPath: feed))
        defer { try? status.close() }
        func titled(_ title: String) -> String { koPane("printf '\\033]2;\(title)\\007'; stty raw -echo; exec /bin/cat") }
        let agent = koPane("printf '\\033]7501;state=idle:app=pi\\007'; stty raw -echo; exec /bin/cat", vars: #"{"pi.session":"s1","pi.name":"Agent caption"}"#)
        let editor = #"{"split":"h","children":[\#(agent),\#(titled("Review changes"))]}"#
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"Shell","tree":\#(titled("Shell prompt"))},{"name":"Editor","tree":\#(editor)},{"name":"Logs","tree":\#(titled("Build output"))}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path
        addTeardownBlock { @MainActor in owner.close() }
        owner.start()
        try await wait("three tabs") { owner.sidebar.tabs.entries.count == 3 }
        let windows = try XCTUnwrap(owner.testModel.map(\.layout.layout.windows)).map(\.id)
        let (shell, middle, last) = (windows[0], windows[1], windows[2])
        let childRequest = directory.appendingPathComponent("child.json")
        try JSONSerialization.data(withJSONObject: [
            "session": "session_1", "name": "Child", "parent": "pane_2", "close": "on_exit",
            "command": ["type": "argv", "argv": ["/bin/sh", "-c", "printf '\\033]7501;state=blocked:app=agent\\007'; exec tail -f " + SSH.quote(feed)]]
        ]).write(to: childRequest)
        try await ko(["api", "-X", "POST", "--input", childRequest.path, "/panes"], dir: directory.path)
        try await wait("the child pane nests under the editor") { owner.testModel.map(\.layout.layout.windows)?.count == 4 && owner.sidebar.tabs.entries.count == 3 }
        let child = try XCTUnwrap(owner.testModel.map(\.layout.layout.windows)?.map(\.id).first { ![shell, middle, last].contains($0) })
        let sidebar = owner.sidebar
        let root = try XCTUnwrap(owner.window.contentView?.superview)
        owner.window.display()
        root.layoutSubtreeIfNeeded()
        sidebar.splitView.setPosition(256, ofDividerAt: 0)
        try await wait("tab titles are the focus panes' labels") { sidebar.tabs.entries.map(\.name) == ["Shell prompt", "Agent caption", "Build output"] }
        try await wait("the nested agent waits in its window's tab") { sidebar.tabs.entries.map(\.status) == [.quiet, .waiting, .quiet] }
        XCTAssertEqual((sidebar.tabs.accessibilityChildren()?[1] as? NSAccessibilityElement)?.accessibilityLabel(), "Window: Agent caption — waiting")
        try status.write(contentsOf: Data("\u{1b}]7501;state=error:app=agent\u{7}".utf8))
        try await wait("a failed child") { sidebar.tabs.entries[1].status == .error }
        try status.write(contentsOf: Data("\u{1b}]7501;state=blocked:app=agent\u{7}".utf8))
        try await wait("waiting again") { sidebar.tabs.entries[1].status == .waiting }
        try owner.testClient?.select(KO_SELECT_WINDOW, child)
        try await wait("descendant active") { owner.navigation.window == middle && owner.testModel?.selection.window == child }
        XCTAssertEqual(sidebar.tabs.entries.first { $0.active }?.id, middle, "a child window's tab is its parent's")
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        try await wait("native tabs layout") { sidebar.tabs.frame.width > 300 && sidebar.tabs.frame.height == 36 }
        owner.perform(.selectWindow(try XCTUnwrap(owner.navigation.session), shell))
        try await wait("first window selected") { owner.navigation.window == shell }
        let point = sidebar.tabs.convert(NSPoint(x: sidebar.tabs.labelRect(1).midX, y: 18), to: nil)
        XCTAssertTrue(root.hitTest(root.convert(point, from: nil)) === sidebar.tabs)
        sidebar.tabs.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        sidebar.tabs.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
        try await wait("middle tab selected") { owner.navigation.window == middle }
        owner.perform(.selectWindow(try XCTUnwrap(owner.navigation.session), shell))
        try await wait("first window again") { owner.navigation.window == shell }
        let menus = SessionMenus()
        menus.send = { owner.perform($0) }
        menus.update(owner.navigation)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        XCTAssertTrue(menus.window.performKeyEquivalent(with: key))
        try await wait("Cmd-2 selects second tab") { owner.navigation.window == middle }
        let area = sidebar.content.convert(sidebar.content.bounds, to: root)
        XCTAssertGreaterThan(sidebar.tabs.convert(sidebar.tabs.bounds, to: root).minY, area.maxY)
        XCTAssertTrue(owner.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "windowTabs" }?.view === sidebar.tabs.superview)
        let tabs = sidebar.tabs.entries
        sidebar.tabs.entries = []
        let empty = root.hitTest(sidebar.tabs.convert(NSPoint(x: sidebar.tabs.bounds.midX, y: 18), to: root))
        XCTAssertFalse(empty === sidebar.tabs)
        XCTAssertTrue(empty?.mouseDownCanMoveWindow == true)
        sidebar.tabs.entries = tabs
        XCTAssertFalse(owner.window.isVisible)
        XCTAssertFalse(owner.window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: try headerImage(sidebar.tabs), as: .pixels, named: "middle", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        sidebar.isCollapsed = true
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        XCTAssertGreaterThanOrEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root).minX, 116)
        await mainQueueFence()
        if let failure = verifySnapshot(of: try headerImage(sidebar.tabs), as: .pixels, named: "collapsed", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        let client = try XCTUnwrap(owner.testClient)
        _ = try await Task.detached { try client.delete(KO_DELETE_WINDOW, child) }.value
        _ = try await Task.detached { try client.edit(.renameWindow(KoSchema.EditRenameWindow(name: "Renamed", window: middle))) }.value
        try await wait("renamed window") { owner.navigation.windows.map(\.name) == ["Shell", "Renamed", "Logs"] }
        _ = try await Task.detached { try client.edit(.reorderWindows(KoSchema.EditReorderWindows(order: [shell, last, middle], session: SessionID(number: 1)))) }.value
        try await wait("reordered tabs") { owner.navigation.windows.map(\.name) == ["Shell", "Logs", "Renamed"] }
        _ = try await Task.detached { try client.delete(KO_DELETE_WINDOW, last) }.value
        try await wait("closed tab") { owner.navigation.windows.map(\.name) == ["Shell", "Renamed"] }
        var created: String?
        owner.createSession("other") { created = $0 ?? "" }
        try await wait("the other session is current") { created != nil && owner.navigation.windows.count == 1 && owner.navigation.windows.first?.id != shell }
        owner.perform(.selectSession(SessionID(number: 1)))
        try await wait("session switched back") { owner.navigation.windows.map(\.name) == ["Shell", "Renamed"] }
    }

    func testPaneDragExcludesReorderGestures() async throws {
        try await start(windows: #"[{"name":"zsh","tree":{"split":"h","children":[\#(koPane()),\#(koPane())]}}]"#)
        try await wait("two panes") { self.terminal?.displayedPanes.count == 2 }
        let view = try XCTUnwrap(terminal), pane = try XCTUnwrap(view.displayedPanes.first?.pane)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(session.reorder.claim(.tab))
        view.visualBeginDrag(pane, down)
        XCTAssertFalse(view.visualPaneDragging, "a tab drag holds the gesture")
        session.reorder.release(.tab)
        view.visualBeginDrag(pane, down)
        XCTAssertTrue(view.visualPaneDragging)
        XCTAssertFalse(session.reorder.claim(.tab))
        XCTAssertFalse(session.reorder.claim(.sidebar))
        view.cancelDrag()
        XCTAssertFalse(view.visualPaneDragging)
        XCTAssertTrue(session.reorder.claim(.sidebar))
    }

    func testFloatingSidebar() async throws {
        try await start()
        window.styleMask.insert([.closable, .miniaturizable])
        let owner = try sidebarOwner()
        let sidebar = owner.sidebar
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = runtime.background
        window.contentViewController = sidebar
        session.frame = sidebar.content.bounds
        session.autoresizingMask = [.width, .height]
        sidebar.content.addSubview(session)
        sidebar.focusTerminal = { [weak self] in self?.session.focusActive() }
        let toolbar = NSToolbar(identifier: "FloatingSidebar")
        toolbar.delegate = sidebar
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 900, height: 560))
        sidebar.tabs.theme = (runtime.background, window.appearance)
        window.display()
        let root = try XCTUnwrap(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        sidebar.splitView.setPosition(292, ofDividerAt: 0)
        sidebar.viewDidLayout()
        let row = try XCTUnwrap(self.terminal?.displayedPanes.first)
        let shown = try XCTUnwrap(model.window)
        sidebar.list.show(Snapshot(clock: .init(now: 0, local: 0), client: .init(session: SessionID(number: 0), window: shown, pane: row.pane), serverInstance: ServerInstance("4242/1791000000"),
                                     sessions: [SessionNodes(id: SessionID(number: 0), name: "visual",
                                                             nodes: [.item(fixtureItem(row.pane.number, window: shown.number, "Terminal", shellLifecycle()))])]))
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        let entries = Array(menu.items.prefix(2))
        let targets = entries.map(\.target)
        defer {
            for (item, target) in zip(entries, targets) { item.target = target }
            sidebar.dismissFloating()
            sidebar.tabs.removeFromSuperview()
        }
        for item in entries { item.target = sidebar }
        try await settle()
        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { try XCTUnwrap(window.standardWindowButton($0)) }
        let parents = buttons.map(\.superview)
        let buttonFrames = buttons.map { $0.convert($0.bounds, to: root) }
        let tools = toolbar.items.filter { ["newSession", "toggleSidebar"].contains($0.itemIdentifier.rawValue) }
        let toolViews = try tools.map { try XCTUnwrap($0.view) }
        let toolParents = toolViews.map(\.superview)
        let toolFrames = toolViews.map { $0.convert($0.bounds, to: root) }
        func chrome(_ phase: String) {
            XCTAssertEqual(window.titleVisibility, .hidden)
            for (index, button) in buttons.enumerated() {
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(button.superview === parents[index])
                XCTAssertEqual(button.convert(button.bounds, to: root), buttonFrames[index])
            }
            for (index, item) in tools.enumerated() {
                XCTAssertFalse(item.isHidden)
                XCTAssertFalse(toolViews[index].isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(toolViews[index].superview === toolParents[index])
                XCTAssertEqual(toolViews[index].convert(toolViews[index].bounds, to: root), toolFrames[index])
            }
            print("native chrome \(phase): buttons=\(buttons.map { $0.convert($0.bounds, to: root) }) toolbar=\(toolViews.map { $0.convert($0.bounds, to: root) }) title=\(window.titleVisibility.rawValue)")
        }
        chrome("initial dock")
        XCTAssertEqual(entries.map(\.keyEquivalent), ["S", "s"])
        XCTAssertEqual(entries.map(\.keyEquivalentModifierMask), [[.command, .shift], .command])
        XCTAssertFalse(menu.items.contains { $0.keyEquivalent == "l" && $0.keyEquivalentModifierMask == [.command, .control] })
        func key(_ modifiers: NSEvent.ModifierFlags = .command) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: modifiers.contains(.shift) ? "S" : "s",
                charactersIgnoringModifiers: modifiers.contains(.shift) ? "S" : "s", isARepeat: false, keyCode: 1))
            if let pane = window.firstResponder as? PaneView {
                var input = ghostty_input_key_s()
                input.action = GHOSTTY_ACTION_PRESS
                input.keycode = 1
                input.mods = ghostty_input_mods_e(GHOSTTY_MODS_SUPER.rawValue | (modifiers.contains(.shift) ? GHOSTTY_MODS_SHIFT.rawValue : 0))
                var flags = ghostty_binding_flags_e(0)
                XCTAssertFalse(ghostty_surface_key_is_binding(pane.surface, input, &flags))
            }
            for item in entries { item.target = sidebar }
            let wasFloating = sidebar.isFloating
            XCTAssertTrue(menu.performKeyEquivalent(with: event))
            let immediateContent = sidebar.content.frame, immediateTabs = sidebar.tabs.frame
            root.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
            if !modifiers.contains(.shift), wasFloating || sidebar.isFloating {
                XCTAssertEqual(sidebar.content.frame, immediateContent)
                XCTAssertEqual(sidebar.tabs.frame, immediateTabs)
                var view: NSView? = sidebar.list
                while let current = view {
                    XCTAssertTrue(current.layer?.animationKeys()?.isEmpty ?? true)
                    view = current.superview
                }
            }
        }
        try key()
        XCTAssertTrue(sidebar.list.containsFocus)
        XCTAssertFalse(sidebar.isFloating)
        try key([.command, .shift])
        XCTAssertTrue(sidebar.isCollapsed)
        try key([.command, .shift])
        try await settle()
        XCTAssertFalse(sidebar.isCollapsed)
        chrome("plain undock/dock")
        try key([.command, .shift])
        try await settle()
        let terminal = try XCTUnwrap(terminal)
        let frame = terminal.frame
        let tabFrame = sidebar.tabs.convert(sidebar.tabs.bounds, to: root)
        let grids = terminal.displayedPanes.map { ghostty_surface_size($0.surface) }
        sentSizes.removeAll()
        let list = sidebar.list
        let listParent = try XCTUnwrap(list.superview)
        var native: NSView = listParent
        while !(native is NSGlassEffectView), let parent = native.superview { native = parent }
        XCTAssertTrue(native is NSGlassEffectView)
        let nativeFrame = native.convert(native.bounds, to: root)
        try key()
        XCTAssertTrue(sidebar.isFloating)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertTrue(sidebar.list === list)
        XCTAssertTrue(toolbar.items.first { $0.itemIdentifier.rawValue == "windowTabs" }?.view === sidebar.tabs.superview)
        XCTAssertTrue(sidebar.list.superview === listParent)
        XCTAssertEqual(native.convert(native.bounds, to: root), nativeFrame)
        XCTAssertTrue(sidebar.list.containsFocus)
        XCTAssertEqual(terminal.frame, frame)
        try await wait("floating layout settled") {
            let floating = sidebar.tabs.convert(sidebar.tabs.bounds, to: root)
            return floating.minX > tabFrame.minX && floating.minX >= nativeFrame.maxX && floating.maxX == tabFrame.maxX
        }
        let floatingTabFrame = sidebar.tabs.convert(sidebar.tabs.bounds, to: root)
        XCTAssertGreaterThan(floatingTabFrame.minX, tabFrame.minX)
        XCTAssertGreaterThanOrEqual(floatingTabFrame.minX, nativeFrame.maxX)
        XCTAssertEqual(floatingTabFrame.maxX, tabFrame.maxX)
        XCTAssertEqual(terminal.displayedPanes.map { ghostty_surface_size($0.surface).columns }, grids.map(\.columns))
        XCTAssertEqual(terminal.displayedPanes.map { ghostty_surface_size($0.surface).rows }, grids.map(\.rows))
        await mainQueueFence()
        XCTAssertEqual(sentSizes, [], "a floating sidebar keeps the server's size")
        try key()
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root), tabFrame)
        XCTAssertTrue(window.firstResponder is PaneView)
        try key()
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        try await wait("the release returns focus") { !sidebar.isFloating && self.window.firstResponder is PaneView }
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertTrue(window.firstResponder is PaneView)
        try key()
        XCTAssertTrue(sidebar.isFloating)
        XCTAssertTrue(sidebar.list.containsFocus)
        sentSizes.removeAll()
        try key([.command, .shift])
        try await settle()
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertTrue(sidebar.list.superview === listParent)
        XCTAssertEqual(native.convert(native.bounds, to: root), nativeFrame)
        XCTAssertNotEqual(terminal.frame, frame)
        XCTAssertNotEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root), tabFrame)
        try await wait("one size for the docked sidebar") { self.sentSizes.count == 1 }
        chrome("shortcut float to dock")
        try key([.command, .shift])
        try key()
        let toggleButton = try XCTUnwrap(toolViews.last as? NSButton)
        toggleButton.performClick(nil)
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        try await settle()
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertFalse(sidebar.isCollapsed)
        chrome("toolbar float to dock")
        try key([.command, .shift])
        try await settle()
        try key()
        try await settle()
        XCTAssertEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root), floatingTabFrame)
        XCTAssertEqual(terminal.displayedPanes.map { ghostty_surface_size($0.surface).columns }, grids.map(\.columns))
        XCTAssertEqual(terminal.displayedPanes.map { ghostty_surface_size($0.surface).rows }, grids.map(\.rows))
        XCTAssertEqual(terminal.frame, frame)
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: sidebar.content.convert(NSPoint(x: sidebar.content.bounds.maxX - 30, y: 100), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let hit = try XCTUnwrap(root.hitTest(root.convert(outside.locationInWindow, from: nil)))
        XCTAssertFalse(hit.isDescendant(of: sidebar.list))
        hit.mouseDown(with: outside)
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertTrue(window.firstResponder is PaneView)
        try key()
        sidebar.list.focus()
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        XCTAssertTrue(owner.notices.testTransients.entries.isEmpty, "the connection banner owns the disconnected state")
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        try await wait("Escape dismisses the sidebar") { !sidebar.isFloating }
        XCTAssertTrue(window.firstResponder is PaneView)
        try key()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertTrue(window.firstResponder is PaneView)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try key()
        try await paint()
        try await presented()
        sidebar.list.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        var views = [root]
        while let view = views.popLast() {
            if let glass = view as? NSGlassEffectView, sidebar.list.isDescendant(of: glass) {
                XCTAssertEqual(glass.layer?.cornerRadius, sidebar.list.layer?.cornerRadius, "offscreen glass fill must match its sidebar corner radius")
            }
            views += view.subviews
        }
        CATransaction.flush()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: root, as: .pixels, named: "collapsed-floating", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    func testCaptionDisplayDelay() async throws {
        func fixture(_ caption: String) -> Snapshot {
            sidebarFixture { $0.sessions[0].nodes[0].item.fixtureLifecycle = piLifecycle(.running(.init()), msg: caption); $0.sessions[0].nodes[0].item.pane.mark = .running }
        }
        let initial = fixture("")
        let changed = fixture("Delayed caption")
        let id = try XCTUnwrap(sidebarRows(changed).first { $0.second == .activity("Delayed caption") }?.id)
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        list.layoutSubtreeIfNeeded()
        list.show(initial)
        XCTAssertEqual(list.captionDelay, 0.2)
        let shownAt = ProcessInfo.processInfo.systemUptime
        list.show(changed)
        let index = try XCTUnwrap(list.visualRows.firstIndex { $0.id == id })
        XCTAssertEqual(list.visualRows[index].second, .none)
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 43)
        try await wait("caption deadline") { list.visualRows[index].second == .activity("Delayed caption") }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - shownAt, 0.2)
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 43)
        let hiddenAt = ProcessInfo.processInfo.systemUptime
        list.show(initial)
        XCTAssertEqual(list.visualRows[index].second, .activity("Delayed caption"))
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 43)
        try await wait("caption hide deadline") { list.visualRows[index].second == .none }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - hiddenAt, 0.2)
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 43)
        list.show(changed)
        XCTAssertEqual(list.visualRows[index].second, .none)
        list.show(nil)
        list.show(changed)
        XCTAssertEqual(list.visualRows[index].second, .activity("Delayed caption"), "identical reconnect snapshot must show its caption immediately")
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 43)
        list.show(nil)
        list.show(changed, pin: id)
        list.show(fixture("Reconnected caption"))
        XCTAssertEqual(list.visualRows[index].second, .activity("Reconnected caption"), "drag during reconnect must not seed old captions")
    }

    func testNestedSidebarRowHeightsAndNavigation() throws {
        let live = sidebarFixture { snapshot in
            var sibling = snapshot.sessions[0].nodes[0].item.children[0].item
            sibling.pane.id = PaneID(number: 999); sibling.window = WindowID(number: 999)
            snapshot.sessions[0].nodes[0].item.children.append(.item(sibling))
        }
        let rows = sidebarDividers(sidebarRows(live))
        XCTAssertTrue(rows.contains { $0.indent > 0 && $0.target != nil })
        let invalid = rows.filter { $0.height <= 0 }
        XCTAssertTrue(invalid.isEmpty, "NSTableView requires positive row heights: \(invalid.map(\.id))")
        guard invalid.isEmpty else { return }
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        list.layoutSubtreeIfNeeded()
        list.show(live)
        let table = list.visualTable
        XCTAssertEqual(table.numberOfRows, rows.count)
        for index in rows.indices {
            XCTAssertGreaterThan(list.tableView(table, heightOfRow: index), 0)
            table.scrollRowToVisible(index)
        }
        let nested = try XCTUnwrap(rows.lastIndex { $0.indent > 0 && $0.target != nil })
        let target = try XCTUnwrap(rows[nested].target)
        var changed = live
        changed.client = target
        list.show(changed)
        XCTAssertEqual(table.selectedRow, nested)
        let origin = list.visualScroll.contentView.bounds.origin
        list.show(changed)
        XCTAssertEqual(table.selectedRow, nested)
        XCTAssertEqual(list.visualScroll.contentView.bounds.origin, origin)
        let previous = try XCTUnwrap(rows[..<nested].lastIndex { $0.target != nil })
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f700}", charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126))
        table.keyDown(with: up)
        XCTAssertEqual(table.selectedRow, previous)
        let divider = try XCTUnwrap(rows.firstIndex { $0.kind == .divider })
        let after = try XCTUnwrap(rows.indices.dropFirst(divider + 1).first { rows[$0].target != nil })
        let before = try XCTUnwrap(rows[..<divider].lastIndex { $0.target != nil })
        list.select(try XCTUnwrap(rows[after].target))
        table.keyDown(with: up)
        XCTAssertEqual(table.selectedRow, before, "navigation skips the divider")
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testProgramRecords() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 680),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.colorSpace = .displayP3
        let list = SidebarView()
        window.contentView = list
        let fixture = sidebarFixture { snapshot in
            snapshot.sessions[0].nodes.insert(.item(fixtureItem(2000, "Claude Code", agentLifecycle(.running(.init())), records: [
                .working(.init(app: "claude-code", id: "")),
                .working(.init(id: "agent-c", title: "Review accessibility")),
                .blocked(.init(id: "agent-a/permission", kind: .permission, msg: "May I run the integration tests?", title: "Approve test command")),
                .working(.init(id: "agent-b", title: "Check toolbar geometry")),
                .working(.init(id: "agent-a", msg: "Comparing native row measurements", title: "Investigate sidebar layout")),
            ], serial: 7, mark: .running)), at: 0)
            snapshot.client = .init(session: SessionID(number: 0), window: WindowID(number: 2000), pane: PaneID(number: 2000))
        }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            list.show(fixture)
            sidebarSnapshot(list, dark ? "claude-dark" : "claude-light")
        }
        let programs = list.visualRows.indices.filter { if case .program = list.visualRows[$0].id { true } else { false } }
        XCTAssertEqual(programs.count, 4)
        var requests: [Navigation] = []
        list.navigate = { navigation, _ in requests.append(navigation) }
        for index in programs {
            XCTAssertFalse(list.tableView(list.visualTable, shouldSelectRow: index))
            list.visualJump(list.visualRows[index])
            let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCell)
            XCTAssertEqual(cell.accessibilityRole(), .staticText)
            XCTAssertTrue(cell.accessibilityLabel()?.contains(list.visualRows[index].indicatorDescription) == true)
            XCTAssertTrue(cell.addWindow.isHidden)
        }
        XCTAssertTrue(requests.isEmpty)
        list.focus()
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
        list.visualTable.keyDown(with: down)
        XCTAssertEqual(list.visualRows[list.visualTable.selectedRow].target?.pane, PaneID(number: 0))
    }

    func testSidebarCards() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 680),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.colorSpace = .displayP3
        let list = SidebarView()
        list.captionDelay = 0
        window.contentView = list
        let live = sidebarFixture()
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            list.show(live)
            sidebarSnapshot(list, dark ? "live-dark" : "live-light")
        }
        let nested = sidebarFixture { snapshot in
            snapshot.client = .init(session: SessionID(number: 0), window: WindowID(number: 458), pane: PaneID(number: 502))
            snapshot.sessions[0].nodes[0].item.fixtureLifecycle = piLifecycle(.idle(.init(outcome: KoSchema.Outcome(result: .success, serial: 1))))
            snapshot.sessions[0].nodes[0].item.pane.mark = .done
            snapshot.sessions[0].nodes[0].item.children[0].item.fixtureLifecycle = .ended(.exited(.init(code: 0)))
            snapshot.sessions[0].nodes[1].group.children[0].fixtureLifecycle = piLifecycle(.waiting(.init()),
                                                                                  msg: "Rebuilding the sidebar cards and testing nested window corners")
            snapshot.sessions[0].nodes[1].group.children[0].pane.mark = .waiting
            snapshot.sessions[0].nodes[1].group.children[0].children[0].item.fixtureLifecycle = piLifecycle(.idle(.init(outcome: KoSchema.Outcome(result: .failure, serial: 1))))
            snapshot.sessions[0].nodes[1].group.children[0].children[0].item.pane.mark = .failed
            snapshot.sessions[0].nodes[1].group.children[1].fixtureLifecycle = shellLifecycle(shellExit(0, command: "make -C ../kido-app/app demo"))
            snapshot.sessions[0].nodes[1].group.children[1].pane.mark = .done
        }
        list.show(nested)
        sidebarSnapshot(list, "active-parent-dark")
        window.appearance = NSAppearance(named: .aqua)
        sidebarSnapshot(list, "active-parent-light")
        window.setContentSize(NSSize(width: 236, height: 680))
        sidebarSnapshot(list, "narrow-light")
        window.setContentSize(NSSize(width: 292, height: 680))
        list.show(sidebarFixture { $0.client = .init(session: SessionID(number: 0), window: WindowID(number: 786), pane: PaneID(number: 892)) })
        sidebarSnapshot(list, "child-active-light")
        let subtree = sidebarFixture { snapshot in
            let zsh = fixtureNode(1991, "zsh", shellLifecycle(shellExit(0)), mark: .done)
            let notes = fixtureNode(1990, "review-notes", piLifecycle(.running(.init()), msg: "Checking nested activity"),
                                    mark: .running, children: [zsh])
            var child = snapshot.sessions[0].nodes[1].group.children[0].children[0].item
            child.children = [notes]
            snapshot.sessions[0].nodes[1].group.children[0].children[0] = .item(child)
            snapshot.client = .init(session: SessionID(number: 0), window: child.window, pane: child.id)
        }
        list.show(subtree)
        sidebarSnapshot(list, "focused-child-subtree-light")
        window.appearance = NSAppearance(named: .darkAqua)
        sidebarSnapshot(list, "focused-child-subtree-dark")
        window.appearance = NSAppearance(named: .aqua)
        let grouped = sidebarFixture { snapshot in
            let first = snapshot.sessions[0].nodes[0].item
            var second = snapshot.sessions[0].nodes[1].group.children[0], third = first
            second.window = first.window
            second.fixtureLifecycle = piLifecycle(msg: "Grouped pane activity")
            third.pane.id = PaneID(number: 999); third.children = []; third.pane.label = "terminal"; third.fixtureLifecycle = shellLifecycle()
            snapshot.sessions[0].nodes = [.window(.init(id: first.window, children: [first, second, third]))]
            snapshot.client = .init(session: SessionID(number: 0), window: first.window, pane: first.id)
        }
        list.show(grouped)
        list.focus()
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        list.visualTable.keyDown(with: down)
        list.visualTable.keyDown(with: down)
        sidebarSnapshot(list, "three-pane-keyboard-light")
        let header = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        header.addWindow.mouseEntered(with: hover)
        sidebarSnapshot(list, "plus-hover-light")
        header.addWindow.mouseExited(with: hover)
    }

    func testHeaderCreatesWindowInItsSession() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"zsh","tree":\#(koPane())}]},{"name":"other","windows":[{"name":"a","tree":\#(koPane())},{"name":"b","tree":\#(koPane())}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path
        defer { owner.close() }
        owner.start()
        let list = owner.sidebar.list, other = SessionID(number: 2)
        try await wait("other session header") { list.visualRows.contains { $0.id == .header(other) } }
        let index = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .header(other) })
        let header = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCell)
        XCTAssertEqual(header.addWindow.accessibilityLabel(), "New window in other")
        header.addWindow.performClick(nil)
        try await wait("the heading's session has the new window") {
            owner.testModel?.layout.layout.sessions.map(\.windows.count) == [1, 3]
        }
        XCTAssertEqual(owner.navigation.session, other, "the new window is selected")
    }

    func testPaletteCreatesNamedSessionInAnchorDirectory() async throws {
        let working = directory.appendingPathComponent("active pane directory")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let resolved = try XCTUnwrap(realpath(working.path, nil))
        defer { free(resolved) }
        let cwd = String(cString: resolved)
        _ = try await KoServer.launch(dir: directory.path)
        let place = try String(decoding: JSONSerialization.data(withJSONObject: cwd, options: .fragmentsAllowed), as: UTF8.self)
        try await koPut(directory.path, #"[{"name":"original","windows":[{"name":"w","tree":{"pane":{"new":{"cwd":\#(place),"command":{"type":"argv","argv":["/bin/cat"]}}}}}]}]"#)
        try loadRuntime()
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        let previous = NSApp.mainMenu
        let other = try XCTUnwrap(app.open(.local, start: false))
        defer { app.closePalette(); owner.close(); other.close(); NSApp.mainMenu = previous }
        owner.testServerDir = directory.path
        other.testServerDir = directory.path
        owner.start(); other.start()
        try await wait("both owners ready") {
            owner.currentSession?.name == "original" && owner.testClient != nil
                && other.currentSession?.name == "original" && other.testClient != nil
        }
        NSApp.mainMenu = app.mainMenu()
        XCTAssertEqual(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.first?.title, "New Session")
        app.togglePalette()
        let panel = try XCTUnwrap(app.palettePanel)
        let palette = panel.palette
        func enter() throws {
            let entry = try XCTUnwrap(palette.shown.first { $0.entry.title == "New Session…" }?.entry)
            palette.chooseEntry(entry)
            XCTAssertEqual(palette.mode, .sessionName(owner, try XCTUnwrap(owner.snapshot).serverInstance, .create))
        }
        func submit(_ name: String) {
            palette.field.stringValue = name
            palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            _ = palette.control(palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }
        try enter()
        submit("")
        XCTAssertEqual(palette.error, "Enter a session name.")
        submit("original")
        XCTAssertEqual(palette.error, "A session named “original” already exists.")
        _ = palette.control(palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(palette.mode, .root)
        try enter()
        let before = try XCTUnwrap(owner.snapshot)
        owner.testReceive(sidebarFixture { $0.serverInstance = ServerInstance("77777/1") })
        submit("stale-create")
        XCTAssertEqual(palette.error, "That window is gone")
        owner.testReceive(before)
        XCTAssertEqual(owner.testModel?.panes.first?.cwd, cwd)
        submit("created here")
        try await wait("created session selected in opening owner") { app.palettePanel == nil && owner.currentSession?.name == "created here" }
        let created = try XCTUnwrap(owner.currentSession)
        let window = try XCTUnwrap(owner.testModel?.layout.layout.session(created.id)?.windows.first)
        try await wait("the new pane's directory") { owner.testModel?.panes.first { $0.id == window.focus }?.cwd == cwd }
        XCTAssertEqual(owner.navigation.session, created.id)
        XCTAssertEqual(other.currentSession?.name, "original")
    }

    func testPaletteJumpToAPaneHiddenByZoomShowsAndFocusesIt() async throws {
        let first = PaneID(number: 1), second = PaneID(number: 2)
        let upper = koPane("printf '\\033]2;cat\\007\\033[2J\\033[HPALETTE UPPER\\r\\n'; exec /bin/cat")
        let lower = koPane("printf '\\033]2;cat\\007\\033[2J\\033[HPALETTE LOWER\\r\\n'; exec /bin/cat")
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"cat","tree":{"split":"v","children":[\#(upper),\#(lower)]}}]}]"#)
        try await koUntil(directory.path, "/panes/pane_2/screen", contains: "PALETTE LOWER")
        try loadRuntime()
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        defer { app.closePalette(); owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("the owner shows the window") { owner.testClient != nil && owner.testSession?.windows.isEmpty == false }
        let client = try XCTUnwrap(owner.testClient)
        _ = try await Task.detached { try client.edit(.zoom(KoSchema.EditZoom(pane: PaneID(number: 1), window: WindowID(number: 1)))) }.value
        func shown() -> [PaneID] {
            owner.testSession?.windows.values.first { !$0.isHidden }?.displayedPanes.filter { !$0.isHidden }.map(\.pane) ?? []
        }
        let rows = { sidebarRows(owner.snapshot).filter { $0.topLevel != nil } }
        try await wait("the zoomed pane alone is shown") {
            shown() == [first] && rows().contains { $0.target?.pane == second }
        }
        app.togglePalette()
        let panel = try XCTUnwrap(app.palettePanel)
        let palette = panel.palette
        let field = try XCTUnwrap(panel.firstResponder as? NSTextView)
        let index = try XCTUnwrap(rows().firstIndex { $0.target?.pane == second })
        XCTAssertEqual(palette.shown.prefix(rows().count).map(\.entry.title), rows().map(\.title))
        for _ in 0..<index { field.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertNil(app.palettePanel)
        try await wait("both panes shown, the chosen one focused") {
            Set(shown()) == [first, second] && (owner.window.firstResponder as? PaneView)?.pane == second
        }
        try await wait("the jump unzooms the window and selects the chosen pane") {
            owner.testModel.map(\.layout.layout.windows)?.first?.zoom == nil && owner.testModel?.selection.pane == PaneID(number: 2)
        }
        owner.window.setFrame(NSRect(origin: owner.window.frame.origin, size: NSSize(width: 1100, height: 740)), display: false)
        let windowView = try XCTUnwrap(owner.testSession?.windows.values.first { !$0.isHidden })
        let root = try XCTUnwrap(owner.window.contentView?.superview)
        func layoutWindow() {
            owner.sidebar.view.needsLayout = true
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
            owner.sidebar.viewDidLayout()
        }
        layoutWindow()
        try await wait("resized two-pane window and sidebar selection are ready") {
            windowView.visualGeometryReady && windowView.displayedPanes.allSatisfy(\.visualReady)
                && rows().contains { $0.focused && $0.target?.pane == second }
        }
        _ = try await Task.detached { try client.edit(.equalize(KoSchema.EditEqualize(pane: PaneID(number: 1)))) }.value
        func leafRows() -> [Int] {
            guard case .split(let split)? = owner.testModel.map(\.layout.layout.windows)?.first?.tree else { return [] }
            return split.children.map { if case .leaf(let leaf) = $0 { leaf.rows } else { 0 } }
        }
        try await wait("even rows") { let rows = leafRows(); return rows.count == 2 && abs(rows[0] - rows[1]) <= 1 }
        try await wait("both even panes have their rendered rows") {
            windowView.visualGeometryReady && zip(windowView.displayedPanes.sorted { $0.pane.number < $1.pane.number }, leafRows()).allSatisfy {
                $0.visualReady && Int(ghostty_surface_size($0.surface).rows) == $1
            }
        }
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        NSApp.mainMenu = app.mainMenu()
        app.togglePalette()
        let rootPanel = try XCTUnwrap(app.palettePanel)
        owner.window.makeFirstResponder(owner.window)
        layoutWindow()
        rootPanel.palette.layoutSubtreeIfNeeded()
        try await wait("complete native pane layout and matching surface sizes") {
            windowView.visualGeometryReady && windowView.displayedPanes.allSatisfy { pane in
                pane.visualReady && pane.visualInstalledPixels == CGSize(width: pane.frame.width * 2, height: pane.frame.height * 2)
            }
        }
        for pane in windowView.displayedPanes {
            let presented = expectation(description: "palette background pane frame")
            pane.visualFrame { result in
                XCTAssertEqual(result, GHOSTTY_RENDER_PRESENTATION_PRESENTED)
                presented.fulfill()
            }
            await fulfillment(of: [presented], timeout: 10)
            var text = ghostty_text_s()
            let selection = ghostty_selection_s(top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0), bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
            XCTAssertTrue(ghostty_surface_read_text(pane.surface, selection, &text))
            let bytes = try XCTUnwrap(text.text)
            defer { ghostty_surface_free_text(pane.surface, &text) }
            XCTAssertEqual(String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), pane.pane == first ? "PALETTE UPPER" : "PALETTE LOWER")
        }
        for pane in windowView.displayedPanes {
            XCTAssertEqual(pane.visualInstalledPixels, CGSize(width: pane.frame.width * 2, height: pane.frame.height * 2), pane.resizeDebug)
            print("palette capture", pane.pane, pane.resizeDebug)
        }
        for view in root.subviews { print("palette capture view", type(of: view), view.frame) }
        let scene = NSView(frame: root.bounds)
        for (source, frame) in [(root, root.bounds), (rootPanel.palette, root.convert(owner.window.convertFromScreen(rootPanel.frame), from: nil))] {
            let bitmap = try XCTUnwrap(source.bitmapImageRepForCachingDisplay(in: source.bounds))
            source.cacheDisplay(in: source.bounds, to: bitmap)
            let rendered = NSImage(size: source.bounds.size)
            rendered.addRepresentation(bitmap)
            let imageView = NSImageView(frame: frame)
            imageView.image = rendered
            imageView.imageScaling = .scaleAxesIndependently
            scene.addSubview(imageView)
        }
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        let snapshots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__/PaletteTests").path
        if let failure = verifySnapshot(of: scene, as: .pixels, named: "light-window-root", record: record, snapshotDirectory: snapshots, testName: "palette"),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    func testSidebarHeadersKeysAndAccessibility() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        let fixture = sidebarFixture()
        list.show(fixture)
        list.focus()
        list.layoutSubtreeIfNeeded()
        let header = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        XCTAssertEqual(list.visualTable.focusRingType, .none)
        XCTAssertEqual(list.visualTable.selectionHighlightStyle, .none)
        XCTAssertTrue((list.visualTable as? Table)?.keyboardSelection == true)
        XCTAssertEqual(header.accessibilityRole(), .staticText)
        XCTAssertNil(header.accessibilityValue())
        XCTAssertFalse(header.accessibilityPerformPress())
        XCTAssertFalse(header.addWindow.isHidden)
        XCTAssertEqual(header.addWindow.accessibilityLabel(), "New window in " + fixture.sessions[0].name)
        var created: [SessionID] = []
        list.newWindow = { created.append($0) }
        header.addWindow.invoke()
        XCTAssertEqual(created, [fixture.sessions[0].id])
        func key(_ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            list.visualTable.keyDown(with: event)
        }
        let rows = list.visualRows
        let selected = list.visualTable.selectedRow
        try key(123)
        try key(124)
        XCTAssertEqual(list.visualRows, rows)
        XCTAssertEqual(list.visualTable.selectedRow, selected)
        for row in list.visualRows where row.target != nil {
            let cell = SidebarCell(SidebarFonts())
            cell.configure(row, now: 0)
            XCTAssertNil(cell.toolTip)
            XCTAssertNil(cell.addWindow.toolTip)
            XCTAssertTrue(cell.accessibilityLabel()?.contains(row.indicatorDescription) == true)
            XCTAssertEqual(cell.focusRingType, .none)
            XCTAssertEqual(cell.addWindow.focusRingType, .none)
            XCTAssertEqual((cell.addWindow.cell as? NSButtonCell)?.highlightsBy, [])
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testNavigationFeedFirst() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let owner = try sidebarOwner()
        let list = owner.sidebar.list
        window.contentView = list
        let initial = sidebarFixture()
        let destination = sidebarFixture { $0.client = .init(session: SessionID(number: 0), window: WindowID(number: 458), pane: PaneID(number: 502)) }
        list.show(initial)
        list.layoutSubtreeIfNeeded()
        let selectedBeforeNil = list.visualTable.selectedRow
        let originBeforeNil = list.visualScroll.contentView.bounds.origin
        owner.perform(.switchWindow(next: true))
        XCTAssertEqual(list.visualTable.selectedRow, selectedBeforeNil)
        XCTAssertEqual(list.visualScroll.contentView.bounds.origin, originBeforeNil)
        list.show(destination)
        let selected = list.visualTable.selectedRow
        XCTAssertGreaterThanOrEqual(selected, 0, "feed-first completion must select the destination")
        if selected >= 0 {
            XCTAssertEqual(list.visualRows[selected].target, destination.client)
            XCTAssertTrue(list.visualTable.visibleRect.intersects(list.visualTable.rect(ofRow: selected)), "destination must be visible")
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testSidebarNavigationAndAnchoring() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        let owner = try sidebarOwner()
        let list = owner.sidebar.list
        list.frame = NSRect(x: 0, y: 0, width: 292, height: 260)
        window.contentView = list
        let fixture = sidebarFixture { $0.repeatSession(Array(0..<20)) }
        list.show(fixture)
        list.layoutSubtreeIfNeeded()
        let anchorIndex = 12
        let anchorID = list.visualRows[anchorIndex].id
        list.visualScroll.contentView.scroll(to: NSPoint(x: 0, y: list.visualTable.rect(ofRow: anchorIndex).minY + 7.25))
        let before = list.visualScroll.contentView.bounds.minY - list.visualTable.rect(ofRow: anchorIndex).minY
        let stable = sidebarFixture { $0.repeatSession([99] + Array(0..<20)) }
        list.show(stable)
        list.layoutSubtreeIfNeeded()
        let newIndex = try XCTUnwrap(list.visualRows.firstIndex { $0.id == anchorID })
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(newIndex, anchorIndex)
        XCTAssertEqual(list.visualScroll.contentView.bounds.minY - list.visualTable.rect(ofRow: newIndex).minY, before, accuracy: 1)
        list.show(fixture)
        XCTAssertTrue(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) })
        let navigated = sidebarFixture { $0.client = .init(session: SessionID(number: 0), window: WindowID(number: 458), pane: PaneID(number: 502)) }
        list.show(navigated)
        XCTAssertEqual(list.visualRows[list.visualTable.selectedRow].target?.window, navigated.client.window)
        XCTAssertTrue(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) })
        let row = try XCTUnwrap(list.visualRows.first { $0.target != nil })
        var left = 0
        list.leave = { left += 1 }
        list.focus()
        list.visualJump(row)
        XCTAssertEqual(left, 0, "a jump that the server did not take keeps the sidebar")
        XCTAssertTrue(owner.notices.testTransients.entries.isEmpty)
        XCTAssertTrue(list.containsFocus)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        list.visualTable.keyDown(with: event)
        XCTAssertNotEqual(list.visualTable.selectedRow, -1)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        list.visualTable.keyDown(with: escape)
        XCTAssertEqual(left, 1, "Escape leaves the sidebar without a server")
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }
}
