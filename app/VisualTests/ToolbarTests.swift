import AppKit
import GhosttyKit
import XCTest
import SnapshotTesting
import SidebarFeed
import TmuxControl
@testable import Kido

@MainActor final class ToolbarTests: VisualTestCase {
    func testHostLabel() async throws {
        let owner = try XCTUnwrap(delegate.open(.remote("buildbox"), start: false))
        defer { owner.close() }
        let tabs = owner.sidebar.tabs
        XCTAssertEqual(tabs.hostLabel()?.alias, "buildbox")
        XCTAssertFalse(try XCTUnwrap(tabs.hostLabel()).connected)
        tabs.entries = SessionModel(session: SessionID(number: 0), windows: [.init(id: WindowID(number: 0), name: "Shell"), .init(id: WindowID(number: 1), name: "Editor")], window: WindowID(number: 0)).navigation(nil).tabs
        owner.window.display()
        let root = try XCTUnwrap(owner.window.contentView?.superview)
        var selections = 0
        tabs.select = { _ in selections += 1 }
        XCTAssertFalse(owner.window(owner.window, willUseFullScreenPresentationOptions: [.fullScreen, .autoHideToolbar]).contains(.autoHideToolbar))
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        for (name, text, connected) in [("connected", "dev@buildbox", true), ("offline", "dev@buildbox", false), ("long", "developer@buildbox.production.eu-west.example.net", true), ("local", "", true)] {
            tabs.hostLabel = { text.isEmpty ? nil : (text, "buildbox", connected) }
            for mode in ["docked", "collapsed", "floating"] {
                owner.sidebar.dismissFloating()
                owner.sidebar.isCollapsed = mode != "docked"
                root.layoutSubtreeIfNeeded()
                owner.sidebar.viewDidLayout()
                if mode == "floating" { owner.sidebar.focusSidebar(nil) }
                root.layoutSubtreeIfNeeded()
                owner.window.display()
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertTrue(owner.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "windowTabs" }?.view === tabs.superview)
                XCTAssertEqual(tabs.theme.background, owner.window.backgroundColor)
                XCTAssertEqual(tabs.frame.height, 36)
                XCTAssertGreaterThan(tabs.frame.width, 85)
                XCTAssertEqual(owner.sidebar.content.convert(owner.sidebar.content.bounds, to: nil).maxY, owner.window.contentLayoutRect.maxY)
                tabs.needsLayout = true
                tabs.layoutSubtreeIfNeeded()
                tabs.needsDisplay = true
                if !text.isEmpty {
                    let point = tabs.convert(NSPoint(x: 4, y: 22), to: nil)
                    XCTAssertFalse(root.hitTest(root.convert(point, from: nil)) === tabs)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    tabs.mouseDown(with: event)
                    XCTAssertEqual(selections, 0)
                    XCTAssertEqual(tabs.view(tabs, stringForToolTip: 0, point: .zero, userData: nil), "buildbox")
                }
                if let failure = verifySnapshot(of: try headerImage(tabs), as: .image, named: "\(name)-\(mode)", record: record),
                   !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
            }
        }
    }

    func testHeaderBackground() async throws {
        final class NativeHeader: NSView {
            override func draw(_ rect: NSRect) { NSColor.white.setFill(); bounds.fill() }
        }
        final class SidebarShadow: NSView {
            override func draw(_ rect: NSRect) {
                NSGradient(starting: NSColor(calibratedWhite: 0, alpha: 0.2), ending: .clear)!.draw(in: bounds, angle: 0)
            }
        }
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("header-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: config) }
        let board = NSPasteboard(name: .init("header-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        for hex in ["fffaf0", "172029"] {
            try "background = #\(hex)\n".write(to: config, atomically: true, encoding: .utf8)
            let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
            let owner = WindowOwner(host: .local, runtime: runtime, start: false)
            defer { owner.close() }
            owner.sidebar.tabs.entries = SessionModel(session: SessionID(number: 0), windows: [.init(id: WindowID(number: 0), name: "Shell")], window: WindowID(number: 0)).navigation(nil).tabs
            let root = try XCTUnwrap(owner.window.contentView?.superview)
            let expected = try XCTUnwrap(runtime.background.usingColorSpace(.sRGB))
            let windowedShadow = SidebarShadow()
            owner.window.contentView?.addSubview(windowedShadow)
            let header = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 52), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            header.isReleasedWhenClosed = false
            header.contentView = NativeHeader()
            header.titlebarAppearsTransparent = true
            header.setFrame(NSRect(x: -20000, y: -20000, width: 900, height: 52), display: false)
            defer { header.close() }
            let transferredTabs = WindowTabs(frame: NSRect(x: 200, y: 8, width: 700, height: 36))
            transferredTabs.sidebar = owner.sidebar
            transferredTabs.theme = owner.sidebar.tabs.theme
            let headerContent = try XCTUnwrap(header.contentView)
            headerContent.addSubview(transferredTabs)
            let paintedBackground = try XCTUnwrap(headerContent.subviews.first)
            XCTAssertTrue(paintedBackground.isOpaque)
            XCTAssertNil(paintedBackground.hitTest(.zero))
            XCTAssertTrue(header.titlebarAppearsTransparent)
            header.setFrame(NSRect(x: owner.window.frame.minX, y: owner.window.frame.maxY - 52, width: 900, height: 52), display: false)
            let transferredShadow = SidebarShadow()
            headerContent.addSubview(transferredShadow, positioned: .below, relativeTo: transferredTabs)
            for mode in ["docked", "docked-wide", "collapsed", "floating"] {
                owner.sidebar.dismissFloating()
                owner.sidebar.isCollapsed = !mode.hasPrefix("docked")
                if mode.hasPrefix("docked") { owner.sidebar.splitView.setPosition(mode == "docked-wide" ? 320 : 236, ofDividerAt: 0) }
                if mode == "floating" { owner.sidebar.focusSidebar(nil) }
                owner.window.display()
                try await Task.sleep(for: .milliseconds(200))
                let tabsRect = owner.sidebar.tabs.convert(owner.sidebar.tabs.bounds, to: root)
                windowedShadow.frame = NSRect(x: tabsRect.minX - 8, y: 0, width: 12, height: owner.window.contentView!.bounds.height)
                transferredTabs.frame = NSRect(x: tabsRect.minX, y: 8, width: tabsRect.width, height: 36)
                transferredShadow.frame = NSRect(x: tabsRect.minX - 8, y: 0, width: 12, height: headerContent.bounds.height)
                windowedShadow.isHidden = mode == "collapsed"
                transferredShadow.isHidden = mode == "collapsed"
                XCTAssertEqual(owner.sidebar.list.layer?.cornerRadius, mode == "floating" ? 18 : 0, "docked sidebar must have square corners")
                XCTAssertEqual(owner.sidebar.list.layer?.borderWidth, mode == "floating" ? 1 / owner.window.backingScaleFactor : 0, "docked sidebar must not draw an extra outline")
                transferredTabs.refreshHeader()
                header.display()
                if mode == "floating" {
                    let card = owner.sidebar.list.convert(owner.sidebar.list.bounds, to: root)
                    var parent = owner.sidebar.list.superview
                    while let view = parent, !(view is NSGlassEffectView) { parent = view.superview }
                    XCTAssertEqual(try XCTUnwrap(parent as? NSGlassEffectView).cornerRadius, 18)
                    for (name, view) in [("windowed", root), ("fullscreen-host", headerContent)] {
                        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: image)
                        let scale = CGFloat(image.pixelsHigh) / view.bounds.height
                        var sampled = 0
                        for (corner, point) in [
                            ("top-left", NSPoint(x: card.minX + 2, y: card.maxY - 2)),
                            ("top-right", NSPoint(x: card.maxX - 2, y: card.maxY - 2)),
                            ("bottom-left", NSPoint(x: card.minX + 2, y: card.minY + 2)),
                            ("bottom-right", NSPoint(x: card.maxX - 2, y: card.minY + 2)),
                        ] {
                            let local = name == "windowed" ? point : header.convertPoint(fromScreen: owner.window.convertPoint(toScreen: root.convert(point, to: nil)))
                            guard view.bounds.contains(local) else { continue }
                            let color = try XCTUnwrap(image.colorAt(x: Int(local.x * scale), y: Int((view.bounds.maxY - local.y) * scale)))
                            sampled += 1
                            XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 2 / 255, "\(hex) \(name) \(corner) outside floating arc red")
                            XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 2 / 255, "\(hex) \(name) \(corner) outside floating arc green")
                            XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 2 / 255, "\(hex) \(name) \(corner) outside floating arc blue")
                        }
                        XCTAssertEqual(sampled, name == "windowed" ? 4 : 2)
                    }
                }
                let hostImage = try XCTUnwrap(headerContent.bitmapImageRepForCachingDisplay(in: headerContent.bounds))
                headerContent.cacheDisplay(in: headerContent.bounds, to: hostImage)
                let leftColor = try XCTUnwrap(hostImage.colorAt(x: 20, y: 10))
                let leftExpected = mode.hasPrefix("docked") ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : expected
                XCTAssertEqual(leftColor.redComponent, leftExpected.redComponent, accuracy: 2 / 255, "fullscreen sidebar region must remain uncovered")
                XCTAssertEqual(leftColor.greenComponent, leftExpected.greenComponent, accuracy: 2 / 255, "fullscreen sidebar region must remain uncovered")
                XCTAssertEqual(leftColor.blueComponent, leftExpected.blueComponent, accuracy: 2 / 255, "fullscreen sidebar region must remain uncovered")
                if mode == "docked" || mode == "floating" {
                    let sidebarRect = owner.sidebar.list.convert(owner.sidebar.list.bounds, to: root)
                    let corners = NSRect(x: sidebarRect.minX, y: sidebarRect.maxY - 80, width: sidebarRect.width + 24, height: 80)
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: corners))
                    root.cacheDisplay(in: corners, to: bitmap)
                    let image = NSImage(size: corners.size)
                    image.addRepresentation(bitmap)
                    let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                    if let failure = verifySnapshot(of: image, as: .image, named: mode == "docked" ? "windowed-corners-\(hex)" : "windowed-floating-corners-\(hex)", record: record),
                       !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
                }
                // This white native-host stand-in pins uncovered geometry, not composited Liquid Glass.
                let snapshot = NSImage(size: headerContent.bounds.size)
                snapshot.addRepresentation(hostImage)
                let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                if let failure = verifySnapshot(of: snapshot, as: .image, named: "fullscreen-\(hex)-\(mode)", record: record),
                   !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
                for (name, view, tabs) in [("windowed", root, owner.sidebar.tabs), ("transferred", headerContent, transferredTabs)] {
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    let scale = CGFloat(image.pixelsHigh) / view.bounds.height
                    let rect = tabs.convert(tabs.bounds, to: view)
                    let x = Int(rect.minX * scale)
                    let y = Int((view.bounds.maxY - rect.midY) * scale)
                    let inside = try XCTUnwrap(image.colorAt(x: x, y: y))
                    let left = try XCTUnwrap(image.colorAt(x: x - 1, y: y))
                    XCTAssertEqual(inside.redComponent, left.redComponent, accuracy: 6 / (255 * scale), "\(hex) \(name) \(mode) shadow column red continuity")
                    XCTAssertEqual(inside.greenComponent, left.greenComponent, accuracy: 6 / (255 * scale), "\(hex) \(name) \(mode) shadow column green continuity")
                    XCTAssertEqual(inside.blueComponent, left.blueComponent, accuracy: 6 / (255 * scale), "\(hex) \(name) \(mode) shadow column blue continuity")
                    let outside = try XCTUnwrap(image.colorAt(x: x, y: Int((view.bounds.maxY - rect.minY + 2) * scale)))
                    XCTAssertEqual(inside.redComponent, outside.redComponent, accuracy: 2 / 255, "\(hex) \(name) \(mode) shadow red continuity")
                    XCTAssertEqual(inside.greenComponent, outside.greenComponent, accuracy: 2 / 255, "\(hex) \(name) \(mode) shadow green continuity")
                    XCTAssertEqual(inside.blueComponent, outside.blueComponent, accuracy: 2 / 255, "\(hex) \(name) \(mode) shadow blue continuity")
                }
                for view in [owner.sidebar.terminalHost, root, headerContent, try XCTUnwrap(headerContent.superview)] {
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    let scale = CGFloat(image.pixelsHigh) / view.bounds.height
                    for y in [CGFloat(3), 26, 49] {
                        let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide - Int(20 * scale), y: Int(y * scale)))
                        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, "\(hex) \(mode) header opacity")
                        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 2 / 255, "\(hex) \(mode) header red")
                        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 2 / 255, "\(hex) \(mode) header green")
                        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 2 / 255, "\(hex) \(mode) header blue")
                    }
                }
                XCTAssertFalse(owner.window.isVisible)
            }
        }
    }

    func testLiveHeaderTheme() async throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        final class NativeHeader: NSView {
            override func draw(_ rect: NSRect) { NSColor.white.setFill(); bounds.fill() }
        }
        let board = NSPasteboard(name: .init("live-header-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { owner.close() }
        owner.sidebar.isCollapsed = false
        owner.window.display()
        try await Task.sleep(for: .milliseconds(200))
        let tabs = owner.sidebar.tabs
        let header = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 52), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        header.isReleasedWhenClosed = false
        header.contentView = NativeHeader()
        header.setFrame(NSRect(x: -20000, y: -20000, width: 900, height: 52), display: false)
        defer { header.close() }
        for transferred in [false, true] {
            if transferred {
                header.setFrame(NSRect(x: owner.window.frame.minX, y: owner.window.frame.maxY - 52, width: 900, height: 52), display: false)
                header.contentView!.addSubview(tabs)
                tabs.frame = NSRect(x: 300, y: 8, width: 592, height: 36)
            }
            for (index, theme) in [("fffaf0", NSAppearance.Name.aqua), ("172029", .darkAqua), ("fffaf0", .aqua)].enumerated() {
                let (hex, appearance) = theme
                let changed = expectation(description: "Ghostty config reload \(hex)")
                runtime.onConfigChange = { [weak owner] in owner?.updateAppearance(); changed.fulfill() }
                let config = try XCTUnwrap(ghostty_config_new())
                let text = "background = #\(hex)\n"
                ghostty_config_load_string(config, text, UInt(text.utf8.count), "/live-header")
                ghostty_config_finalize(config)
                ghostty_app_update_config(runtime.app, config)
                ghostty_config_free(config)
                await fulfillment(of: [changed], timeout: 3)
                XCTAssertEqual(owner.window.appearance?.name, appearance, "\(hex) main window")
                XCTAssertEqual(tabs.effectiveAppearance.name, appearance, "\(hex) tabs transferred=\(transferred)")
                XCTAssertEqual(tabs.window?.appearance?.name, appearance, "\(hex) host transferred=\(transferred)")
                let view = try XCTUnwrap(tabs.window?.contentView)
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                let expected = try XCTUnwrap(runtime.background.usingColorSpace(.sRGB))
                if transferred {
                    let left = try XCTUnwrap(image.colorAt(x: 20, y: 10))
                    XCTAssertEqual(left.redComponent, 1, accuracy: 2 / 255)
                    XCTAssertEqual(left.greenComponent, 1, accuracy: 2 / 255)
                    XCTAssertEqual(left.blueComponent, 1, accuracy: 2 / 255)
                    let snapshot = NSImage(size: view.bounds.size)
                    snapshot.addRepresentation(image)
                    let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                    if let failure = verifySnapshot(of: snapshot, as: .image, named: "fullscreen-switch-\(index)-\(hex)", record: record),
                       !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
                }
                let scale = CGFloat(image.pixelsHigh) / view.bounds.height
                for y in [CGFloat(3), 26, 49] {
                    let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide - Int(20 * scale), y: Int(y * scale)))
                    XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
                    XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 2 / 255)
                    XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 2 / 255)
                    XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 2 / 255)
                }
            }
        }
    }

    func testOrphanedTab() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"asks":[],"client":{"session":"$0","window":"@1","pane":"%1"},"sessions":[{"id":"$0","name":"s","current":true,"nodes":[{"kind":"shell","id":"%0","pane":"%0","window":"@0","program_status":{"serial":0,"records":[]},"title":[],"tail":[],"attention":false,"children":[{"kind":"run","id":"%1","pane":"%1","window":"@1","program_status":{"serial":0,"records":[]},"title":[],"tail":[],"attention":false,"children":[]}]}]}]}
        """.utf8))
        let model = SessionModel(session: SessionID(number: 0), windows: [.init(id: WindowID(number: 1), name: "Child")], window: WindowID(number: 1))
        XCTAssertEqual(model.navigation(snapshot).tabs.map(\.id), [WindowID(number: 1)], "orphan child must retain a tab")
    }

    func testWindowSelectionTargetsSession() {
        let model = SessionModel(session: SessionID(number: 3), windows: [.init(id: WindowID(number: 7), name: "w")], window: WindowID(number: 7))
        XCTAssertEqual(model.select(.number(1)), RPCRequest.selectWindow(SessionID(number: 3), WindowID(number: 7)), "selection must target the tab's session")
        XCTAssertNil(PaneCommand.window(.number(1)).command(PaneID(number: 0), cell: .zero))
        XCTAssertEqual(model.select(.next), .switchWindow(next: true))
        XCTAssertEqual(model.select(.previous), .switchWindow(next: false))
        XCTAssertEqual(SessionModel().select(.next), .switchWindow(next: true))
        XCTAssertEqual(SessionModel().select(.previous), .switchWindow(next: false))
        XCTAssertNil(SessionModel().select(.number(1)))
        XCTAssertEqual(model.select(.last), model.select(.number(1)))
        let menus = SessionMenus()
        var commands: [RPCRequest] = []
        menus.send = { commands.append($0) }
        menus.update(model)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        XCTAssertTrue(menus.window.performKeyEquivalent(with: key))
        XCTAssertEqual(commands, [model.select(.number(1))!])
    }

    func testWindowShortcutsUseRPC() {
        let menus = SessionMenus()
        var requests: [RPCRequest] = []
        menus.send = { requests.append($0) }
        menus.update(SessionModel())
        for (key, next) in [("}", true), ("{", false)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            XCTAssertTrue(menus.window.performKeyEquivalent(with: event))
            XCTAssertEqual(requests.last, .switchWindow(next: next))
        }
        XCTAssertEqual(requests.count, 2)
        let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        XCTAssertFalse(view?.items.contains { $0.title.contains("Window in Sidebar") } == true)
        XCTAssertFalse(view?.items.contains { ["j", "k"].contains($0.keyEquivalent) && $0.keyEquivalentModifierMask == [.command, .control] } == true)
        XCTAssertNil(PaneCommand.newWindow.command(PaneID(number: 0), cell: .zero))
    }

    func testSessionShortcutsUseRPCNavigationOnce() {
        let menus = SessionMenus()
        var commands: [RPCRequest] = []
        menus.send = { commands.append($0) }
        menus.update(SessionModel())
        for (key, code, next) in [("]", UInt16(30), true), ("[", UInt16(33), false)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            XCTAssertTrue(menus.session.performKeyEquivalent(with: event))
            XCTAssertEqual(commands.last, .switchSession(next: next))
        }
        XCTAssertEqual(commands, [.switchSession(next: true), .switchSession(next: false)])
    }

    func testOfflineDismissesFloatingSidebar() throws {
        let owner = try XCTUnwrap(delegate.open(.local, start: false))
        defer { owner.close() }
        let sidebar = owner.sidebar
        sidebar.isCollapsed = true
        sidebar.focusSidebar(nil)
        XCTAssertTrue(sidebar.isFloating)
        owner.down("Disconnected", "", button: "Reconnect")
        XCTAssertFalse(sidebar.isFloating, "offline must remove floating Outside blocker")
        XCTAssertTrue(sidebar.isCollapsed)
        sidebar.dismissFloating()
    }

    func testToolbarHitRegions() throws {
        let sidebar = Sidebar()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = sidebar
        let toolbar = NSToolbar(identifier: "ToolbarHitRegions")
        toolbar.delegate = sidebar
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        let root = try XCTUnwrap(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        sidebar.splitView.setPosition(236, ofDividerAt: 0)
        for width in [900, 800] {
            window.setContentSize(NSSize(width: width, height: 560))
            for collapsed in [false, true] {
                sidebar.isCollapsed = collapsed
                root.layoutSubtreeIfNeeded()
                sidebar.viewDidLayout()
                root.layoutSubtreeIfNeeded()
                for id in ["newSession", "toggleSidebar"] {
                    let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == id })
                    XCTAssertEqual(item.isHidden, id == "newSession" && collapsed)
                    if item.isHidden { continue }
                    let button = try XCTUnwrap(item.view as? NSButton)
                    let cell = try XCTUnwrap(button.cell)
                    XCTAssertFalse(button.isBordered)
                    let frame = button.convert(button.bounds, to: nil)
                    XCTAssertGreaterThanOrEqual(frame.height, 28)
                    for y in stride(from: frame.minY + 0.5, through: frame.maxY - 0.5, by: 1) {
                        for x in stride(from: frame.minX + 0.5, through: frame.maxX - 0.5, by: 1) {
                            let point = NSPoint(x: x, y: y)
                            let target = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
                            XCTAssertTrue(target === button || target.isDescendant(of: button) || target === button.superview)
                            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                eventNumber: 1, clickCount: 1, pressure: 1))
                            XCTAssertEqual(cell.hitTest(for: event, in: button.bounds, of: button), [.contentArea, .trackableArea])
                        }
                    }
                }
            }
        }
    }
}
