import AppKit
import GhosttyKit
import SnapshotTesting
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

func clipboardQueryScript(ready: String, result: String, selector: String, deadline: Int) -> String {
    """
    import os, select, time, tty
    tty.setraw(0)
    deadline = time.monotonic() + 5
    while not os.path.exists('\(ready)') and time.monotonic() < deadline: time.sleep(0.02)
    os.write(1, b'\\x1b]52;\(selector);?\\x1b\\\\')
    deadline = time.monotonic() + \(deadline)
    reply = b''
    while time.monotonic() < deadline:
        readable, _, _ = select.select([0], [], [], 0.4 if reply else 0.1)
        if readable: reply += os.read(0, 65536)
        elif reply: break
    open('\(result)', 'wb').write(reply)
    time.sleep(3)
    """
}

@MainActor class VisualTestCase: XCTestCase {
    override func invokeTest() {
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { super.invokeTest() }
    }

    func headerImage(_ tabs: WindowTabs) throws -> NSImage {
        let root = try XCTUnwrap(tabs.window?.contentView?.superview)
        let rect = tabs.convert(tabs.bounds, to: root)
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: rect))
        root.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: tabs.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    override func setUp() async throws {
        WindowOwner.clipboardConsent.reset()
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}

@MainActor final class VisualTests: VisualTestCase {
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
        (window.contentViewController as? Sidebar)?.tabs.entries = model.navigation(tabSnapshot, activePanes: session.windows.compactMapValues(\.active)).tabs
    }

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: "/tmp/kido-visual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socket = directory.appendingPathComponent("socket").path
        tmux = try XCTUnwrap(ProcessInfo.processInfo.environment["KIDO_VISUAL_TMUX"])
        addTeardownBlock { @MainActor [self] in
            if FileManager.default.fileExists(atPath: socket) {
                _ = try? await Child.run(tmux, ["-S", socket, "kill-server"])
            }
        }
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

    @discardableResult private func start(height: CGFloat = 560, dark: Bool = false, history: Int = 1000) async throws -> String {
        NSApp.appearance = NSAppearance(named: .aqua)
        if Self.processRuntime == nil {
            let config = directory.appendingPathComponent("ghostty.conf")
            let themes = app.appendingPathComponent("Resources/themes").path
            let theme = "light:\(themes)/kido-light,dark:\(themes)/kido-dark"
            try "theme = \(theme)\nfont-family = Menlo\nfont-size = 13\n".write(to: config, atomically: true, encoding: .utf8)
            Self.processRuntime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))))
        }
        runtime = try XCTUnwrap(Self.processRuntime)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: height),
                          styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .displayP3
        session = SessionView(runtime: runtime)
        session.onPaneChange = { [weak self] in self?.updateTabs() }
        session.frame = NSRect(x: 0, y: 0, width: 700, height: height)
        window.contentView = session
        let tmuxConfig = directory.appendingPathComponent("tmux.conf")
        try "set -g history-limit \(history)\nset -s get-clipboard request\n".write(to: tmuxConfig, atomically: true, encoding: .utf8)
        _ = try await command(["-f", tmuxConfig.path, "new-session", "-d", "-s", "visual", "-x", "80", "-y", "30", "exec /bin/cat"])
        let clipboardMode = try await command(["show", "-sv", "get-clipboard"])
        connection = try Connection(server: Server(tmux: tmux, socket: socket, protocolVersion: .required), view: session,
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
        return clipboardMode
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
        sidebar.tabs.theme = (runtime.background, window.appearance)
        window.display()
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
        func fixture(_ status: String = "waiting", filtered: Bool = false, review: String = "Review changes") throws -> Snapshot {
            func item(_ pane: [String], children: [[String: Any]] = [], status: String = "idle") -> [String: Any] {
                ["kind": pane[0] == child ? "run" : "shell", "run": pane[0] == child ? "agent" as Any : NSNull(), "id": pane[1], "pane": pane[1], "window": pane[0],
                 "title": [["text": pane[0] == middle ? (pane[1] == secondPane ? review : "Agent caption") : pane[0] == last ? "Build output" : "Shell prompt", "role": "plain"]], "tail": [], "indicator": ["kind": status],
                 "attention": status == "done", "children": children]
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
        XCTAssertEqual(sidebar.tabs.entries.map(\.name), ["Shell prompt", "Review changes", "Build output"])
        let firstPane = try XCTUnwrap(panes.first { $0[0] == middle && $0[1] != secondPane })[1]
        let beforePaneChange = model
        _ = try await command(["select-pane", "-t", firstPane])
        try await wait("inactive window pane title") { sidebar.tabs.entries[1].name == "Agent caption" }
        XCTAssertEqual(model, beforePaneChange)
        _ = try await command(["select-pane", "-t", secondPane])
        try await wait("inactive window pane restored") { sidebar.tabs.entries[1].name == "Review changes" }
        updateTabs(.running(try fixture(review: "Review updated")), query: "")
        XCTAssertEqual(sidebar.tabs.entries[1].name, "Review updated")
        XCTAssertEqual((sidebar.tabs.accessibilityChildren()?[1] as? NSAccessibilityElement)?.accessibilityLabel(), "Window: Review updated — attention")
        updateTabs(.running(try fixture()), query: "")
        XCTAssertEqual(sidebar.tabs.entries.map(\.status), [.quiet, .attention, .quiet])
        sidebar.list.filter = { query in self.updateTabs(.running(try! fixture(filtered: true)), query: query) }
        sidebar.list.visualSearch.stringValue = "hidden"
        XCTAssertTrue(sidebar.list.visualSearch.sendAction(try XCTUnwrap(sidebar.list.visualSearch.action), to: sidebar.list.visualSearch.target))
        XCTAssertEqual(sidebar.tabs.entries.map(\.name), ["Shell prompt", "Review changes", "Build output"])
        sidebar.list.visualSearch.stringValue = ""
        updateTabs(.running(try fixture("failed")), query: "")
        XCTAssertEqual(sidebar.tabs.entries[1].status, .error)
        updateTabs(.running(try fixture()), query: "")
        connection.send([Command("select-window", "-t", child)])
        try await wait("descendant active") { self.model.window?.description == child }
        XCTAssertEqual(sidebar.tabs.entries.first { $0.active }?.id.description, middle)
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        try await wait("native tabs layout") { sidebar.tabs.frame.width > 300 && sidebar.tabs.frame.height == 36 }
        let point = sidebar.tabs.convert(NSPoint(x: 240, y: 18), to: nil)
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
        XCTAssertGreaterThan(sidebar.tabs.convert(sidebar.tabs.bounds, to: root).minY, area.maxY)
        XCTAssertTrue(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "windowTabs" }?.view === sidebar.tabs.superview)
        XCTAssertEqual(sidebar.tabs.frame.height, 36)
        let tabs = sidebar.tabs.entries
        sidebar.tabs.entries = []
        let empty = root.hitTest(sidebar.tabs.convert(NSPoint(x: sidebar.tabs.bounds.midX, y: 18), to: root))
        XCTAssertFalse(empty === sidebar.tabs)
        XCTAssertTrue(empty?.mouseDownCanMoveWindow == true)
        sidebar.tabs.entries = tabs
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        updateTabs(.running(try fixture("stalled")), query: "")
        XCTAssertEqual(sidebar.tabs.entries[1].status, .quiet)
        updateTabs(.running(try fixture("done")), query: "")
        XCTAssertEqual(sidebar.tabs.entries[1].status, .quiet)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: try headerImage(sidebar.tabs), as: .image, named: "middle", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        sidebar.isCollapsed = true
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        XCTAssertGreaterThanOrEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root).minX, 116)
        try await Task.sleep(for: .milliseconds(200))
        if let failure = verifySnapshot(of: try headerImage(sidebar.tabs), as: .image, named: "collapsed", record: record),
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
        sidebar.tabs.theme = (runtime.background, window.appearance)
        window.display()
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
        XCTAssertTrue(toolbar.items.first { $0.itemIdentifier.rawValue == "windowTabs" }?.view === sidebar.tabs.superview)
        XCTAssertTrue(sidebar.list.superview === listParent)
        XCTAssertEqual(native.convert(native.bounds, to: root), nativeFrame)
        XCTAssertTrue(sidebar.list.containsFocus)
        XCTAssertEqual(terminal.frame, frame)
        try await Task.sleep(for: .milliseconds(200))
        let floatingTabFrame = sidebar.tabs.convert(sidebar.tabs.bounds, to: root)
        XCTAssertGreaterThan(floatingTabFrame.minX, tabFrame.minX)
        XCTAssertGreaterThanOrEqual(floatingTabFrame.minX, nativeFrame.maxX)
        XCTAssertEqual(floatingTabFrame.maxX, tabFrame.maxX)
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
        try await settle()
        XCTAssertEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root), floatingTabFrame)
        XCTAssertEqual(terminal.panes.map { ghostty_surface_size($0.surface).columns }, grids.map(\.columns))
        XCTAssertEqual(terminal.panes.map { ghostty_surface_size($0.surface).rows }, grids.map(\.rows))
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
        var views = [root]
        while let view = views.popLast() {
            if let glass = view as? NSGlassEffectView, sidebar.list.isDescendant(of: glass) {
                XCTAssertEqual(glass.layer?.cornerRadius, sidebar.list.layer?.cornerRadius, "offscreen glass fill must match its sidebar corner radius")
            }
            views += view.subviews
        }
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

    func testTerminalMouseShape() async throws {
        try await start()
        try await paint(lines: 100)
        let terminal = try XCTUnwrap(terminal)
        let pane = try XCTUnwrap(terminal.panes.first)
        for (name, shape, cursor) in [("pointer", GHOSTTY_MOUSE_SHAPE_POINTER, NSCursor.pointingHand),
                                      ("text", GHOSTTY_MOUSE_SHAPE_TEXT, NSCursor.iBeam),
                                      ("default", GHOSTTY_MOUSE_SHAPE_DEFAULT, NSCursor.arrow)] {
            XCTAssertTrue(pane.feed(Data("\u{1b}]22;\(name)\u{7}".utf8)))
            try await wait("mouse shape \(name)") { pane.mouseShape == shape }
            XCTAssertTrue(pane.mouseCursor === cursor)
        }
        pane.setMouseShape(GHOSTTY_MOUSE_SHAPE_POINTER)
        let grid = terminal.convert(try XCTUnwrap(pane.terminalCursorRects.first), from: pane)
        XCTAssertTrue(terminal.paneCursorRects.contains { $0.0.contains(CGPoint(x: grid.midX, y: grid.midY)) && $0.1 === NSCursor.pointingHand })
        XCTAssertFalse(pane.scroller.isHidden)
        let strip = terminal.convert(pane.scroller.bounds, from: pane.scroller)
        XCTAssertFalse(terminal.paneCursorRects.contains { $0.1 === NSCursor.pointingHand && $0.0.intersects(strip) })
        pane.showFind()
        pane.layoutSubtreeIfNeeded()
        let find = try XCTUnwrap(pane.find)
        let findRect = terminal.convert(find.bounds, from: find)
        XCTAssertFalse(terminal.paneCursorRects.contains { $0.1 === NSCursor.pointingHand && $0.0.intersects(findRect) })
        find.close()
        _ = try await command(["split-window", "-h", "-t", "visual", "exec /bin/cat"])
        try await wait("split for cursor priority") { terminal.panes.count == 2 }
        for view in terminal.panes { view.setMouseShape(GHOSTTY_MOUSE_SHAPE_POINTER) }
        let dividers = terminal.paneCursorRects.filter { $0.1 === NSCursor.resizeLeftRight }
        XCTAssertFalse(dividers.isEmpty)
        for (rect, _) in dividers {
            XCTAssertFalse(terminal.paneCursorRects.contains { $0.1 === NSCursor.pointingHand && $0.0.intersects(rect) })
        }
        _ = try await command(["break-pane", "-W", "-s", "visual:0.1", "-X", "5", "-Y", "2", "-x", "35", "-y", "10"])
        try await wait("float for cursor priority") { terminal.visualLayout.contains("float %") }
        try await settle()
        XCTAssertTrue(terminal.paneCursorRects.contains { $0.1 === NSCursor.openHand })
        let linkRects = terminal.paneCursorRects.filter { $0.1 === NSCursor.pointingHand }.map { $0.0 }
        for (rect, cursor) in terminal.paneCursorRects where cursor !== NSCursor.pointingHand {
            XCTAssertFalse(linkRects.contains { $0.intersects(rect) }, "chrome cursor must win")
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

    func testEmptyPaneWheelDoesNotFloodMetadata() async throws {
        try await start()
        let pane = try XCTUnwrap(terminal?.panes.first)
        XCTAssertEqual(pane.scrollPosition().retainedHistoryRows, 0)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        let queries = connection.visualMetadataQueries
        let revision = pane.scrollRevision
        for _ in 0..<30 {
            pane.scrollWheel(with: try XCTUnwrap(pane.wheelEvent(y: 1)))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await settle()
        XCTAssertEqual(connection.visualMetadataQueries - queries, 0, "idle empty wheel gesture must not query tmux metadata")
        XCTAssertEqual(pane.scrollRevision, revision, "clamped wheel packets must not invalidate an already-applied viewport")
    }

    func testFirstWheelWithZeroSampleRendersFractionalFrame() async throws {
        try await start()
        let original = try XCTUnwrap(terminal?.panes.first)
        var input = Data()
        var pane: PaneView? = try XCTUnwrap(PaneView(runtime: runtime, pane: original.pane, font: original.font,
                                         onInput: { input.append($0) }))
        window.contentView?.addSubview(pane!)
        defer { pane?.dispose(); pane?.removeFromSuperview() }
        pane!.frame = NSRect(x: -10000, y: -10000, width: pane!.cell.width * 80, height: pane!.cell.height * 24)
        pane!.resize(cols: 80, rows: 24)
        pane!.needsLayout = true
        pane!.layout()
        XCTAssertGreaterThan(pane!.wheelRowHeight, 1)
        XCTAssertTrue(pane!.feed(Data("\u{1b}c".utf8), kind: .snapshot, epoch: pane!.historyEpoch))
        XCTAssertTrue(pane!.commitSnapshot(epoch: pane!.historyEpoch))
        try await settle()
        pane!.updateScroller(sampledTmuxHistoryRows: 0, position: pane!.scrollPosition(), alternate: false)
        XCTAssertEqual(pane!.scrollPosition().retainedHistoryRows, 0)
        XCTAssertTrue(pane!.feed(Data((0..<200).map { "live\($0)\r\n" }.joined().utf8), kind: .live, epoch: pane!.historyEpoch))
        try await wait("live retained rows and frame") { pane!.scrollPosition().retainedHistoryRows > 0 && pane!.renderedPixels != nil }
        try await settle()
        let before = pane!.renderedPixels
        let event = try XCTUnwrap(pane!.wheelEvent(y: 1))
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        pane!.scrollWheel(with: event)
        let target = try XCTUnwrap(pane!.wheelDistance)
        XCTAssertGreaterThan(target, 0)
        XCTAssertLessThan(target, 1)
        try await wait("fractional wheel frame applied") {
            let state = pane!.finalRenderDiagnostics
            return state["revision"] as? Int == state["applied-revision"] as? Int && pane!.renderedPixels != before
        }
        XCTAssertTrue(input.isEmpty)
        weak let released = pane
        pane?.dispose()
        pane?.removeFromSuperview()
        pane = nil
        try await wait("wheel fixture surface freed") { released == nil }
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
        XCTAssertEqual(pane.scrollPosition().retainedHistoryRows, historyChunkSize)
        pane.requestScroll(historyChunkSize)
        try await wait("100k pill visible") { pane.visualPill }
        pane.onLoadMore()
        try await wait("pill adds one chunk") { pane.scrollPosition().retainedHistoryRows == 2 * historyChunkSize }
        pane.showFind()
        pane.find?.field.stringValue = "row-12345"
        pane.find?.search()
        try await wait("find loads deep match") { pane.scrollPosition().retainedHistoryRows > 80000 }
        try await wait("find navigates to deep match") {
            let position = pane.scrollPosition()
            return position.retainedHistoryRows - position.offset > 80000
        }
        pane.find?.close()
        pane.requestScroll(5000)
        try await settle()
        window.setContentSize(NSSize(width: 700, height: 590))
        try await settle()
        XCTAssertEqual(pane.scrollTarget ?? 0, 5000, accuracy: 4)
        pane.onLoadMore()
        try await wait("older chunk reloaded") { pane.scrollPosition().retainedHistoryRows == 2 * historyChunkSize }
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
        window.layoutIfNeeded()
        list.layoutSubtreeIfNeeded()
        list.visualTable.tile()
        list.visualTable.layoutSubtreeIfNeeded()
        if list.visualTable.numberOfRows > 0 { list.visualTable.scrollRowToVisible(0) }
        list.visualScroll.reflectScrolledClipView(list.visualScroll.contentView)
        list.displayIfNeeded()
        CATransaction.flush()
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: list, as: .image, named: name, record: record, testName: testName),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    func testNestedSidebarRowHeightsAndNavigation() throws {
        var fixture: [String: Any] = [:]
        let live = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            var nodes = sessions[0]["nodes"] as! [[String: Any]]
            var children = nodes[0]["children"] as! [[String: Any]]
            var sibling = children[0]
            sibling["id"] = "%999"
            sibling["pane"] = "%999"
            sibling["window"] = "@999"
            children.append(sibling)
            nodes[0]["children"] = children
            sessions[0]["nodes"] = nodes
            object["sessions"] = sessions
            fixture = object
        }
        let rows = sidebarRows(live)
        XCTAssertTrue(rows.contains { $0.indent > 0 && $0.target != nil })
        let invalid = rows.filter { $0.height <= 0 }
        XCTAssertTrue(invalid.isEmpty, "NSTableView requires positive row heights: \(invalid.map(\.id))")
        guard invalid.isEmpty else { return }
        window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        list.layoutSubtreeIfNeeded()
        list.update(.running(live))
        let table = list.visualTable
        XCTAssertEqual(table.numberOfRows, rows.count)
        for index in rows.indices {
            XCTAssertGreaterThan(list.tableView(table, heightOfRow: index), 0)
            table.scrollRowToVisible(index)
        }
        let nested = try XCTUnwrap(rows.lastIndex { $0.indent > 0 && $0.target != nil })
        let target = try XCTUnwrap(rows[nested].target)
        var object = fixture
        object["client"] = ["session": target.session.description, "window": target.window.description, "pane": target.pane.description]
        let changed = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        list.update(.running(changed))
        XCTAssertEqual(table.selectedRow, nested)
        let origin = list.visualScroll.contentView.bounds.origin
        object["error"] = "same shape"
        list.update(.running(try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))))
        XCTAssertEqual(table.selectedRow, nested)
        XCTAssertEqual(list.visualScroll.contentView.bounds.origin, origin)
        let previous = try XCTUnwrap(rows[..<nested].lastIndex { $0.target != nil })
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f700}", charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126))
        table.keyDown(with: up)
        XCTAssertEqual(table.selectedRow, previous)
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testSidebarCards() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 680),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.colorSpace = .displayP3
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
        let nested = try sidebarFixture { object in
            object["client"] = ["session": "$0", "window": "@458", "pane": "%502"]
            var sessions = object["sessions"] as! [[String: Any]]
            var nodes = sessions[0]["nodes"] as! [[String: Any]]
            var children = nodes[1]["children"] as! [[String: Any]]
            nodes[0]["indicator"] = ["kind": "done"]
            nodes[0]["attention"] = true
            var runs = nodes[0]["children"] as! [[String: Any]]
            runs[0]["indicator"] = ["kind": "gone", "outcome": "completed"]
            runs[0]["started"] = NSNull()
            nodes[0]["children"] = runs
            children[0]["indicator"] = ["kind": "waiting"]
            children[0]["attention"] = true
            children[0]["tail"] = [["text": "Rebuilding the sidebar cards and testing nested window corners", "role": "dim"]]
            var agents = children[0]["children"] as! [[String: Any]]
            agents[0]["indicator"] = ["kind": "stalled"]
            children[0]["children"] = agents
            children[1]["indicator"] = ["kind": "done"]
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
        window.setContentSize(NSSize(width: 292, height: 680))
        list.update(.running(try sidebarFixture { $0["client"] = ["session": "$0", "window": "@786", "pane": "%892"] }))
        sidebarSnapshot(list, "child-active-light")
        let grouped = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            let nodes = sessions[0]["nodes"] as! [[String: Any]]
            var second = (nodes[1]["children"] as! [[String: Any]])[0], third = nodes[0]
            second["window"] = nodes[0]["window"]
            second["tail"] = [["text": "Grouped pane activity", "role": "dim"]]
            third["id"] = "%999"; third["pane"] = "%999"
            third["children"] = []; third["title"] = [["text": "terminal", "role": "plain"]]; third["kind"] = "shell"
            sessions[0]["nodes"] = [["kind": "window", "id": nodes[0]["window"]!, "window": nodes[0]["window"]!,
                                     "name": "group", "children": [nodes[0], second, third]]]
            object["sessions"] = sessions
            object["client"] = ["session": "$0", "window": nodes[0]["window"]!, "pane": nodes[0]["pane"]!]
        }
        list.update(.running(grouped))
        list.focus()
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        list.visualTable.keyDown(with: down)
        sidebarSnapshot(list, "three-pane-keyboard-light")
        let header = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        header.addWindow.mouseEntered(with: hover)
        sidebarSnapshot(list, "plus-hover-light")
        header.addWindow.mouseExited(with: hover)
        window.setContentSize(NSSize(width: 236, height: 680))
        list.visualSearch.stringValue = "no-such-session"
        list.visualSearch.isHidden = false
        list.update(.running(try sidebarFixture { $0["filter"] = "no-such-session"; $0["sessions"] = [] }))
        sidebarSnapshot(list, "no-matches-light")
    }

    func testFilteredEnterSendsOnce() async throws {
        for reply: Reply in [.success([]), .failure(["delayed failure"])] {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let list = SidebarView()
            window.contentView = list
            list.update(.running(try sidebarFixture { $0["filter"] = "main" }))
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

    func testSwitchWindowAndSessionOutputAndReconnect() async throws {
        for navigation in [Feed.Navigation.window, .session] {
            let scratch = app.appendingPathComponent("build/sbfix/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let script = scratch.appendingPathComponent("kido")
            let fixture = scratch.appendingPathComponent("feed.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent("VisualTests/Fixtures/live-feed.json")))
            try JSONSerialization.data(withJSONObject: object).write(to: fixture)
            try """
            #!/bin/sh
            exec python3 -u -c '
            import json, sys
            print(json.dumps(dict(hello=dict(protocol="1.1"))))
            snapshot = json.load(open("\(fixture.path)"))
            print(json.dumps(snapshot))
            held = None
            for line in sys.stdin:
                request = json.loads(line)
                if request.get("filter") == "exit": break
                if "\(navigation.rawValue)" not in request: continue
                direction = request["\(navigation.rawValue)"]["direction"]
                reply = dict(id=request["id"], switched=dict(session="$3", window="@12") if direction == "next" else dict(session="$1", window="@5"))
                if request["id"] == 3:
                    print(json.dumps(dict(reply=dict(id=request["id"], switched=None))))
                elif request["id"] == 4:
                    print(json.dumps(dict(reply=dict(id=request["id"], error="navigation failed"))))
                elif request["id"] <= 2:
                    if held is None: held = reply
                    else:
                        print(json.dumps(dict(reply=reply)))
                        print(json.dumps(snapshot))
                        print(json.dumps(dict(reply=held)))
                '
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
            feed.switchTarget(navigation, next: true) { target, error in
                XCTAssertNil(error)
                XCTAssertEqual(target?.session, SessionID(number: 3), "navigation must return its own stdout session")
                XCTAssertEqual(target?.window, WindowID(number: 12), "navigation must return its own stdout window")
                switched.fulfill()
            }
            let previous = expectation(description: "previous target")
            feed.switchTarget(navigation, next: false) { target, error in
                XCTAssertNil(error)
                XCTAssertEqual(target?.session, SessionID(number: 1))
                XCTAssertEqual(target?.window, WindowID(number: 5))
                previous.fulfill()
            }
            await fulfillment(of: [switched, previous], timeout: 5)
            let noop = expectation(description: "null target")
            feed.switchTarget(navigation, next: true) { target, error in
                XCTAssertNil(error)
                XCTAssertNil(target)
                noop.fulfill()
            }
            let failed = expectation(description: "RPC error")
            feed.switchTarget(navigation, next: false) { target, error in
                XCTAssertNil(target)
                XCTAssertEqual(error, "navigation failed")
                failed.fulfill()
            }
            await fulfillment(of: [noop, failed], timeout: 5)
            let stale = expectation(description: "pending request fails once")
            stale.assertForOverFulfill = true
            feed.switchTarget(navigation, next: true) { target, error in
                XCTAssertNil(target)
                XCTAssertNotNil(error)
                stale.fulfill()
            }
            feed.filter("exit")
            try await wait("feed reconnected") { starts == 2 && snapshots == 3 }
            await fulfillment(of: [stale], timeout: 5)
        }
    }

    func testOSC52ClipboardConsentAndPrivatePaneTransport() async throws {
        let clipboardModeBeforeAttach = try await start()
        XCTAssertNotEqual(runtime.pasteboard.name.rawValue, "NSGeneralPboard")
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        window.contentView = nil
        window.isReleasedWhenClosed = false
        window.close()
        window = owner.window
        window.contentView = session
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { owner.close() }
        let pane = try XCTUnwrap(terminal?.panes.first)
        let board = runtime.pasteboard
        board.clearContents()
        board.setString("before", forType: .string)
        let copy = Data("copied ✓".utf8).base64EncodedString()
        let replay = Data("\u{1b}]52;c;\(copy)\u{7}\u{1b}]52;c;?\u{1b}\\".utf8)
        pane.feed(replay, kind: .snapshot)
        try await settle()
        XCTAssertEqual(board.string(forType: .string), "before")
        XCTAssertNil(owner.preparedAlert)
        pane.feed(Data("\u{1b}]52;c;\(copy)".utf8), kind: .snapshot)
        pane.feed(Data([7]))
        try await wait("partial captured OSC completed live") { board.string(forType: .string) == "copied ✓" }
        pane.feed(replay, kind: .snapshot)
        try await settle()
        XCTAssertNil(owner.preparedAlert)
        _ = try await command(["set-option", "-s", "set-clipboard", "on"])
        let clipboardMode = try await command(["show", "-sv", "get-clipboard"])
        XCTAssertEqual(clipboardMode, clipboardModeBeforeAttach)
        _ = try await command(["set-buffer", "stale-tmux-buffer"])
        let script = directory.appendingPathComponent("clipboard.py")
        let result = directory.appendingPathComponent("clipboard-reply")
        let ready = directory.appendingPathComponent("clipboard-ready")
        board.clearContents()
        board.setString("before-live", forType: .string)
        let program = clipboardQueryScript(ready: ready.path, result: result.path, selector: "p", deadline: 12)
        try program.write(to: script, atomically: true, encoding: .utf8)
        _ = try await command(["respawn-pane", "-k", "-t", pane.pane.description, "printf '\\033]52;c;\(copy)\\007'; exec /usr/bin/python3 " + script.path])
        try await wait("OSC52 private pane printf live copy") { board.string(forType: .string) == "copied ✓" }
        _ = try await command(["set-buffer", "stale-tmux-buffer"])
        try Data().write(to: ready)
        try await wait("OSC52 private pane consent sheet") { owner.preparedAlert != nil }
        let alert = try XCTUnwrap(owner.preparedAlert?.alert)
        XCTAssertEqual(alert.messageText, "Allow applications on “Local” to read your Mac clipboard?")
        XCTAssertEqual(alert.informativeText, "This also permits applications reached through SSH inside its panes.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Allow for this connection", "Always allow", "Deny"])
        let text = "named ✓\nclipboard"
        board.clearContents()
        board.setString(text, forType: .string)
        owner.respondToAlert(.alertFirstButtonReturn)
        try await wait("OSC52 reply received in original private pane") { FileManager.default.fileExists(atPath: result.path) }
        let expected = Data("\u{1b}]52;p;\(Data(text.utf8).base64EncodedString())\u{1b}\\".utf8)
        XCTAssertEqual(try Data(contentsOf: result), expected)
        let buffer = try await command(["show-buffer"])
        XCTAssertEqual(buffer, "stale-tmux-buffer")
        print("OSC52 E2E private pane: live write changed named board; consented p read returned exactly one named-board reply, not seeded tmux buffer")
    }

    func testServerProtocolFields() throws {
        for stamp in ["null", "\"0.9\"", "\"1.0\"", "\"2.0\""] {
            let server = try JSONDecoder().decode(Server.self, from: Data("{\"tmux\":\"/bin/kido-tmux\",\"socket\":\"/tmp/private/socket\",\"protocol\":\"1.1\",\"server\":\(stamp)}".utf8))
            XCTAssertEqual(server.binaryProtocol, .required)
            XCTAssertFalse(server.protocolVersion?.compatible == true)
            XCTAssertEqual(server.protocolVersion?.description, stamp == "null" ? nil : String(stamp.dropFirst().dropLast()))
        }
    }

    func testMismatchAlertCases() throws {
        let remote = Kido.Host.remote("dev@buildbox")
        for (host, stamp, binary, title, body) in [
            (Kido.Host.local, nil, nil, "Restart the local kido server", "This server was started by an older kido. Restart it to use the kido bundled with this app."),
            (.local, "0.9", nil, "Restart the local kido server", "This server was started by an older kido. Restart it to use the kido bundled with this app."),
            (.local, "2.0", nil, "This server needs a newer Kido.app", "This local server was started by a newer Kido.app. Update the app, or restart the server using this bundle. Restarting ends all its sessions and panes."),
            (remote, nil, nil, "Update kido on dev@buildbox", "The host is running an older kido server that this app cannot connect to. Upgrade kido on the host and restart its server, then reconnect."),
            (remote, "0.9", "0.9", "Update kido on dev@buildbox", "The host is running an older kido server that this app cannot connect to. Upgrade kido on the host and restart its server, then reconnect."),
            (remote, "2.0", "2.0", "Update Kido.app to connect", "The server on dev@buildbox is newer than this app supports. Update Kido.app, then reconnect."),
            (remote, "1.0", "2.0", "Update Kido.app to connect", "kido on dev@buildbox is newer than this app supports, but its running server still uses the older version. Update Kido.app, then restart that server and reconnect."),
            (remote, nil, "2.0", "Update Kido.app to connect", "kido on dev@buildbox is newer than this app supports, but its running server still uses the older version. Update Kido.app, then restart that server and reconnect."),
            (remote, "0.9", "2.0", "Update Kido.app to connect", "kido on dev@buildbox is newer than this app supports, but its running server still uses the older version. Update Kido.app, then restart that server and reconnect."),
            (remote, "0.9", "1.1", "Restart kido on dev@buildbox", "kido was updated on the host, but its running server still uses the older version. Restart that server, then reconnect.")
        ] as [(Kido.Host, String?, String?, String, String)] {
            let alert = WindowOwner.mismatchAlert(host: host, server: stamp.flatMap(RPCVersion.init), binary: binary.flatMap(RPCVersion.init))
            XCTAssertEqual(alert.messageText, title)
            let showBinary = host != .local && (binary == "1.1" || binary == "2.0" && binary != stamp)
            XCTAssertEqual(alert.informativeText, body + "\n\nCompatibility: this app needs protocol 1.1 or later within major 1. Server: \(stamp ?? "unstamped (older kido)")." + (showBinary ? " Host binary: \(binary!)." : "") + " Protocol numbers are not Kido.app release numbers.")
            XCTAssertEqual(alert.buttons.map(\.title), [host == .local ? "Restart…" : "Reconnect", "Close"])
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        }
    }

    func testPrivateServerRPCAndProtocolSheet() async throws {
        let endpointOutput = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        XCTAssertEqual(endpointOutput.status, 0, endpointOutput.err)
        let endpoint = try JSONDecoder().decode(Server.self, from: Data(endpointOutput.out.utf8))
        XCTAssertEqual(endpoint.protocolVersion, .required)
        XCTAssertEqual(endpoint.binaryProtocol, .required)
        try await start()
        _ = try await command(["new-window", "-d", "-t", "visual", "-n", "second", "exec /bin/cat"])
        var snapshots = 0
        let feed = Feed(serverDir: directory.path, locate: connection.locateFeed, query: { "" }, onChange: { status in
            if case .running = status { snapshots += 1 }
        })
        defer { feed.stop() }
        try await wait("private RPC hello and snapshot") { snapshots > 0 }
        let switched = expectation(description: "private RPC switch reply")
        feed.switchTarget(.window, next: true) { target, error in
            XCTAssertNil(error)
            XCTAssertNotNil(target)
            print("RPC E2E switched: \(target?.session.description ?? "nil") \(target?.window.description ?? "nil")")
            switched.fulfill()
        }
        await fulfillment(of: [switched], timeout: 5)
        feed.stop()
        _ = try await command(["set-environment", "-gu", "KIDO_PROTOCOL"])
        var refused = false
        let unstamped = Feed(serverDir: directory.path, locate: connection.locateFeed, query: { "" }, onChange: { status in
            if case .protocolMismatch(let version, let binary) = status { XCTAssertNil(version); XCTAssertEqual(binary, .required); refused = true }
        })
        defer { unstamped.stop() }
        try await wait("unstamped RPC refusal") { refused }
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        let unstampedOutput = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        owner.testEndpoint = Endpoint(server: try JSONDecoder().decode(Server.self, from: Data(unstampedOutput.out.utf8)), kido: tools.kido)
        defer { owner.close() }
        owner.start()
        try await wait("unstamped local Restart alert") { owner.preparedAlert != nil }
        XCTAssertNil(owner.window.attachedSheet)
        XCTAssertTrue(owner.testBanner.isHidden)
        XCTAssertEqual(owner.sidebar.content.layer?.backgroundColor, runtime.background.cgColor)
        XCTAssertEqual(owner.sidebar.view.layer?.backgroundColor, runtime.background.cgColor)
        XCTAssertEqual(owner.window.backgroundColor, runtime.background)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: owner.sidebar.content, as: .image, named: "no-terminal", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        let mismatch = try XCTUnwrap(owner.preparedAlert?.alert)
        XCTAssertEqual(mismatch.messageText, "Restart the local kido server")
        XCTAssertEqual(mismatch.buttons.map(\.title), ["Restart…", "Close"])
        XCTAssertTrue(mismatch.window.defaultButtonCell === mismatch.buttons[0].cell)
        owner.respondToAlert(.alertFirstButtonReturn)
        let confirmation = try XCTUnwrap(owner.preparedAlert?.alert)
        XCTAssertEqual(confirmation.messageText, "Restart the local server?")
        XCTAssertEqual(confirmation.buttons.map(\.title), ["Cancel", "Restart"])
        XCTAssertTrue(confirmation.buttons[1].hasDestructiveAction)
        XCTAssertTrue(confirmation.window.defaultButtonCell === confirmation.buttons[0].cell)
        XCTAssertTrue(confirmation.window.initialFirstResponder === confirmation.buttons[0])
        owner.respondToAlert(.alertFirstButtonReturn)
        XCTAssertEqual(owner.preparedAlert?.alert.messageText, mismatch.messageText)
        owner.respondToAlert(.alertSecondButtonReturn)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertFalse(owner.testBanner.isHidden)
        XCTAssertNil(owner.testConnection)
        owner.start()
        try await wait("Reconnect repeats incompatible check") { owner.preparedAlert != nil }
        XCTAssertNil(owner.window.attachedSheet)
        XCTAssertNil(owner.testConnection)
        XCTAssertFalse(owner.window.isVisible || owner.window.isKeyWindow || owner.window.isMainWindow || NSApp.isActive)
        print("RPC E2E hello 1.1; unstamped server refused; local mismatch alert prepared off-screen")
    }

    func testSidebarHeadersKeysAndAccessibility() throws {
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
            cell.configure(row)
            XCTAssertNil(cell.toolTip)
            XCTAssertNil(cell.addWindow.toolTip)
            XCTAssertTrue(cell.accessibilityLabel()?.contains(row.indicatorDescription) == true)
            XCTAssertEqual(cell.focusRingType, .none)
            XCTAssertEqual(cell.addWindow.focusRingType, .none)
            XCTAssertEqual((cell.addWindow.cell as? NSButtonCell)?.highlightsBy, [])
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testClockWidthChangeInvalidatesTitle() throws {
        let fixture = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            var nodes = sessions[0]["nodes"] as! [[String: Any]]
            var children = nodes[0]["children"] as! [[String: Any]]
            children[0]["title"] = [["text": String(repeating: "Long title ", count: 20), "role": "plain"]]
            nodes[0]["children"] = children
            sessions[0]["nodes"] = nodes
            object["sessions"] = sessions
        }
        let row = try XCTUnwrap(sidebarRows(fixture).first { $0.started != nil })
        let started = try XCTUnwrap(row.started)
        let cell = SidebarCell(SidebarFonts())
        cell.frame = NSRect(x: 0, y: 0, width: 292, height: 32)
        defer { SidebarView.visualNow = nil }
        for (before, after) in [(9.0, 10.0), (59.0, 60.0), (3599.0, 3600.0)] {
            SidebarView.visualNow = started.addingTimeInterval(before)
            cell.configure(row)
            SidebarView.visualNow = started.addingTimeInterval(after)
            cell.updateClock()
            XCTAssertEqual(cell.visualClockDirtyRect.minX, 36 + CGFloat(row.indent) * 21,
                           "width-changing tick must invalidate the title’s truncation edge")
        }
        SidebarView.visualNow = started.addingTimeInterval(11)
        cell.configure(row)
        SidebarView.visualNow = started.addingTimeInterval(12)
        cell.updateClock()
        XCTAssertGreaterThan(cell.visualClockDirtyRect.minX, 200, "equal-width tick must remain clock-only")
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
        let selectedBeforeNil = list.visualTable.selectedRow
        let originBeforeNil = list.visualScroll.contentView.bounds.origin
        list.completedNavigation(to: nil)
        XCTAssertEqual(list.visualTable.selectedRow, selectedBeforeNil)
        XCTAssertEqual(list.visualScroll.contentView.bounds.origin, originBeforeNil)
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
        list.update(.running(fixture))
        XCTAssertTrue(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) })
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
