import AppKit
import GhosttyKit
import KoClient
import KoModel
import SidebarFeed
import SnapshotTesting
import XCTest
@testable import Kido

// The runtimes that a pane can run in: the stripe, the pill and the row suffix, then the palette's rows
// and step. The window states run against a private server whose `command` runtimes are held starting,
// made to fail or left up; the sidebar and the palette read a model fixture.
let runtimeGapWithMessage = "ssh: connect to host gpu-1 port 22: Connection refused"

extension VisualTestCase {
    // Writes the runtimes file that the private server of this test reads from the private config directory.
    // The Visual scheme lets the server run `command` runtimes; a test never changes its own environment.
    func koRuntimes(_ runtimes: [String: [String: Any]]) throws {
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"])
        try FileManager.default.createDirectory(atPath: config + "/ko", withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: config + "/ko/runtimes.json")
        try JSONSerialization.data(withJSONObject: ["runtimes": runtimes], options: [.sortedKeys]).write(to: file)
        addTeardownBlock { @MainActor in try? FileManager.default.removeItem(at: file) }
    }

    // A pane that prints `text`, then runs `cat` in raw mode, in the runtime when one is named.
    func runtimePane(_ runtime: String?, _ text: String, vars: String = "{}", status: String = "", cwd: String? = nil) -> String {
        let script = "printf '\(text)'; \(status)stty raw -echo; printf '\\033]2;raw-ready\\007'; exec /bin/cat"
        let command = try! String(decoding: JSONSerialization.data(withJSONObject: ["type": "shell", "command": script]), as: UTF8.self)
        return #"{"pane":{"new":{\#(runtime.map { #""runtime":"\#($0)","# } ?? "")\#(cwd.map { #""cwd":"\#($0)","# } ?? "")"vars":\#(vars),"command":\#(command)}}}"#
    }
}

private let routedVars = #"{"pi.session":"s1","pi.name":"kido-app","pi.runtime":{"name":"buildbox","cwd":"/src/kido"}}"#
private let piStatus = "printf '\\033]7501;state=idle:app=pi\\007'; "

