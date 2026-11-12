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
    // Writes the config file (JSON is YAML) that the private server of this test reads from the private config directory.
    // The Visual scheme lets the server run `command` runtimes; a test never changes its own environment.
    func koRuntimes(_ runtimes: [String: [String: Any]]) throws {
        let config = try XCTUnwrap(ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"])
        try FileManager.default.createDirectory(atPath: config + "/ko", withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: config + "/ko/config.yaml")
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

let routedVars = #"{"pi.session":"s1","pi.name":"kido-app","pi.runtime":{"name":"buildbox","cwd":"/src/kido"}}"#
let piStatus = "printf '\\033]7501;state=idle:app=pi\\007'; "

func splitTree(_ axis: String, _ children: [String]) -> String { #"{"split":"\#(axis)","children":[\#(children.joined(separator: ","))]}"# }

private func marked(_ node: SidebarFeed.Node, _ runtime: RuntimeMark?) -> SidebarFeed.Node {
    var item = node.item
    item.runtime = runtime
    return .item(item)
}

private func runtimeMark(_ name: String, _ state: KoSchema.LinkState = .up, kind: KoSchema.RuntimeKind = .ssh, routed: Bool = false) -> RuntimeMark {
    RuntimeMark.known(KoSchema.ClientRuntime(kind: kind, name: name, source: .config, state: state), routed: routed)
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
        let buildbox = runtimeMark("buildbox"), py311 = runtimeMark("py311", kind: .container)
        let routed = runtimeMark("buildbox", routed: true)
        let tree: [SidebarFeed.Node] = [
            fixtureNode(1, "Terminal", shellLifecycle()),
            marked(fixtureNode(2, "make verify", shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "make verify", startedAt: fixtureSince))))), mark: .running), buildbox),
            marked(fixtureNode(3, "kido-app", piLifecycle(session: "s3"), children: [
                marked(fixtureNode(4, "make test", shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "make test", startedAt: fixtureSince))))), mark: .running), buildbox),
                marked(fixtureNode(5, "pi-review", piLifecycle(session: "s5"), children: [
                    marked(fixtureNode(11, "pi-review-notes", piLifecycle(session: "s11")), routed),
                ]), routed),
                marked(fixtureNode(6, "pytest -x", shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "pytest -x", startedAt: fixtureSince))))), mark: .running), py311),
            ]), routed),
            marked(fixtureNode(7, "trainer", piLifecycle(session: "s7")), runtimeMark("py311", routed: true)),
            marked(fixtureNode(8, "nvidia-smi", shellLifecycle(shellExit(1, command: "nvidia-smi")), mark: .failed), runtimeMark("gpu-1", .failed(.init(message: runtimeGapWithMessage)))),
            marked(fixtureNode(9, "Terminal", shellLifecycle()), runtimeMark("e2e", .starting, kind: .command)),
            marked(fixtureNode(10, "a very long title that truncates before the suffix does", shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "a very long title that truncates before the suffix does", startedAt: fixtureSince))))), mark: .running), py311),
        ]
        for dark in [false, true] {
            let (list, window) = list(dark: dark)
            list.show(fixtureSnapshot(window: 3, pane: 3, [(name: "main", nodes: tree)]))
            sidebarSnapshot(list, "\(dark ? "dark" : "light")-rows", testName: "runtime")
            _ = window
        }
    }

    func testRuntimeRoutedRow() throws {
        let tree: [SidebarFeed.Node] = [
            marked(fixtureNode(3, "kido-app", piLifecycle(.running(.init()), msg: "Running the e2e suite", session: "s3"), mark: .running), runtimeMark("buildbox", routed: true)),
        ]
        for dark in [false, true] {
            let (list, window) = list(dark: dark)
            list.show(fixtureSnapshot(window: 3, pane: 3, [(name: "main", nodes: tree)]))
            sidebarSnapshot(list, "\(dark ? "dark" : "light")-routed", testName: "runtime")
            _ = window
        }
    }
}

