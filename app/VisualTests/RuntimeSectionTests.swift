import AppKit
import XCTest
import SnapshotTesting
import SidebarFeed
import KoModel
@testable import Kido

@MainActor final class RuntimeSectionTests: VisualTestCase {
    func testRuntimeSectionStartsAndStopsWithoutAddingAPane() async throws {
        try koRuntimes(["box": ["command": [String: Any]()]])
        let dir = try koServerDir()
        _ = try await KoServer.launch(dir: dir)
        let defineDev = "printf '%s' '{\"command\":{}}' | ko api --method PUT --input - /runtimes/dev; "
        let defineOther = "printf '%s' '{\"command\":{}}' | ko api --method PUT --input - /runtimes/other; "
        try await koPut(dir, #"[{"name":"main","windows":[{"name":"host","tree":\#(runtimePane(nil, "host", status: defineDev))}]},{"name":"other","windows":[{"name":"other","tree":\#(runtimePane(nil, "other", status: defineOther))}]}]"#)
        let board = NSPasteboard(name: .init("runtime-section-" + UUID().uuidString))
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        owner.testServerDir = dir
        defer { owner.close(); board.releaseGlobally() }
        owner.start()
        let section = owner.sidebar.list.runtimeSection
        let key = RuntimeKey(name: "box", source: .config)
        try await wait("the runtime rows") { owner.runtimes.count == 3 && section.rows.map { $0.runtime.name } == ["box", "dev"] }
        XCTAssertEqual(owner.runtimes.first?.state, .down)
        section.start(key)
        try await wait("the pane-less runtime starts") { owner.runtimes.first?.state == .up }
        XCTAssertEqual(owner.snapshot?.sessions.flatMap(\.nodes).count, 2)
        XCTAssertEqual(owner.runtimePaneCount(key), 0)
        owner.testRuntimes = (owner.runtimes, nil)
        section.stop(key)
        XCTAssertTrue(try XCTUnwrap(section.rows.first).stopping)
        XCTAssertNil(owner.preparedAlert)
        try await wait("the completed request clears stopping without a down model") { section.rows.first?.stopping == false }
        XCTAssertEqual(section.rows.first?.runtime.state, .up)
        owner.testRuntimes = nil
        owner.updateRuntimeSection()
        try await wait("the runtime is down") { owner.runtimes.first?.state == .down }
        XCTAssertEqual(owner.snapshot?.sessions.flatMap(\.nodes).count, 2)
        let sessions = try XCTUnwrap(owner.snapshot?.sessions)
        let current = try XCTUnwrap(owner.navigation.session)
        let other = try XCTUnwrap(sessions.first { $0.id != current }).id
        XCTAssertEqual(section.rows.map { $0.runtime.name }, ["box", "dev"])
        owner.perform(.selectSession(other))
        try await wait("the runtime list follows the selected session") { section.rows.map { $0.runtime.name } == ["box", "other"] }
        let command = NSMenuItem(title: "New Window", action: #selector(SidebarView.runCommand(_:)), keyEquivalent: "t")
        command.representedObject = PaneCommand.newWindow
        owner.sidebar.focusSidebar(nil)
        owner.window.makeFirstResponder(section)
        section.selection = .runtime(key)
        try await wait("the pane command is ready") { owner.sidebar.list.validateMenuItem(command) }
        let windows = owner.snapshot?.sessions.flatMap(\.nodes).count ?? 0
        owner.sidebar.list.runCommand(command)
        try await wait("the runtime-focused menu command adds a window") { (owner.snapshot?.sessions.flatMap(\.nodes).count ?? 0) == windows + 1 }
    }

    func testRuntimeSectionKeyboardAndActions() throws {
        let original = UserDefaults.standard.object(forKey: "runtimesCollapsed")
        defer { if let original { UserDefaults.standard.set(original, forKey: "runtimesCollapsed") } else { UserDefaults.standard.removeObject(forKey: "runtimesCollapsed") } }
        let section = RuntimeSection()
        let up = KoSchema.ClientRuntime(kind: .ssh, name: "buildbox", source: .config, state: .up)
        let down = KoSchema.ClientRuntime(kind: .container, name: "py311", source: .config, state: .down)
        section.rows = [.init(runtime: up, panes: 3, stopping: false), .init(runtime: down, panes: 0, stopping: false)]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 200), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = section
        defer { window.close() }
        section.collapsed = false
        let point = section.convert(NSPoint(x: 50, y: 43.5), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        XCTAssertTrue(window.makeFirstResponder(section))
        section.selection = .runtime(down.key)
        let menu = try XCTUnwrap(section.menu(for: event))
        XCTAssertEqual(section.selection, .runtime(down.key))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Start", "Shut Down…", "Copy Name"])
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.isEnabled), [false, true, true])
        section.collapsed = true
        section.selection = .header
        var actions: [String] = []
        section.start = { actions.append("start " + $0.name) }
        section.stop = { actions.append("stop " + $0.name) }
        section.open = { actions.append("open " + $0.name) }
        section.previous = { actions.append("previous") }
        section.leave = { actions.append("leave") }
        func key(_ code: UInt16, _ text: String = "") throws {
            section.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        }
        try key(125)
        XCTAssertEqual(section.selection, .header)
        try key(124)
        XCTAssertFalse(section.collapsed)
        try key(125)
        XCTAssertEqual(section.selection, .runtime(up.key))
        try key(49)
        try key(36)
        try key(125)
        try key(49)
        try key(125)
        XCTAssertEqual(section.selection, .runtime(down.key))
        try key(123)
        XCTAssertEqual(section.selection, .header)
        try key(126)
        section.selection = .runtime(up.key)
        section.rows[0] = .init(runtime: up, panes: 3, stopping: true)
        try key(49)
        section.rows.removeFirst()
        XCTAssertNil(section.selection)
        try key(53)
        XCTAssertEqual(actions, ["stop buildbox", "open buildbox", "start py311", "previous", "leave"])
    }