private func splitTree(_ axis: String, _ children: [String]) -> String { #"{"split":"\#(axis)","children":[\#(children.joined(separator: ","))]}"# }

extension VisualTests {
    private func marks(_ condition: @escaping @MainActor ([PaneID: RuntimeMark]) -> Bool) async throws {
        try await wait("the runtimes' marks") { condition(self.session.marks) }
    }

    // The window of the test over a private server. The dark theme is a runtime of its own, with a config file
    // that stays in place.
    private func startThemed(_ dark: Bool, windows: String) async throws {
        var config: String?
        if dark {
            config = FileManager.default.temporaryDirectory.appendingPathComponent("kido-runtime-dark-\(getpid()).conf").path
            let theme = ThemeConf.line(.init(light: "kido-dark", dark: "kido-dark"))
            try "\(theme)\nfont-family = Menlo\nfont-size = 13\ncursor-style-blink = false\n".write(toFile: try XCTUnwrap(config), atomically: true, encoding: .utf8)
        }
        try await start(configFile: config, windows: windows)
        if dark { window.appearance = NSAppearance(named: .darkAqua) }
    }

    // Replaces what a pane of a runtime shows: the wrapper of the runtime clears the screen as the pane starts.
    private func fill(_ id: PaneID, _ text: String) async throws {
        let pane = try XCTUnwrap(terminal?.panes.first { $0.pane == id })
        try await emit(pane, "\u{1b}[2J\u{1b}[H" + text)
    }

    private func runtimeSnapshot(_ dark: Bool, _ state: String) async throws {
        try await snapshot("\(dark ? "dark" : "light")-\(state)", testName: "runtime")
    }

    private func hover(_ pane: PaneID, entering: Bool = true) async throws {
        let chrome = try XCTUnwrap(terminal?.subviews.compactMap { $0 as? PaneChrome }.first { $0.pane == pane })
        let point = chrome.convert(NSPoint(x: chrome.toolbarFrame.midX, y: chrome.toolbarFrame.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: entering ? point : .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        chrome.mouseMoved(with: event)
        if entering {
            try await wait("the toolbar fades in") { chrome.subviews.compactMap { $0 as? PaneToolbar }.first.map { $0.alphaValue == 1 } == true }
        } else {
            try await wait("the toolbar fades out") { chrome.subviews.compactMap { $0 as? PaneToolbar }.allSatisfy { $0.alphaValue == 0 } }
        }
    }

    // window, window-hover, zoomed and label-find: a runtime pane, a host pane and a routed pi agent.
    func runtimeWindowStates(dark: Bool, find: Bool = false) async throws {
        try koRuntimes(["buildbox": ["kind": "command"]])
        RuntimePill.spins = false
        let tree = splitTree("h", [
            runtimePane("buildbox", "buildbox ~/src/kido\\r\\n$ make verify\\r\\ncargo build ok\\r\\n"),
            splitTree("v", [
                runtimePane(nil, "~/Workspace/kido\\r\\n$ git status --short\\r\\n M ko_server/src/runtime/pane.rs\\r\\n"),
                runtimePane(nil, "pi - kido-app\\r\\ntools in buildbox\\r\\n", vars: routedVars, status: piStatus),
            ]),
        ])
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree)}]"#)
        let (first, routed) = (PaneID(number: 1), PaneID(number: 3))
        try await marks { $0[first]?.state == .up && $0[routed]?.routed == true && $0[PaneID(number: 2)] == nil }
        try client?.select(KO_SELECT_PANE, first)
        try await wait("the runtime pane is active") { self.terminal?.active == first }
        try await fill(first, "buildbox ~/src/kido\r\n$ make verify\r\ncargo build ok")
        try await settle()
        if find {
            let pane = try XCTUnwrap(terminal?.panes.first { $0.pane == first })
            pane.showFind(nil)
            try await wait("the find capsule") { pane.find != nil }
            try await hover(first)
            try await runtimeSnapshot(dark, "label-find")
            pane.find?.close()
            try await wait("the find capsule closed") { pane.find == nil }
            return
        }
        try await runtimeSnapshot(dark, "window")
        try await hover(first)
        try await runtimeSnapshot(dark, "window-hover")
        try await hover(first, entering: false)
        try await toggleZoom(1)
        try await wait("the zoom") { self.terminal?.panes.filter { !$0.isHidden }.count == 1 }
        try await settle()
        try await runtimeSnapshot(dark, "zoomed")
    }

    // starting: a runtime whose start is held, with its dashed stripe and the spinner in the pill.
    func runtimeStartingState(dark: Bool) async throws {
        let fifo = directory.path + "/hold"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        try koRuntimes(["e2e": ["kind": "command", "up": ["/bin/sh", "-c", "read hold < '\(fifo)'"]]])
        RuntimePill.spins = false
        let tree = splitTree("h", [runtimePane("e2e", ""), runtimePane(nil, "~/Workspace/kido\\r\\n$ \\r\\n")])
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree)}]"#)
        try await marks { $0[PaneID(number: 1)]?.state == .starting }
        try client?.select(KO_SELECT_PANE, PaneID(number: 1))
        try await wait("the runtime pane is active") { self.terminal?.active == PaneID(number: 1) }
        try await settle()
        try await runtimeSnapshot(dark, "starting")
    }

    // failed: the pill carries the message, and the pane's screen the same message from ko.
    func runtimeFailedState(dark: Bool) async throws {
        try koRuntimes(["gpu-1": ["kind": "command", "up": ["/bin/sh", "-c", "echo '\(runtimeGapWithMessage)' >&2; exit 255"]]])
        RuntimePill.spins = false
        let tree = splitTree("h", [runtimePane("gpu-1", ""), runtimePane(nil, "~/Workspace/kido\\r\\n$ \\r\\n")])
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree)}]"#)
        try await marks { $0[PaneID(number: 1)]?.failure == runtimeGapWithMessage }
        try client?.select(KO_SELECT_PANE, PaneID(number: 1))
        try await wait("the runtime pane is active") { self.terminal?.active == PaneID(number: 1) }
        try await settle()
        try await runtimeSnapshot(dark, "failed")
    }

    // float: a float in a runtime over two host panes, its stripe clipped by the card's corners.
    func runtimeFloatState(dark: Bool) async throws {
        try koRuntimes(["py311": ["kind": "command"]])
        RuntimePill.spins = false
        let float = runtimePane("py311", "py311 /work\\r\\n$ pytest -x\\r\\n")
        let tree = splitTree("h", [runtimePane(nil, "left\\r\\n"), runtimePane(nil, "right\\r\\n")])
        let floats = #"[{"pane":\#(String(float.dropFirst(8).dropLast())),"x":10,"y":4,"cols":34,"rows":8}]"#
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree),"floats":\#(floats)}]"#)
        let pane = PaneID(number: 3)
        try await marks { $0[pane]?.state == .up }
        try client?.select(KO_SELECT_PANE, pane)
        try await wait("the float is active") { self.terminal?.active == pane }
        try await fill(pane, "py311 /work\r\n$ pytest -x")
        try await settle()
        try await runtimeSnapshot(dark, "float")
    }

    // colour-hash and colour-config: four runtimes in four panes; gpu-1 takes its configured colour.
    func runtimeColourState(dark: Bool, configured: Bool) async throws {
        var gpu: [String: Any] = ["kind": "command"]
        if configured { gpu["color"] = "#d08a2a" }
        try koRuntimes(["buildbox": ["kind": "command"], "py311": ["kind": "command"], "gpu-1": gpu, "e2e": ["kind": "command"]])
        RuntimePill.spins = false
        let names = ["buildbox", "py311", "gpu-1", "e2e"]
        let tree = splitTree("h", [splitTree("v", names[..<2].map { runtimePane($0, "\($0)\\r\\n") }), splitTree("v", names[2...].map { runtimePane($0, "\($0)\\r\\n") })])
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree)}]"#)
        try await marks { marks in names.indices.allSatisfy { marks[PaneID(number: UInt32($0 + 1))]?.state == .up } }
        try client?.select(KO_SELECT_PANE, PaneID(number: 1))
        try await wait("the first pane is active") { self.terminal?.active == PaneID(number: 1) }
        for (index, name) in names.enumerated() { try await fill(PaneID(number: UInt32(index + 1)), name) }
        try await settle()
        try await runtimeSnapshot(dark, configured ? "colour-config" : "colour-hash")
    }

    func testRuntimeWindowLight() async throws { try await runtimeWindowStates(dark: false) }
    func testRuntimeWindowDark() async throws { try await runtimeWindowStates(dark: true) }
    func testRuntimeLabelFindLight() async throws { try await runtimeWindowStates(dark: false, find: true) }
    func testRuntimeLabelFindDark() async throws { try await runtimeWindowStates(dark: true, find: true) }
    func testRuntimeStartingLight() async throws { try await runtimeStartingState(dark: false) }
    func testRuntimeStartingDark() async throws { try await runtimeStartingState(dark: true) }
    func testRuntimeFailedLight() async throws { try await runtimeFailedState(dark: false) }
    func testRuntimeFailedDark() async throws { try await runtimeFailedState(dark: true) }
    func testRuntimeFloatLight() async throws { try await runtimeFloatState(dark: false) }
    func testRuntimeFloatDark() async throws { try await runtimeFloatState(dark: true) }
    func testRuntimeColourHashLight() async throws { try await runtimeColourState(dark: false, configured: false) }
    func testRuntimeColourHashDark() async throws { try await runtimeColourState(dark: true, configured: false) }
    func testRuntimeColourConfigLight() async throws { try await runtimeColourState(dark: false, configured: true) }
    func testRuntimeColourConfigDark() async throws { try await runtimeColourState(dark: true, configured: true) }
}