// palette-root, palette-step, palette-step-failed, palette-step-host and palette-step-nofocus.
@MainActor final class RuntimePaletteTests: VisualTestCase {
    func testRuntimePalette() async throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-palette-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: config) }
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let runtimes = [
            KoSchema.ClientRuntime(kind: .ssh, name: "buildbox", source: .config, state: .up),
            KoSchema.ClientRuntime(kind: .container, name: "py311", source: .config, state: .up),
            KoSchema.ClientRuntime(kind: .ssh, name: "gpu-1", source: .config, state: .failed(.init(message: runtimeGapWithMessage))),
            KoSchema.ClientRuntime(kind: .command, name: "e2e", source: .config, state: .starting),
        ]
        for (theme, background, foreground) in [("light", "fff9ec", "424242"), ("dark", "171717", "c9c9c9")] {
            try configYAML(at: config, background: background, foreground: foreground).write(to: config, atomically: true, encoding: .utf8)
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
                marked(fixtureNode(1, "make verify", shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "make verify", startedAt: fixtureSince))))), mark: .running), RuntimeMark.known(runtimes[0], routed: false)),
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
                checkSnapshot { verifySnapshot(of: palette, as: .pixels, named: "\(theme)-\(name)", record: $0, testName: "runtime") }
            }
            XCTAssertEqual(palette.shown.prefix(3).map(\.entry.title), ["make verify", "@kido-app", "Host"], "the panes come first, then the runtimes")
            XCTAssertEqual(palette.selectedEntry?.id, .hostRuntime, "the host comes first and is selected while the pane in focus runs in a runtime")
            XCTAssertEqual(palette.shown.compactMap { entry -> String? in switch entry.entry.id { case .hostRuntime, .runtime: entry.entry.title; default: nil } },
                           ["Host", "Runtime: buildbox", "Runtime: py311", "Runtime: gpu-1", "Runtime: e2e"])
            XCTAssertEqual(palette.shown.compactMap { entry -> String? in switch entry.entry.id { case .hostRuntime, .runtime: entry.entry.detail; default: nil } },
                           ["this Mac", "ssh · up", "container · up", "ssh · failed · \(runtimeGapWithMessage)", "command · starting"])
            image("palette-root")
            func step(_ name: String?, _ state: KoSchema.LinkState = .up) -> RuntimeMark? {
                name.map { RuntimeMark.known(KoSchema.ClientRuntime(kind: .ssh, name: $0, source: .config, state: state), routed: false) }
            }
            palette.enter(.runtime(step("buildbox")))
            XCTAssertEqual(palette.shown.map(\.entry.title), ["New Window", "Split Right", "Split Down", "Shut Down Runtime"])
            XCTAssertEqual(palette.shown.map(\.entry.detail), ["in session main", "beside the focused pane", "below the focused pane", "buildbox"])
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
            XCTAssertEqual(palette.shown.map(\.entry.title), ["New Window", "Shut Down Runtime"], "the splits need a live pane in focus")
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
                owner.testRuntimes = (runtimes.map { $0.name == "e2e" ? KoSchema.ClientRuntime(kind: .command, name: "e2e", source: .config, state: state) : $0 }, "buildbox")
                app.paletteStateChanged()
            }
            change(.failed(.init(message: "boom")))
            XCTAssertEqual(palette.error, "e2e failed: boom. The new pane starts it again.")
            XCTAssertEqual(palette.mode, .runtime(RuntimeMark.known(KoSchema.ClientRuntime(kind: .command, name: "e2e", source: .config, state: .failed(.init(message: "boom"))), routed: false)))
            XCTAssertEqual(palette.field.stringValue, "split")
            XCTAssertEqual(palette.selectedEntry?.id, before)
            change(.up)
            XCTAssertNil(palette.error)
            XCTAssertEqual(palette.mode, .runtime(RuntimeMark.known(KoSchema.ClientRuntime(kind: .command, name: "e2e", source: .config, state: .up), routed: false)))
        }
    }
}


