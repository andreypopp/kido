import AppKit
import GhosttyKit
import KoModel
import KoClient
import SnapshotTesting
import XCTest
@testable import Kido

@MainActor final class NoticesTests: VisualTestCase {
    private let move = ("Could not move the window", "window_3 is gone.")
    private let split = ("Could not split the pane", "The window is zoomed.")
    private let long = ("Could not open a window in gpu-1", "ssh: connect to host gpu-1.lab port 22: Operation timed out after 30 seconds. The runtime runs ssh in BatchMode, so a host that asks for a password fails at once; check the host, its ssh config and the key that the agent holds. The link stays failed until the next start.")

    private func fixture(_ side: String) async throws -> WindowOwner {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("notices-\(UUID().uuidString).yaml")
        try "app: {theme: kido-\(side)}\n".write(to: config, atomically: true, encoding: .utf8)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        let dir = try koServerDir()
        _ = try await KoServer.launch(dir: dir)
        let pane = koPane("printf 'buildbox ~/src/kido\\r\\n$ make verify\\r\\ncargo build --locked ........... ok\\r\\ncargo test -p ko_server ........ running\\r\\n'; " + rawScript)
        try await koPut(dir, #"[{"name":"main","windows":[{"name":"make verify","tree":{"split":"h","children":[\#(pane),{"split":"v","children":[\#(pane),\#(pane)]}]}}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = dir
        owner.notices.testTime = 0
        owner.window.setContentSize(NSSize(width: 1100, height: 740))
        owner.sidebar.isCollapsed = false
        owner.sidebar.splitView.setPosition(292, ofDividerAt: 0)
        owner.updateAppearance()
        owner.start()
        addTeardownBlock { @MainActor in owner.close(); board.releaseGlobally(); try? FileManager.default.removeItem(at: config) }
        try await wait("notice fixture connected") { owner.testSession?.windows.values.contains { !$0.isHidden && !$0.panes.isEmpty && $0.visualGeometryReady } == true }
        return owner
    }

    private func ready(_ owner: WindowOwner) async throws {
        owner.window.contentView?.superview?.layoutSubtreeIfNeeded()
        try await wait("pane geometry") {
            owner.testSession?.windows.values.filter { !$0.isHidden }.allSatisfy { $0.visualGeometryReady && $0.panes.allSatisfy(\.visualReady) } == true
        }
        for pane in owner.testSession?.windows.values.filter({ !$0.isHidden }).flatMap(\.panes) ?? [] {
            pane.scroller.isHidden = true
            await presentedFrame(pane)
        }
        CATransaction.flush()
    }

    func testMockupStates() async throws {
        for side in ["light", "dark"] {
            let owner = try await fixture(side)
            let error = ConfigError(path: owner.runtime.home + "/.config/ko/config.yaml", problem: .init(line: 14, column: 5, message: "runtimes: gpu-1: unknown field \"prot\""))
            for state in ["transient", "two", "long", "config", "config-transient", "columns", "float", "banner", "none", "fullscreen-docked", "fullscreen-floating", "floating", "collapsed", "fullscreen-collapsed"] {
                for entry in owner.notices.testTransients.entries { owner.notices.dismiss(entry.id) }
                owner.runtime.testConfigError(nil)
                owner.testBanner.isHidden = true
                owner.sidebar.dismissFloating()
                owner.sidebar.isCollapsed = state == "collapsed" || state == "floating" || state == "fullscreen-floating" || state == "fullscreen-collapsed"
                if state == "floating" || state == "fullscreen-floating" { owner.sidebar.focusSidebar(nil); owner.focusSelected() }
                let leaves = try XCTUnwrap(owner.testSession?.windows.values.first(where: { !$0.isHidden })).panes.map(\.pane).sorted { $0.number < $1.number }
                XCTAssertEqual(leaves.count, 3)
                let pane = leaves.map { #"{"pane":"\#($0)"}"# }
                let tree: String = switch state {
                case "columns": #"{"split":"h","children":[\#(pane[0]),\#(pane[1]),\#(pane[2])]}"#
                case "float": #"{"split":"h","children":[\#(pane[0]),\#(pane[1])]}"#
                default: #"{"split":"h","children":[\#(pane[0]),{"split":"v","children":[\#(pane[1]),\#(pane[2])]}]}"#
                }
                let floats = state == "float" ? #", "floats":[{"pane":"\#(leaves[2])","x":50,"y":30,"cols":40,"rows":12}]"# : ""
                if ["columns", "float", "banner"].contains(state) {
                    let dir = try XCTUnwrap(owner.testServerDir)
                    let current = try JSONDecoder().decode(KoSchema.Snapshot.self, from: Data(try await ko(["api", "/layout"], dir: dir).utf8))
                    let session = try XCTUnwrap(current.layout.sessions.first)
                    let window = try XCTUnwrap(session.windows.first)
                    let applied = try await ko(layoutPut(#"{"revision":\#(current.revision),"layout":{"sessions":[{"id":"\#(session.id)","name":"main","windows":[{"id":"\#(window.id)","name":"make verify","tree":\#(tree)\#(floats)}]}]}}"#, dir: dir), dir: dir)
                    guard let snapshot = try? JSONDecoder().decode(KoSchema.Snapshot.self, from: Data(applied.utf8)) else {
                        XCTFail(applied)
                        return
                    }
                    try await wait("new notice layout", within: 5) { (owner.testModel?.layout.revision ?? -1) >= snapshot.revision }
                }
                try await ready(owner)
                if ["config", "config-transient", "banner", "fullscreen-docked", "fullscreen-floating", "floating", "collapsed", "fullscreen-collapsed"].contains(state) { owner.runtime.testConfigError(error) }
                switch state {
                case "two": owner.notices.show(split.0, split.1); owner.notices.show(move.0, move.1)
                case "long": owner.notices.show(long.0, long.1)
                case "transient", "float": owner.notices.show(split.0, split.1)
                case "config-transient", "columns", "fullscreen-docked", "fullscreen-floating", "floating", "collapsed", "fullscreen-collapsed": owner.notices.show(move.0, move.1)
                default: break
                }
                if state == "banner" { owner.down("Disconnected from local", "Reconnecting…", button: "Start") }
                owner.notices.layoutSubtreeIfNeeded()
                let cards = owner.notices.testCards + (owner.notices.testConfigCard.map { [$0] } ?? [])
                for card in cards {
                    XCTAssertEqual(card.frame.width, 360)
                    XCTAssertEqual(owner.notices.bounds.maxX - card.frame.maxX, 16)
                }
                if let anchored = owner.notices.testConfigCard ?? owner.notices.testCards.last { XCTAssertEqual(anchored.frame.minY, 16) }
                if state == "float" {
                    let float = try XCTUnwrap(owner.testSession?.windows.values.first(where: { !$0.isHidden })?.panes.last)
                    XCTAssertFalse(float.convert(float.bounds, to: owner.sidebar.content).intersection(try XCTUnwrap(cards.first).frame).isEmpty)
                }
                try await ready(owner)
                let root = try XCTUnwrap(owner.window.contentView?.superview)
                XCTAssertEqual(owner.sidebar.content.subviews.filter { $0 is Notices }.count, 1)
                var views = [root]
                var columns = 0
                while let view = views.popLast() {
                    if view is Notices { columns += 1 }
                    views.append(contentsOf: view.subviews)
                }
                XCTAssertEqual(columns, 1)
                XCTAssertEqual(Set(owner.notices.subviews.map(ObjectIdentifier.init)), Set(cards.map(ObjectIdentifier.init)))
                for card in cards {
                    XCTAssertEqual(card.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.filter { $0.accessibilityRole() == .staticText }.count, 2)
                }
                if state.hasPrefix("fullscreen-") {
                    let image = try fullscreenHostImage(owner, root: root)
                    checkSnapshot { verifySnapshot(of: image, as: .image, named: "\(side)-\(state)", record: $0) }
                } else {
                    checkSnapshot { verifySnapshot(of: root, as: .image, named: "\(side)-\(state)", record: $0) }
                }
            }
            owner.close()
        }
    }

    func testUnownedNewWindowShowsOneCard() async throws {
        let owner = try await fixture("light")
        owner.testEditor { _ in throw KoError(code: KO_ERR_INVALID, detail: "window refused") }
        owner.newWindow()
        try await wait("new window refusal") { owner.notices.testTransients.entries.count == 1 }
        XCTAssertEqual(owner.notices.testTransients.entries.first?.title, "Could not open a window")
        XCTAssertEqual(owner.notices.testTransients.entries.first?.detail, "window refused")
    }

    func testConfigErrorKeepsPaneGeometryAndStaysAboveBanner() async throws {
        let owner = try await fixture("light")
        try await ready(owner)
        let pane = try XCTUnwrap(owner.testSession?.windows.values.first(where: { !$0.isHidden })?.panes.first)
        owner.window.makeFirstResponder(pane)
        let contentFrame = owner.sidebar.content.frame
        let paneFrame = pane.frame
        try "app: {font: {size: wrong}}\n".write(toFile: owner.runtime.configFile, atomically: true, encoding: .utf8)
        try await wait("config notice") { owner.notices.testConfigCard != nil }
        owner.window.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertEqual(owner.sidebar.content.frame, contentFrame)
        XCTAssertEqual(pane.frame, paneFrame)
        XCTAssertTrue(owner.window.firstResponder === pane)
        owner.down("Disconnected", "Retrying", button: nil)
        XCTAssertNotNil(owner.notices.testConfigCard)
        XCTAssertTrue(owner.sidebar.content.subviews.last === owner.notices)
    }

    func testCardClicksKeepPaneFocusIncludingFloatingSidebarOutside() async throws {
        let owner = try await fixture("light")
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        let pane = try XCTUnwrap(owner.testSession?.windows.values.first(where: { !$0.isHidden })?.panes.first)
        owner.window.makeFirstResponder(pane)
        let focused = owner.testModel?.current?.window.focus
        let error = ConfigError(path: owner.runtime.home + "/.config/ko/config.yaml", problem: .init(line: 14, column: 5, message: "bad field"))
        var opened: [URL] = []
        owner.notices.testOpenFile = { opened.append($0) }
        for floating in [false, true] {
            if floating { owner.sidebar.isCollapsed = true; owner.sidebar.focusSidebar(nil); owner.window.makeFirstResponder(pane) }
            owner.notices.show(split.0, split.1)
            try click(try XCTUnwrap(owner.notices.testCards.first), in: owner)
            XCTAssertTrue(owner.notices.testTransients.entries.isEmpty)
            XCTAssertTrue(owner.window.firstResponder === pane)
            XCTAssertEqual(owner.testModel?.current?.window.focus, focused)
            XCTAssertEqual(owner.sidebar.isFloating, floating)
            owner.runtime.testConfigError(error)
            let config = try XCTUnwrap(owner.notices.testConfigCard)
            try click(config, in: owner, at: NSPoint(x: 40, y: 12))
            XCTAssertNotNil(owner.notices.testConfigCard)
            XCTAssertTrue(owner.window.firstResponder === pane)
            XCTAssertEqual(owner.testModel?.current?.window.focus, focused)
            XCTAssertEqual(owner.sidebar.isFloating, floating)
            let openedBefore = opened.count
            for button in config.subviews.compactMap({ $0 as? NSButton }).sorted(by: { $0.title > $1.title }) {
                XCTAssertFalse(button.acceptsFirstResponder)
                try click(button, in: owner)
                XCTAssertTrue(owner.window.firstResponder === pane)
                XCTAssertEqual(owner.testModel?.current?.window.focus, focused)
                XCTAssertEqual(owner.sidebar.isFloating, floating)
                if button.title == "Open config" {
                    XCTAssertEqual(opened.count, openedBefore + 1)
                    XCTAssertEqual(opened.last?.path, error.path)
                    XCTAssertTrue(owner.notices.testConfigCard === config)
                } else {
                    XCTAssertNil(owner.notices.testConfigCard)
                    XCTAssertNil(owner.runtime.visibleConfigError)
                }
            }
            owner.runtime.testConfigError(nil)
        }
    }

    private func fullscreenHostImage(_ owner: WindowOwner, root: NSView) throws -> NSImage {
        let size = root.bounds.size
        let header = fullscreenHeader(width: size.width, background: nil)
        header.titlebarAppearsTransparent = true
        header.appearance = owner.window.appearance
        defer { header.close() }
        let host = try XCTUnwrap(header.contentView)
        host.wantsLayer = true
        host.layer?.backgroundColor = owner.runtime.background.cgColor
        let tabs = WindowTabs(frame: owner.sidebar.tabs.convert(owner.sidebar.tabs.bounds, to: root))
        tabs.frame.origin.y = 8
        tabs.sidebar = owner.sidebar
        tabs.theme = owner.sidebar.tabs.theme
        tabs.entries = owner.sidebar.tabs.entries
        host.addSubview(tabs)
        host.layoutSubtreeIfNeeded()
        header.display()
        let bodyBitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bodyBitmap)
        let body = NSImage(size: size)
        body.addRepresentation(bodyBitmap)
        let headerBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: headerBitmap)
        let band = NSImage(size: host.bounds.size)
        band.addRepresentation(headerBitmap)
        return NSImage(size: size, flipped: false) { rect in
            body.draw(in: rect)
            band.draw(in: NSRect(x: 0, y: size.height - 52, width: size.width, height: 52))
            return true
        }
    }

    private func click(_ card: NSView, in owner: WindowOwner, at point: NSPoint? = nil) throws {
        let point = card.convert(point ?? NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        let root = try XCTUnwrap(owner.window.contentView?.superview)
        let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
        XCTAssertTrue(hit === card)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: owner.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        let event = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true))
        owner.window.sendEvent(event)
        if let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { owner.window.sendEvent(event) }
    }
}