private func marked(_ node: SidebarFeed.Node, _ runtime: RuntimeMark?) -> SidebarFeed.Node {
    var item = node.item
    item.runtime = runtime
    return .item(item)
}

private func runtimeMark(_ name: String, _ state: KoSchema.LinkState = .up, kind: KoSchema.RuntimeKind = .ssh, routed: Bool = false) -> RuntimeMark {
    RuntimeMark(KoSchema.ClientRuntime(kind: kind, name: name, state: state), routed: routed)
}

// rows and routed: the sidebar's suffix in every case, and a routed pi agent's row.
@MainActor final class RuntimeSidebarTests: VisualTestCase {
    private func list(dark: Bool) -> (SidebarView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 560), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.colorSpace = .displayP3
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let list = SidebarView()
        list.captionDelay = 0
        list.terminalDark = dark
        window.contentView = list
        return (list, window)
    }

    func testRuntimeRows() throws {
        SidebarView.visualNow = Date(timeIntervalSince1970: 1791131198)
        defer { SidebarView.visualNow = nil }
        let buildbox = runtimeMark("buildbox"), py311 = runtimeMark("py311", kind: .container)
        let routed = runtimeMark("buildbox", routed: true)
        let tree: [SidebarFeed.Node] = [
            fixtureNode(1, "Terminal", shellLifecycle()),
            marked(fixtureNode(2, "make verify", shellLifecycle(.running(.init(command: "make verify", startedAt: fixtureSince), fullscreen: false)), run: "r-2", started: 1791131000, mark: .running), buildbox),
            marked(fixtureNode(3, "kido-app", piLifecycle(session: "s3"), children: [
                marked(fixtureNode(4, "make test", shellLifecycle(.running(.init(command: "make test", startedAt: fixtureSince), fullscreen: false)), run: "r-4", started: 1791131100, mark: .running), buildbox),
                marked(fixtureNode(5, "pi-review", piLifecycle(session: "s5"), children: [
                    marked(fixtureNode(11, "pi-review-notes", piLifecycle(session: "s11")), routed),
                ]), routed),
                marked(fixtureNode(6, "pytest -x", shellLifecycle(.running(.init(command: "pytest -x", startedAt: fixtureSince), fullscreen: false)), run: "r-6", started: 1791131150, mark: .running), py311),
            ]), routed),
            marked(fixtureNode(7, "trainer", piLifecycle(session: "s7")), runtimeMark("py311", routed: true)),
            marked(fixtureNode(8, "nvidia-smi", shellLifecycle(shellExit(1, command: "nvidia-smi")), mark: .failed), runtimeMark("gpu-1", .failed(.init(message: runtimeGapWithMessage)))),
            marked(fixtureNode(9, "Terminal", shellLifecycle()), runtimeMark("e2e", .starting, kind: .command)),
            marked(fixtureNode(10, "a very long title that truncates before the suffix does", shellLifecycle(.running(.init(command: "a very long title that truncates before the suffix does", startedAt: fixtureSince), fullscreen: false)), run: "r-10", started: 1791131190, mark: .running), py311),
        ]
        for dark in [false, true] {
            let (list, window) = list(dark: dark)
            list.update(fixtureSnapshot(window: 3, pane: 3, [(name: "main", nodes: tree)]))
            sidebarSnapshot(list, "\(dark ? "dark" : "light")-rows", testName: "runtime")
            _ = window
        }
    }

    func testRuntimeRoutedRow() throws {
        SidebarView.visualNow = Date(timeIntervalSince1970: 1791131198)
        defer { SidebarView.visualNow = nil }
        let tree: [SidebarFeed.Node] = [
            marked(fixtureNode(3, "kido-app", piLifecycle(.running(progress: nil), msg: "Running the e2e suite", session: "s3"), run: "r-3", started: 1791131000, mark: .running), runtimeMark("buildbox", routed: true)),
        ]
        for dark in [false, true] {
            let (list, window) = list(dark: dark)
            list.update(fixtureSnapshot(window: 3, pane: 3, [(name: "main", nodes: tree)]))
            sidebarSnapshot(list, "\(dark ? "dark" : "light")-routed", testName: "runtime")
            _ = window
        }
    }
}