// The commands that make a pane from another: the pane's runtime and directory, in the request and in the row.
@MainActor final class RuntimeActionTests: VisualTestCase {
    func testRuntimeShutdownConfirmation() async throws {
        try koRuntimes(["deb": ["command": [String: Any]()]])
        let dir = try koServerDir()
        _ = try await KoServer.launch(dir: dir)
        try await koPut(dir, #"[{"name":"main","windows":[{"name":"w","tree":\#(runtimePane("deb", "runtime"))}]}]"#)
        let board = NSPasteboard(name: .init("runtime-down-" + UUID().uuidString))
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        owner.testServerDir = dir
        defer { owner.close(); board.releaseGlobally() }
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        owner.start()
        try await wait("runtime up") { owner.runtimes.first?.state == .up && owner.runtimePaneCount(.init(name: "deb", source: .config)) == 1 }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            owner.window.appearance = NSAppearance(named: appearance)
            owner.shutDownRuntime(.init(name: "deb", source: .config))
            let alert = try XCTUnwrap(owner.preparedAlert?.alert)
            alert.window.appearance = NSAppearance(named: appearance)
            try await wait("the confirmation sheet") { owner.window.attachedSheet === alert.window }
            await mainQueueFence()
            alert.layout()
            let view = try XCTUnwrap(alert.window.contentView?.superview)
            checkSnapshot { verifySnapshot(of: view, as: .pixels, named: name, record: $0, testName: "runtimeShutdownConfirmation") }
            owner.respondToAlert(.alertSecondButtonReturn)
            try await wait("the confirmation closes") { owner.window.attachedSheet == nil }
        }
    }

    func testANewPaneTakesItsRuntimeFromThePaneItIsMadeFromAndAsksTheServerForItsDirectory() async throws {
        try koRuntimes(["box": ["command": [String: Any]()]])
        let dir = try koServerDir()
        _ = try await KoServer.launch(dir: dir)
        let tree = #"{"split":"h","children":[\#(runtimePane(nil, "a", cwd: "/tmp")),\#(runtimePane("box", "b")),\#(runtimePane(nil, "c", vars: routedVars, status: piStatus, cwd: "/var"))]}"#
        try await koPut(dir, #"[{"name":"main","windows":[{"name":"w","tree":\#(tree)}]}]"#)
        PaneView.renderOffscreen = true
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-actions-\(getpid()).yaml")
        try "app: {font: {size: 13}}\n".write(to: config, atomically: true, encoding: .utf8)
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
        let from = { (pane: PaneID) in KoSchema.Cwd.pane(.init(pane: pane)) }
        XCTAssertEqual(model.newPane(from: host), KoSchema.CreatePane(cwd: from(host), runtime: nil), "a host pane keeps its directory")
        XCTAssertEqual(model.newPane(from: routed), KoSchema.CreatePane(cwd: from(routed), runtime: nil), "a routed pi's pane is a host pane")
        XCTAssertEqual(model.newPane(from: box), KoSchema.CreatePane(cwd: from(box), runtime: "box"), "the server takes a runtime pane's directory as it is")
        XCTAssertEqual(model.newPane(from: box, .host), KoSchema.CreatePane(cwd: from(box), runtime: nil), "the server maps it back to the host or uses the default")
        XCTAssertEqual(model.newPane(from: host, .named("box")), KoSchema.CreatePane(cwd: from(host), runtime: "box"), "the server maps a host directory into a runtime")
        func made(_ number: UInt32, runtime: String?, _ command: () -> Void) async throws {
            command()
            try await wait("pane \(number)", within: 10) { owner.testModel?.pane(PaneID(number: number)) != nil }
            XCTAssertEqual(owner.testModel?.pane(PaneID(number: number))?.runtime, runtime, "pane \(number)")
        }
        try await made(4, runtime: nil) { owner.paneCommand(.split(.right), box, .host) }
        try await made(5, runtime: "box") { owner.paneCommand(.split(.right), host, .named("box")) }
        try await made(6, runtime: nil) { owner.paneCommand(.split(.down), routed) }
        try await made(7, runtime: "box") { owner.paneCommand(.split(.down), box) }
        let createdDirectory = try XCTUnwrap(owner.testModel?.pane(PaneID(number: 6))?.cwd)
        let sourceDirectory = try XCTUnwrap(model.pane(routed)?.cwd)
        XCTAssertEqual(URL(fileURLWithPath: createdDirectory).resolvingSymlinksInPath().path, URL(fileURLWithPath: sourceDirectory).resolvingSymlinksInPath().path, "a split of a host pane keeps its directory")
    }
}
