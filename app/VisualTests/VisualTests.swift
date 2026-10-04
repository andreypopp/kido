import AppKit
import GhosttyKit
import SnapshotTesting
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class VisualTests: XCTestCase {
    private let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private var tmux = ""
    private var socket = ""
    private var directory: URL!
    private var window: NSWindow!
    private static var processRuntime: GhosttyRuntime?
    private var runtime: GhosttyRuntime!
    private var session: SessionView!
    private var connection: Connection!
    private var model = SessionModel()
    private var tabSnapshot: Snapshot?

    private func updateTabs(_ status: Feed.Status? = nil, query: String = "") {
        if case .running(let snapshot) = status, query.isEmpty, snapshot.filter.isEmpty { tabSnapshot = snapshot }
        (window.contentViewController as? Sidebar)?.tabs.entries = model.navigation(tabSnapshot).tabs
    }

    override func setUp() async throws {
        directory = URL(fileURLWithPath: "/tmp/kido-visual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socket = directory.appendingPathComponent("socket").path
        tmux = try XCTUnwrap(ProcessInfo.processInfo.environment["KIDO_VISUAL_TMUX"])
        PaneView.renderOffscreen = true
    }

    override func tearDown() async throws {
        if connection != nil { connection.gridFailed() }
        window?.contentView = nil
        window?.close()
        connection = nil
        session = nil
        runtime?.onConfigChange = {}
        runtime?.onColorSchemeChange = {}
        runtime = nil
        if FileManager.default.fileExists(atPath: socket) { _ = try? await command(["kill-session", "-t", "visual"]) }
        PaneView.renderOffscreen = false
        NSApp.appearance = nil
    }

    @discardableResult private func command(_ args: [String]) async throws -> String {
        let (status, out, err) = try await Child.run(tmux, ["-S", socket] + args)
        XCTAssertEqual(status, 0, "\(args): \(err)")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wait(_ description: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let done = expectation(description: description)
        let deadline = Date().addingTimeInterval(20)
        @MainActor func poll() {
            if predicate() { done.fulfill() }
            else if Date() >= deadline { XCTFail("Timed out: \(description)"); done.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() } }
        }
        poll()
        await fulfillment(of: [done], timeout: 21)
    }

    private var terminal: WindowView? { session?.windows.values.first { !$0.isHidden } }

    private func start(height: CGFloat = 560, dark: Bool = false, history: Int = 1000) async throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        if Self.processRuntime == nil {
            let config = directory.appendingPathComponent("ghostty.conf")
            let themes = app.appendingPathComponent("Resources/themes").path
            let theme = "light:\(themes)/kido-light,dark:\(themes)/kido-dark"
            try "theme = \(theme)\nfont-family = Menlo\nfont-size = 13\n".write(to: config, atomically: true, encoding: .utf8)
            Self.processRuntime = try XCTUnwrap(GhosttyRuntime(configFile: config.path))
        }
        runtime = try XCTUnwrap(Self.processRuntime)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: height),
                          styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        session = SessionView(runtime: runtime)
        session.frame = NSRect(x: 0, y: 0, width: 700, height: height)
        window.contentView = session
        let tmuxConfig = directory.appendingPathComponent("tmux.conf")
        try "set -g history-limit \(history)\n".write(to: tmuxConfig, atomically: true, encoding: .utf8)
        _ = try await command(["-f", tmuxConfig.path, "new-session", "-d", "-s", "visual", "-x", "80", "-y", "30", "exec /bin/cat"])
        connection = try Connection(server: Server(tmux: tmux, socket: socket, build: nil), view: session,
                                    onChange: { [weak self] model in
                                        self?.session.show(model.window)
                                        self?.model = model
                                        self?.updateTabs()
                                    },
                                    onDiagnostic: { XCTFail($0) }, onClose: { _ in })
        try await wait("initial layout") { self.terminal?.panes.isEmpty == false }
        try await settle()
        if dark {
            let changed = expectation(description: "appearance config changed")
            runtime.onConfigChange = { [weak self] in self?.session.updateBackground(); changed.fulfill() }
            runtime.onColorSchemeChange = { [weak self] in self?.session.updateColorScheme() }
            window.appearance = NSAppearance(named: .darkAqua)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await fulfillment(of: [changed], timeout: 20)
            try await settle()
        }
    }

    private func settle() async throws {
        try await wait("authoritative restore and presented frame") {
            guard let terminal = self.terminal else { return false }
            return terminal.visualGeometryReady && !terminal.panes.isEmpty && terminal.panes.filter { !$0.isHidden }.allSatisfy(\.visualReady)
        }
    }

    private func paint(lines: Int? = nil, alternate: Bool = false) async throws {
        for pane in try XCTUnwrap(terminal).panes.filter({ !$0.isHidden }) {
            let grid = ghostty_surface_size(pane.surface)
            let count = lines ?? Int(grid.rows)
            var text = alternate ? "\u{1b}[?1049h" : ""
            text += "\u{1b}[2J\u{1b}[H"
            for i in 0..<count {
                let color = i == count - 1 ? 32 : i == 0 ? 31 : [34, 35, 36, 33][i % 4]
                text += "\u{1b}[\(color)m" + String(repeating: "█", count: Int(grid.columns)) + "\u{1b}[0m"
                if i != count - 1 { text += "\r\n" }
            }
            let fixture = directory.appendingPathComponent("pane-\(pane.pane.number).txt")
            try text.write(to: fixture, atomically: true, encoding: .utf8)
            let done = directory.appendingPathComponent("done-\(UUID().uuidString)")
            _ = try await command(["respawn-pane", "-k", "-t", pane.pane.description, "/bin/cat '" + fixture.path + "'; /usr/bin/touch '" + done.path + "'; exec /bin/sleep 600"])
            try await wait("fixture cat completed") { FileManager.default.fileExists(atPath: done.path) }
        }
        for pane in try XCTUnwrap(terminal).panes.filter({ !$0.isHidden }) {
            let restored = expectation(description: "tmux capture replayed")
            pane.markContentDirty()
            connection.sync(pane.pane) { restored.fulfill() }
            await fulfillment(of: [restored], timeout: 20)
        }
        try await settle()
    }

    private func snapshot(_ name: String, pill: Bool = false, testName: String = #function) async throws {
        try await settle()
        let terminal = try XCTUnwrap(terminal)
        XCTAssertEqual(terminal.panes.contains { $0.visualPill }, pill)
        for pane in terminal.panes.filter({ !$0.isHidden }) {
            let frame = expectation(description: "Ghostty presented \(pane.pane)")
            pane.visualFrame { success in XCTAssertTrue(success); frame.fulfill() }
            await fulfillment(of: [frame], timeout: 10)
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertFalse(NSApp.isActive)
        CATransaction.flush()
        terminal.panes.forEach { $0.scroller.isHidden = true }
        CATransaction.flush()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        for failure in [
            verifySnapshot(of: terminal, as: .image, named: name, record: record, testName: testName),
            verifySnapshot(of: terminal.visualLayout, as: .lines, named: name, record: record, testName: testName),
        ].compactMap({ $0 }) {
            if !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        }
    }

    func testWindowTabs() async throws {
        try await start()
        let sidebar = Sidebar()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = runtime.background
        window.contentViewController = sidebar
        session.frame = sidebar.content.bounds
        session.autoresizingMask = [.width, .height]
        sidebar.content.addSubview(session)
        let toolbar = NSToolbar(identifier: "WindowTabs")
        toolbar.delegate = sidebar
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 900, height: 560))
        let root = try XCTUnwrap(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        sidebar.splitView.setPosition(236, ofDividerAt: 0)
        sidebar.tabs.select = { [weak self] step in
            guard let self, let command = model.navigation(tabSnapshot).model.select(step) else { return }
            connection.send([command])
        }
        _ = try await command(["rename-window", "-t", "visual:0", "Shell"])
        let middle = try await command(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "visual", "-n", "Editor", "exec /bin/cat"])
        let last = try await command(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "visual", "-n", "Logs", "exec /bin/cat"])
        let child = try await command(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "visual", "-n", "Child run", "exec /bin/cat"])
        let secondPane = try await command(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", middle, "exec /bin/cat"])
        _ = try await command(["select-pane", "-t", secondPane])
        try await wait("four tmux windows") { self.model.windows.count == 4 }
        let listing = try await command(["list-panes", "-s", "-t", "visual", "-F", "#{window_id} #{pane_id}"])
        let panes = listing.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        let shell = try XCTUnwrap(panes.first { $0[0] != middle && $0[0] != last && $0[0] != child })
        let childPane = try XCTUnwrap(panes.first { $0[0] == child })[1]
        func fixture(_ status: String = "waiting", filtered: Bool = false) throws -> Snapshot {
            func item(_ pane: [String], children: [[String: Any]] = [], status: String = "idle") -> [String: Any] {
                ["kind": pane[0] == child ? "run" : "shell", "id": pane[1], "pane": pane[1], "window": pane[0],
                 "title": [["text": "Pane", "role": "plain"]], "tail": [], "indicator": ["kind": status],
                 "attention": false, "children": children]
            }
            let nodes: [[String: Any]] = [item(shell),
                ["kind": "window", "id": middle, "window": middle, "name": "Editor",
                 "children": panes.filter { $0[0] == middle }.enumerated().map { i, pane in
                     item(pane, children: i == 0 ? [item([child, childPane], status: status)] : [])
                 }], item(try XCTUnwrap(panes.first { $0[0] == last }))]
            let object: [String: Any] = ["v": 2, "client": ["session": "$0", "window": child, "pane": childPane],
                "filter": filtered ? "hidden" : "", "sessions": [["id": "$0", "name": "visual", "current": true,
                    "nodes": filtered ? [nodes[1]] : nodes]]]
            return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        updateTabs(.running(try fixture()), query: "")
        XCTAssertEqual(sidebar.tabs.entries.map(\.name), ["Shell", "Editor", "Logs"])
        XCTAssertEqual(sidebar.tabs.entries.map(\.status), [.quiet, .attention, .quiet])
        sidebar.list.filter = { query in self.updateTabs(.running(try! fixture(filtered: true)), query: query) }
        sidebar.list.visualSearch.stringValue = "hidden"
        XCTAssertTrue(sidebar.list.visualSearch.sendAction(try XCTUnwrap(sidebar.list.visualSearch.action), to: sidebar.list.visualSearch.target))
        XCTAssertEqual(sidebar.tabs.entries.map(\.name), ["Shell", "Editor", "Logs"])
        sidebar.list.visualSearch.stringValue = ""
        updateTabs(.running(try fixture("failed")), query: "")
        XCTAssertEqual(sidebar.tabs.entries[1].status, .error)
        updateTabs(.running(try fixture()), query: "")
        connection.send([Command("select-window", "-t", child)])
        try await wait("descendant active") { self.model.window?.description == child }
        XCTAssertEqual(sidebar.tabs.entries.first { $0.active }?.id.description, middle)
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        let point = sidebar.tabs.convert(NSPoint(x: 240, y: 22), to: nil)
        XCTAssertTrue(root.hitTest(root.convert(point, from: nil)) === sidebar.tabs)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        sidebar.tabs.mouseDown(with: event)
        try await wait("middle tab selected") { self.model.window?.description == middle }
        let current = try await command(["display-message", "-p", "-t", "visual", "#{window_id}"])
        XCTAssertEqual(current, middle)
        let restoredPane = try await command(["display-message", "-p", "-t", middle, "#{pane_id}"])
        XCTAssertEqual(restoredPane, secondPane)
        connection.send([Command("select-window", "-t", shell[0])])
        try await wait("first window selected") { self.model.window?.description == shell[0] }
        let menus = SessionMenus()
        menus.send = { [weak self] in self?.connection.send($0) }
        menus.update(model.navigation(tabSnapshot).model)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        XCTAssertTrue(menus.window.performKeyEquivalent(with: key))
        try await wait("Cmd-2 selects second tab") { self.model.window?.description == middle }
        XCTAssertEqual(model.navigation(tabSnapshot).model.select(.number(2)), Command("switch-client", "-t", "$0:\(middle)"))
        XCTAssertEqual(session.windows.first { !$0.value.isHidden }?.key.description, middle)
        let area = sidebar.content.convert(sidebar.content.bounds, to: root)
        XCTAssertEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root).maxY, area.maxY)
        XCTAssertTrue(sidebar.tabs.superview === sidebar.splitView)
        XCTAssertEqual(sidebar.tabs.frame.height, 44)
        let empty = root.hitTest(NSPoint(x: area.maxX - 4, y: area.maxY - 22))
        XCTAssertFalse(empty === sidebar.tabs)
        XCTAssertTrue(empty?.mouseDownCanMoveWindow == true)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: sidebar.tabs, as: .image, named: "middle", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        sidebar.isCollapsed = true
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        XCTAssertGreaterThanOrEqual(sidebar.tabs.frame.minX, 116)
        if let failure = verifySnapshot(of: sidebar.tabs, as: .image, named: "collapsed", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        _ = try await command(["kill-window", "-t", child])
        _ = try await command(["rename-window", "-t", middle, "Renamed"])
        try await wait("renamed tab") { self.model.windows.map(\.name) == ["Shell", "Renamed", "Logs"] }
        _ = try await command(["swap-window", "-d", "-s", middle, "-t", last])
        try await wait("reordered tabs") { self.model.windows.map(\.name) == ["Shell", "Logs", "Renamed"] }
        _ = try await command(["kill-window", "-t", last])
        try await wait("closed tab") { self.model.windows.map(\.name) == ["Shell", "Renamed"] }
        _ = try await command(["new-session", "-d", "-s", "other", "-n", "Other session", "exec /bin/cat"])
        let pendingSelection = try XCTUnwrap(model.navigation(tabSnapshot).model.select(.number(2)))
        connection.visualCommands.removeAll()
        let selected = expectation(description: "pending selection completed")
        connection.send([Command("switch-client", "-t", "other"), pendingSelection]) { replies in
            XCTAssertNotNil(replies)
            selected.fulfill()
        }
        await fulfillment(of: [selected], timeout: 20)
        let selectedSession = try await command(["list-clients", "-F", "#{session_id}:#{window_id}"])
        XCTAssertEqual(selectedSession, "$0:\(middle)")
        try await wait("pending selection returns to its own session") { self.model.session == SessionID(number: 0) && self.model.window?.description == middle }
        XCTAssertEqual(connection.visualCommands.filter { $0.line.hasPrefix("switch-client") }.count, 2)
        connection.send([Command("switch-client", "-t", "other")])
        try await wait("current session tabs only") { self.model.windows.map(\.name) == ["Other session"] }
        connection.send([Command("switch-client", "-t", "visual")])
        try await wait("session switched back") { self.model.windows.map(\.name) == ["Shell", "Renamed"] }
        _ = try await command(["kill-session", "-t", "other"])
        sidebar.tabs.removeFromSuperview()
    }

    func testFloatingSidebar() async throws {
        try await start()
        window.styleMask.insert([.closable, .miniaturizable])
        let sidebar = Sidebar()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = runtime.background
        window.contentViewController = sidebar
        session.frame = sidebar.content.bounds
        session.autoresizingMask = [.width, .height]
        sidebar.content.addSubview(session)
        sidebar.focusTerminal = { [weak self] in self?.session.focusActive() }
        sidebar.list.send = { [weak self] in self?.connection.send($0, then: $1) }
        let toolbar = NSToolbar(identifier: "FloatingSidebar")
        toolbar.delegate = sidebar
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 900, height: 560))
        let root = try XCTUnwrap(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        sidebar.splitView.setPosition(292, ofDividerAt: 0)
        sidebar.viewDidLayout()
        let row = try XCTUnwrap(self.terminal?.panes.first)
        let object: [String: Any] = ["v": 2, "filter": "", "client": ["session": "$0", "window": connection.model.window!.description, "pane": row.pane.description],
            "sessions": [["id": "$0", "name": "visual", "current": true, "nodes": [["kind": "shell", "id": row.pane.description,
                "pane": row.pane.description, "window": connection.model.window!.description, "title": [["text": "Terminal", "role": "plain"]], "tail": [], "indicator": ["kind": "idle"], "attention": false, "children": []]]]]]
        sidebar.list.update(.running(try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))))
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
            XCTAssertTrue(menu.performKeyEquivalent(with: event))
            root.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
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
        let grids = terminal.panes.map { ghostty_surface_size($0.surface) }
        let clientSize = try await command(["list-clients", "-F", "#{client_width}x#{client_height}"])
        connection.visualCommands.removeAll()
        let list = sidebar.list
        let listParent = try XCTUnwrap(list.superview)
        var native: NSView = listParent
        while !(native is NSGlassEffectView), let parent = native.superview { native = parent }
        XCTAssertTrue(native is NSGlassEffectView)
        let nativeFrame = native.convert(native.bounds, to: root)
        sidebar.list.visualSearch.stringValue = "preserved"
        try key()
        XCTAssertTrue(sidebar.isFloating)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertTrue(sidebar.list === list)
        XCTAssertTrue(sidebar.tabs.superview === sidebar.splitView)
        XCTAssertTrue(sidebar.list.superview === listParent)
        XCTAssertEqual(native.convert(native.bounds, to: root), nativeFrame)
        XCTAssertTrue(sidebar.list.containsFocus)
        XCTAssertEqual(terminal.frame, frame)
        XCTAssertEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root), tabFrame)
        XCTAssertEqual(terminal.panes.map { ghostty_surface_size($0.surface).columns }, grids.map(\.columns))
        XCTAssertEqual(terminal.panes.map { ghostty_surface_size($0.surface).rows }, grids.map(\.rows))
        let floatingSize = try await command(["list-clients", "-F", "#{client_width}x#{client_height}"])
        XCTAssertEqual(floatingSize, clientSize)
        XCTAssertFalse(connection.visualCommands.contains { $0.line.hasPrefix("refresh-client -C") })
        try key()
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root), tabFrame)
        XCTAssertTrue(window.firstResponder is PaneView)
        try key()
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertTrue(window.firstResponder is PaneView)
        try key()
        let searchKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "/", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        window.sendEvent(searchKey)
        XCTAssertNotNil(sidebar.list.visualSearch.currentEditor())
        window.sendEvent(escape)
        XCTAssertTrue(sidebar.isFloating)
        XCTAssertEqual(sidebar.list.query, "")
        XCTAssertTrue(sidebar.list.containsFocus)
        sidebar.list.visualSearch.stringValue = "preserved"
        connection.visualCommands.removeAll()
        try key([.command, .shift])
        try await settle()
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertTrue(sidebar.list.superview === listParent)
        XCTAssertEqual(native.convert(native.bounds, to: root), nativeFrame)
        XCTAssertNotEqual(terminal.frame, frame)
        XCTAssertNotEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root), tabFrame)
        XCTAssertEqual(connection.visualCommands.filter { $0.line.hasPrefix("refresh-client -C") }.count, 1)
        chrome("shortcut float to dock")
        XCTAssertEqual(sidebar.list.query, "preserved")
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
        XCTAssertEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root), tabFrame)
        XCTAssertEqual(terminal.frame, frame)
        XCTAssertEqual(sidebar.list.query, "preserved")
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
        connection.visualCommands.removeAll()
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await wait("jump dismisses sidebar") { !sidebar.isFloating }
        XCTAssertTrue(window.firstResponder is PaneView)
        XCTAssertEqual(connection.visualCommands.filter { $0.line.hasPrefix("switch-client") }.count, 1)
        try key()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertTrue(window.firstResponder is PaneView)
        try key()
        try await paint()
        sidebar.list.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        CATransaction.flush()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: root, as: .image, named: "collapsed-floating", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    func testSingle() async throws {
        try await start()
        try await paint()
        try await snapshot("560")
        for height in [CGFloat(420), 680] {
            window.setContentSize(NSSize(width: 700, height: height))
            try await settle()
            try await paint()
            try await snapshot("\(Int(height))")
        }
    }

    func testSplitZoomFloat() async throws {
        try await start()
        _ = try await command(["split-window", "-h", "-t", "visual", "exec /bin/cat"])
        _ = try await command(["split-window", "-v", "-t", "visual:0.0", "exec /bin/cat"])
        _ = try await command(["split-window", "-v", "-t", "visual:0.1", "exec /bin/cat"])
        _ = try await command(["select-layout", "-t", "visual", "tiled"])
        try await wait("four panes") { self.terminal?.panes.count == 4 }
        try await paint()
        try await snapshot("2x2")
        _ = try await command(["resize-pane", "-Z", "-t", "visual:0.0"])
        try await wait("zoom") { self.terminal?.panes.filter { !$0.isHidden }.count == 1 }
        try await paint()
        try await snapshot("zoom")
        _ = try await command(["resize-pane", "-Z", "-t", "visual:0.0"])
        _ = try await command(["break-pane", "-W", "-s", "visual:0.3", "-X", "5", "-Y", "0", "-x", "35", "-y", "10"])
        try await wait("floating layout") { self.terminal?.visualLayout.contains("float %") == true }
        try await settle()
        try await paint()
        try await snapshot("float-top")
    }

    func testFractionalAlternateResizeDark() async throws {
        try await start(dark: true)
        try await paint(lines: 200)
        try XCTUnwrap(terminal?.panes.first).visualScroll(8.35)
        try await snapshot("fractional-dark")
        try await paint(alternate: true)
        try await snapshot("alternate-dark")
        for height in [430, 610, 480, 620, 560] { window.setContentSize(NSSize(width: 700, height: height)) }
        try await settle()
        try await snapshot("resize-settled-dark")
    }

    func testHistoryChunksAndResizeAnchors() async throws {
        try await start(history: 200000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        let fixture = directory.appendingPathComponent("history.txt")
        try (0..<100000).map { "row-\($0)\r\n" }.joined().write(to: fixture, atomically: true, encoding: .utf8)
        let done = directory.appendingPathComponent("history-done")
        _ = try await command(["respawn-pane", "-k", "-t", pane.pane.description,
                               "/bin/cat '" + fixture.path + "'; /usr/bin/touch '" + done.path + "'; exec /bin/sleep 600"])
        try await wait("100k fixture completed") { FileManager.default.fileExists(atPath: done.path) }
        let restored = expectation(description: "100k restore")
        pane.markContentDirty()
        connection.sync(pane.pane) { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 20)
        try await settle()
        XCTAssertEqual(pane.scrollPosition().history, historyChunkSize)
        pane.requestScroll(historyChunkSize)
        try await wait("100k pill visible") { pane.visualPill }
        pane.onLoadMore()
        try await wait("pill adds one chunk") { pane.scrollPosition().history == 2 * historyChunkSize }
        pane.showFind()
        pane.find?.field.stringValue = "row-12345"
        pane.find?.search()
        try await wait("find loads deep match") { pane.scrollPosition().history > 80000 }
        try await wait("find navigates to deep match") {
            let position = pane.scrollPosition()
            return position.history - position.offset > 80000
        }
        pane.find?.close()
        pane.requestScroll(5000)
        try await settle()
        window.setContentSize(NSSize(width: 700, height: 590))
        try await settle()
        XCTAssertEqual(pane.scrollTarget ?? 0, 5000, accuracy: 4)
        pane.onLoadMore()
        try await wait("older chunk reloaded") { pane.scrollPosition().history == 2 * historyChunkSize }
        pane.requestScroll(15000)
        try await settle()
        window.setContentSize(NSSize(width: 700, height: 560))
        try await settle()
        XCTAssertEqual(pane.scrollTarget ?? 0, 0)
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testHistoryPill() async throws {
        try await start(history: 100000)
        try await paint(lines: historyChunkSize + 1000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        pane.requestScroll(historyChunkSize)
        try await wait("Load more visible") { pane.visualPill }
        try await snapshot("history-top", pill: true)
    }

    private func sidebarFixture(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Snapshot {
        let url = app.appendingPathComponent("VisualTests/Fixtures/live-feed.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func sidebarSnapshot(_ list: SidebarView, _ name: String, testName: String = #function) {
        list.layoutSubtreeIfNeeded()
        list.visualTable.layoutSubtreeIfNeeded()
        list.displayIfNeeded()
        CATransaction.flush()
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: list, as: .image, named: name, record: record, testName: testName),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    func testSidebarCards() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 680),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        SidebarView.visualNow = Date(timeIntervalSince1970: 1791131198)
        defer { SidebarView.visualNow = nil }
        let live = try sidebarFixture()
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            list.update(.running(live))
            sidebarSnapshot(list, dark ? "live-dark" : "live-light")
        }
        list.visualFold(SessionID(number: 0))
        sidebarSnapshot(list, "folded-dark")
        list.visualFold(SessionID(number: 0))
        let nested = try sidebarFixture { object in
            object["client"] = ["session": "$0", "window": "@458", "pane": "%502"]
            var sessions = object["sessions"] as! [[String: Any]]
            var nodes = sessions[0]["nodes"] as! [[String: Any]]
            var children = nodes[1]["children"] as! [[String: Any]]
            children[0]["tail"] = [["text": "Rebuilding the sidebar cards and testing nested window corners", "role": "dim"]]
            nodes[1]["children"] = children
            sessions[0]["nodes"] = nodes
            object["sessions"] = sessions
        }
        list.update(.running(nested))
        sidebarSnapshot(list, "active-parent-dark")
        window.appearance = NSAppearance(named: .aqua)
        sidebarSnapshot(list, "active-parent-light")
        window.setContentSize(NSSize(width: 236, height: 680))
        sidebarSnapshot(list, "narrow-light")
        list.visualSearch.stringValue = "no-such-session"
        list.visualSearch.isHidden = false
        list.update(.running(try sidebarFixture { $0["filter"] = "no-such-session"; $0["sessions"] = [] }))
        sidebarSnapshot(list, "no-matches-light")
    }

    func testFoldedFilteredEnterSendsOnce() async throws {
        for reply: Reply in [.success([]), .failure(["delayed failure"])] {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let list = SidebarView()
            window.contentView = list
            list.update(.running(try sidebarFixture { $0["filter"] = "main" }))
            list.visualFold(SessionID(number: 0))
            list.visualSearch.stringValue = "main"
            var commands: [[Command]] = []
            var pending: [@MainActor @Sendable ([Reply]?) -> Void] = []
            list.send = { batch, done in commands.append(batch); pending.append(done) }
            _ = list.control(list.visualSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(commands.count, 1, "one Enter must send one switch-client before delayed reply")
            let completed = expectation(description: "delayed reply")
            DispatchQueue.main.async {
                for done in pending { done([reply]) }
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(commands.count, 1, "delayed reply must not send another switch-client")
            XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
        }
    }

    func testSwitchWindowOutputAndReconnect() async throws {
        let scratch = app.appendingPathComponent("build/sbfix/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let script = scratch.appendingPathComponent("kido")
        let fixture = scratch.appendingPathComponent("feed.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent("VisualTests/Fixtures/live-feed.json")))
        try JSONSerialization.data(withJSONObject: object).write(to: fixture)
        try """
        #!/bin/sh
        if [ "$1" = switch-window ]; then
            [ "$3" = --client ] && [ "$4" = private-client ] && [ "$5" = --server ] && [ "$6" = '\(scratch.path)' ] || exit 2
            sleep 0.2
            [ "$2" = next ] && printf '$3 @12\\n'
            exit 0
        fi
        cat '\(fixture.path)'
        printf '\\n'
        while IFS= read -r line; do
            [ "$line" = 'filter exit' ] && exit 0
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var starts = 0
        var snapshots = 0
        let feed = Feed(serverDir: scratch.path, locate: { done in
            done(.success("private-client"))
        }, query: { "" }, onChange: { status in
            if case .starting = status { starts += 1 }
            if case .running = status { snapshots += 1 }
        })
        feed.testKido = script.path
        defer { feed.stop() }
        try await wait("fake feed ready") { snapshots == 1 }
        let switched = expectation(description: "switch stdout")
        feed.switchWindow(next: true) { target, error in
            XCTAssertNil(error)
            XCTAssertEqual(target?.session, SessionID(number: 3), "navigation must return its own stdout session")
            XCTAssertEqual(target?.window, WindowID(number: 12), "navigation must return its own stdout window")
            switched.fulfill()
        }
        await fulfillment(of: [switched], timeout: 5)
        let noop = expectation(description: "empty stdout")
        feed.switchWindow(next: false) { target, error in
            XCTAssertNil(error)
            XCTAssertNil(target, "empty stdout must be a no-op")
            noop.fulfill()
        }
        await fulfillment(of: [noop], timeout: 5)
        let stale = expectation(description: "old generation completion")
        stale.isInverted = true
        feed.switchWindow(next: true) { _, _ in stale.fulfill() }
        feed.filter("exit")
        try await wait("feed reconnected") { starts == 2 && snapshots == 2 }
        await fulfillment(of: [stale], timeout: 0.5)
    }

    func testSidebarFoldingKeysAndAccessibility() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        let fixture = try sidebarFixture()
        list.update(.running(fixture))
        list.focus()
        list.layoutSubtreeIfNeeded()
        let header = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        XCTAssertEqual(list.visualTable.focusRingType, .none)
        XCTAssertEqual(list.visualTable.selectionHighlightStyle, .none)
        XCTAssertTrue((list.visualTable as? Table)?.keyboardSelection == true)
        XCTAssertEqual(header.accessibilityRole(), .button)
        XCTAssertEqual(header.accessibilityValue() as? String, "expanded")
        func key(_ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            list.visualTable.keyDown(with: event)
        }
        try key(123)
        XCTAssertFalse(list.visualRows.contains { $0.target?.session == fixture.client.session })
        XCTAssertEqual(list.visualTable.selectedRow, -1)
        try key(124)
        XCTAssertTrue(list.visualRows.contains { $0.target == fixture.client })
        XCTAssertEqual(list.visualTable.selectedRow, -1)
        list.focus()
        let selected = list.visualTable.selectedRow
        try key(124)
        XCTAssertEqual(list.visualTable.selectedRow, selected, "unfolding keeps selection")
        let expanded = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        XCTAssertTrue(expanded.accessibilityPerformPress())
        let collapsed = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        XCTAssertEqual(collapsed.accessibilityValue() as? String, "collapsed")
        XCTAssertFalse(collapsed.addWindow.isHidden)
        XCTAssertTrue(collapsed.accessibilityPerformPress())
        for row in list.visualRows where row.target != nil {
            let cell = SidebarCell(SidebarFonts())
            cell.configure(row, expanded: true)
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
        let list = SidebarView()
        window.contentView = list
        let initial = try sidebarFixture()
        let destination = try sidebarFixture { $0["client"] = ["session": "$0", "window": "@458", "pane": "%502"] }
        list.update(.running(initial))
        list.layoutSubtreeIfNeeded()
        list.visualFold(SessionID(number: 0))
        list.update(.running(destination))
        list.completedNavigation(to: (destination.client.session, destination.client.window))
        let selected = list.visualTable.selectedRow
        XCTAssertGreaterThanOrEqual(selected, 0, "feed-first completion must select the destination")
        if selected >= 0 {
            XCTAssertEqual(list.visualRows[selected].target, destination.client)
            XCTAssertTrue(list.visualTable.visibleRect.intersects(list.visualTable.rect(ofRow: selected)), "destination must be visible")
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testNoOpNavigationConsumesReveal() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        list.update(.running(try sidebarFixture()))
        list.visualFold(SessionID(number: 0))
        list.completedNavigation(to: nil)
        list.update(.running(try sidebarFixture { $0["client"] = ["session": "$0", "window": "@458", "pane": "%502"] }))
        XCTAssertFalse(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) }, "unrelated client change must not consume a completed no-op navigation")
    }

    func testSidebarNavigationAndAnchoring() async throws {
        try await start()
        let list = SidebarView()
        list.frame = NSRect(x: 0, y: 0, width: 292, height: 260)
        window.contentView = list
        let fixture = try sidebarFixture { object in
            let original = (object["sessions"] as! [[String: Any]])[0]
            object["sessions"] = (0..<20).map { i -> [String: Any] in
                var session = original
                session["id"] = "$\(i)"
                session["name"] = "session-\(i)"
                return session
            }
        }
        list.update(.running(fixture))
        list.layoutSubtreeIfNeeded()
        let anchorIndex = 12
        let anchorID = list.visualRows[anchorIndex].id
        list.visualScroll.contentView.scroll(to: NSPoint(x: 0, y: list.visualTable.rect(ofRow: anchorIndex).minY + 7.25))
        let before = list.visualScroll.contentView.bounds.minY - list.visualTable.rect(ofRow: anchorIndex).minY
        let stable = try sidebarFixture { object in
            let original = (object["sessions"] as! [[String: Any]])[0]
            object["sessions"] = ([99] + Array(0..<20)).map { i -> [String: Any] in
                var session = original
                session["id"] = "$\(i)"
                session["name"] = "session-\(i)"
                return session
            }
        }
        list.update(.running(stable))
        list.layoutSubtreeIfNeeded()
        let newIndex = try XCTUnwrap(list.visualRows.firstIndex { $0.id == anchorID })
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(newIndex, anchorIndex)
        XCTAssertEqual(list.visualScroll.contentView.bounds.minY - list.visualTable.rect(ofRow: newIndex).minY, before, accuracy: 1)
        list.visualFold(SessionID(number: 0))
        list.update(.running(fixture))
        XCTAssertFalse(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) })
        let navigated = try sidebarFixture { $0["client"] = ["session": "$0", "window": "@458", "pane": "%502"] }
        list.completedNavigation(to: (navigated.client.session, navigated.client.window))
        XCTAssertEqual(list.visualRows[list.visualTable.selectedRow].target?.window, navigated.client.window)
        list.update(.running(navigated))
        XCTAssertTrue(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) })
        let row = try XCTUnwrap(list.visualRows.first { $0.target != nil })
        var commands: [[Command]] = []
        var left = 0
        var filters: [String] = []
        list.leave = { left += 1 }
        list.filter = { filters.append($0) }
        list.visualSearch.stringValue = "main"
        list.focus()
        list.send = { batch, done in commands.append(batch); done([.failure(["no such pane"])]) }
        list.visualJump(row)
        XCTAssertEqual(commands, [[Command("switch-client", "-t", "\(row.target!.session):\(row.target!.window).\(row.target!.pane)")]])
        XCTAssertEqual(list.query, "main")
        XCTAssertEqual(left, 0)
        XCTAssertEqual(list.visualDiagnostic, "no such pane")
        XCTAssertTrue(list.containsFocus)
        list.send = { batch, done in commands.append(batch); XCTAssertTrue(Thread.isMainThread); done([.success([])]) }
        list.visualJump(row)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(left, 1)
        XCTAssertEqual(list.query, "")
        XCTAssertEqual(filters, [""])
        list.visualSearch.stringValue = "keep-me"
        list.update(.running(try sidebarFixture()))
        XCTAssertEqual(list.query, "keep-me")
        _ = list.control(list.visualSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(list.query, "")
        XCTAssertTrue(list.visualSearch.isHidden)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        list.visualTable.keyDown(with: event)
        XCTAssertNotEqual(list.visualTable.selectedRow, -1)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        list.visualTable.keyDown(with: escape)
        XCTAssertEqual(left, 2)
        let target = try XCTUnwrap(list.visualRows.first { $0.target != nil })
        let failed = expectation(description: "real private tmux jump reply")
        list.send = { [weak self] batch, done in
            self?.connection.send(batch) { replies in XCTAssertTrue(Thread.isMainThread); done(replies); failed.fulfill() }
        }
        list.visualJump(target)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }
}