// palette-root, palette-step, palette-step-failed, palette-step-host and palette-step-nofocus.
@MainActor final class RuntimePaletteTests: VisualTestCase {
    func testRuntimePalette() async throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-palette-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: config) }
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let runtimes = [
            KoSchema.ClientRuntime(kind: .ssh, name: "buildbox", state: .up),
            KoSchema.ClientRuntime(kind: .container, name: "py311", state: .up),
            KoSchema.ClientRuntime(kind: .ssh, name: "gpu-1", state: .failed(.init(message: runtimeGapWithMessage))),
            KoSchema.ClientRuntime(kind: .command, name: "e2e", state: .starting),
        ]
        for (theme, background, foreground) in [("light", "fff9ec", "424242"), ("dark", "171717", "c9c9c9")] {
            try "background = #\(background)\nforeground = #\(foreground)\n".write(to: config, atomically: true, encoding: .utf8)
            let board = NSPasteboard(name: .init("runtime-palette-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
            let suite = "runtime-palette-" + UUID().uuidString
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            let app = AppDelegate(runtime: runtime, routes: WindowRoutes(preferences: preferences))
            let owner = try XCTUnwrap(app.open(.local, start: false))
            owner.window.setFrame(NSRect(origin: owner.window.frame.origin, size: NSSize(width: 1100, height: 740)), display: false)
            defer { app.closePalette(); owner.close() }
            let tree: [SidebarFeed.Node] = [
                marked(fixtureNode(1, "make verify", shellLifecycle(.running(.init(command: "make verify", startedAt: fixtureSince), fullscreen: false)), run: "r-1", started: 1791131000, mark: .running), RuntimeMark(runtimes[0])),
                fixtureNode(2, "kido-app", piLifecycle(session: "s2")),
            ]
            var snapshot = fixtureSnapshot(window: 1, pane: 1, [(name: "main", nodes: tree)])
            owner.testRuntimes = (runtimes, "buildbox")
            owner.testReceive(snapshot)
            NSApp.mainMenu = app.mainMenu()
            let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 1), font: 13, input: { _ in }))
            owner.sidebar.content.addSubview(pane)
            owner.window.makeFirstResponder(pane)
            defer { pane.dispose(); pane.removeFromSuperview() }
            app.togglePalette()
            var palette = try XCTUnwrap(app.palettePanel).palette
            func image(_ name: String) {
                palette.layoutSubtreeIfNeeded()
                let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                if let failure = verifySnapshot(of: palette, as: .image, named: "\(theme)-\(name)", record: record, testName: "runtime"),
                   !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
            }
            XCTAssertEqual(palette.shown.prefix(3).map(\.entry.title), ["make verify", "@kido-app", "Host"], "the panes come first, then the runtimes")
            XCTAssertEqual(palette.selectedEntry?.id, .runtime(nil), "the host comes first and is selected while the pane in focus runs in a runtime")
            XCTAssertEqual(palette.shown.compactMap { entry -> String? in if case .runtime = entry.entry.id { entry.entry.title } else { nil } },
                           ["Host", "Runtime: buildbox", "Runtime: py311", "Runtime: gpu-1", "Runtime: e2e"])
            XCTAssertEqual(palette.shown.compactMap { entry -> String? in if case .runtime = entry.entry.id { entry.entry.detail } else { nil } },
                           ["this Mac", "ssh · up", "container · up", "ssh · failed · \(runtimeGapWithMessage)", "command · starting"])
            image("palette-root")
            func step(_ name: String?, _ state: KoSchema.LinkState = .up) -> RuntimeMark? {
                name.map { RuntimeMark(KoSchema.ClientRuntime(kind: .ssh, name: $0, state: state)) }
            }
            palette.enter(.runtime(step("buildbox")))
            XCTAssertEqual(palette.shown.map(\.entry.title), ["New Window", "Split Right", "Split Down"])
            XCTAssertEqual(palette.shown.map(\.entry.detail), ["in session main", "beside the focused pane", "below the focused pane"])
            image("palette-step")
            palette.enter(.root)
            palette.enter(.runtime(step("gpu-1", .failed(.init(message: runtimeGapWithMessage)))))
            XCTAssertEqual(palette.error, "gpu-1 failed: \(runtimeGapWithMessage). The new pane starts it again.")
            image("palette-step-failed")
            palette.enter(.root)
            palette.enter(.runtime(step(nil)))
            image("palette-step-host")
            app.closePalette()
            owner.window.makeFirstResponder(nil)
            pane.removeFromSuperview()
            app.togglePalette()
            palette = try XCTUnwrap(app.palettePanel).palette
            palette.enter(.runtime(step("buildbox")))
            XCTAssertEqual(palette.shown.map(\.entry.title), ["New Window"], "the splits need a live pane in focus")
            image("palette-step-nofocus")
            // The step follows the model: a state change adds and removes the status line, and keeps the query and the row.
            app.closePalette()
            owner.window.makeFirstResponder(pane)
            owner.sidebar.content.addSubview(pane)
            owner.window.makeFirstResponder(pane)
            app.togglePalette()
            palette = try XCTUnwrap(app.palettePanel).palette
            palette.enter(.runtime(step("e2e", .starting)))
            palette.field.stringValue = "split"
            palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertNil(palette.error)
            let before = palette.selectedEntry?.id
            func change(_ state: KoSchema.LinkState) {
                owner.testRuntimes = (runtimes.map { $0.name == "e2e" ? KoSchema.ClientRuntime(kind: .command, name: "e2e", state: state) : $0 }, "buildbox")
                app.paletteStateChanged()
            }
            change(.failed(.init(message: "boom")))
            XCTAssertEqual(palette.error, "e2e failed: boom. The new pane starts it again.")
            XCTAssertEqual(palette.mode, .runtime(RuntimeMark(KoSchema.ClientRuntime(kind: .command, name: "e2e", state: .failed(.init(message: "boom"))))))
            XCTAssertEqual(palette.field.stringValue, "split")
            XCTAssertEqual(palette.selectedEntry?.id, before)
            change(.up)
            XCTAssertNil(palette.error)
            XCTAssertEqual(palette.mode, .runtime(RuntimeMark(KoSchema.ClientRuntime(kind: .command, name: "e2e", state: .up))))
        }
    }
}


