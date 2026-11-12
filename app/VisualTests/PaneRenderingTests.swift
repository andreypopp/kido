import AppKit
import GhosttyKit
import KoClient
import KoClientKit
import KoModel
import SnapshotTesting
import SidebarFeed
import PaneGeometry
import XCTest
@testable import Kido

@MainActor final class PaneRenderingTests: AppWindowCase {

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
            checkSnapshot { verifySnapshot(of: owner.sidebar.view, as: .pixels, named: "\(side)-connecting", record: $0) }
            gate.signal()
            try await wait("the held edit ends") { !owner.testEditing }
            owner.testEditor { _ in throw KoError(code: KO_ERR_INVALID, detail: "creation refused") }
            owner.ensureSession()
            try await wait("creation fails with Retry") { !owner.testEditing && owner.testBanner.testText.title == "Could not create a session" }
            XCTAssertEqual(owner.testBanner.testText.button, "Retry")
            owner.window.layoutIfNeeded()
            owner.sidebar.view.layoutSubtreeIfNeeded()
            checkSnapshot { verifySnapshot(of: owner.sidebar.view, as: .pixels, named: "\(side)-failed", record: $0) }
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
                if let failure = verifySnapshot(of: owner.testBanner, as: .pixels, named: name, record: record),
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
        sidebar.splitView.setPosition(256, ofDividerAt: 0)
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
                try await snapshot(hidden || dark ? "corner-\(side)-\(name)" : "pane-\(name)", view: root)
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
                XCTAssertEqual(kido, ["IconButton", "MouseButton", "PaneView", "Table", "RuntimeSection"], "pane chrome, dividers, tabs and sidebar rows never take first mouse; PaneView, Table and RuntimeSection answer true only in the visual build")
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
                let distance = zip([edge.redComponent, edge.greenComponent, edge.blueComponent], shifted).map { abs($0 * 255 - Double($1)) }.max() ?? 0
                XCTAssertGreaterThan(distance, 5, "sidebar edge on all four sides")
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
                try await snapshot("corner-left-dark", view: root)
                sidebar.toggleSidebar(nil)
                try await snapshot("pane-dark", view: root)
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
        try await snapshot("alternate-dark")
    }
}