    func testRuntimeSectionStates() throws {
        let defaults = UserDefaults.standard.object(forKey: "runtimesCollapsed")
        defer { if let defaults { UserDefaults.standard.set(defaults, forKey: "runtimesCollapsed") } else { UserDefaults.standard.removeObject(forKey: "runtimesCollapsed") } }
        let runtimes = [
            KoSchema.ClientRuntime(kind: .ssh, name: "buildbox", source: .config, state: .up),
            KoSchema.ClientRuntime(kind: .container, name: "py311", source: .config, state: .down),
            KoSchema.ClientRuntime(color: "#d08a2a", kind: .ssh, name: "gpu-1", source: .config, state: .failed(.init(message: "ssh: connect to host gpu-1 port 22: Connection refused"))),
            KoSchema.ClientRuntime(kind: .podman, name: "e2e", source: .config, state: .starting),
        ]
        for dark in [false, true] {
            for state in ["collapsed", "expanded", "pinned-long", "none-hidden", "config-error", "hover", "hover-stop", "selected", "narrow", "adhoc", "stopping"] {
                let width: CGFloat = state == "narrow" ? 200 : 292
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 686), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.colorSpace = .displayP3
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let list = SidebarView()
                list.captionDelay = 0
                list.terminalDark = dark
                window.contentView = list
                list.wantsLayer = true
                list.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.137, green: 0.137, blue: 0.137, alpha: 1) : NSColor(srgbRed: 0.95, green: 0.928, blue: 0.879, alpha: 1)).cgColor
                let section = list.runtimeSection
                section.collapsed = state == "collapsed"
                section.rows = state == "none-hidden" ? [] : runtimes.enumerated().map { .init(runtime: $0.element, panes: $0.offset == 0 ? 3 : 0, stopping: state == "stopping" && $0.offset == 0) }
                if state == "adhoc" {
                    section.rows.append(.init(runtime: .init(kind: .container, name: "dev", source: .session(.init(id: SessionID(number: 1))), state: .up), panes: 1, stopping: false))
                }
                if state == "config-error" { section.configError = "/Users/me/.config/ko/config.yaml: runtimes: gpu-1: unknown field \"prot\"" }
                var tree: [Node] = [
                    .window(.init(id: WindowID(number: 1), children: [
                        fixtureItem(1, window: 1, "make verify", shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "make verify", startedAt: fixtureSince))))), mark: .running),
                        fixtureItem(2, window: 1, "Terminal", shellLifecycle()),
                        fixtureItem(3, window: 1, "kido-app", piLifecycle(session: "s3"), children: [
                            fixtureNode(4, "make e2e", shellLifecycle(.running(.init(fullscreen: false, origin: .command(.init(command: "make e2e", startedAt: fixtureSince))))), mark: .running),
                            fixtureNode(5, "pi-review", piLifecycle(.waiting(.init()), session: "s5"), mark: .waiting),
                        ]),
                    ])),
                    fixtureNode(6, "nvidia-smi", shellLifecycle(.unknown), mark: .failed),
                    fixtureNode(7, "Terminal", shellLifecycle()),
                    fixtureNode(8, "Terminal", shellLifecycle()),
                ]
                if state == "adhoc" { tree.append(fixtureNode(9, "pytest -x", shellLifecycle())) }
                var sessions: [(name: String, nodes: [Node])] = [("main", tree), ("visa", [fixtureNode(10, "Terminal", shellLifecycle())])]
                if state == "pinned-long" { for (i, name) in ["website", "tap", "bench", "notes"].enumerated() { sessions.append((name, [fixtureNode(UInt32(20 + i * 2), "@" + name, piLifecycle()), fixtureNode(UInt32(21 + i * 2), "Terminal", shellLifecycle())])) } }
                var snapshot = fixtureSnapshot(window: 1, pane: 1, sessions)
                snapshot.mapItems { item in
                    let index: Int? = switch item.id.number { case 1, 3, 4, 5: 0; case 6: 2; case 7: 3; default: nil }
                    if let index { item.runtime = RuntimeMark.known(runtimes[index], routed: item.id.number == 3) }
                }
                list.show(snapshot)
                list.layoutSubtreeIfNeeded()
                if state == "selected" { section.selection = .runtime(runtimes[0].key) }
                if state == "hover" || state == "hover-stop" {
                    let index = state == "hover" ? 1 : 0
                    let point = section.convert(NSPoint(x: width - 28, y: 29.5 + CGFloat(index) * 28 + 14), to: nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                    section.mouseMoved(with: event)
                }
                XCTAssertEqual(section.height == 0, state == "none-hidden")
                if state != "none-hidden" { XCTAssertEqual(section.frame.maxY, list.bounds.maxY - 10) }
                let name = "\(dark ? "dark" : "light")-\(state)"
                if state == "pinned-long" {
                    list.visualTable.tile()
                    list.visualTable.layoutSubtreeIfNeeded()
                    let footer = section.frame
                    list.visualTable.scrollRowToVisible(list.visualTable.numberOfRows - 1)
                    list.visualScroll.reflectScrolledClipView(list.visualScroll.contentView)
                    list.displayIfNeeded()
                    XCTAssertEqual(section.frame, footer)
                    XCTAssertGreaterThan(list.visualScroll.contentView.bounds.minY, 0)
                    checkSnapshot { verifySnapshot(of: list, as: .image, named: name, record: $0, testName: "runtime-section") }
                } else {
                    sidebarSnapshot(list, name, testName: "runtime-section")
                }
                window.close()
            }
        }
    }
}
