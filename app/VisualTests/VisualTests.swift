import AppKit
import GhosttyKit
import KoClient
import KoModel
import SnapshotTesting
import SidebarFeed
import PaneGeometry
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

@MainActor final class VisualTests: VisualTestCase {
    private let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    var directory: URL!
    var window: NSWindow!
    private static var processRuntime: GhosttyRuntime?
    // Outlives every test's directory: Ghostty reads the file again on each appearance change.
    nonisolated private static let processConfig = FileManager.default.temporaryDirectory.appendingPathComponent("kido-visual-\(getpid()).yaml")

    override class func tearDown() {
        try? FileManager.default.removeItem(at: processConfig)
        super.tearDown()
    }
    var runtime: GhosttyRuntime!
    private(set) var session: SessionView!
    // The harness's own client of the private server, as an owner's: it shows the session's windows.
    var client: KoClient?
    private var editor: LayoutEditor?
    private var model = SessionModel()
    private(set) var koModel: KoModel?
    // The sizes that the harness sent the server.
    private(set) var sentSizes: [String] = []

    func testBackgroundLaunchIsNotActivatable() {
        XCTAssertTrue(background)
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited, "a background launch must not be activatable")
    }

    func testVsyncMeasurement() async throws {
        guard ProcessInfo.processInfo.environment["KIDO_VSYNC_MEASURE"] == "1" else { throw XCTSkip("authorized on-screen measurement only") }
        let go = directory.path + "/go"
        try await start(pane: "while [ ! -e " + SSH.quote(go) + " ]; do sleep 0.01; done; python3 -u -c 'import time; end=time.monotonic()+10; print(\"\\033[?25l\"); i=0\nwhile time.monotonic()<end: print(i); i+=1; time.sleep(0.004)\ntime.sleep(30)'")
        NSApp.setActivationPolicy(.regular)
        PaneView.renderOffscreen = false
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("private measurement window is unoccluded") { self.window.occlusionState.contains(.visible) }
        try Data().write(to: URL(fileURLWithPath: "/tmp/kido-vsync-visible-\(getpid())"))
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        var installations: [Double] = []
        let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { installations.append(CACurrentMediaTime()) }
        defer { observation.invalidate(); window.orderOut(nil) }
        let display = window.screen?.displayID ?? 0
        FileManager.default.createFile(atPath: go, contents: nil)
        try await Task.sleep(for: .seconds(10))
        let sorted = zip(installations.dropFirst(), installations).map { ($0.0 - $0.1) * 1000 }.sorted()
        XCTAssertGreaterThan(sorted.count, 30)
        let quantiles = [0.5, 0.95, 0.99].map { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * $0))] }
        let report = "host pid=\(getpid()), display_id=\(display), display=\(window.screen?.localizedName ?? "none"), maximum=\(window.screen?.maximumFramesPerSecond ?? 0)Hz, key=\(window.isKeyWindow), first_responder=\(window.firstResponder === pane)\nIOSurface installations (NOT physical presentation): count=\(installations.count), median/p95/p99_ms=\(quantiles)\n"
        try report.write(toFile: "/tmp/kido-vsync-measure-\(getpid()).txt", atomically: true, encoding: .utf8)
        print(report)
    }

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: try koServerDir())
        PaneView.renderOffscreen = true
    }

    override func tearDown() async throws {
        client?.close()
        client = nil
        editor = nil
        session?.close()
        window?.contentView = nil
        window?.close()
        session = nil
        runtime?.onConfigChange = {}
        runtime?.onConfigReload = { _ in }
        runtime = nil
        PaneView.renderOffscreen = false
        NSApp.appearance = nil
    }

    // The pane that the harness starts with runs `cat` in raw mode, so what a test writes to it comes back as output.
    func rawPane(dark: Bool = false) async throws -> PaneView {
        try await start(dark: dark)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        window.makeFirstResponder(pane)
        return pane
    }

    // A new snapshot of the pane from the server.
    func restore(_ pane: PaneView) async throws {
        try XCTUnwrap(pane.koView).resync()
        try await wait("the pane restored") { !pane.restoring }
        try await settle()
        window.makeFirstResponder(pane)
    }

    // Writes `text` to the raw pane, which echoes it, and waits until the surface parsed all of it; a
    // frozen pane drops it once the server parsed it.
    // The fence title is cleared again, so that no tab shows it.
    func emit(_ pane: PaneView, _ text: String, until marker: String? = nil) async throws {
        if !rawPanes.contains(pane.pane) {
            try await wait("the pane's tty is raw", within: 5) { self.koModel?.panes.first { $0.id == pane.pane }?.title.isEmpty == false }
            rawPanes.insert(pane.pane)
        }
        let title = "raw-output-" + UUID().uuidString
        let data = Data((text + "\u{1b}]2;" + title + "\u{7}\u{1b}]2;\u{7}").utf8)
        let dropped = pane.visualDropped.withLock { $0 }
        try XCTUnwrap(pane.koView).text(data)
        let cleared = { self.koModel?.panes.first { $0.id == pane.pane }?.title.isEmpty == true }
        if pane.frozen {
            try await wait("the frozen pane dropped the echo", within: 5) { pane.visualDropped.withLock { $0 } >= dropped + data.count && cleared() }
            return
        }
        try await wait("the surface parsed the output", within: 5) { pane.visualTitles.contains(title) && cleared() }
        if let marker { XCTAssertTrue(surfaceText(pane).contains(marker)) }
    }
    private var rawPanes: Set<PaneID> = []

    // A layout edit through the core, as a gesture sends it.
    @discardableResult func edit(_ edit: KoSchema.Edit) async throws -> KoSchema.Edited {
        let client = try XCTUnwrap(client)
        return try await Task.detached { try client.edit(edit) }.value
    }

    // A pane that runs `cat` in raw mode, so what a test writes to it comes back as output.
    let rawCat = KoSchema.CreatePane(command: .shell(.init(command: rawScript)))

    // A new raw `cat` pane beside `pane`: `.h` to its right, `.v` below it.
    func split(_ pane: Int, _ axis: KoSchema.Axis) async throws {
        let split = KoSchema.Edit.split(KoSchema.EditSplit(axis: axis, new: rawCat, pane: PaneID(number: UInt32(pane))))
        let edited = try await edit(split)
        let created = try XCTUnwrap(selectedPane(by: split, edited))
        try client?.select(KO_SELECT_PANE, created)
    }

    // Zooms the pane's window to it, or ends the zoom.
    func toggleZoom(_ pane: Int) async throws {
        let zoom = KoSchema.Edit.toggleZoom(KoSchema.EditToggleZoom(pane: PaneID(number: UInt32(pane))))
        let edited = try await edit(zoom)
        if let selected = selectedPane(by: zoom, edited) { try client?.select(KO_SELECT_PANE, selected) }
    }

    // The server's text of a pane.
    func serverScreen(_ pane: PaneID) async throws -> String {
        try await ko(["api", "/panes/" + pane.description + "/screen"], dir: directory.path)
    }

    var terminal: WindowView? { session?.windows.values.first { !$0.isHidden } }
    var currentModel: SessionModel { model }

    private func loadRuntime(configFile: String? = nil) throws {
        if let configFile {
            let board = NSPasteboard(name: .init("config-test-\(UUID().uuidString)"))
            addTeardownBlock { @MainActor in board.releaseGlobally() }
            runtime = try XCTUnwrap(GhosttyRuntime(configFile: configFile, pasteboard: board))
            return
        }
        if Self.processRuntime == nil {
            let config = Self.processConfig
            try "app: {font: {size: 13}}\n".write(to: config, atomically: true, encoding: .utf8)
            Self.processRuntime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))))
            Self.processRuntime?.loadTestBindings("keybind = super+e=text:X\nkeybind = super+shift+c=text:Y\n")
        }
        runtime = try XCTUnwrap(Self.processRuntime)
    }

    private func sidebarOwner() throws -> WindowOwner {
        try loadRuntime()
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        addTeardownBlock { @MainActor in owner.close() }
        return owner
    }

    // A private server whose session "visual" has the window "zsh" of one pane that runs `pane`, or the
    // given windows, shown in a 700-point session view.
    func start(width: CGFloat = 700, height: CGFloat = 560, dark: Bool = false, configFile: String? = nil, pane: String = rawScript, windows: String? = nil) async throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        try loadRuntime(configFile: configFile)
        window = OwnerWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .displayP3
        session = SessionView(runtime: runtime)
        runtime.onConfigReload = { [weak self] font in self?.session.reloadConfig(font: font) }
        runtime.onConfigChange = { [weak self] in self?.session?.updateWebview() }
        session.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = session
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":\#(windows ?? #"[{"name":"zsh","tree":\#(koPane(pane))}]"#)}]"#)
        let client = try KoClient(socket: directory.path + "/socket", hello: KoHello(name: "visual", viewport: KoSize(cols: 80, rows: 24, cell: nil), webview: runtime.values.webview.enabled)) { [weak self] event in
            self?.handle(event)
        }
        self.client = client
        let editor = LayoutEditor { try client.edit($0) }
        editor.onFailure = { _, text in XCTFail("edit failed: \(text)") }
        editor.onSettled = { [weak self] in self?.session?.editsSettled() }
        self.editor = editor
        session.client = client
        session.webview = { [weak self] in self?.koModel?.pane($0)?.webview }
        session.edit = { edit, key in editor.submit(edit, key: key) }
        session.editing = { editor.holding }
        session.selectPane = { pane in try? client.select(KO_SELECT_PANE, pane) }
        session.sizeClient = { [weak self] viewport, windows in
            self?.sentSizes.append("\(viewport.cols)x\(viewport.rows)")
            do { try client.size(viewport: viewport, windows: windows); return true }
            catch { return false }
        }
        session.paneCommand = { [weak self] command, pane in
            guard let self, let window = koModel?.layout.layout.locate(pane)?.window,
                  let action = command.action(pane, in: window, new: KoSchema.CreatePane(), cell: session.cell ?? .zero) else { return }
            switch action {
            case .edit(let edit):
                editor.submit(edit) { result in
                    guard case .success(let edited) = result, let pane = selectedPane(by: edit, edited) else { return }
                    try? client.select(KO_SELECT_PANE, pane)
                }
            case .select(let target): try? client.select(KO_SELECT_PANE, target)
            }
        }
        try await wait("initial layout") { self.terminal?.displayedPanes.isEmpty == false }
        try await settle()
        if dark { try await darken() }
    }

    private func handle(_ event: KoEvent) {
        switch event {
        case .layout(let revision):
            receive()
            editor?.layoutChanged(revision: Int(revision))
        case .welcome, .model, .selected: receive()
        case .failed, .mismatch: break
        case .clipboardWrite(_, let contents): (window.delegate as? WindowOwner)?.writeClipboard(contents)
        case .clipboardRead(let read): session.pane(read.pane)?.receiveClipboardRead(read)
        }
    }

    private func receive() {
        guard let client, let next = try? client.model() else { return }
        koModel = next
        if next.selection.session == nil, let first = next.layout.layout.sessions.first { try? client.select(KO_SELECT_SESSION, first.id) }
        model = SessionModel(next)
        let windows = next.layout.layout.windows
        session.update(model.session.flatMap { next.layout.layout.session($0) }?.windows ?? [],
                       alive: Set(windows.map(\.id)), selected: next.selection.pane, marks: next.runtimeMarks)
        session.show(model.window)
        let snapshot = Snapshot(model: next)
        (window.contentViewController as? Sidebar)?.tabs.entries = model.navigation(snapshot, panes: PaneProjection(snapshot), activePanes: session.windows.compactMapValues(\.active)).tabs
    }

    func testSinglePaneHeaderPaper() async throws {
        let config = directory.appendingPathComponent("single-pane-header.yaml")
        try configYAML(at: config, background: "fffaf0").write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { owner.close() }
        let content = owner.sidebar.content
        content.addSubview(session)
        session.frame = content.bounds
        session.autoresizingMask = [.width, .height]
        for hex in ["fffaf0", "172029"] {
            runtime.onConfigChange = { owner.updateAppearance(); self.session.updateBackground() }
            let config = try XCTUnwrap(ghostty_config_new())
            let text = "background = #\(hex)\n"
            ghostty_config_load_string(config, text, UInt(text.utf8.count), "/single-pane-header")
            ghostty_config_finalize(config)
            ghostty_app_update_config(runtime.app, config)
            ghostty_config_free(config)
            let rgb = headerPaperRGB[hex]!
            try await wait("single pane theme \(hex)", within: 3) {
                guard let color = self.runtime.background.usingColorSpace(.sRGB) else { return false }
                return zip([color.redComponent, color.greenComponent, color.blueComponent], rgb).allSatisfy {
                    abs(Double($0.0) * 255 - $0.1) < 0.5
                }
            }
            for collapsed in [false, true] {
                owner.sidebar.isCollapsed = collapsed
                let root = try XCTUnwrap(owner.window.contentView?.superview)
                root.layoutSubtreeIfNeeded()
                owner.window.display()
                try await presented()
                let pane = try XCTUnwrap(terminal?.displayedPanes.first)
                XCTAssertEqual(terminal?.displayedPanes.count, 1)
                XCTAssertEqual(pane.paperColor, runtime.background)
                let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: image)
                let pixels = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default))
                for point in [(2, 2), (pixels.pixelsWide - 2, pixels.pixelsHigh - 2), (pixels.pixelsWide / 2, pixels.pixelsHigh / 2)] {
                    try assertPaperPixel(pixels, x: point.0, y: point.1, expected: headerPaperRGB[hex]!, "\(hex) single pane paper and outer padding stay pure")
                }
            }
            let split = try await edit(.split(KoSchema.EditSplit(axis: .h, new: rawCat, pane: PaneID(number: 1))))
            try await wait("inactive tiled paper") { self.terminal?.displayedPanes.count == 2 }
            let inactive = try XCTUnwrap(terminal?.displayedPanes.first { $0.shiftedBackground })
            XCTAssertEqual(inactive.paperColor, owner.window.backgroundColor)
            XCTAssertEqual(inactive.paperColor, owner.sidebar.tabs.theme.background)
            let added = try XCTUnwrap(split.createdPane)
            try await ko(["api", "-X", "DELETE", "/panes/" + added.description], dir: directory.path)
            try await wait("single pane restored") { self.terminal?.displayedPanes.count == 1 }
        }
    }

    func testThemeFileReloadRepaintsExistingPane() async throws {
        let config = directory.appendingPathComponent("theme-reload.yaml")
        let themes = ThemePaths.directory(configFile: config.path)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let theme = themes.appendingPathComponent("custom")
        try "background = #000000\n".write(to: theme, atomically: true, encoding: .utf8)
        try "app: {theme: custom, window: {unfocused_shift: 0}}\n".write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        func check(_ rgb: [Int]) async throws {
            try await presented()
            let root = try XCTUnwrap(window.contentView)
            let image = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            let point = root.convert(CGPoint(x: pane.bounds.midX, y: pane.bounds.midY), from: pane)
            let scale = CGFloat(image.pixelsWide) / root.bounds.width
            let color = try XCTUnwrap(image.colorAt(x: Int(point.x * scale), y: Int((root.bounds.maxY - point.y) * scale))?.usingColorSpace(.sRGB))
            for (actual, expected) in zip([color.redComponent, color.greenComponent, color.blueComponent], rgb) {
                XCTAssertEqual(actual * 255, Double(expected), accuracy: 2)
            }
        }
        try await check([0, 0, 0])
        let reloaded = expectation(description: "theme contents reach existing surfaces")
        let previous = runtime.onConfigReload
        runtime.onConfigReload = { font in previous(font); reloaded.fulfill() }
        try "background = #ffffff\n".write(to: theme, atomically: true, encoding: .utf8)
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "reload_config", 13))
        await fulfillment(of: [reloaded], timeout: 5)
        try await check([255, 255, 255])
    }

    func testYAMLFontRendering() async throws {
        let config = directory.appendingPathComponent("font.yaml")
        try "app: {theme: kido-light, font: {family: Menlo, size: 15}}\n".write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await emit(pane, "Menlo 15\r\nAaBb 0123456789 => != ffi\r\n")
        window.makeFirstResponder(pane)
        pane.syncFocus()
        ghostty_app_set_focus(runtime.app, true)
        ghostty_surface_set_focus(pane.surface, true)
        try await snapshot("font-size-family", testName: "testYAMLSettingsRendering")
    }

    func testYAMLSettingsRendering() async throws {
        let config = directory.appendingPathComponent("settings.yaml")
        try "app: {theme: kido-light}\n".write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await emit(pane, "System monospaced font\r\nAaBb 0123456789 => != ffi\r\n")
        try await snapshot("system-mono-light")
        let themes = directory.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "background = #123456\nforeground = #fefefe\ncursor-color = #ffcc00\n".write(to: themes.appendingPathComponent("custom"), atomically: true, encoding: .utf8)
        for (name, label, yaml) in [
            ("dark", "System mono 13, kido-dark theme", "app: {theme: kido-dark}\n"),
            ("user-theme", "System mono 13, user theme custom", "app: {theme: custom}\n")
        ] {
            let changed = expectation(description: name)
            runtime.onConfigChange = { changed.fulfill() }
            try yaml.write(to: config, atomically: true, encoding: .utf8)
            await fulfillment(of: [changed], timeout: 5)
            XCTAssertNil(runtime.configError)
            XCTAssertEqual(runtime.diagnostics, [])
            window.backgroundColor = runtime.unfocusedPaper
            window.appearance = NSAppearance(named: runtime.background.isDark ? .darkAqua : .aqua)
            session.updateBackground()
            try await emit(pane, "\u{1b}[2J\u{1b}[H\(label)\r\nAaBb 0123456789 => != ffi\r\n\u{1b}[?25h")
            window.makeFirstResponder(pane)
            pane.syncFocus()
            ghostty_app_set_focus(runtime.app, true)
            ghostty_surface_set_focus(pane.surface, true)
            try await settle()
            try await snapshot(name)
        }
    }

    func testEmptySessionConnectionAndRetryBanner() async throws {
        for side in ["light", "dark"] {
            let config = directory.appendingPathComponent("empty-\(side).yaml")
            try "app: {theme: kido-\(side)}\n".write(to: config, atomically: true, encoding: .utf8)
            try loadRuntime(configFile: config.path)
            let owner = WindowOwner(host: .local, runtime: runtime, start: false)
            owner.window.appearance = NSAppearance(named: side == "dark" ? .darkAqua : .aqua)
            owner.window.colorSpace = .displayP3
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            owner.testEditor { _ in
                guard gate.wait(timeout: .now() + 5) == .success else { throw KoError(code: KO_ERR_INVALID, detail: "edit gate timed out") }
                throw KoError(code: KO_ERR_INVALID, detail: "creation refused")
            }
            owner.ensureSession()
            XCTAssertTrue(owner.testEditing)
            owner.window.layoutIfNeeded()
            owner.sidebar.view.layoutSubtreeIfNeeded()
            checkSnapshot { verifySnapshot(of: owner.sidebar.view, as: .image, named: "\(side)-connecting", record: $0) }
            gate.signal()
            try await wait("the held edit ends") { !owner.testEditing }
            owner.testEditor { _ in throw KoError(code: KO_ERR_INVALID, detail: "creation refused") }
            owner.ensureSession()
            try await wait("creation fails with Retry") { !owner.testEditing && owner.testBanner.testText.title == "Could not create a session" }
            XCTAssertEqual(owner.testBanner.testText.button, "Retry")
            owner.window.layoutIfNeeded()
            owner.sidebar.view.layoutSubtreeIfNeeded()
            checkSnapshot { verifySnapshot(of: owner.sidebar.view, as: .image, named: "\(side)-failed", record: $0) }
            owner.close()
        }
    }

    func testClientRefusalBanner() async throws {
        for side in ["light", "dark"] {
            let config = directory.appendingPathComponent("refusal-\(side).yaml")
            try "app: {theme: kido-\(side)}\n".write(to: config, atomically: true, encoding: .utf8)
            try loadRuntime(configFile: config.path)
            for host in [Host.local, .remote("example")] {
                let owner = WindowOwner(host: host, runtime: runtime, start: false)
                owner.window.appearance = NSAppearance(named: side == "dark" ? .darkAqua : .aqua)
                owner.window.colorSpace = .displayP3
                owner.refused("missing field `required_extra`")
                owner.window.layoutIfNeeded()
                owner.testBanner.layoutSubtreeIfNeeded()
                let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                let name = "\(side)-\(host == .local ? "local" : "remote")"
                if let failure = verifySnapshot(of: owner.testBanner, as: .image, named: name, record: record),
                   !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
                owner.close()
            }
        }
    }

    func testAdjustedFontConfigReload() async throws {
        let config = directory.appendingPathComponent("adjusted-font.yaml")
        try "app: {font: {size: 13}}\n".write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path)
        let first = try XCTUnwrap(terminal?.displayedPanes.first)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "=",
            charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24))
        first.keyDown(with: key)
        try await wait("adjusted font") { first.font > 13 }
        let adjusted = first.font
        try await edit(.split(KoSchema.EditSplit(axis: .h, new: rawCat, pane: PaneID(number: 1))))
        try await wait("new pane") { self.terminal?.displayedPanes.count == 2 }
        let panes = try XCTUnwrap(terminal).displayedPanes
        for pane in panes { XCTAssertEqual(pane.font, adjusted) }
        let added = try await edit(.addWindow(KoSchema.EditAddWindow(after: WindowID(number: 1), new: rawCat, session: SessionID(number: 1))))
        let hidden = try XCTUnwrap(added.createdWindow)
        try client?.select(KO_SELECT_WINDOW, hidden)
        try await wait("hidden window") { first.isHidden || first.superview?.isHidden == true }
        let allPanes = session.windows.values.flatMap(\.retainedPanes)
        XCTAssertTrue(allPanes.contains { $0 === first }, "the cached hidden pane must be checked")
        XCTAssertEqual(allPanes.count, 3)
        let reloads: [(configSize: Int, background: String, expectedSize: Float)] = [
            (13, "#112233", adjusted), (20, "#223344", 20),
        ]
        for (size, background, expected) in reloads {
            let changed = expectation(description: "config reload")
            runtime.onConfigChange = { changed.fulfill() }
            try configYAML(at: config, background: background, size: size).write(to: config, atomically: false, encoding: .utf8)
            await fulfillment(of: [changed], timeout: 3)
            await mainQueueFence()
            for pane in allPanes {
                XCTAssertEqual(pane.font, expected, "pane \(pane.pane) after font-size \(size)")
            }
        }
        let active = try XCTUnwrap(terminal?.displayedPanes.first)
        active.keyDown(with: key)
        try await wait("font shortcut after reload") { allPanes.allSatisfy { $0.font > 20 } }
        let reset = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "0",
            charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29))
        active.keyDown(with: reset)
        try await wait("reset uses new config font") { allPanes.allSatisfy { $0.font == 20 } }
    }

    // A ko snapshot restores the cells with their backgrounds: the restored pane draws what the live output
    // drew, at the bottom of the history and at its top.
    func testRestoredCellsKeepTheirBackgrounds() async throws {
        let pane = try await rawPane()
        let fill = "\u{1B}[48;2;223;231;236m"
        let boxes = (0..<40).map { "\(fill)BOX\($0)      \u{1B}[m\r\n\(fill)\u{1B}[K\u{1B}[m\r\n\u{1B}[49mtool\u{1B}[m\r\n" }.joined()
        try await emit(pane, "\u{1B}[?25l\(fill)ABCDEFGHIJKLMNOPQRSTUVWX\u{1B}[m\r\n\u{1B}[1;3;7;9;4:3;58;2;255;0;80mreverse\u{1B}[m\r\n"
            + boxes + "\(fill)abcdefghijklmnopqrstuvwx\u{1B}[mEND")
        func drawn() async throws -> [(text: String, cells: [NSColor])] {
            var drawn: [(text: String, cells: [NSColor])] = []
            for position in ["scroll_to_bottom", "scroll_to_top"] {
                XCTAssertTrue(ghostty_surface_binding_action(pane.surface, position, UInt(position.utf8.count)))
                try await presented()
                let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
                pane.cacheDisplay(in: pane.bounds, to: bitmap)
                let rows = Int(ghostty_surface_size(pane.surface).rows), cell = pane.cell, top = pane.renderInsets.top
                let scale = CGFloat(bitmap.pixelsWide) / pane.bounds.width
                let cells = try (0..<rows).flatMap { row in
                    try (0..<26).map { column in
                        let x = Int((CGFloat(column) + 0.5) * cell.width * scale), y = Int((top + (CGFloat(row) + 0.5) * cell.height) * scale)
                        return try XCTUnwrap(bitmap.colorAt(x: min(x, bitmap.pixelsWide - 1), y: min(y, bitmap.pixelsHigh - 1)))
                    }
                }
                drawn.append((surfaceText(pane, in: GHOSTTY_POINT_VIEWPORT), cells))
            }
            return drawn
        }
        let live = try await drawn()
        XCTAssertTrue(live[1].text.contains("ABCDEFGHIJKL"), "the top of the history")
        try await restore(pane)
        let restored = try await drawn()
        for (name, index) in [("bottom", 0), ("top", 1)] {
            XCTAssertEqual(restored[index].text, live[index].text, name)
            XCTAssertEqual(restored[index].cells, live[index].cells, name)
        }
    }

    func testLiveConfigReflowsPane() async throws {
        let config = directory.appendingPathComponent("live.yaml")
        try "app: {font: {size: 13}}\n".write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        let before = ghostty_surface_size(pane.surface)
        let shaded = expectation(description: "shade-only reload")
        runtime.onConfigChange = { shaded.fulfill() }
        try "app: {font: {size: 13}, window: {sidebar_shade: 30}}\n".write(to: config, atomically: false, encoding: .utf8)
        await fulfillment(of: [shaded], timeout: 0.3)
        await mainQueueFence()
        XCTAssertEqual(ghostty_surface_size(pane.surface).cell_height_px, before.cell_height_px, "a shade-only reload keeps the cell")
        let changed = expectation(description: "font config reload")
        runtime.onConfigChange = { changed.fulfill() }
        try "app: {font: {size: 20}}\n".write(to: config, atomically: false, encoding: .utf8)
        await fulfillment(of: [changed], timeout: 0.3)
        try await settle()
        let after = ghostty_surface_size(pane.surface)
        XCTAssertGreaterThan(after.cell_height_px, before.cell_height_px)
        XCTAssertNotEqual(after.columns, before.columns)
        let leaf = koModel.flatMap { model -> KoSchema.Leaf? in
            if case .leaf(let leaf)? = model.layout.layout.sessions.first?.windows.first?.tree { leaf } else { nil }
        }
        XCTAssertEqual(leaf.map { [$0.cols, $0.rows] }, [Int(after.columns), Int(after.rows)], "the server took the new grid")
    }

    func darken(_ appearance: NSAppearance.Name = .darkAqua) async throws {
        let changed = expectation(description: "appearance config changed")
        runtime.onConfigChange = { [weak self] in self?.session.updateColorScheme(); self?.session.updateBackground(); changed.fulfill() }
        window.appearance = NSAppearance(named: appearance)
        NSApp.appearance = NSAppearance(named: appearance)
        await fulfillment(of: [changed], timeout: 20)
        try await settle()
    }

    func settle() async throws {
        try await wait("authoritative restore and presented frame") {
            guard let terminal = self.terminal else { return false }
            return terminal.visualGeometryReady && !terminal.displayedPanes.isEmpty && terminal.displayedPanes.filter { !$0.isHidden }.allSatisfy(\.visualReady)
        }
    }

    // Fills every shown pane with coloured rows, or `content`, through its raw cat.
    func paint(lines: Int? = nil, alternate: Bool = false, content: String? = nil) async throws {
        for pane in try XCTUnwrap(terminal).displayedPanes.filter({ !$0.isHidden }) {
            let grid = ghostty_surface_size(pane.surface)
            let count = lines ?? Int(grid.rows)
            var text = alternate ? "\u{1b}[?1049h" : ""
            text += "\u{1b}[2J\u{1b}[H"
            for i in 0..<count {
                let color = i == count - 1 ? 32 : i == 0 ? 31 : [34, 35, 36, 33][i % 4]
                text += "\u{1b}[\(color)m" + String(repeating: "█", count: Int(grid.columns)) + "\u{1b}[0m"
                if i != count - 1 { text += "\r\n" }
            }
            if let content { text = "\u{1b}[2J\u{1b}[H" + content }
            try await emit(pane, text)
        }
        try await settle()
    }

    // Waits until every shown pane presented a frame of what it holds.
    func presented() async throws {
        try await settle()
        let terminal = try XCTUnwrap(terminal)
        window.contentView?.layoutSubtreeIfNeeded()
        for pane in terminal.displayedPanes.filter({ !$0.isHidden }) {
            await presentedFrame(pane)
        }
    }

    func snapshot(_ name: String, testName: String = #function, view: NSView? = nil) async throws {
        try await presented()
        let terminal = try XCTUnwrap(terminal)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertFalse(NSApp.isActive)
        CATransaction.flush()
        terminal.displayedPanes.forEach { $0.scroller.isHidden = true }
        CATransaction.flush()
        checkSnapshot { verifySnapshot(of: view ?? terminal, as: .image, named: name, record: $0, testName: testName) }
        checkSnapshot { verifySnapshot(of: terminal.visualLayout, as: .lines, named: name, record: $0, testName: testName) }
    }

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
        sidebar.splitView.setPosition(236, ofDividerAt: 0)
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
        if let failure = verifySnapshot(of: try headerImage(sidebar.tabs), as: .image, named: "middle", record: record),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        sidebar.isCollapsed = true
        root.layoutSubtreeIfNeeded()
        sidebar.viewDidLayout()
        XCTAssertGreaterThanOrEqual(sidebar.tabs.convert(sidebar.tabs.bounds, to: root).minX, 116)
        await mainQueueFence()
        if let failure = verifySnapshot(of: try headerImage(sidebar.tabs), as: .image, named: "collapsed", record: record),
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
        let shown = try XCTUnwrap(currentModel.window)
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
        let pane = try XCTUnwrap(terminal.displayedPanes.first)
        for (name, shape, cursor) in [("pointer", GHOSTTY_MOUSE_SHAPE_POINTER, NSCursor.pointingHand),
                                      ("text", GHOSTTY_MOUSE_SHAPE_TEXT, NSCursor.iBeam),
                                      ("default", GHOSTTY_MOUSE_SHAPE_DEFAULT, NSCursor.arrow)] {
            try await emit(pane, "\u{1b}]22;\(name)\u{7}")
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
        try await split(1, .h)
        try await wait("split for cursor priority") { terminal.displayedPanes.count == 2 }
        for view in terminal.displayedPanes { view.setMouseShape(GHOSTTY_MOUSE_SHAPE_POINTER) }
        let dividers = terminal.paneCursorRects.filter { $0.1 === NSCursor.resizeLeftRight }
        XCTAssertFalse(dividers.isEmpty)
        for (rect, _) in dividers {
            XCTAssertFalse(terminal.paneCursorRects.contains { $0.1 === NSCursor.pointingHand && $0.0.intersects(rect) })
        }
        try await edit(.float(KoSchema.EditFloat(cols: 35, pane: PaneID(number: 2), rows: 10, x: 5, y: 2)))
        try await wait("float for cursor priority") { terminal.visualLayout.contains("float pane_") }
        try await settle()
        XCTAssertTrue(terminal.paneCursorRects.contains { $0.1 === NSCursor.openHand })
        let linkRects = terminal.paneCursorRects.filter { $0.1 === NSCursor.pointingHand }.map { $0.0 }
        for (rect, cursor) in terminal.paneCursorRects where cursor !== NSCursor.pointingHand {
            XCTAssertFalse(linkRects.contains { $0.intersects(rect) }, "chrome cursor must win")
        }
    }

    func testPaneFocusTreatment() async throws {
        class FocusWindow: OwnerWindow {
            var fullscreen = false
            override var styleMask: NSWindow.StyleMask {
                get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
                set { super.styleMask = newValue }
            }
        }
        let config = directory.appendingPathComponent("focus.yaml")
        try "app: {font: {size: 13}}\n".write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path)
        window.contentView = nil
        window.isReleasedWhenClosed = false
        window.close()
        let focusWindow = FocusWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                      styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window = focusWindow
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .displayP3
        let sidebar = Sidebar()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = runtime.background
        window.contentViewController = sidebar
        session.frame = sidebar.content.bounds
        session.autoresizingMask = [.width, .height]
        sidebar.content.addSubview(session)
        let toolbar = NSToolbar(identifier: "PaneFocus")
        toolbar.delegate = sidebar
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.display()
        let root = try XCTUnwrap(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        sidebar.splitView.setPosition(236, ofDividerAt: 0)
        sidebar.list.show(sidebarFixture())
        session.sidebarFocused = { [weak sidebar] in sidebar?.list.containsFocus == true }
        (window as? OwnerWindow)?.focusChanged = { [weak self, weak sidebar] _, _ in
            self?.terminal?.updateFocusTreatment()
            sidebar?.updateFocusEdge()
            sidebar?.view.needsLayout = true
            sidebar?.view.layoutSubtreeIfNeeded()
        }
        let testName = #function
        func snapshot(_ name: String, view: NSView) async throws {
            try await wait("stable focus tab title") { sidebar.tabs.entries.map(\.name) == ["cat"] }
            try await self.snapshot(name, testName: testName, view: view)
        }
        func capture() throws -> NSBitmapImageRep {
            let image = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: image)
            return image
        }
        func color(_ image: NSBitmapImageRep, _ view: NSView, _ point: CGPoint) throws -> NSColor {
            let p = root.convert(point, from: view)
            let scale = CGFloat(image.pixelsWide) / root.bounds.width
            return try XCTUnwrap(image.colorAt(x: Int(p.x * scale), y: Int((root.bounds.maxY - p.y) * scale)))
        }
        func check(_ actual: NSColor, _ rgb: [Int], _ message: String) {
            for (value, expected) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent], rgb) {
                XCTAssertEqual(value * 255, Double(expected), accuracy: 1.1, message)
            }
            XCTAssertEqual(actual.alphaComponent, 1, accuracy: 0.001, "opaque paper")
        }
        for dark in [false, true] {
            if dark { try await darken() }
            let name = dark ? "dark" : "light"
            let pure = dark ? [23, 23, 23] : [255, 249, 236]
            let shifted = dark ? [30, 30, 30] : [247, 242, 229]
            let sidebarShifted = dark ? [35, 35, 35] : [242, 237, 224]
            sidebar.updateAppearance(runtime: runtime)
            window.backgroundColor = runtime.background
            let terminal = try XCTUnwrap(terminal)
            if dark {
                try await toggleZoom(1)
                try await wait("unzoom for dark focus") { terminal.displayedPanes.filter { !$0.isHidden }.count == 3 }
            } else {
                try await split(1, .h)
                try await split(2, .v)
                try await wait("three focus panes") { terminal.displayedPanes.count == 3 }
            }
            let content = "pi · kido-app\r\n\r\n› Refine pane focus.\r\nKeep the native chrome.\r\nInactive text stays readable.\r\n\r\n\u{1b}[34m$ git status --short\u{1b}[0m\r\n› "
            try await paint(content: content)
            let active = try XCTUnwrap(terminal.displayedPanes.first { $0.pane == terminal.active })
            window.makeFirstResponder(active)
            terminal.updateFocusTreatment()
            try await drain(runtime)
            try await snapshot("pane-\(name)", view: root)
            for hidden in [false, true] {
                sidebar.isCollapsed = hidden
                sidebar.dismissFloating()
                root.layoutSubtreeIfNeeded()
                try await settle()
                let chromes = terminal.subviews.compactMap { $0 as? PaneChrome }.filter { !$0.isHidden }
                let chrome = try XCTUnwrap(chromes.sorted {
                    let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
                    if abs(a.minY - b.minY) > 1 { return a.minY < b.minY }
                    return hidden ? a.minX < b.minX : a.maxX > b.maxX
                }.first)
                terminal.focus(chrome.pane)
                terminal.updateFocusTreatment()
                try await drain(runtime)
                let side = hidden ? "left" : "right"
                try await snapshot("corner-\(side)-\(name)", view: root)
                if #available(macOS 27, *), let radii = window.contentView?.effectiveCornerRadii {
                    let radius = hidden ? radii.bottomLeft : radii.bottomRight
                    XCTAssertGreaterThan(radius, 0)
                    let offset = radius - (radius - 0.5) / sqrt(2)
                    let point = CGPoint(x: hidden ? offset : chrome.bounds.maxX - offset, y: chrome.bounds.maxY - offset)
                    let image = try capture()
                    let curve = try color(image, chrome, point)
                    let contrast = zip([curve.redComponent, curve.greenComponent, curve.blueComponent], pure).map { abs($0 * 255 - Double($1)) }.max() ?? 0
                    XCTAssertGreaterThan(contrast, 30, "focus stroke follows the window curve")
                }
                focusWindow.fullscreen = true
                chrome.needsDisplay = true
                try await snapshot("corner-\(side)-fullscreen-\(name)", view: root)
                let square = try capture()
                let edge = try color(square, chrome, CGPoint(x: hidden ? 0.75 : chrome.bounds.maxX - 0.75, y: chrome.bounds.maxY - 5))
                XCTAssertGreaterThan(abs(edge.blueComponent * 255 - Double(pure[2])), 3, "full-screen focus edge stays square")
                focusWindow.fullscreen = false
                chrome.needsDisplay = true
            }
            sidebar.isCollapsed = false
            root.layoutSubtreeIfNeeded()
            try await settle()
            terminal.focus(active.pane)
            terminal.updateFocusTreatment()
            func expectLook(_ looksFocused: Bool, _ message: String, edge: Bool = true) async throws {
                let chromes = terminal.subviews.compactMap { $0 as? PaneChrome }.filter { !$0.isHidden }
                for chrome in chromes {
                    let frame = expectation(description: "presented \(chrome.pane)")
                    try XCTUnwrap(terminal.displayedPanes.first { $0.pane == chrome.pane }).visualFrame { _ in frame.fulfill() }
                    await fulfillment(of: [frame], timeout: 10)
                }
                let image = try capture()
                for chrome in chromes {
                    let pane = try XCTUnwrap(terminal.displayedPanes.first { $0.pane == chrome.pane })
                    let focused = looksFocused && chrome.pane == terminal.active
                    XCTAssertEqual(chrome.treatment, focused && edge ? .edge : .plain, "\(message) \(chrome.pane) treatment")
                    check(try color(image, pane, CGPoint(x: pane.bounds.midX, y: 35)), focused ? pure : shifted, "\(message) \(chrome.pane) paper")
                    let inset = try color(image, chrome, CGPoint(x: chrome.bounds.maxX - 0.75, y: chrome.bounds.midY))
                    if focused && edge { XCTAssertGreaterThan(abs(inset.blueComponent * 255 - Double(pure[2])), 3, "\(message) focused pane edge") }
                    else { check(inset, focused ? pure : shifted, "\(message) \(chrome.pane) has no edge") }
                    var metrics = ghostty_surface_grid_metrics_s()
                    XCTAssertTrue(ghostty_surface_grid_metrics(pane.surface, &metrics))
                    let cursor = CGPoint(x: (CGFloat(metrics.cursor_column) + 0.5) * pane.cell.width,
                                         y: pane.bounds.maxY - pane.renderInsets.top - (CGFloat(metrics.cursor_row) + 0.5) * pane.cell.height)
                    let centre = try color(image, pane, cursor)
                    if focused { XCTAssertGreaterThan(abs(centre.redComponent * 255 - Double(pure[0])), 10, "\(message) \(chrome.pane) solid cursor") }
                    else { check(centre, shifted, "\(message) \(chrome.pane) hollow cursor") }
                }
            }
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            try await drain(runtime)
            try await snapshot("window-not-key-\(name)", view: root)
            try await expectLook(false, "window not key")
            XCTAssertTrue(sidebar.visualFocusEdge.isHidden)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try await drain(runtime)
            try await expectLook(true, "window key again")
            sidebar.focusSidebar(nil)
            XCTAssertFalse(sidebar.visualFocusEdge.isHidden)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            try await drain(runtime)
            try await expectLook(false, "sidebar focused, window not key")
            XCTAssertTrue(sidebar.visualFocusEdge.isHidden, "no sidebar stroke while the window is not key")
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try await drain(runtime)
            try await expectLook(false, "sidebar focused, window key again")
            XCTAssertFalse(sidebar.visualFocusEdge.isHidden, "sidebar stroke returns with the window")
            window.makeFirstResponder(active)
            terminal.updateFocusTreatment()
            if !dark {
                let panes = terminal.displayedPanes.filter { !$0.isHidden }
                let target = try XCTUnwrap(panes.first { $0 !== active })
                func click(_ view: NSView) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
                                                     modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                }
                var selected = 0
                let onSelect = target.onSelect
                target.onSelect = { selected += 1 }
                defer { target.onSelect = onSelect }
                func release(_ view: NSView) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
                                                     modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
                }
                let sidebarDown = try click(sidebar.list)
                for pane in panes { XCTAssertTrue(pane.visualEventMonitor?(sidebarDown) === sidebarDown) }
                XCTAssertTrue(window.firstResponder === active, "a first click outside a pane leaves the pane focus alone")
                let down = try click(target)
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false
                window.beginSheet(sheet, completionHandler: nil)
                XCTAssertNotNil(window.attachedSheet)
                for pane in panes { XCTAssertTrue(pane.visualEventMonitor?(down) === down) }
                window.endSheet(sheet)
                window.orderOut(nil)
                XCTAssertTrue(window.firstResponder === active, "a click under a sheet focuses nothing")
                XCTAssertEqual(selected, 0, "a click under a sheet selects nothing")
                for pane in panes { XCTAssertTrue(pane.visualEventMonitor?(down) === down, "the click continues to AppKit, which only activates the window") }
                XCTAssertTrue(window.firstResponder === target, "the first click focuses the clicked pane")
                XCTAssertEqual(selected, 1, "the first click selects the clicked pane on the server")
                target.visualAcceptsFirstMouse = false
                window.sendEvent(down)
                XCTAssertEqual(target.visualPressed, 0, "the first click is not a terminal press")
                window.sendEvent(try release(target))
                target.visualAcceptsFirstMouse = true
                for pane in panes { _ = pane.visualEventMonitor?(down) }
                XCTAssertEqual(selected, 1, "a click on the focused pane selects nothing")
                window.makeFirstResponder(active)
                var firstMouse: Set<String> = []
                var views = [root]
                while let view = views.popLast() {
                    if view.acceptsFirstMouse(for: nil) { firstMouse.insert(String(describing: type(of: view))) }
                    views += view.subviews
                }
                let kido = firstMouse.filter { !$0.hasPrefix("NS") && !$0.hasPrefix("_") }
                let toolbarButtons = PaneToolbar(runtime: runtime).subviews.compactMap { $0 as? IconButton }
                XCTAssertTrue(toolbarButtons.allSatisfy { !$0.acceptsFirstMouse(for: nil) }, "a first click on a hover toolbar button only activates the window")
                XCTAssertEqual(kido, ["IconButton", "MouseButton", "PaneView", "Table", "RuntimeSection", "SidebarDisclosure", "SidebarChildren"], "pane chrome, dividers, tabs and sidebar rows never take first mouse; PaneView, Table and RuntimeSection answer true only in the visual build")
            }
            var image = try capture()
            let textRect = root.convert(CGRect(x: 20, y: active.bounds.maxY - 80, width: 240, height: 75), from: active)
            let scale = CGFloat(image.pixelsWide) / root.bounds.width
            let crop = CGRect(x: textRect.minX * scale, y: (root.bounds.maxY - textRect.maxY) * scale, width: textRect.width * scale, height: textRect.height * scale)
            let transparentText = try XCTUnwrap(image.cgImage?.cropping(to: crop))
            active.transparentPaper = false
            try await settle()
            let frame = expectation(description: "opaque reference frame")
            active.visualFrame { _ in frame.fulfill() }
            await fulfillment(of: [frame], timeout: 10)
            let opaqueText = try XCTUnwrap(try capture().cgImage?.cropping(to: crop))
            func pixels(_ image: CGImage) throws -> Data {
                var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
                let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                                     bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return Data(bytes)
            }
            let transparent = [UInt8](try pixels(transparentText)), opaque = [UInt8](try pixels(opaqueText))
            var counts: [UInt32: Int] = [:]
            for i in stride(from: 0, to: opaque.count, by: 4) {
                let rgb = UInt32(opaque[i]) << 16 | UInt32(opaque[i + 1]) << 8 | UInt32(opaque[i + 2])
                counts[rgb, default: 0] += 1
            }
            let paper = try XCTUnwrap(counts.max { $0.value < $1.value }?.key)
            let ink = try XCTUnwrap(dark ? counts.keys.max() : counts.keys.min())
            var edgeDelta = 0, solidDelta = 0, solidPixels = 0
            for i in stride(from: 0, to: opaque.count, by: 4) {
                let rgb = UInt32(opaque[i]) << 16 | UInt32(opaque[i + 1]) << 8 | UInt32(opaque[i + 2])
                let delta = (0..<3).map { abs(Int(transparent[i + $0]) - Int(opaque[i + $0])) }.max()!
                edgeDelta = max(edgeDelta, delta)
                if rgb == paper || rgb == ink { solidDelta = max(solidDelta, delta); solidPixels += 1 }
            }
            XCTAssertGreaterThan(solidPixels, 1000)
            XCTAssertLessThanOrEqual(solidDelta, 2, "glyph interiors and paper match opaque reference")
            XCTAssertLessThanOrEqual(edgeDelta, 32, "bounded antialias edge change")
            print("focus glyph crop \(name): solid delta \(solidDelta), edge delta \(edgeDelta)")
            for (kind, cgImage) in [("transparent", transparentText), ("opaque", opaqueText)] {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pane-focus-\(name)-\(kind).png"))
            }
            active.transparentPaper = true
            try await settle()
            for chrome in terminal.subviews.compactMap({ $0 as? PaneChrome }).filter({ !$0.isHidden }) {
                let pane = try XCTUnwrap(terminal.displayedPanes.first { $0.pane == chrome.pane })
                let fill = chrome.pane == active.pane ? pure : shifted
                check(try color(image, pane, CGPoint(x: pane.bounds.midX, y: 35)), fill, "pane paper \(name) \(chrome.pane)")
                let inset = try color(image, chrome, CGPoint(x: chrome.bounds.maxX - 0.75, y: chrome.bounds.midY))
                if chrome.pane == active.pane {
                    XCTAssertGreaterThan(abs(inset.blueComponent * 255 - Double(fill[2])), 3, "focused pane edge")
                } else {
                    check(inset, shifted, "inactive pane has no edge")
                    var metrics = ghostty_surface_grid_metrics_s()
                    XCTAssertTrue(ghostty_surface_grid_metrics(pane.surface, &metrics))
                    XCTAssertTrue(metrics.cursor_in_viewport)
                    let cursor = CGPoint(x: (CGFloat(metrics.cursor_column) + 0.5) * pane.cell.width,
                                         y: pane.bounds.maxY - pane.renderInsets.top - (CGFloat(metrics.cursor_row) + 0.5) * pane.cell.height)
                    check(try color(image, pane, cursor), shifted, "inactive cursor centre stays hollow")
                    let border = try color(image, pane, CGPoint(x: CGFloat(metrics.cursor_column) * pane.cell.width + 0.25, y: cursor.y))
                    XCTAssertGreaterThan(abs(border.redComponent * 255 - Double(shifted[0])), 3, "inactive hollow cursor remains visible")
                }
            }
            sidebar.focusSidebar(nil)
            terminal.updateFocusTreatment()
            sidebar.view.needsLayout = true
            root.layoutSubtreeIfNeeded()
            try await drain(runtime)
            try await snapshot("sidebar-\(name)", view: root)
            image = try capture()
            let line = dark ? [55, 55, 55] : [221, 216, 205]
            for divider in terminal.subviews.compactMap({ $0 as? NSBox }).filter({ $0.bounds.width <= 1 || $0.bounds.height <= 1 }) {
                check(try color(image, divider, CGPoint(x: divider.bounds.midX, y: divider.bounds.midY)), line, "top line and pane dividers")
                if divider.bounds.width <= 1 {
                    check(try color(image, terminal, CGPoint(x: divider.frame.midX, y: terminal.bounds.maxY - 0.25)), line, "vertical divider reaches outer bottom margin")
                } else if divider.frame.minY > terminal.bounds.minY + 1 {
                    check(try color(image, terminal, CGPoint(x: terminal.bounds.maxX - 0.25, y: divider.frame.midY)), line, "horizontal divider reaches outer right margin")
                }
            }
            check(try color(image, sidebar.visualFocusEdge, CGPoint(x: sidebar.visualFocusEdge.bounds.maxX + 0.25, y: sidebar.visualFocusEdge.bounds.midY)), dark ? [55, 55, 55] : [202, 198, 188], "full-height sidebar divider")
            let left = try XCTUnwrap(terminal.subviews.compactMap { $0 as? PaneChrome }.filter { !$0.isHidden }.min { $0.frame.minX < $1.frame.minX })
            let near = try color(image, left, CGPoint(x: 4, y: left.bounds.midY))
            XCTAssertEqual(near.redComponent * 255, dark ? 25 : 229, accuracy: dark ? 0.75 : 2, "docked shadow strength 4pt from pane edge")
            check(try color(image, sidebar.visualFocusEdge, CGPoint(x: sidebar.visualFocusEdge.bounds.maxX - 4, y: sidebar.visualFocusEdge.bounds.midY)), sidebarShifted, "shadow must not cover sidebar paper")
            check(try color(image, sidebar.visualFocusEdge, CGPoint(x: sidebar.visualFocusEdge.bounds.maxX - 4, y: sidebar.visualFocusEdge.bounds.maxY - 20)), sidebarShifted, "shadow must not cover sidebar toolbar band")
            let toolbarNear = try color(image, sidebar.visualFocusEdge, CGPoint(x: sidebar.visualFocusEdge.bounds.maxX + 4, y: sidebar.visualFocusEdge.bounds.maxY - 20))
            XCTAssertLessThan(toolbarNear.redComponent * 255, Double(pure[0]) - 1, "sidebar shadow covers the toolbar band")
            check(try color(image, left, CGPoint(x: 50, y: left.bounds.midY)), shifted, "sidebar shadow ends before distant paper")
            for chrome in terminal.subviews.compactMap({ $0 as? PaneChrome }).filter({ !$0.isHidden }) {
                let pane = try XCTUnwrap(terminal.displayedPanes.first { $0.pane == chrome.pane })
                check(try color(image, pane, CGPoint(x: pane.bounds.midX, y: 35)), shifted, "sidebar focus shifts all panes")
                check(try color(image, chrome, CGPoint(x: chrome.bounds.maxX - 0.75, y: chrome.bounds.midY)), shifted, "sidebar focus removes pane edges")
            }
            XCTAssertFalse(sidebar.visualFocusEdge.isHidden)
            for point in [CGPoint(x: 0.25, y: sidebar.visualFocusEdge.bounds.midY),
                          CGPoint(x: sidebar.visualFocusEdge.bounds.maxX - 0.25, y: sidebar.visualFocusEdge.bounds.midY),
                          CGPoint(x: sidebar.visualFocusEdge.bounds.midX, y: 0.25),
                          CGPoint(x: sidebar.visualFocusEdge.bounds.midX, y: sidebar.visualFocusEdge.bounds.maxY - 0.25)] {
                let edge = try color(image, sidebar.visualFocusEdge, point)
                XCTAssertGreaterThan(abs(edge.blueComponent * 255 - Double(shifted[2])), 5, "sidebar edge on all four sides")
            }
            window.makeFirstResponder(active)
            sidebar.isCollapsed = true
            try await settle()
            sidebar.focusSidebar(nil)
            root.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
            for sidebarFocused in [true, false] {
                if !sidebarFocused { window.makeFirstResponder(active) }
                terminal.updateFocusTreatment()
                sidebar.view.needsLayout = true
                root.layoutSubtreeIfNeeded()
                try await drain(runtime)
                try await snapshot("floating-\(sidebarFocused ? "sidebar" : "pane")-\(name)", view: root)
                let floating = try capture()
                let card = sidebar.visualFocusEdge
                for point in [CGPoint(x: 1.25, y: card.bounds.midY), CGPoint(x: card.bounds.maxX - 1.25, y: card.bounds.midY),
                              CGPoint(x: card.bounds.midX, y: 1.25), CGPoint(x: card.bounds.midX, y: card.bounds.maxY - 1.25)] {
                    let edge = try color(floating, card, point)
                    if sidebarFocused {
                        XCTAssertGreaterThan(abs(edge.blueComponent * 255 - Double(shifted[2])), 3, "floating sidebar focus edge")
                    } else { check(edge, sidebarShifted, "unfocused floating sidebar has no accent edge") }
                }
                let paper = sidebarFocused || left.pane != active.pane ? shifted : pure
                let near = try color(floating, card, CGPoint(x: card.bounds.maxX + 4, y: card.bounds.midY))
                XCTAssertEqual(near.redComponent * 255, dark ? (paper[0] == 23 ? 21 : 28) : (paper[0] == 255 ? 246 : 238), accuracy: dark ? 0.75 : 1.1, "floating shadow strength 4pt from card edge")
                check(try color(floating, card, CGPoint(x: card.bounds.maxX + 50, y: card.bounds.midY)), paper, "floating shadow ends before distant paper")
                check(try color(floating, card, CGPoint(x: card.bounds.maxX - 4, y: card.bounds.midY)), sidebarShifted, "floating shadow must not fill the card")
                for chrome in terminal.subviews.compactMap({ $0 as? PaneChrome }).filter({ !$0.isHidden }) {
                    XCTAssertEqual(chrome.treatment, !sidebarFocused && chrome.pane == active.pane ? .edge : .plain)
                }
            }
            sidebar.dismissFloating()
            sidebar.isCollapsed = false
            root.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
            try await settle()
            if dark {
                sidebar.toggleSidebar(nil)
                try await snapshot("collapsed-dark", view: root)
                sidebar.toggleSidebar(nil)
                try await snapshot("expanded-dark", view: root)
                let expanded = try capture()
                for chrome in terminal.subviews.compactMap({ $0 as? PaneChrome }).filter({ chrome in !chrome.isHidden && terminal.displayedPanes.first(where: { $0.pane == chrome.pane })?.shiftedBackground == true }) {
                    for x in [2.0, 4, 6] {
                        for y in [2.0, chrome.bounds.midY, chrome.bounds.maxY - 2] {
                            check(try color(expanded, chrome, CGPoint(x: x, y: y)), [30, 30, 30], "expanded inactive left padding is shifted")
                        }
                    }
                }
            }
            try await toggleZoom(1)
            try await wait("single visible focus pane") { terminal.displayedPanes.filter { !$0.isHidden }.count == 1 }
            try await paint(content: content)
            try await snapshot("single-\(name)", view: root)
            let chrome = try XCTUnwrap(terminal.subviews.compactMap { $0 as? PaneChrome }.first { !$0.isHidden })
            let pane = try XCTUnwrap(terminal.displayedPanes.first { !$0.isHidden })
            window.makeFirstResponder(pane)
            try await expectLook(true, "single pane key", edge: false)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            try await drain(runtime)
            try await snapshot("single-window-not-key-\(name)", view: root)
            try await expectLook(false, "single pane window not key", edge: false)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try await drain(runtime)
            try await expectLook(true, "single pane window key again", edge: false)
            sidebar.focusSidebar(nil)
            terminal.updateFocusTreatment()
            sidebar.view.needsLayout = true
            root.layoutSubtreeIfNeeded()
            try await drain(runtime)
            try await snapshot("single-sidebar-\(name)", view: root)
            image = try capture()
            check(try color(image, pane, CGPoint(x: pane.bounds.midX, y: 35)), pure, "single pane stays pure with sidebar focus")
            check(try color(image, chrome, CGPoint(x: chrome.bounds.maxX - 0.75, y: chrome.bounds.midY)), pure, "single pane stays without an edge")
            XCTAssertFalse(sidebar.visualFocusEdge.isHidden)
        }
        let terminal = try XCTUnwrap(terminal)
        try await toggleZoom(1)
        try await wait("unzoom for config reload") { terminal.displayedPanes.filter { !$0.isHidden }.count == 3 }
        let reloaded = expectation(description: "focus config reloaded")
        runtime.onConfigChange = { [weak self] in
            guard let self else { return }
            session.updateBackground()
            window.backgroundColor = runtime.background
            sidebar.updateAppearance(runtime: runtime)
            reloaded.fulfill()
        }
        try "app: {theme: kido-light, window: {sidebar_shade: 40}}\n".write(to: config, atomically: false, encoding: .utf8)
        await fulfillment(of: [reloaded], timeout: 5)
        try await settle()
        try await drain(runtime)
        XCTAssertEqual(runtime.sidebarShade, 0.4)
        try await paint(content: "\u{1b}[48;2;255;249;236m" + String(repeating: " ", count: 40) + "\u{1b}[0m")
        let frames = expectation(description: "reloaded paper presented")
        frames.expectedFulfillmentCount = terminal.displayedPanes.count
        for pane in terminal.displayedPanes { pane.visualFrame { _ in frames.fulfill() } }
        await fulfillment(of: [frames], timeout: 10)
        let image = try capture()
        for pane in terminal.displayedPanes {
            check(try color(image, pane, CGPoint(x: pane.bounds.midX, y: 35)), [247, 242, 229], "pane shade ignores sidebar override after reload")
            check(try color(image, pane, CGPoint(x: 40, y: pane.bounds.maxY - 15)), [255, 249, 236], "explicit default-colour cell background stays opaque")
        }
        for (setting, expected) in [(20, [204, 199, 189]), (3, [247, 242, 229]), (-20, [204, 199, 189])] {
            let changed = expectation(description: "pane shift reloaded")
            runtime.onConfigChange = { [weak self] in
                self?.session.updateBackground()
                changed.fulfill()
            }
            try "app: {theme: kido-light, window: {sidebar_shade: 40, unfocused_shift: \(setting)}}\n".write(to: config, atomically: false, encoding: .utf8)
            await fulfillment(of: [changed], timeout: 5)
            try await settle()
            try await drain(runtime)
            let frames = expectation(description: "pane shift presented")
            frames.expectedFulfillmentCount = terminal.displayedPanes.count
            for pane in terminal.displayedPanes { pane.visualFrame { _ in frames.fulfill() } }
            await fulfillment(of: [frames], timeout: 10)
            let image = try capture()
            for pane in terminal.displayedPanes {
                check(try color(image, pane, CGPoint(x: pane.bounds.midX, y: 35)), expected, "inactive pane paper follows shift-only reload")
            }
        }
    }

    func testFirstWheelWithZeroSampleRendersFractionalFrame() async throws {
        try await start()
        let original = try XCTUnwrap(terminal?.displayedPanes.first)
        var input = Data()
        var pane: PaneView? = try XCTUnwrap(PaneView(runtime: runtime, pane: original.pane, font: original.font,
                                         input: { input.append($0) }))
        window.contentView?.addSubview(pane!)
        defer { pane?.dispose(); pane?.removeFromSuperview() }
        pane!.frame = NSRect(x: -10000, y: -10000, width: pane!.cell.width * 80, height: pane!.cell.height * 24)
        pane!.resize(cols: 80, rows: 24)
        pane!.needsLayout = true
        pane!.layout()
        XCTAssertGreaterThan(pane!.wheelRowHeight, 1)
        pane!.visualFeed(Data("\u{1b}c".utf8))
        try await settle()
        pane!.refreshScroller()
        XCTAssertEqual(pane!.scrollPosition().retainedHistoryRows, 0)
        XCTAssertTrue(pane!.feed(Data((0..<200).map { "live\($0)\r\n" }.joined().utf8)))
        try await wait("live retained rows and frame") { pane!.scrollPosition().retainedHistoryRows > 0 && pane!.renderedPixels != nil }
        try await settle()
        let before = pane!.renderedPixels
        let event = try XCTUnwrap(pane!.wheelEvent(y: 1))
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        pane!.scrollWheel(with: event)
        let target = try XCTUnwrap(pane!.wheelDistance)
        XCTAssertGreaterThan(target, 0)
        XCTAssertLessThan(target, 1)
        try await wait("fractional wheel frame applied") { pane!.visualReady && pane!.renderedPixels != before }
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
        try XCTUnwrap(terminal?.displayedPanes.first).visualScroll(8.35)
        try await snapshot("fractional-dark")
        try await paint(alternate: true)
        try await snapshot("alternate-dark")
        for height in [430, 610, 480, 620, 560] { window.setContentSize(NSSize(width: 700, height: height)) }
        try await settle()
        try await snapshot("resize-settled-dark")
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

    func testCaptionDisplayDelay() async throws {
        func fixture(_ caption: String) -> Snapshot {
            sidebarFixture { $0.sessions[0].nodes[0].item.fixtureLifecycle = piLifecycle(.running(.init()), msg: caption); $0.sessions[0].nodes[0].item.pane.mark = .running }
        }
        let initial = fixture("")
        let changed = fixture("Delayed caption")
        let id = try XCTUnwrap(sidebarRows(changed).rows.first { $0.tail == "Delayed caption" }?.id)
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
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 42)
        try await wait("caption deadline") { list.visualRows[index].tail == "Delayed caption" }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - shownAt, 0.2)
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 42)
        let hiddenAt = ProcessInfo.processInfo.systemUptime
        list.show(initial)
        XCTAssertEqual(list.visualRows[index].tail, "Delayed caption")
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 42)
        try await wait("caption hide deadline") { list.visualRows[index].tail.isEmpty }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - hiddenAt, 0.2)
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 42)
        list.show(changed)
        XCTAssertEqual(list.visualRows[index].tail, "")
        list.show(nil)
        list.show(changed)
        XCTAssertEqual(list.visualRows[index].tail, "Delayed caption", "identical reconnect snapshot must show its caption immediately")
        XCTAssertEqual(list.visualTable.rect(ofRow: index).height, 42)
        list.show(nil)
        list.show(changed, pin: id)
        list.show(fixture("Reconnected caption"))
        XCTAssertEqual(list.visualRows[index].tail, "Reconnected caption", "drag during reconnect must not seed old captions")
    }

    func testNestedSidebarRowHeightsAndNavigation() throws {
        let live = sidebarFixture { snapshot in
            var sibling = snapshot.sessions[0].nodes[0].item.children[0].item
            sibling.pane.id = PaneID(number: 999); sibling.window = WindowID(number: 999)
            snapshot.sessions[0].nodes[0].item.children.append(.item(sibling))
        }
        let rows = sidebarDividers(sidebarRows(live, expanded: Set(PaneProjection(live).placements.values.map { .pane($0.position.session, $0.position.pane) })).rows)
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
        list.visualExpandAll()
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
            list.visualExpandAll()
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
            XCTAssertEqual(cell.accessibilityRole(), list.visualRows[index].children == .leaf ? .staticText : .group)
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
            list.visualExpandAll()
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
        list.visualExpandAll()
        sidebarSnapshot(list, "active-parent-dark")
        window.appearance = NSAppearance(named: .aqua)
        sidebarSnapshot(list, "active-parent-light")
        window.setContentSize(NSSize(width: 236, height: 680))
        sidebarSnapshot(list, "narrow-light")
        window.setContentSize(NSSize(width: 292, height: 680))
        list.show(sidebarFixture { $0.client = .init(session: SessionID(number: 0), window: WindowID(number: 786), pane: PaneID(number: 892)) })
        list.visualExpandAll()
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
        XCTAssertTrue(sidebarRows(subtree).rows.filter(\.focused).isEmpty)
        list.show(subtree)
        list.visualExpandAll()
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

    func testBecomingKeyRestoresPaneFocusUnlessSheetOrSidebarOwnsIt() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"a","tree":\#(koPane())}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("owner ready") { owner.testSession?.activePane != nil && owner.testBanner.isHidden }
        let pane = try XCTUnwrap(owner.testSession?.activePane)
        let window = try XCTUnwrap(owner.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        window.makeFirstResponder(nil)
        let sheetFocus = window.firstResponder
        XCTAssertNotNil(window.attachedSheet)
        window.becomeKey()
        XCTAssertTrue(window.firstResponder === sheetFocus, "activation must not take focus under a sheet")
        window.endSheet(sheet)
        sheet.close()

        owner.sidebar.focusSidebar(nil)
        let sidebarFocus = window.firstResponder
        XCTAssertFalse(owner.sidebar.isFloating)
        XCTAssertTrue(owner.sidebar.list.containsFocus)
        window.becomeKey()
        XCTAssertTrue(window.firstResponder === sidebarFocus, "explicit sidebar keyboard focus survives activation")

        owner.sidebar.list.leave()
        window.makeFirstResponder(nil)
        window.becomeKey()
        XCTAssertTrue(window.firstResponder === pane, "becoming key must restore the active pane")
    }

    func testBannerDismissalRestoresPaneFocus() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"a","tree":\#(koPane())}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("owner ready") { owner.snapshot != nil && owner.testSession?.activePane != nil && owner.testBanner.isHidden }
        let pane = try XCTUnwrap(owner.testSession?.activePane)
        owner.window.makeFirstResponder(pane)
        let snapshot = try XCTUnwrap(owner.snapshot)
        owner.down("Disconnected", "Reconnecting…", button: nil)
        XCTAssertFalse(owner.window.firstResponder === pane)
        owner.testReceive(snapshot)
        XCTAssertTrue(owner.testBanner.isHidden)
        XCTAssertTrue(owner.window.firstResponder === pane, "a restored connection must restore pane focus without activation")
    }

    func testPaletteDismissalDoesNotRestoreHiddenPane() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"a","tree":\#(koPane())},{"name":"b","tree":\#(koPane())}]}]"#)
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        defer { app.closePalette(); owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("two windows ready") { owner.testSession?.windows.count == 2 }
        let session = try XCTUnwrap(owner.testSession)
        let original = try XCTUnwrap(session.activePane)
        owner.window.makeFirstResponder(original)
        app.togglePalette()
        XCTAssertNotNil(app.palettePanel)
        let next = try XCTUnwrap(session.windows.first { !$0.value.displayedPanes.contains { $0 === original } }?.key)
        session.show(next)
        XCTAssertTrue(original.isHiddenOrHasHiddenAncestor)
        app.closePalette()
        XCTAssertTrue(owner.window.firstResponder === session.activePane, "palette dismissal must not restore a hidden pane")
    }

    func testSameWindowDeferredPaneFocus() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"zsh","tree":{"split":"h","children":[\#(koPane()),\#(koPane())]}}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path
        defer { owner.close() }
        owner.start()
        let split = PaneID(number: 2), first = PaneID(number: 1)
        try await wait("owner split snapshot") { owner.sidebar.list.visualRows.contains { $0.target?.pane == split } }
        let row = try XCTUnwrap(owner.sidebar.list.visualRows.first { $0.target?.pane == split })
        owner.sidebar.focusSidebar(nil)
        owner.sidebar.list.visualJump(row)
        XCTAssertTrue(owner.sidebar.list.containsFocus, "focus must wait until the pane becomes current")
        try await wait("the jump lands") { owner.window.firstResponder.flatMap(PaneView.owner)?.pane == split }
        let original = try XCTUnwrap(owner.sidebar.list.visualRows.first { $0.target?.pane == first })
        owner.sidebar.focusSidebar(nil)
        owner.sidebar.list.visualJump(original)
        owner.sidebar.focusSidebar(nil)
        try await wait("the server moved the client") { owner.testModel?.selection.pane == first }
        await mainQueueFence()
        XCTAssertTrue(owner.sidebar.list.containsFocus, "new focus intent must cancel a deferred pane target")
        let list = owner.sidebar.list, table = list.visualTable
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderBack(nil)
        owner.window.display()
        func click(_ index: Int) throws {
            let rect = table.rect(ofRow: index)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            for type: NSEvent.EventType in [.leftMouseUp, .leftMouseDown] {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)), atStart: true)
            }
            owner.window.sendEvent(try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { owner.window.sendEvent(up) }
        }
        list.leave()
        let pane = try XCTUnwrap(owner.window.firstResponder as? PaneView)
        try await wait("the copy pane is ready") { !pane.restoring }
        pane.toggleCopyMode(nil)
        try await wait("the pane enters copy mode") { if case .cursor = pane.copyMode { true } else { false } }
        try click(try XCTUnwrap(list.visualRows.firstIndex { $0.target?.pane == pane.pane }))
        XCTAssertTrue(owner.window.firstResponder === pane)
        XCTAssertNotNil(pane.copyMode, "a sidebar click does not end the pane's copy mode")
        pane.endCopy()
        for floating in [false, true] {
            owner.sidebar.isCollapsed = floating
            owner.sidebar.focusSidebar(nil)
            let index = try XCTUnwrap(list.visualRows.firstIndex { $0.target != nil && $0.target != list.position })
            let target = try XCTUnwrap(list.visualRows[index].target)
            try click(index)
            try await wait("mouse selection completed") { list.position == target }
            XCTAssertTrue(list.containsFocus)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            NSApp.postEvent(event, atStart: true)
            owner.window.sendEvent(try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)))
            try await wait("Return leaves sidebar") { !list.containsFocus }
            XCTAssertFalse(owner.sidebar.isFloating)
        }
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

    func testOSC52ClipboardConsentAndPrivatePaneTransport() async throws {
        let copy = Data("copied ✓".utf8).base64EncodedString()
        let script = directory.appendingPathComponent("clipboard.py")
        let result = directory.appendingPathComponent("clipboard-reply")
        let ready = directory.appendingPathComponent("clipboard-ready")
        let go = directory.appendingPathComponent("clipboard-go")
        try clipboardQueryScript(ready: ready.path, result: result.path, query: "\\x1b]52;p;?\\x1b\\\\", deadline: 12).write(to: script, atomically: true, encoding: .utf8)
        try await start(pane: "while [ ! -e " + SSH.quote(go.path) + " ]; do sleep 0.02; done; printf '\\033]52;c;\(copy)\\007'; exec /usr/bin/python3 " + SSH.quote(script.path))
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
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        let board = runtime.pasteboard
        board.clearContents()
        board.setString("before", forType: .string)
        board.clearContents()
        board.setString("before-live", forType: .string)
        try client?.focus(true)
        try Data().write(to: go)
        try await wait("OSC52 private pane printf live copy") { board.string(forType: .string) == "copied ✓" }
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
        XCTAssertEqual(try Data(contentsOf: result), expected, "the reply goes to the pane through the server")
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
        let rows = { sidebarRows(owner.snapshot).rows.filter { $0.topLevel != nil } }
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
        if let failure = verifySnapshot(of: scene, as: .image, named: "light-window-root", record: record, snapshotDirectory: snapshots, testName: "palette"),
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
        XCTAssertEqual(list.visualRows.first { $0.id == rows[selected].id }?.children, .expanded)
        try key(123)
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