// The commands that make a pane from another: the pane's runtime and directory, in the request and in the row.
@MainActor final class RuntimeActionTests: VisualTestCase {
    func testANewPaneTakesItsRuntimeFromThePaneItIsMadeFromAndItsDirectoryOnlyFromAHostPane() async throws {
        try koRuntimes(["box": ["kind": "command"]])
        let dir = try koServerDir()
        _ = try await KoServer.launch(dir: dir)
        let tree = #"{"split":"h","children":[\#(runtimePane(nil, "a", cwd: "/tmp")),\#(runtimePane("box", "b")),\#(runtimePane(nil, "c", vars: routedVars, status: piStatus, cwd: "/var"))]}"#
        try await koPut(dir, #"[{"name":"main","windows":[{"name":"w","tree":\#(tree)}]}]"#)
        PaneView.renderOffscreen = true
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-actions-\(getpid()).conf")
        try "\(ThemeConf.line(.init()))\nfont-family = Menlo\nfont-size = 13\n".write(to: config, atomically: true, encoding: .utf8)
        let board = NSPasteboard(name: .init("runtime-actions-" + UUID().uuidString))
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board)), start: false)
        owner.testServerDir = dir
        addTeardownBlock { @MainActor in
            owner.close()
            board.releaseGlobally()
            PaneView.renderOffscreen = false
        }
        owner.start()
        let (host, box, routed) = (PaneID(number: 1), PaneID(number: 2), PaneID(number: 3))
        try await wait("the panes and their runtimes", within: 10) {
            let marks = owner.testModel?.runtimeMarks
            return marks?[box]?.state == .up && marks?[routed]?.routed == true && owner.testSession?.cell != nil
        }
        let model = try XCTUnwrap(owner.testModel)
        let cwd = { (pane: PaneID) in model.pane(pane)?.cwd }
        XCTAssertEqual(model.newPane(from: host), KoSchema.CreatePane(cwd: cwd(host), runtime: nil), "a host pane keeps its directory")
        XCTAssertEqual(model.newPane(from: routed), KoSchema.CreatePane(cwd: cwd(routed), runtime: nil), "a routed pi's pane is a host pane")
        XCTAssertEqual(model.newPane(from: box), KoSchema.CreatePane(cwd: nil, runtime: "box"), "a runtime pane's directory is a path in the runtime, so nothing goes with it")
        XCTAssertEqual(model.newPane(from: box, .host), KoSchema.CreatePane(cwd: nil, runtime: nil))
        XCTAssertEqual(model.newPane(from: host, .named("box")), KoSchema.CreatePane(cwd: cwd(host), runtime: "box"), "the server maps a host directory into a runtime")
        func made(_ number: UInt32, runtime: String?, _ command: () -> Void) async throws {
            command()
            try await wait("pane \(number)", within: 10) { owner.testModel?.pane(PaneID(number: number)) != nil }
            XCTAssertEqual(owner.testModel?.pane(PaneID(number: number))?.runtime, runtime, "pane \(number)")
        }
        try await made(4, runtime: nil) { owner.paneCommand(.split(.right), box, .host) }
        try await made(5, runtime: "box") { owner.paneCommand(.split(.right), host, .named("box")) }
        try await made(6, runtime: nil) { owner.paneCommand(.split(.down), routed) }
        try await made(7, runtime: "box") { owner.paneCommand(.split(.down), box) }
        XCTAssertEqual(owner.testModel?.pane(PaneID(number: 6))?.cwd, cwd(routed), "a split of a host pane keeps its directory")
    }
}
