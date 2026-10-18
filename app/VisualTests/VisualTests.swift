import AppKit
import GhosttyKit
import SnapshotTesting
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

func clipboardQueryScript(ready: String, result: String, query: String, deadline: Int) -> String {
    """
    import os, select, time, tty
    tty.setraw(0)
    deadline = time.monotonic() + 5
    while not os.path.exists('\(ready)') and time.monotonic() < deadline: time.sleep(0.02)
    os.write(1, b'\(query)')
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
    func observeFrames(_ layer: CALayer, _ frame: @escaping @MainActor () -> Void) -> NSKeyValueObservation {
        layer.observe(\.contents, options: .new) { layer, _ in
            guard layer.contents != nil else { return }
            MainActor.assumeIsolated { frame() }
        }
    }

    func mainQueueFence() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func drain(_ runtime: GhosttyRuntime) async throws {
        var quiet = 0
        for _ in 0..<20 where quiet < 3 {
            ghostty_app_tick(runtime.app)
            let wakeups = runtime.visualWakeups
            await mainQueueFence()
            quiet = runtime.visualWakeups == wakeups ? quiet + 1 : 0
        }
    }

    func wait(_ description: String, within seconds: Double = 20, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let done = expectation(description: description)
        var finished = false
        func finish() { if !finished { finished = true; done.fulfill() } }
        @MainActor func poll() {
            if finished { return }
            if predicate() { finish() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { poll() } }
        }
        // One block at the original deadline, never a poll's own clock check: after a main-queue stall,
        // main-queue timers due earlier than this deadline still run before the verdict.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if !finished { if !predicate() { XCTFail("Timed out: \(description)") }; finish() }
        }
        poll()
        await fulfillment(of: [done], timeout: seconds + 1)
    }

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

    func sidebarFixture(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Snapshot {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/live-feed.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
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
    var directory: URL!
    var window: NSWindow!
    private static var processRuntime: GhosttyRuntime?
    var runtime: GhosttyRuntime!
    private var session: SessionView!
    var connection: Connection!
    private var model = SessionModel()
    private var tabSnapshot: Snapshot?
    private var rpc: Feed?

    func testBackgroundLaunchIsNotActivatable() {
        XCTAssertTrue(background)
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited, "a background launch must not be activatable")
    }

    func testVsyncMeasurement() async throws {
        guard ProcessInfo.processInfo.environment["KIDO_VSYNC_MEASURE"] == "1" else { throw XCTSkip("authorized on-screen measurement only") }
        try await start()
        NSApp.setActivationPolicy(.regular)
        PaneView.renderOffscreen = false
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("private measurement window is unoccluded") { self.window.occlusionState.contains(.visible) }
        let pane = try XCTUnwrap(terminal?.panes.first)
        let driver = try XCTUnwrap(pane.visualVsync)
        ghostty_surface_set_focus(pane.surface, true)
        var report = "host pid=\(getpid()), display=\(window.screen?.localizedName ?? "none"), maximum=\(window.screen?.maximumFramesPerSecond ?? 0)Hz\n"
        func stats(_ name: String, _ values: [Double], period: Double) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { XCTFail("\(name): no measurement samples"); return "\(name): NO SAMPLES\n" }
            let quantiles = [0.5, 0.95, 0.99].map { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * $0))] * 1000 }
            var missed: [Int: Int] = [:]
            for value in values { let multiple = Int((value / period).rounded()); if multiple > 1 { missed[multiple, default: 0] += 1 } }
            return "\(name): n=\(values.count) median/p95/p99_ms=\(quantiles), missed multiples=\(missed)\n"
        }
        for bursts in [false, true] {
            var timestamps: [Double] = []
            var periods: [Double] = []
            var installations: [Double] = []
            let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { installations.append(CACurrentMediaTime()) }
            driver.visualTick = { timestamp, target in
                timestamps.append(timestamp)
                periods.append(target - timestamp)
                if timestamps.count % 10 == 0, let event = pane.wheelEvent(y: timestamps.count % 20 == 0 ? -1 : 1) { pane.scrollWheel(with: event) }
                if bursts && timestamps.count % 30 == 0 { Thread.sleep(forTimeInterval: [0.002, 0.004, 0.008, 0.016][(timestamps.count / 30) % 4]) }
            }
            try await command(["respawn-pane", "-k", "-t", "%0", "python3 -u -c 'import time; end=time.monotonic()+6; print(\"\\033[?25h\"); i=0\nwhile time.monotonic()<end: print(i); i+=1; time.sleep(0.004)\nprint(\"\\033[?25l\"); time.sleep(30)'"])
            try await Task.sleep(for: .seconds(6.5))
            driver.visualTick = nil
            observation.invalidate()
            XCTAssertGreaterThan(timestamps.count, 30)
            let period = periods.sorted().dropFirst(periods.count / 2).first ?? 0
            report += "bursts=\(bursts), actual link period_ms=\(period * 1000), rate=\(period > 0 ? 1 / period : 0)Hz, creates=\(driver.creates), jobs=\(driver.jobs), visible=\(window.isVisible), occlusion=\(window.occlusionState.contains(.visible)), hidden=\(pane.isHiddenOrHasHiddenAncestor)\n"
            XCTAssertEqual(period, 1 / 120, accuracy: 0.0007, "window's actual link period must confirm 120Hz")
            report += stats("link intervals", zip(timestamps.dropFirst(), timestamps).map { $0.0 - $0.1 }, period: max(period, 0.001))
            report += stats("IOSurface contents intervals (NOT physical presentation)", zip(installations.dropFirst(), installations).map { $0.0 - $0.1 }, period: max(period, 0.001))
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(driver.hasLink)
        let ticks = driver.ticks
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(driver.hasLink)
        XCTAssertEqual(driver.ticks, ticks)
        report += "active→idle: total ticks=\(ticks), settled link=\(driver.hasLink), ticks delta=\(driver.ticks - ticks) over 3s\n"
        try report.write(toFile: "/tmp/kido-vsync-measure-\(getpid()).txt", atomically: true, encoding: .utf8)
        print(report)
    }

    private func updateTabs(_ status: Feed.Status? = nil) {
        if case .running(let snapshot) = status { tabSnapshot = snapshot }
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
        rpc?.stop()
        rpc = nil
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

    @discardableResult func command(_ args: [String]) async throws -> String {
        let (status, out, err) = try await Child.run(tmux, ["-S", socket] + args)
        XCTAssertEqual(status, 0, "\(args): \(err)")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func fakeFeedScript(_ scratch: URL, _ python: String) throws -> URL {
        let script = scratch.appendingPathComponent("kido")
        try ("#!/bin/sh\nexec python3 -u -c '\n" + python + "\n'\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    var terminal: WindowView? { session?.windows.values.first { !$0.isHidden } }

    private func loadRuntime() throws {
        if Self.processRuntime == nil {
            let config = directory.appendingPathComponent("ghostty.conf")
            let themes = app.appendingPathComponent("Resources/themes").path
            let theme = "light:\(themes)/kido-light,dark:\(themes)/kido-dark"
            let blink = ProcessInfo.processInfo.environment["KIDO_VSYNC_MEASURE"] == "1"
            try "theme = \(theme)\nfont-family = Menlo\nfont-size = 13\ncursor-style-blink = \(blink)\nkeybind = super+e=text:X\nkeybind = super+shift+c=text:Y\n".write(to: config, atomically: true, encoding: .utf8)
            Self.processRuntime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))))
        }
        runtime = try XCTUnwrap(Self.processRuntime)
    }

    private func sidebarOwner() throws -> WindowOwner {
        try loadRuntime()
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        addTeardownBlock { @MainActor in owner.close() }
        return owner
    }

    @discardableResult func start(height: CGFloat = 560, dark: Bool = false, history: Int = 1000) async throws -> String {
        NSApp.appearance = NSAppearance(named: .aqua)
        try loadRuntime()
        window = OwnerWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: height),
                             styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .displayP3
        session = SessionView(runtime: runtime)
        session.onPaneChange = { [weak self] in self?.updateTabs() }
        session.frame = NSRect(x: 0, y: 0, width: 700, height: height)
        window.contentView = session
        let tmuxConfig = directory.appendingPathComponent("tmux.conf")
        try "set -g history-limit \(history)\nset -s get-clipboard request\n".write(to: tmuxConfig, atomically: true, encoding: .utf8)
        let endpoint = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        XCTAssertEqual(endpoint.status, 0, endpoint.err)
        _ = try await command(["source-file", tmuxConfig.path])
        _ = try await command(["rename-session", "-t", "$0", "visual"])
        _ = try await command(["rename-window", "-t", "@0", "zsh"])
        _ = try await command(["respawn-pane", "-k", "-t", "%0", "exec /bin/cat"])
        _ = try await command(["clear-history", "-t", "%0"])
        let clipboardMode = try await command(["show", "-sv", "get-clipboard"])
        connection = try Connection(server: Server(tmux: tmux, socket: socket, stamp: ServerStamp("visual"), expected: ServerStamp("visual")), view: session,
                                    onChange: { [weak self] model in
                                        self?.session.show(model.window)
                                        self?.model = model
                                        self?.updateTabs()
                                    },
                                    onDiagnostic: { XCTFail($0) }, onClose: { _, _ in })
        try await wait("initial layout") { self.terminal?.panes.isEmpty == false }
        rpc = Feed(serverDir: directory.path, locate: connection.locateFeed, onChange: { _ in })
        try await wait("RPC ready") { if case .running? = self.rpc?.status { return true }; return false }
        connection.navigate = { [weak self] command in
            guard let self else { return }
            switch command {
            case .window(let step):
                switch step {
                case .next: rpc?.request(.switchWindow(next: true)) { _ in }
                case .previous: rpc?.request(.switchWindow(next: false)) { _ in }
                default: if let request = model.navigation(tabSnapshot).model.select(step) { rpc?.request(request) { _ in } }
                }
            case .newWindow: if let window = model.window { rpc?.request(.newWindow(window)) { _ in } }
            default: break
            }
        }
        try await settle()
        if dark { try await darken() }
        return clipboardMode
    }

    func darken() async throws {
        let changed = expectation(description: "appearance config changed")
        runtime.onConfigChange = { [weak self] in self?.session.updateBackground(); changed.fulfill() }
        runtime.onColorSchemeChange = { [weak self] in self?.session.updateColorScheme() }
        window.appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await fulfillment(of: [changed], timeout: 20)
        try await settle()
    }

    func settle() async throws {
        try await wait("authoritative restore and presented frame") {
            guard let terminal = self.terminal else { return false }
            return terminal.visualGeometryReady && !terminal.panes.isEmpty && terminal.panes.filter { !$0.isHidden }.allSatisfy(\.visualReady)
        }
    }

    func paint(lines: Int? = nil, alternate: Bool = false) async throws {
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

    func snapshot(_ name: String, pill: Bool = false, testName: String = #function) async throws {
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
            rpc?.request(command) { if case .failure(let error) = $0 { XCTFail(error.message) } }
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
        func fixture(_ status: String = "waiting", review: String = "Review changes") throws -> Snapshot {
            func item(_ pane: [String], children: [[String: Any]] = [], status: String = "idle") -> [String: Any] {
                let state: [Any] = switch status {
                case "waiting": ["Waiting", ["kind": NSNull(), "progress": NSNull()]]
                case "failed", "done": ["Idle", ["outcome": ["serial": 1, "result": status == "done" ? "success" : "failure"]]]
                default: ["Idle", ["outcome": NSNull()]]
                }
                return ["kind": "pane", "run": pane[0] == child ? "agent" as Any : NSNull(), "started": NSNull(), "id": pane[1], "pane": pane[1], "window": pane[0],
                        "program_status": ["serial": 0, "records": []], "title": pane[0] == middle ? (pane[1] == secondPane ? review : "Agent caption") : pane[0] == last ? "Build output" : "Shell prompt",
                        "lifecycle": pane[0] == child ? agentLifecycle(state) : shellLifecycle(), "children": children]
            }
            let nodes: [[String: Any]] = [item(shell),
                ["kind": "window", "id": middle, "window": middle, "name": "Editor",
                 "children": panes.filter { $0[0] == middle }.enumerated().map { i, pane in
                     item(pane, children: i == 0 ? [item([child, childPane], status: status)] : [])
                 }], item(try XCTUnwrap(panes.first { $0[0] == last }))]
            let object: [String: Any] = ["v": 2, "client": ["session": "$0", "window": child, "pane": childPane],
                "server_instance": ["started_at": 1791000000, "pid": 4242], "sessions": [["id": "$0", "name": "visual", "current": true,
                    "nodes": nodes]]]
            return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        updateTabs(.running(try fixture()))
        XCTAssertEqual(sidebar.tabs.entries.map(\.name), ["Shell prompt", "Review changes", "Build output"])
        let firstPane = try XCTUnwrap(panes.first { $0[0] == middle && $0[1] != secondPane })[1]
        let beforePaneChange = model
        _ = try await command(["select-pane", "-t", firstPane])
        try await wait("inactive window pane title") { sidebar.tabs.entries[1].name == "Agent caption" }
        XCTAssertEqual(model, beforePaneChange)
        _ = try await command(["select-pane", "-t", secondPane])
        try await wait("inactive window pane restored") { sidebar.tabs.entries[1].name == "Review changes" }
        updateTabs(.running(try fixture(review: "Review updated")))
        XCTAssertEqual(sidebar.tabs.entries[1].name, "Review updated")
        XCTAssertEqual((sidebar.tabs.accessibilityChildren()?[1] as? NSAccessibilityElement)?.accessibilityLabel(), "Window: Review updated — waiting")
        updateTabs(.running(try fixture()))
        XCTAssertEqual(sidebar.tabs.entries.map(\.status), [.quiet, .waiting, .quiet])
        updateTabs(.running(try fixture("failed")))
        XCTAssertEqual(sidebar.tabs.entries[1].status, .error)
        updateTabs(.running(try fixture()))
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
        sidebar.tabs.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
        try await wait("middle tab selected") { self.model.window?.description == middle }
        let current = try await command(["display-message", "-p", "-t", "visual", "#{window_id}"])
        XCTAssertEqual(current, middle)
        let restoredPane = try await command(["display-message", "-p", "-t", middle, "#{pane_id}"])
        XCTAssertEqual(restoredPane, secondPane)
        connection.send([Command("select-window", "-t", shell[0])])
        try await wait("first window selected") { self.model.window?.description == shell[0] }
        let menus = SessionMenus()
        menus.send = { [weak self] request in self?.rpc?.request(request) { if case .failure(let error) = $0 { XCTFail(error.message) } } }
        menus.update(model.navigation(tabSnapshot).model)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        XCTAssertTrue(menus.window.performKeyEquivalent(with: key))
        try await wait("Cmd-2 selects second tab") { self.model.window?.description == middle }
        XCTAssertEqual(model.navigation(tabSnapshot).model.select(.number(2)), RPCRequest.selectWindow(SessionID(number: 0), WindowID(middle)!))
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
        updateTabs(.running(try fixture("done")))
        XCTAssertEqual(sidebar.tabs.entries[1].status, .done)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: try headerImage(sidebar.tabs), as: .image, named: "middle", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        sidebar.isCollapsed = true
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        XCTAssertGreaterThanOrEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root).minX, 116)
        await mainQueueFence()
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
        _ = try await command(["switch-client", "-t", "other"])
        rpc?.request(pendingSelection) { result in
            if case .failure(let error) = result { XCTFail(error.message) }
            selected.fulfill()
        }
        await fulfillment(of: [selected], timeout: 20)
        let appClient: String = try await withCheckedThrowingContinuation { continuation in
            connection.locateFeed { continuation.resume(with: $0) }
        }
        let selectedSession = try await command(["display-message", "-p", "-c", appClient, "#{session_id}:#{window_id}"])
        XCTAssertEqual(selectedSession, "$0:\(middle)")
        try await wait("pending selection returns to its own session") { self.model.session == SessionID(number: 0) && self.model.window?.description == middle }
        XCTAssertEqual(connection.visualCommands.filter { $0.line.hasPrefix("switch-client") }.count, 0)
        connection.send([Command("switch-client", "-t", "other")])
        try await wait("current session tabs only") { self.model.windows.map(\.name) == ["Other session"] }
        connection.send([Command("switch-client", "-t", "visual")])
        try await wait("session switched back") { self.model.windows.map(\.name) == ["Shell", "Renamed"] }
        _ = try await command(["kill-session", "-t", "other"])
        sidebar.tabs.removeFromSuperview()
    }

    func testPaneDragExcludesReorderGestures() async throws {
        try await start()
        _ = try await command(["split-window", "-d", "-t", "%0", "exec /bin/cat"])
        try await wait("two panes") { self.terminal?.panes.count == 2 }
        let view = try XCTUnwrap(terminal), pane = try XCTUnwrap(view.panes.first?.pane)
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
        owner.request = { [weak self] in self?.rpc?.request($0, completed: $1) }
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
        let object: [String: Any] = ["v": 2, "client": ["session": "$0", "window": connection.model.window!.description, "pane": row.pane.description],
            "server_instance": ["started_at": 1791000000, "pid": 4242],
            "sessions": [["id": "$0", "name": "visual", "current": true, "nodes": [["kind": "pane", "id": row.pane.description,
                "pane": row.pane.description, "window": connection.model.window!.description, "program_status": ["serial": 0, "records": []], "title": "Terminal",
                "lifecycle": shellLifecycle(), "run": NSNull(), "started": NSNull(), "children": []]]]]]
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
        try await wait("RPC release returns focus") { !sidebar.isFloating && self.window.firstResponder is PaneView }
        XCTAssertFalse(sidebar.isFloating)
        XCTAssertTrue(window.firstResponder is PaneView)
        try key()
        XCTAssertTrue(sidebar.isFloating)
        XCTAssertTrue(sidebar.list.containsFocus)
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
        XCTAssertEqual(connection.visualCommands.filter { $0.line.hasPrefix("switch-client") }.count, 0)
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
        let scrollerAlpha = pane.scroller.alphaValue
        pane.scroller.alphaValue = 0
        XCTAssertFalse(terminal.paneCursorRects.contains { $0.1 === NSCursor.pointingHand && $0.0.intersects(strip) })
        pane.scroller.alphaValue = scrollerAlpha
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
            await mainQueueFence()
        }
        try await drain(runtime)
        let fenced = expectation(description: "client queue fenced")
        connection.send([Command("display-message", "-p", "")]) { _ in fenced.fulfill() }
        await fulfillment(of: [fenced], timeout: 2)
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

    func hover(_ pane: PaneView, _ inside: Bool) async throws {
        let chrome = try XCTUnwrap(terminal?.subviews.compactMap { $0 as? PaneChrome }.first { $0.pane == pane.pane })
        let ended = chrome.subviews.compactMap { $0 as? PaneToolbar }.first?.visualAnimationsEnded ?? 0
        let point = inside ? NSPoint(x: chrome.toolbarFrame.midX, y: chrome.toolbarFrame.maxY + 4) : NSPoint(x: 20, y: chrome.bounds.maxY - 20)
        chrome.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: chrome.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        try await wait("toolbar fade settled", within: 2) {
            guard let toolbar = chrome.subviews.compactMap({ $0 as? PaneToolbar }).first else { return true }
            return toolbar.visualAnimationsEnded > ended && (inside ? toolbar.alphaValue == 1 : toolbar.alphaValue == 0)
        }
    }

    func testHistoryPill() async throws { try await historyPill(dark: false) }
    func testHistoryPillDark() async throws { try await historyPill(dark: true) }

    private func historyPill(dark: Bool, testName: String = #function) async throws {
        let fade = WindowView.toolbarFadeDuration
        WindowView.toolbarFadeDuration = 0
        defer { WindowView.toolbarFadeDuration = fade }
        try await start(dark: dark, history: 100000)
        try await paint(lines: historyChunkSize + 1000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        pane.requestScroll(historyChunkSize)
        try await wait("Load more visible") { pane.visualPill }
        try await snapshot("history-top", pill: true, testName: testName)
        try await hover(pane, true)
        try await snapshot("history-toolbar", pill: true, testName: testName)
    }

    private func agentLifecycle(_ state: [Any], msg: Any = NSNull()) -> [Any] {
        ["Live", ["Pi_agent", ["id": "session", "status": ["since": 1791131000, "msg": msg, "state": state]]]]
    }

    private func shellLifecycle(_ last: Any = NSNull()) -> [Any] { ["Live", ["Terminal", ["phase": ["Idle", ["last": last]], "report": NSNull()]]] }

    private func sidebarSnapshot(_ list: SidebarView, _ name: String, testName: String = #function) {
        window.layoutIfNeeded()
        list.layoutSubtreeIfNeeded()
        list.visualTable.tile()
        list.visualTable.layoutSubtreeIfNeeded()
        list.displayIfNeeded()
        CATransaction.flush()
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

    func testCaptionDisplayDelay() async throws {
        func fixture(_ caption: String) throws -> Snapshot {
            try sidebarFixture { object in
                var sessions = object["sessions"] as! [[String: Any]]
                var nodes = sessions[0]["nodes"] as! [[String: Any]]
                nodes[0]["lifecycle"] = agentLifecycle(["Running", ["progress": NSNull()]], msg: caption)
                sessions[0]["nodes"] = nodes
                object["sessions"] = sessions
            }
        }
        let initial = try fixture("")
        let changed = try fixture("Delayed caption")
        let id = try XCTUnwrap(sidebarRows(changed).first { $0.tail == "Delayed caption" }?.id)
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
        XCTAssertEqual(list.visualRows[index].tail, "")
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 32)
        try await wait("caption deadline") { list.visualRows[index].tail == "Delayed caption" }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - shownAt, 0.2)
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 48)
        let hiddenAt = ProcessInfo.processInfo.systemUptime
        list.show(initial)
        XCTAssertEqual(list.visualRows[index].tail, "Delayed caption")
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 48)
        try await wait("caption hide deadline") { list.visualRows[index].tail.isEmpty }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - hiddenAt, 0.2)
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 32)
        list.update(.running(changed))
        XCTAssertEqual(list.visualRows[index].tail, "")
        list.update(.restarting("Reconnect test"))
        list.update(.running(changed))
        XCTAssertEqual(list.visualRows[index].tail, "Delayed caption", "identical reconnect snapshot must show its caption immediately")
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 48)
        list.update(.restarting("Reconnect during drag"))
        list.show(changed, pin: id)
        list.update(.running(try fixture("Reconnected caption")))
        XCTAssertEqual(list.visualRows[index].tail, "Reconnected caption", "drag during reconnect must not seed old captions")
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

    func testProgramRecords() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 680),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.colorSpace = .displayP3
        let list = SidebarView()
        window.contentView = list
        SidebarView.visualNow = Date(timeIntervalSince1970: 1791131198)
        defer { SidebarView.visualNow = nil }
        let fixture = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            var nodes = sessions[0]["nodes"] as! [[String: Any]]
            nodes.insert(["kind": "pane", "id": "%2000", "pane": "%2000", "window": "@2000", "title": "Claude Code",
                          "lifecycle": ["Live", ["Some_agent", ["name": "claude-code", "status": ["since": 1791131000, "msg": NSNull(), "state": ["Running", ["progress": NSNull()]]]]]],
                          "run": NSNull(), "started": NSNull(), "children": [],
                          "program_status": ["serial": 7, "records": [
                            ["id": "", "app": "claude-code", "state": "working"],
                            ["id": "agent-c", "title": "Review accessibility", "state": "working"],
                            ["id": "agent-a/permission", "title": "Approve test command", "state": "blocked", "kind": "permission", "msg": "May I run the integration tests?"],
                            ["id": "agent-b", "title": "Check toolbar geometry", "state": "working"],
                            ["id": "agent-a", "title": "Investigate sidebar layout", "state": "working", "msg": "Comparing native row measurements"]
                          ]]], at: 0)
            sessions[0]["nodes"] = nodes
            object["sessions"] = sessions
            object["client"] = ["session": "$0", "window": "@2000", "pane": "%2000"]
        }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            list.update(.running(fixture))
            sidebarSnapshot(list, dark ? "claude-dark" : "claude-light")
        }
        let programs = list.visualRows.indices.filter { if case .program = list.visualRows[$0].id { true } else { false } }
        XCTAssertEqual(programs.count, 4)
        var requests: [RPCRequest] = []
        list.navigate = { requests.append($0) }
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
            nodes[0]["lifecycle"] = agentLifecycle(["Idle", ["outcome": ["serial": 1, "result": "success"]]])
            var runs = nodes[0]["children"] as! [[String: Any]]
            runs[0]["lifecycle"] = ["Ended", ["result": "completed"]]
            runs[0]["started"] = NSNull()
            nodes[0]["children"] = runs
            children[0]["lifecycle"] = agentLifecycle(["Waiting", ["kind": NSNull(), "progress": NSNull()]],
                                                      msg: "Rebuilding the sidebar cards and testing nested window corners")
            var agents = children[0]["children"] as! [[String: Any]]
            agents[0]["lifecycle"] = agentLifecycle(["Idle", ["outcome": ["serial": 1, "result": "failure"]]])
            children[0]["children"] = agents
            children[1]["lifecycle"] = shellLifecycle(["code": 0, "command": "make -C ../kido-app/app demo", "started_at": 1791131000, "ended_at": 1791131001])
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
        let subtree = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            var nodes = sessions[0]["nodes"] as! [[String: Any]]
            var panes = nodes[1]["children"] as! [[String: Any]]
            var children = panes[0]["children"] as! [[String: Any]]
            children[0]["children"] = [["kind": "pane", "id": "%1990", "pane": "%1990", "window": "@1990", "program_status": ["serial": 0, "records": []],
                                        "title": "review-notes", "lifecycle": agentLifecycle(["Running", ["progress": NSNull()]], msg: "Checking nested activity"),
                                        "run": "agent", "started": 1791131100,
                                        "children": [["kind": "pane", "id": "%1991", "pane": "%1991", "window": "@1991", "program_status": ["serial": 0, "records": []],
                                                      "title": "zsh", "run": NSNull(), "started": NSNull(),
                                                      "lifecycle": shellLifecycle(["code": 0, "command": "true", "started_at": 1791131000, "ended_at": 1791131001]),
                                                      "children": []]]]]
            object["client"] = ["session": "$0", "window": children[0]["window"]!, "pane": children[0]["pane"]!]
            panes[0]["children"] = children
            nodes[1]["children"] = panes
            sessions[0]["nodes"] = nodes
            object["sessions"] = sessions
        }
        XCTAssertEqual(sidebarRows(subtree).filter { $0.focused && $0.target != nil }.map { $0.target!.window },
                       [WindowID(number: 824)])
        list.update(.running(subtree))
        sidebarSnapshot(list, "focused-child-subtree-light")
        window.appearance = NSAppearance(named: .darkAqua)
        sidebarSnapshot(list, "focused-child-subtree-dark")
        window.appearance = NSAppearance(named: .aqua)
        let grouped = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            let nodes = sessions[0]["nodes"] as! [[String: Any]]
            var second = (nodes[1]["children"] as! [[String: Any]])[0], third = nodes[0]
            second["window"] = nodes[0]["window"]
            second["lifecycle"] = agentLifecycle(["Idle", ["outcome": NSNull()]], msg: "Grouped pane activity")
            third["id"] = "%999"; third["pane"] = "%999"
            third["children"] = []; third["title"] = "terminal"; third["lifecycle"] = shellLifecycle()
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
        list.visualTable.keyDown(with: down)
        sidebarSnapshot(list, "three-pane-keyboard-light")
        let header = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        header.addWindow.mouseEntered(with: hover)
        sidebarSnapshot(list, "plus-hover-light")
        header.addWindow.mouseExited(with: hover)
    }

    func testSupersededSidebarReplies() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        let owner = try sidebarOwner()
        let list = owner.sidebar.list
        window.contentView = list
        list.update(.running(try sidebarFixture()))
        var pending: [@MainActor @Sendable (Result<RPCEvent.Reply.Value, Failure>) -> Void] = []
        var left = 0
        owner.request = { _, done in pending.append(done) }
        list.leave = { left += 1 }
        let rows = list.visualRows.filter { $0.target != nil }
        list.focus()
        list.visualTable.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        list.focus()
        pending.removeFirst()(.success(.released))
        XCTAssertEqual(left, 0, "an old Escape must not leave after a newer intent")
        list.focus()
        list.visualJump(rows[0])
        list.focus()
        list.visualJump(rows[1])
        XCTAssertEqual(pending.count, 2, "a newer intent must be able to replace a pending activation")
        guard pending.count == 2 else { return }
        pending[1](.success(.jumped(rows[1].target!)))
        let afterB = left
        pending[0](.success(.jumped(rows[0].target!)))
        XCTAssertEqual(left, afterB, "A completing after B must not act on B's UI")
    }

    func testSameWindowDeferredPaneFocus() async throws {
        try await start()
        let pane = try await command(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", "%0", "exec /bin/cat"])
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        let endpoint = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        owner.testEndpoint = Endpoint(server: try JSONDecoder().decode(Server.self, from: Data(endpoint.out.utf8)), kido: tools.kido)
        defer { owner.close() }
        owner.start()
        try await wait("owner split snapshot") { owner.sidebar.list.visualRows.contains { $0.target?.pane.description == pane } }
        let row = try XCTUnwrap(owner.sidebar.list.visualRows.first { $0.target?.pane.description == pane })
        owner.request = { _, done in done(.success(.jumped(row.target!))) }
        owner.sidebar.list.focus()
        owner.sidebar.list.visualJump(row)
        XCTAssertTrue(owner.sidebar.list.containsFocus, "focus must wait until the pane becomes current")
        let view = try XCTUnwrap(owner.testSession?.windows[row.target!.window])
        view.focus(row.target!.pane)
        XCTAssertEqual((owner.window.firstResponder as? PaneView)?.pane.description, pane, "onPaneChange must consume deferred focus without a topology notification")
        let original = try XCTUnwrap(owner.sidebar.list.visualRows.first { $0.target?.pane == PaneID(number: 0) })
        owner.request = { _, done in done(.success(.jumped(original.target!))) }
        owner.sidebar.list.focus()
        owner.sidebar.list.visualJump(original)
        owner.sidebar.list.focus()
        view.focus(original.target!.pane)
        XCTAssertTrue(owner.sidebar.list.containsFocus, "new focus intent must cancel a deferred pane target")
    }

    func testHeaderCreatesWindowInItsSession() async throws {
        try await start()
        let other = try await command(["new-session", "-d", "-P", "-F", "#{session_id}", "-s", "other", "exec /bin/cat"])
        let current = try await command(["new-window", "-P", "-F", "#{window_id}", "-t", other, "exec /bin/cat"])
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        let endpoint = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        owner.testEndpoint = Endpoint(server: try JSONDecoder().decode(Server.self, from: Data(endpoint.out.utf8)), kido: tools.kido)
        defer { owner.close() }
        owner.start()
        let list = owner.sidebar.list
        try await wait("other session header") { list.visualRows.contains { $0.id == .header(SessionID(other)!) } }
        var requests: [RPCRequest] = []
        owner.request = { request, done in requests.append(request); done(.failure(.terminal("test response"))) }
        let index = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .header(SessionID(other)!) })
        let header = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCell)
        XCTAssertEqual(header.addWindow.accessibilityLabel(), "New window in other")
        header.addWindow.performClick(nil)
        XCTAssertEqual(requests, [.newWindow(WindowID(current)!)], "heading plus must honour that session's current window, not the client's session")
    }

    func testSwitchWindowAndSessionOutputAndReconnect() async throws {
        for navigation in ["switch-window", "switch-session"] {
            let scratch = app.appendingPathComponent("build/sbfix/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let fixture = scratch.appendingPathComponent("feed.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent("VisualTests/Fixtures/live-feed.json")))
            try JSONSerialization.data(withJSONObject: object).write(to: fixture)
            let script = try fakeFeedScript(scratch, """
            import json, sys
            print(json.dumps(dict(hello=dict(protocol="5.0"))))
            snapshot = json.load(open("\(fixture.path)"))
            print(json.dumps(snapshot))
            held = None
            for line in sys.stdin:
                request = json.loads(line)
                if request["id"] == 5: break
                if "\(navigation)" not in request: continue
                direction = request["\(navigation)"]["direction"]
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
            """)
            var starts = 0
            var snapshots = 0
            let feed = Feed(serverDir: scratch.path, locate: { done in
                done(.success("private-client"))
            }, onChange: { status in
                if case .starting = status { starts += 1 }
                if case .running = status { snapshots += 1 }
            })
            feed.testKido = script.path
            defer { feed.stop() }
            try await wait("fake feed ready") { snapshots == 1 }
            let next: RPCRequest = navigation == "switch-window" ? .switchWindow(next: true) : .switchSession(next: true)
            let prev: RPCRequest = navigation == "switch-window" ? .switchWindow(next: false) : .switchSession(next: false)
            let switched = expectation(description: "switch stdout")
            feed.request(next) { result in
                guard case .success(.switched(let target)) = result else { return XCTFail("switch failed") }
                XCTAssertEqual(target?.session, SessionID(number: 3), "navigation must return its own stdout session")
                XCTAssertEqual(target?.window, WindowID(number: 12), "navigation must return its own stdout window")
                switched.fulfill()
            }
            let previous = expectation(description: "previous target")
            feed.request(prev) { result in
                guard case .success(.switched(let target)) = result else { return XCTFail("switch failed") }
                XCTAssertEqual(target?.session, SessionID(number: 1))
                XCTAssertEqual(target?.window, WindowID(number: 5))
                previous.fulfill()
            }
            await fulfillment(of: [switched, previous], timeout: 5)
            let noop = expectation(description: "null target")
            feed.request(next) { result in
                guard case .success(.switched(let target)) = result else { return XCTFail("switch failed") }
                XCTAssertNil(target)
                noop.fulfill()
            }
            let failed = expectation(description: "RPC error")
            feed.request(prev) { result in
                guard case .failure(let error) = result else { return XCTFail("missing error") }
                XCTAssertEqual(error.message, "navigation failed")
                failed.fulfill()
            }
            await fulfillment(of: [noop, failed], timeout: 5)
            let stale = expectation(description: "pending request fails once")
            stale.assertForOverFulfill = true
            feed.request(next) { result in
                guard case .failure = result else { return XCTFail("missing disconnect failure") }
                stale.fulfill()
            }
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
        let program = clipboardQueryScript(ready: ready.path, result: result.path, query: "\\x1b]52;p;?\\x1b\\\\", deadline: 12)
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

    func testServerCompatibilityFields() throws {
        for (stamp, version, compatible) in [
            ("null", "5.0", false), ("\"other\"", "5.0", false),
            ("\"0123456789ab\"", "5.0", true), ("\"0123456789ab\"", "4.0", false)
        ] {
            let json = "{\"tmux\":\"/bin/kido-tmux\",\"socket\":\"/tmp/private/socket\",\"protocol\":\"\(version)\",\"server\":\(stamp),\"expected\":\"0123456789ab\"}"
            let server = try JSONDecoder().decode(Server.self, from: Data(json.utf8))
            XCTAssertEqual(server.compatible, compatible)
        }
    }

    private func localMismatchOwners(_ count: Int, stamp: String = "2.1") async throws -> [WindowOwner] {
        directory = try XCTUnwrap(tools.serverDir.hasPrefix("/tmp/ka-visual-") ? URL(fileURLWithPath: tools.serverDir) : nil, "Native mismatch tests require a private KIDO_APP_SERVER")
        socket = directory.appendingPathComponent("socket").path
        let output = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        XCTAssertEqual(output.status, 0, output.err)
        _ = try await command(["set-environment", "-g", "KIDO_SERVER", stamp])
        var owners: [WindowOwner] = []
        for _ in 0..<count {
            let owner = try sidebarOwner()
            owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            owner.window.orderFront(nil)
            owner.start()
            owners.append(owner)
        }
        try await wait("local mismatch sheets attached") { owners.allSatisfy { $0.window.attachedSheet != nil && $0.preparedAlert != nil } }
        return owners
    }

    func testReorderAgainstPrivateServer() async throws {
        directory = try XCTUnwrap(tools.serverDir.hasPrefix("/tmp/ka-visual-") ? URL(fileURLWithPath: tools.serverDir) : nil, "requires a private KIDO_APP_SERVER")
        socket = directory.appendingPathComponent("socket").path
        let output = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        XCTAssertEqual(output.status, 0, output.err)
        _ = try await command(["rename-session", "-t", "$0", "alpha"])
        let alphaText = try await command(["display-message", "-p", "-t", "alpha:", "#{session_id}"])
        let alpha = try XCTUnwrap(SessionID(alphaText))
        let firstText = try await command(["display-message", "-p", "-t", "alpha:", "#{window_id}"])
        let first = try XCTUnwrap(WindowID(firstText))
        let middleText = try await command(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "alpha", "exec /bin/cat"])
        let middle = try XCTUnwrap(WindowID(middleText))
        let lastText = try await command(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "alpha", "exec /bin/cat"])
        let last = try XCTUnwrap(WindowID(lastText))
        _ = try await command(["new-session", "-d", "-s", "beta", "exec /bin/cat"])
        let betaText = try await command(["display-message", "-p", "-t", "beta:", "#{session_id}"])
        let beta = try XCTUnwrap(SessionID(betaText))
        _ = try await command(["select-window", "-t", middle.description])
        let owner = try sidebarOwner()
        owner.start()
        try await wait("connected") { owner.testConnection != nil && owner.testBanner.isHidden && owner.snapshot != nil }
        owner.perform(.selectWindow(alpha, middle))
        try await wait("client on alpha") { owner.navigation.session == alpha && owner.navigation.windows.count == 3 }
        func roots() -> [WindowID] { owner.snapshot?.sessions.first { $0.id == alpha }?.nodes.map(\.window) ?? [] }
        func settled(_ order: [WindowID]) async throws {
            try await wait("server order \(order)") { owner.reorder.state.pending == nil && roots() == order }
            XCTAssertEqual(owner.sidebar.tabs.entries.map(\.id), order, "tabs follow the snapshot")
            XCTAssertEqual(owner.navigation.windows.map(\.id), order)
            let current = try await command(["display-message", "-p", "-t", "alpha:", "#{window_id}"])
            XCTAssertEqual(current, middle.description, "the session's current window is unchanged")
        }
        XCTAssertEqual(roots(), [first, middle, last])
        XCTAssertEqual(owner.snapshot?.sessions.map(\.id), [alpha, beta])

        owner.sidebar.list.move(.session(beta, relativeTo: alpha, .before))
        try await wait("session order") { owner.reorder.state.pending == nil && owner.snapshot?.sessions.map(\.id) == [beta, alpha] }
        XCTAssertEqual(owner.navigation.sessions.map(\.id), [beta, alpha])

        try await wait("middle displayed") { owner.testSession?.windows[middle]?.isHidden == false }
        var displayed: [WindowID] = []
        owner.testSession?.visualShown = { displayed.append($0) }
        var replied = false
        let request = owner.request
        owner.request = { message, done in request(message) { done($0); replied = true } }
        owner.sidebar.tabs.move(.window(alpha, middle, relativeTo: last, .after))
        XCTAssertEqual(owner.sidebar.tabs.entries.map(\.id), [first, last, middle], "the drop shows at once")
        try await settled([first, last, middle])
        try await wait("reorder reply") { replied }
        try await Task.sleep(for: .milliseconds(300))
        owner.request = request
        XCTAssertEqual(displayed, [], "moving the current window never displays another one")
        XCTAssertEqual(owner.testSession?.windows[middle]?.isHidden, false)
        _ = try await command(["select-window", "-t", first.description])
        try await wait("a real switch is still followed") { owner.testSession?.windows[first]?.isHidden == false }
        XCTAssertEqual(displayed, [first])
        _ = try await command(["select-window", "-t", middle.description])
        try await wait("back to middle") { owner.testSession?.windows[middle]?.isHidden == false }
        owner.sidebar.tabs.move(.window(alpha, last, relativeTo: first, .before))
        try await settled([last, first, middle])

        let rejected = expectation(description: "relative-to-itself reply")
        owner.request(.reorder(.window(alpha, first, relativeTo: first, .before))) { result in
            if case .failure(let error) = result { XCTAssertEqual(error.message, "cannot reorder relative to itself") } else { XCTFail("\(result)") }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 10)

        _ = try await command(["new-session", "-d", "-t", "alpha", "-s", "grouped"])
        try await wait("grouped session reported") { owner.snapshot?.sessions.count == 3 }
        owner.sidebar.tabs.move(.window(alpha, first, relativeTo: middle, .after))
        XCTAssertEqual(owner.sidebar.tabs.entries.map(\.id), [last, middle, first])
        try await settled([last, first, middle])
        XCTAssertEqual(owner.sidebar.list.visualDiagnostic, "cannot reorder windows in a grouped session", "the failure reverts and is shown")
        XCTAssertFalse(owner.window.isVisible || owner.window.isKeyWindow || NSApp.isActive)
    }

    func testReorderHoldYieldsToEverythingElse() async throws {
        directory = try XCTUnwrap(tools.serverDir.hasPrefix("/tmp/ka-visual-") ? URL(fileURLWithPath: tools.serverDir) : nil, "requires a private KIDO_APP_SERVER")
        socket = directory.appendingPathComponent("socket").path
        let output = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        XCTAssertEqual(output.status, 0, output.err)
        _ = try await command(["rename-session", "-t", "$0", "alpha"])
        let alphaText = try await command(["display-message", "-p", "-t", "alpha:", "#{session_id}"])
        let alpha = try XCTUnwrap(SessionID(alphaText))
        for _ in 0..<3 { _ = try await command(["new-window", "-d", "-t", "alpha", "exec /bin/cat"]) }
        _ = try await command(["new-session", "-d", "-s", "beta", "exec /bin/cat"])
        let betaText = try await command(["display-message", "-p", "-t", "beta:", "#{session_id}"])
        let beta = try XCTUnwrap(SessionID(betaText))
        let owner = try sidebarOwner()
        owner.start()
        try await wait("connected") { owner.testConnection != nil && owner.testBanner.isHidden && owner.snapshot != nil }
        let connection = try XCTUnwrap(owner.testConnection)
        let client: String = try await withCheckedThrowingContinuation { continuation in connection.locateFeed { continuation.resume(with: $0) } }
        _ = try await command(["switch-client", "-c", client, "-t", "alpha"])
        try await wait("client on alpha") { owner.navigation.session == alpha && owner.navigation.windows.count == 4 }
        func shown() -> WindowID? { owner.testSession?.windows.first { !$0.value.isHidden }?.key }
        func within(_ seconds: Double, _ predicate: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if predicate() { return true }; try await Task.sleep(for: .milliseconds(20)) }
            return predicate()
        }
        let request = owner.request
        var parked: [() -> Void] = []
        owner.request = { message, done in
            guard case .reorder = message else { return request(message, done) }
            request(message) { result in parked.append { done(result) } }
        }
        func moveCurrent() async throws {
            try await wait("a window is shown") { shown() != nil && shown() == owner.navigation.window }
            let order = owner.navigation.windows.map(\.id), current = try XCTUnwrap(shown())
            if current != order.last { owner.sidebar.tabs.move(.window(alpha, current, relativeTo: order.last!, .after)) }
            else { owner.sidebar.tabs.move(.window(alpha, current, relativeTo: order.first!, .before)) }
            try await wait("the server moved it") { parked.count == 1 }
        }
        func finish() async throws {
            parked.forEach { $0() }
            parked.removeAll()
            try await wait("reorder settled") { owner.reorder.state.pending == nil }
        }

        try await moveCurrent()
        let target = owner.navigation.windows[0].id
        XCTAssertNotEqual(target, shown())
        owner.selectWindow(.number(1))
        let navigated = try await within(1) { shown() == target }
        XCTAssertTrue(navigated, "app navigation shows its window while a reorder reply is outstanding")
        try await finish()

        try await moveCurrent()
        let held = try XCTUnwrap(shown())
        _ = try await command(["kill-window", "-t", held.description])
        let survived = try await within(1) { shown() != nil && shown() != held }
        XCTAssertTrue(survived, "killing the held window shows a survivor, never a blank terminal")
        try await finish()

        try await moveCurrent()
        let away = try XCTUnwrap(shown())
        _ = try await command(["switch-client", "-c", client, "-t", "beta"])
        try await wait("on beta") { owner.navigation.session == beta }
        let other = try XCTUnwrap(owner.navigation.windows.first?.id)
        let windows = try await command(["list-windows", "-t", "alpha", "-F", "#{window_id}"]).split(separator: "\n").map(String.init)
        _ = try await command(["select-window", "-t", try XCTUnwrap(windows.first { $0 != away.description })])
        _ = try await command(["switch-client", "-c", client, "-t", "alpha"])
        let current = try await command(["display-message", "-p", "-t", "alpha:", "#{window_id}"])
        XCTAssertNotEqual(current, away.description)
        let followed = try await within(1) { owner.navigation.session == alpha && shown()?.description == current }
        XCTAssertTrue(followed, "leaving the session drops the hold: shown \(shown().map { "\($0)" } ?? "none"), expected \(current), other \(other)")
        try await finish()

        owner.request = request
        try await wait("a window is shown") { shown() != nil && shown() == owner.navigation.window }
        var displayed: [WindowID] = []
        owner.testSession?.visualShown = { displayed.append($0) }
        let gate = DispatchSemaphore(value: 0)
        await withCheckedContinuation { parked in
            connection.locateFeed { _ in
                parked.resume()
                _ = gate.wait(timeout: .now() + 5)
            }
        }
        owner.request = { message, done in
            request(message) { result in
                done(result)
                if case .reorder = message { gate.signal() }
            }
        }
        let order = owner.navigation.windows.map(\.id), moved = try XCTUnwrap(shown())
        if moved != order.last { owner.sidebar.tabs.move(.window(alpha, moved, relativeTo: order.last!, .after)) }
        else { owner.sidebar.tabs.move(.window(alpha, moved, relativeTo: order.first!, .before)) }
        try await wait("reorder settled") { owner.reorder.state.pending == nil }
        try await Task.sleep(for: .milliseconds(500))
        owner.request = request
        XCTAssertEqual(displayed, [], "a reply that beats the control stream still shows no fallback window")
        XCTAssertEqual(shown(), moved)
        XCTAssertFalse(owner.window.isVisible || owner.window.isKeyWindow || NSApp.isActive)
    }

    func testLocalMismatchNativeRestart() async throws {
        for stamp in ["3.0", "3.2", "4.0"] {
            let owner = try await localMismatchOwners(1, stamp: stamp)[0]
            defer { owner.close() }
            let alert = try XCTUnwrap(owner.preparedAlert?.alert)
            XCTAssertEqual(alert.messageText, "Restart the local kido server")
            XCTAssertTrue(alert.informativeText.contains("different kido build or config"))
            XCTAssertEqual(alert.buttons.map(\.title), ["Restart", "Close"])
            XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
            XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[1].cell)
            XCTAssertTrue(alert.window.initialFirstResponder === alert.buttons[1])
            let pid = try await command(["display-message", "-p", "#{pid}"])
            alert.buttons[0].performClick(nil)
            var secondSheet = false
            try await wait("native Restart connects without a second sheet") {
                if let pending = owner.preparedAlert?.alert, pending !== alert { secondSheet = true }
                return owner.testConnection != nil && owner.testBanner.isHidden
            }
            XCTAssertFalse(secondSheet, "A second restart sheet was prepared")
            XCTAssertNil(owner.preparedAlert)
            XCTAssertNil(owner.window.attachedSheet)
            let current = try await command(["show-environment", "-g", "KIDO_SERVER"])
            XCTAssertEqual(current.count, "KIDO_SERVER=".count + 12)
            let newPID = try await command(["display-message", "-p", "#{pid}"])
            XCTAssertNotEqual(newPID, pid)
        }
    }

    func testLocalMismatchNativeClose() async throws {
        let owner = try await localMismatchOwners(1)[0]
        let alert = try XCTUnwrap(owner.preparedAlert?.alert)
        let pid = try await command(["display-message", "-p", "#{pid}"])
        alert.buttons[1].performClick(nil)
        try await wait("Close dismisses mismatch sheet") { owner.preparedAlert == nil && owner.window.attachedSheet == nil }
        XCTAssertNil(owner.testConnection)
        let stamp = try await command(["show-environment", "-g", "KIDO_SERVER"])
        XCTAssertEqual(stamp, "KIDO_SERVER=2.1")
        let unchangedPID = try await command(["display-message", "-p", "#{pid}"])
        XCTAssertEqual(unchangedPID, pid)
    }

    func testLocalMismatchEscapeCloses() async throws {
        let owner = try await localMismatchOwners(1)[0]
        let alert = try XCTUnwrap(owner.preparedAlert?.alert)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: alert.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(alert.window.performKeyEquivalent(with: escape))
        try await wait("Escape closes local mismatch") { owner.preparedAlert == nil && owner.window.attachedSheet == nil }
        XCTAssertNil(owner.testConnection)
        let stamp = try await command(["show-environment", "-g", "KIDO_SERVER"])
        XCTAssertEqual(stamp, "KIDO_SERVER=2.1")
    }

    func testLocalMismatchNativeRestartOtherWindow() async throws {
        let owners = try await localMismatchOwners(2)
        let alert = try XCTUnwrap(owners[0].preparedAlert?.alert)
        let pid = try await command(["display-message", "-p", "#{pid}"])
        alert.buttons[0].performClick(nil)
        try await wait("both Local windows reconnect after one Restart") {
            owners.allSatisfy { $0.testConnection != nil && $0.testBanner.isHidden && $0.preparedAlert == nil && $0.window.attachedSheet == nil }
        }
        let newPID = try await command(["display-message", "-p", "#{pid}"])
        XCTAssertNotEqual(newPID, pid)
        for owner in owners {
            let connected = expectation(description: "owner connected to the new server PID")
            owner.send([Command("display-message", "-p", "#{pid}")]) { replies in
                guard case .success(let lines)? = replies?.first else { return XCTFail("Owner control client did not reply") }
                XCTAssertEqual(lines, [newPID])
                connected.fulfill()
            }
            await fulfillment(of: [connected], timeout: 5)
        }
        let stamp = try await command(["show-environment", "-g", "KIDO_SERVER"])
        XCTAssertEqual(stamp.count, "KIDO_SERVER=".count + 12)
    }

    func testMismatchAlertCases() throws {
        for host in [Kido.Host.local, .remote("dev@buildbox")] {
            for stamp in [nil, ServerStamp("other")] {
                let alert = WindowOwner.mismatchAlert(host: host, server: stamp, binary: .required)
                XCTAssertEqual(alert.messageText, host == .local ? "Restart the local kido server" : "Restart kido on dev@buildbox")
                XCTAssertTrue(alert.informativeText.contains("different kido build or config"))
                XCTAssertEqual(alert.buttons.map(\.title), [host == .local ? "Restart" : "Reconnect", "Close"])
                XCTAssertEqual(alert.buttons[0].hasDestructiveAction, host == .local)
                if host == .local { XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[1].cell) }
            }
            for version in ["3.1", "5.1"] {
                let alert = WindowOwner.mismatchAlert(host: host, server: ServerStamp("same"), binary: try XCTUnwrap(RPCVersion(version)))
                XCTAssertTrue(alert.informativeText.contains("needs kido RPC 5.0"))
                XCTAssertTrue(alert.informativeText.contains("speaks \(version)"))
                if host != .local && version == "3.1" { XCTAssertTrue(alert.informativeText.contains("Upgrade kido there")) }
                if version == "5.1" { XCTAssertTrue(alert.informativeText.contains("Update Kido.app, then reconnect.")) }
            }
        }
    }

    func testPrivateServerRPCAndProtocolSheet() async throws {
        let endpointOutput = try await Child.run(tools.kido, ["server", "--server", directory.path], env: tools.environment)
        XCTAssertEqual(endpointOutput.status, 0, endpointOutput.err)
        let endpoint = try JSONDecoder().decode(Server.self, from: Data(endpointOutput.out.utf8))
        XCTAssertEqual(endpoint.stamp, endpoint.expected)
        XCTAssertEqual(endpoint.binaryProtocol, .required)
        try await start()
        _ = try await command(["new-window", "-d", "-t", "visual", "-n", "second", "exec /bin/cat"])
        var snapshots = 0
        let feed = Feed(serverDir: directory.path, locate: connection.locateFeed, onChange: { status in
            if case .running = status { snapshots += 1 }
        })
        defer { feed.stop() }
        try await wait("private RPC hello and snapshot") { snapshots > 0 }
        let switched = expectation(description: "private RPC switch reply")
        feed.request(.switchWindow(next: true)) { result in
            guard case .success(.switched(let target)) = result else { return XCTFail("switch failed") }
            XCTAssertNotNil(target)
            print("RPC E2E switched: \(target?.session.description ?? "nil") \(target?.window.description ?? "nil")")
            switched.fulfill()
        }
        await fulfillment(of: [switched], timeout: 5)
        let before = try XCTUnwrap(model.window)
        let cwd = try await command(["display-message", "-p", "-t", before.description, "#{pane_current_path}"])
        let count = model.windows.count
        try XCTUnwrap(terminal?.panes.first).onCommand(.newWindow)
        try await wait("RPC-created window reaches topology") { self.model.windows.count == count + 1 && self.model.window != before }
        let created = try XCTUnwrap(model.window)
        let order = model.windows.map(\.id)
        XCTAssertEqual(order.firstIndex(of: created), order.firstIndex(of: before).map { $0 + 1 })
        let inherited = try await command(["display-message", "-p", "-t", created.description, "#{pane_current_path}"])
        XCTAssertEqual(inherited, cwd)
        let newSession = expectation(description: "RPC new session")
        var location: Snapshot.Position?
        feed.request(.newSession) { result in
            if case .success(.created(let target)) = result { location = target }
            else { XCTFail("new session failed") }
            newSession.fulfill()
        }
        await fulfillment(of: [newSession], timeout: 5)
        let target = try XCTUnwrap(location)
        let selected = expectation(description: "RPC selects session")
        feed.request(.selectSession(target.session)) { result in
            if case .success(.selected(let selected)) = result { XCTAssertEqual(selected, target) }
            else { XCTFail("select session failed") }
            selected.fulfill()
        }
        await fulfillment(of: [selected], timeout: 5)
        let rejected = expectation(description: "invalid jump does not navigate")
        feed.request(.jump(Snapshot.Position(session: target.session, window: before, pane: target.pane))) { result in
            if case .failure = result {} else { XCTFail("invalid membership succeeded") }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 5)
        let unchanged = try await command(["list-clients", "-F", "#{session_id}:#{window_id}"])
        XCTAssertEqual(Set(unchanged.split(separator: "\n").map(String.init)), ["\(target.session):\(target.window)"])
        feed.stop()
        _ = try await command(["set-environment", "-gu", "KIDO_SERVER"])
        var refused = false
        let unstamped = Feed(serverDir: directory.path, locate: connection.locateFeed, onChange: { status in
            if case .protocolMismatch(let stamp, let expected, let binary) = status { XCTAssertNil(stamp); XCTAssertNotNil(expected); XCTAssertEqual(binary, .required); refused = true }
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
        XCTAssertEqual(owner.window.backgroundColor, runtime.background)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: owner.sidebar.content, as: .image, named: "no-terminal", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        let mismatch = try XCTUnwrap(owner.preparedAlert?.alert)
        XCTAssertEqual(mismatch.messageText, "Restart the local kido server")
        XCTAssertEqual(mismatch.buttons.map(\.title), ["Restart", "Close"])
        XCTAssertTrue(mismatch.buttons[0].hasDestructiveAction)
        XCTAssertTrue(mismatch.window.defaultButtonCell === mismatch.buttons[1].cell)
        owner.respondToAlert(.alertSecondButtonReturn)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertFalse(owner.testBanner.isHidden)
        XCTAssertNil(owner.testConnection)
        owner.start()
        try await wait("Reconnect repeats incompatible check") { owner.preparedAlert != nil }
        XCTAssertNil(owner.window.attachedSheet)
        XCTAssertNil(owner.testConnection)
        XCTAssertFalse(owner.window.isVisible || owner.window.isKeyWindow || owner.window.isMainWindow || NSApp.isActive)
        print("RPC E2E hello 5.0; unstamped server refused; local mismatch alert prepared off-screen")
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
        defer { SidebarView.visualNow = nil }
        for multi in [false, true] {
            let fixture = try sidebarFixture { object in
                var sessions = object["sessions"] as! [[String: Any]]
                var nodes = sessions[0]["nodes"] as! [[String: Any]]
                var children = nodes[0]["children"] as! [[String: Any]]
                children[0]["title"] = String(repeating: "Long title ", count: 20)
                children[0]["lifecycle"] = ["Live", ["Terminal", ["phase": ["Unknown"], "report": ["since": 1791131000, "msg": "Activity", "state": ["Running", ["progress": NSNull()]]]]]]
                if multi {
                    var sibling = children[0]
                    sibling["id"] = "%1999"; sibling["pane"] = "%1999"
                    children[0] = ["kind": "window", "id": children[0]["window"]!, "window": children[0]["window"]!,
                                   "name": "group", "children": [children[0], sibling]]
                }
                nodes[0]["children"] = children
                sessions[0]["nodes"] = nodes
                object["sessions"] = sessions
            }
            let row = try XCTUnwrap(sidebarRows(fixture).first { $0.started != nil })
            XCTAssertFalse(row.tail.isEmpty)
            let started = try XCTUnwrap(row.started)
            let cell = SidebarCell(SidebarFonts())
            cell.frame = NSRect(x: 0, y: 0, width: 292, height: row.height)
            for (before, after) in [(9.0, 10.0), (59.0, 60.0), (3599.0, 3600.0)] {
                SidebarView.visualNow = started.addingTimeInterval(before)
                cell.configure(row)
                SidebarView.visualNow = started.addingTimeInterval(after)
                cell.updateClock()
                XCTAssertEqual(cell.visualClockDirtyRect.minX, 51,
                               "width-changing tick must invalidate the nested title’s truncation edge")
                XCTAssertEqual(cell.visualClockDirtyRect.minY, 7)
            }
            SidebarView.visualNow = started.addingTimeInterval(11)
            cell.configure(row)
            SidebarView.visualNow = started.addingTimeInterval(12)
            cell.updateClock()
            XCTAssertGreaterThan(cell.visualClockDirtyRect.minX, 200, "equal-width tick must remain clock-only")
            let activityRect = NSRect(x: row.leading, y: row.tailY, width: cell.bounds.width - row.leading - 24, height: 15)
            XCTAssertFalse(cell.visualClockDirtyRect.intersects(activityRect),
                           "equal-width nested \(multi ? "multi" : "single") clock must not redraw activity")
        }
    }

    func testNavigationFeedFirst() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let owner = try sidebarOwner()
        let list = owner.sidebar.list
        window.contentView = list
        let initial = try sidebarFixture()
        let destination = try sidebarFixture { $0["client"] = ["session": "$0", "window": "@458", "pane": "%502"] }
        list.update(.running(initial))
        list.layoutSubtreeIfNeeded()
        let selectedBeforeNil = list.visualTable.selectedRow
        let originBeforeNil = list.visualScroll.contentView.bounds.origin
        owner.request = { _, done in done(.success(.switched(nil))) }
        owner.perform(.switchWindow(next: true))
        XCTAssertEqual(list.visualTable.selectedRow, selectedBeforeNil)
        XCTAssertEqual(list.visualScroll.contentView.bounds.origin, originBeforeNil)
        list.update(.running(destination))
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
        let owner = try sidebarOwner()
        let list = owner.sidebar.list
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
        list.update(.running(navigated))
        XCTAssertEqual(list.visualRows[list.visualTable.selectedRow].target?.window, navigated.client.window)
        XCTAssertTrue(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) })
        let row = try XCTUnwrap(list.visualRows.first { $0.target != nil })
        var commands: [RPCRequest] = []
        var left = 0
        list.leave = { left += 1 }
        list.focus()
        owner.request = { request, done in commands.append(request); done(.failure(.terminal("no such pane"))) }
        list.visualJump(row)
        XCTAssertEqual(commands, [.jump(row.target!)])
        XCTAssertEqual(left, 0)
        XCTAssertEqual(list.visualDiagnostic, "no such pane")
        XCTAssertTrue(list.containsFocus)
        owner.request = { request, done in
            commands.append(request)
            XCTAssertTrue(Thread.isMainThread)
            done(.success(request == .releaseSideFocus ? .released : .jumped(row.target!)))
        }
        list.visualJump(row)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(left, 1)
        list.focus()
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
        owner.request = { [weak self] request, done in
            self?.rpc?.request(request) { result in XCTAssertTrue(Thread.isMainThread); done(result); failed.fulfill() }
        }
        list.visualJump(target)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }
}
