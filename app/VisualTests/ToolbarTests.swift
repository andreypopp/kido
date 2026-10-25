import AppKit
import GhosttyKit
import XCTest
import SnapshotTesting
import SidebarFeed
import TmuxControl
@testable import Kido

let headerPaperRGB: [String: [Double]] = [
    "fffaf0": [255, 250, 240],
    "fffaf0-shifted": [247.35, 242.5, 232.8],
    "fffaf0-shifted10": [229.5, 225, 216],
    "172029": [23, 32, 41],
    "172029-shifted": [29.96, 38.69, 47.42],
    "172029-shifted10": [46.2, 54.3, 62.4],
    "white": [255, 255, 255],
    "fff9ec-shifted": [247.35, 241.53, 228.92],
]

func assertPaperPixel(_ image: NSBitmapImageRep, x: Int, y: Int, expected: [Double], _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) throws {
    let pixels = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default), file: file, line: line)
    let color = try XCTUnwrap(pixels.colorAt(x: x, y: y), file: file, line: line)
    XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, message, file: file, line: line)
    for (value, expected) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
        XCTAssertEqual(value * 255, expected, accuracy: 2, message, file: file, line: line)
    }
}

@MainActor final class ToolbarTests: VisualTestCase {
    func testTabActivityMarks() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("tab-marks-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: config) }
        let board = NSPasteboard(name: .init("tab-marks-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        for (name, hex) in [("light", "fffaf0"), ("dark", "172029")] {
            try "background = #\(hex)\n".write(to: config, atomically: true, encoding: .utf8)
            let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
            let owner = WindowOwner(host: .local, runtime: runtime, start: false)
            defer { owner.close() }
            let tabs = owner.sidebar.tabs
            tabs.entries = [.init(id: WindowID(number: 0), name: "Running", active: true, status: .running),
                            .init(id: WindowID(number: 1), name: "Done", active: false, status: .done)]
            let root = try XCTUnwrap(owner.window.contentView?.superview)
            if owner.sidebar.isCollapsed { owner.sidebar.toggleSidebar(nil) }
            root.layoutSubtreeIfNeeded()
            owner.window.display()
            for mode in ["collapsed", "docked", "collapsed", "floating", "docked"] {
                if mode == "floating" { owner.sidebar.focusSidebar(nil) }
                else { owner.sidebar.toggleSidebar(nil) }
                root.layoutSubtreeIfNeeded()
                owner.window.display()
                let activity = mode != "docked"
                XCTAssertEqual(owner.sidebar.isFloating, mode == "floating")
                XCTAssertEqual(tabs.showsActivity, activity)
                XCTAssertEqual(tabs.labelRect(0).minX, 28)
                let labels = tabs.accessibilityChildren()?.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() } ?? []
                XCTAssertTrue(labels.contains("Window: Running" + (activity ? " — running" : "")))
                XCTAssertTrue(labels.contains("Window: Done" + (activity ? " — done" : "")))
                let image = try headerImage(tabs)
                let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                var data = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
                let context = try XCTUnwrap(CGContext(data: &data, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                                                      bytesPerRow: pixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
                var green = 0
                for pixel in stride(from: 0, to: data.count, by: 4) {
                    let red = Double(data[pixel]), greenComponent = Double(data[pixel + 1]), blue = Double(data[pixel + 2])
                    if greenComponent > 127.5 && greenComponent > red * 1.5 && greenComponent > blue * 1.5 { green += 1 }
                }
                XCTAssertEqual(green > 0, activity, "\(mode) visible marks")
                if mode != "floating" {
                    let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                    if let failure = verifySnapshot(of: image, as: .image, named: "\(name)-\(mode)", record: record),
                       !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
                }
            }
        }
    }

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
                await mainQueueFence()
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
        final class ShadowStandIn: NSView {
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
            let owner = WindowOwner(host: .remote("header-\(UUID().uuidString)"), runtime: runtime, start: false)
            owner.sidebar.tabs.hostLabel = { nil }
            defer { owner.close() }
            owner.sidebar.tabs.entries = SessionModel(session: SessionID(number: 0), windows: [.init(id: WindowID(number: 0), name: "Shell")], window: WindowID(number: 0)).navigation(nil).tabs
            let root = try XCTUnwrap(owner.window.contentView?.superview)
            let rgb = headerPaperRGB["\(hex)-shifted"]!
            let expected = NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1)
            let windowedShadow = ShadowStandIn()
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
            let transferredShadow = ShadowStandIn()
            headerContent.addSubview(transferredShadow, positioned: .below, relativeTo: transferredTabs)
            for mode in ["docked", "docked-wide", "collapsed", "floating"] {
                owner.sidebar.dismissFloating()
                owner.sidebar.isCollapsed = !mode.hasPrefix("docked")
                if mode.hasPrefix("docked") { owner.sidebar.splitView.setPosition(mode == "docked-wide" ? 320 : 236, ofDividerAt: 0) }
                if mode == "floating" { owner.sidebar.focusSidebar(nil) }
                owner.window.display()
                await mainQueueFence()
                if mode.hasPrefix("docked") {
                    let terminal = owner.sidebar.terminalHost.convert(owner.sidebar.terminalHost.bounds, to: owner.sidebar.splitView)
                    XCTAssertEqual(terminal.minX, 0)
                    XCTAssertEqual(terminal.width, owner.sidebar.splitView.bounds.width)
                }
                let tabsRect = owner.sidebar.tabs.convert(owner.sidebar.tabs.bounds, to: root)
                windowedShadow.frame = NSRect(x: tabsRect.minX - 8, y: 0, width: 12, height: owner.window.contentView!.bounds.height)
                transferredTabs.frame = NSRect(x: tabsRect.minX, y: 8, width: tabsRect.width, height: 36)
                transferredShadow.frame = NSRect(x: tabsRect.minX - 8, y: 0, width: 12, height: headerContent.bounds.height)
                windowedShadow.isHidden = mode == "collapsed"
                transferredShadow.isHidden = mode != "floating"
                XCTAssertEqual(owner.sidebar.list.layer?.cornerRadius, mode == "floating" ? 18 : 0, "docked sidebar must have square corners")
                XCTAssertEqual(owner.sidebar.list.layer?.borderWidth, mode == "floating" ? 1 / owner.window.backingScaleFactor : 0, "docked sidebar must not draw an extra outline")
                transferredTabs.refreshHeader()
                header.display()
                if mode == "floating" {
                    let tabs = owner.sidebar.tabs
                    let host = try XCTUnwrap(tabs.superview)
                    host.postsFrameChangedNotifications = true
                    let laidOut = expectation(description: "floating tabs follow the sidebar edge")
                    laidOut.assertForOverFulfill = false
                    let finishLayout: @MainActor @Sendable () -> Void = {
                        let edge = owner.sidebar.list.convert(owner.sidebar.list.bounds, to: root).maxX
                        let left = tabs.convert(tabs.bounds, to: root).minX
                        if abs(owner.sidebar.list.bounds.width - 320) < 0.5, abs(left - edge - 8) < 0.5 {
                            laidOut.fulfill()
                        }
                    }
                    let observation = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: host, queue: .main) { _ in
                        MainActor.assumeIsolated { finishLayout() }
                    }
                    defer { NotificationCenter.default.removeObserver(observation) }
                    for width in [CGFloat(236), 320] {
                        owner.sidebar.splitView.setPosition(width, ofDividerAt: 0)
                        root.layoutSubtreeIfNeeded()
                        owner.sidebar.viewDidLayout()
                        transferredTabs.refreshHeader()
                        var glass = owner.sidebar.list.superview
                        while let view = glass, !(view is NSGlassEffectView) { glass = view.superview }
                        let liveGlass = try XCTUnwrap(glass)
                        let edge = liveGlass.convert(NSPoint(x: liveGlass.bounds.maxX, y: liveGlass.bounds.maxY), to: nil)
                        let convertedEdge = header.convertPoint(fromScreen: owner.window.convertPoint(toScreen: edge)).x
                        XCTAssertEqual(paintedBackground.frame.minX, convertedEdge, accuracy: 0.5, "floating fullscreen backing must start at the live glass edge at width \(width)")
                        header.display()
                        let image = try XCTUnwrap(headerContent.bitmapImageRepForCachingDisplay(in: headerContent.bounds))
                        headerContent.cacheDisplay(in: headerContent.bounds, to: image)
                        let pixels = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default))
                        let scale = CGFloat(pixels.pixelsWide) / headerContent.bounds.width
                        try assertPaperPixel(pixels, x: Int(20 * scale), y: 10, expected: headerPaperRGB["white"]!, "floating fullscreen left stand-in must remain uncovered")
                        try assertPaperPixel(pixels, x: pixels.pixelsWide - Int(20 * scale), y: 10, expected: rgb)
                    }
                    finishLayout()
                    await fulfillment(of: [laidOut], timeout: 0.3)
                    root.layoutSubtreeIfNeeded()
                    owner.window.display()
                    let card = owner.sidebar.list.convert(owner.sidebar.list.bounds, to: root)
                    var parent = owner.sidebar.list.superview
                    while let view = parent, !(view is NSGlassEffectView) { parent = view.superview }
                    let glass = try XCTUnwrap(parent as? NSGlassEffectView)
                    XCTAssertEqual(glass.cornerRadius, 18)
                    let cardImage = try XCTUnwrap(glass.bitmapImageRepForCachingDisplay(in: glass.bounds))
                    glass.cacheDisplay(in: glass.bounds, to: cardImage)
                    let cardScale = CGFloat(cardImage.pixelsHigh) / glass.bounds.height
                    for x in [2.0, glass.bounds.maxX - 2] {
                        for y in [2.0, glass.bounds.maxY - 2] {
                            let pixel = try XCTUnwrap(cardImage.colorAt(x: Int(x * cardScale), y: Int(y * cardScale)))
                            XCTAssertLessThan(pixel.alphaComponent, 0.05, "floating card corners stay transparent without its separate shadow")
                        }
                    }
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
                            let cornerExpected = name == "fullscreen-host" ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : expected
                            for (channel, value, expected) in [("red", color.redComponent, cornerExpected.redComponent),
                                                               ("green", color.greenComponent, cornerExpected.greenComponent),
                                                               ("blue", color.blueComponent, cornerExpected.blueComponent)] {
                                if name == "fullscreen-host" {
                                    XCTAssertEqual(value, expected, accuracy: 2 / 255, "\(hex) \(name) \(corner) outside floating arc \(channel)")
                                } else {
                                    XCTAssertLessThanOrEqual(value, expected + 2 / 255, "\(hex) \(corner) shadow cannot lighten \(channel)")
                                    XCTAssertGreaterThanOrEqual(value, expected * (hex == "172029" ? 0.6 : 0.82) - 2 / 255, "\(hex) \(corner) bounded floating shadow \(channel)")
                                }
                            }
                        }
                        XCTAssertEqual(sampled, name == "windowed" ? 4 : 2)
                    }
                }
                let hostImage = try XCTUnwrap(headerContent.bitmapImageRepForCachingDisplay(in: headerContent.bounds))
                headerContent.cacheDisplay(in: headerContent.bounds, to: hostImage)
                let hostPixels = try XCTUnwrap(hostImage.converting(to: .sRGB, renderingIntent: .default))
                if mode == "collapsed" { XCTAssertEqual(paintedBackground.frame, headerContent.bounds) }
                try assertPaperPixel(hostPixels, x: 20, y: 10, expected: mode == "collapsed" ? rgb : headerPaperRGB["white"]!, "fullscreen sidebar region must remain uncovered")
                if mode == "docked" || mode == "floating" {
                    let sidebarRect = owner.sidebar.list.convert(owner.sidebar.list.bounds, to: root)
                    if mode == "floating" {
                        let tabs = owner.sidebar.tabs
                        XCTAssertEqual(tabs.convert(tabs.bounds, to: root).minX, sidebarRect.maxX + 8, accuracy: 0.5)
                        XCTAssertEqual(tabs.entries.count, 1)
                        XCTAssertEqual(tabs.entries.first?.active, true)
                        XCTAssertEqual(tabs.effectiveAppearance.name, owner.window.effectiveAppearance.name)
                    }
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
                    XCTAssertEqual(inside.redComponent * 255, left.redComponent * 255, accuracy: 6 / scale, "\(hex) \(name) \(mode) shadow column red continuity")
                    XCTAssertEqual(inside.greenComponent * 255, left.greenComponent * 255, accuracy: 6 / scale, "\(hex) \(name) \(mode) shadow column green continuity")
                    XCTAssertEqual(inside.blueComponent * 255, left.blueComponent * 255, accuracy: 6 / scale, "\(hex) \(name) \(mode) shadow column blue continuity")
                    let outside = try XCTUnwrap(image.colorAt(x: x, y: Int((view.bounds.maxY - rect.minY + 2) * scale)))
                    XCTAssertEqual(inside.redComponent, outside.redComponent, accuracy: 2 / 255, "\(hex) \(name) \(mode) shadow red continuity")
                    XCTAssertEqual(inside.greenComponent, outside.greenComponent, accuracy: 2 / 255, "\(hex) \(name) \(mode) shadow green continuity")
                    XCTAssertEqual(inside.blueComponent, outside.blueComponent, accuracy: 2 / 255, "\(hex) \(name) \(mode) shadow blue continuity")
                }
                for view in [owner.sidebar.terminalHost, root, headerContent, try XCTUnwrap(headerContent.superview)] {
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    let pixels = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default))
                    let scale = CGFloat(pixels.pixelsHigh) / view.bounds.height
                    // The trailing 28pt tab-strip slot contains the new-window plus.
                    for y in [CGFloat(3), 26, 49] {
                        try assertPaperPixel(pixels, x: pixels.pixelsWide - Int(40 * scale), y: Int(y * scale), expected: rgb, "\(hex) \(mode) header")
                    }
                }
                let paper = owner.sidebar.content
                let paperImage = try XCTUnwrap(paper.bitmapImageRepForCachingDisplay(in: paper.bounds))
                paper.cacheDisplay(in: paper.bounds, to: paperImage)
                let paperPixels = try XCTUnwrap(paperImage.converting(to: .sRGB, renderingIntent: .default))
                for point in [(paperPixels.pixelsWide / 2, paperPixels.pixelsHigh / 2), (paperPixels.pixelsWide - 2, paperPixels.pixelsHigh - 2)] {
                    try assertPaperPixel(paperPixels, x: point.0, y: point.1, expected: headerPaperRGB[hex]!, "\(hex) \(mode) paper below band stays pure")
                }
                XCTAssertFalse(owner.window.isVisible)
            }
        }
    }

    func testKidoSettings() async throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("other"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("kido-app.conf")
        let notes = directory.appendingPathComponent("notes.log")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.conf"),
                                                  withDestinationURL: directory.appendingPathComponent("other/theme.conf"))
        func load(_ text: String) throws -> (settings: GhosttyRuntime.KidoSettings, lines: [Substring]) {
            try ("background = #172029\nkido-unknown-key = 1\n" + text + "\n").write(to: config, atomically: false, encoding: .utf8)
            FileManager.default.createFile(atPath: notes.path, contents: nil)
            let log = try FileHandle(forWritingTo: notes)
            let saved = dup(STDERR_FILENO)
            dup2(log.fileDescriptor, STDERR_FILENO)
            let loaded = GhosttyRuntime.loadConfig(file: config.path, home: directory.path)
            dup2(saved, STDERR_FILENO)
            close(saved)
            try log.close()
            let parsed = try XCTUnwrap(loaded)
            ghostty_config_free(parsed.config)
            return (parsed.settings, try String(contentsOf: notes, encoding: .utf8).split(separator: "\n"))
        }
        for (text, files, shade, note) in [
            ("kido-unfocused-background-shift = 30%", [:], 0.3, nil),
            ("kido-unfocused-background-shift = 30", [:], 0.3, nil),
            ("kido-unfocused-background-shift = 0", [:], 0, nil),
            ("kido-unfocused-background-shift = -0", [:], 0, nil),
            ("kido-unfocused-background-shift = -100", [:], 1, nil),
            ("kido-unfocused-background-shift = \"\"", [:], nil, nil),
            ("kido-unfocused-background-shift = 20%\nkido-unfocused-background-shift = 40%", [:], 0.4, nil),
            ("kido-unfocused-background-shift =   \" 30.5% \"  ", [:], 0.305, nil),
            ("kido-unfocused-background-shift = +30", [:], nil, "+30"),
            ("kido-unfocused-background-shift = 1e1", [:], nil, "1e1"),
            ("kido-unfocused-background-shift = 0x1p4", [:], nil, "0x1p4"),
            ("kido-unfocused-background-shift = 100%", [:], 1, nil),
            ("kido-unfocused-background-shift = 101", [:], nil, "101"),
            ("kido-unfocused-background-shift = -10%", [:], 0.1, nil),
            ("kido-unfocused-background-shift = -101", [:], nil, "-101"),
            ("kido-unfocused-background-shift = dark", [:], nil, "dark"),
            ("", [:], nil, nil),
            ("kido-unfocused-background-shift = 20%\nkido-unfocused-background-shift =", [:], nil, nil),
            ("kido-unfocused-background-shift = 20%\nkido-unfocused-background-shift =   ", [:], nil, nil),
            ("config-file = included.conf", ["included.conf": "kido-unfocused-background-shift = 30%"], 0.3, nil),
            ("kido-unfocused-background-shift = 20%\nconfig-file = ?missing.conf\nconfig-file = ?\"included.conf\"",
             ["included.conf": "config-file = nested.conf", "nested.conf": "kido-unfocused-background-shift = \"30%\""], 0.3, nil),
            ("kido-unfocused-background-shift = 20%\nconfig-file = included.conf",
             ["included.conf": "kido-unfocused-background-shift ="], nil, nil),
            ("config-file = included.conf\nconfig-file = sibling.conf",
             ["included.conf": "kido-unfocused-background-shift = 10%\nconfig-file = nested.conf",
              "sibling.conf": "kido-unfocused-background-shift = 20%",
              "nested.conf": "kido-unfocused-background-shift = 30%\nconfig-file = included.conf"], 0.3, nil),
            ("config-file = linked.conf",
             ["other/theme.conf": "config-file = child.conf", "other/child.conf": "kido-unfocused-background-shift = 40%",
              "child.conf": "kido-unfocused-background-shift = 50%"], 0.4, nil)
        ] as [(String, [String: String], Double?, String?)] {
            for (name, contents) in files {
                try contents.write(to: directory.appendingPathComponent(name), atomically: false, encoding: .utf8)
            }
            let (settings, lines) = try load(text)
            XCTAssertEqual(settings.unfocusedShift, shade ?? 0.03, text)
            XCTAssertFalse(lines.contains { $0.contains("kido-unfocused-background-shift: unknown field") }, "\(text): \(lines)")
            XCTAssertTrue(lines.contains { $0.contains("kido-unknown-key: unknown field") }, text)
            XCTAssertEqual(lines.contains { $0.contains("not a percentage") }, note != nil, text)
            if let note { XCTAssertTrue(lines.contains { $0.hasSuffix("kido-unfocused-background-shift: not a percentage from -100 to 100: " + note) }, text) }
        }

        for (text, spacing, note) in [
            ("kido-pane-spacing = 8", 8, nil),
            ("kido-pane-spacing = \"12.5\"", 12.5, nil),
            ("kido-pane-spacing = 2", 2, nil),
            ("kido-pane-spacing = 32", 32, nil),
            ("", 8, nil),
            ("kido-pane-spacing = 12\nkido-pane-spacing =", 8, nil),
            ("kido-pane-spacing = 33", 8, "kido-pane-spacing: not a number of points from 2 to 32: 33"),
            ("kido-pane-spacing = 1.9", 8, "kido-pane-spacing: not a number of points from 2 to 32: 1.9"),
            ("kido-pane-spacing = 0", 8, "kido-pane-spacing: not a number of points from 2 to 32: 0"),
            ("kido-pane-spacing = wide", 8, "kido-pane-spacing: not a number of points from 2 to 32: wide"),
        ] as [(String, CGFloat, String?)] {
            let (parsed, lines) = try load(text)
            XCTAssertEqual(parsed.paneSpacing, spacing, text)
            XCTAssertFalse(lines.contains { $0.contains("kido-pane-spacing: unknown field") }, "\(text): \(lines)")
            XCTAssertEqual(lines.contains { $0.contains("not a number of points") }, note != nil, text)
            if let note { XCTAssertTrue(lines.contains { $0.hasSuffix(note) }, text) }
        }
    }

    func testLiveConfigFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("kido-app.conf")
        let included = directory.appendingPathComponent("included.conf")
        try "kido-unfocused-background-shift = 20%\n".write(to: included, atomically: false, encoding: .utf8)
        let board = NSPasteboard(name: .init("live-config-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file.path, pasteboard: board))
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.03)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { runtime.onConfigChange = {}; owner.close() }
        func reload(_ edit: () throws -> Void) async throws {
            let changed = expectation(description: "config reload")
            runtime.onConfigChange = { owner.updateAppearance(); changed.fulfill() }
            try edit()
            await fulfillment(of: [changed], timeout: 0.3)
        }
        for (text, shade, atomic) in [("kido-unfocused-background-shift = 30%\nbackground = #172029\n", 0.3, false),
                                      ("kido-unfocused-background-shift = 20%\nbackground = #fffaf0\n", 0.2, true),
                                      ("kido-unfocused-background-shift = 40%\n", 0.4, false),
                                      ("background = #172029\n", 0.03, false),
                                      ("kido-unfocused-background-shift =\n", 0.03, false),
                                      ("kido-unfocused-background-shift = bad\n", 0.03, false),
                                      ("kido-unfocused-background-shift = -10%\nbackground = #171717\n", 0.1, false),
                                      ("kido-unfocused-background-shift = 40%\nbackground = #171717\n", 0.4, false),
                                      ("background = #fefaf1\n", 0.03, false),
                                      ("background = #192028\n", 0.03, false),
                                      ("background = #fff9ec\n", 0.03, false),
                                      ("background = #171717\n", 0.03, false),
                                      (nil, 0.03, false)] as [(String?, Double, Bool)] {
            try await reload {
                if let text { try text.write(to: file, atomically: atomic, encoding: .utf8) }
                else { try FileManager.default.removeItem(at: file) }
            }
            XCTAssertEqual(runtime.settings.unfocusedShift, shade)
            owner.sidebar.viewDidLayout()
            XCTAssertEqual(owner.sidebar.list.layer?.backgroundColor, owner.sidebar.listBackground?.cgColor)
            if let text, let expected = ["background = #fefaf1\n": [238.76, 235, 226.54], "background = #192028\n": [16.25, 20.8, 26],
                                        "background = #fff9ec\n": [239.7, 234.06, 221.84], "background = #171717\n": [14.95, 14.95, 14.95]][text] {
                let color = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
                for (actual, target) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
                    XCTAssertEqual(actual, target / 255, accuracy: 0.000001)
                }
            }
            if text?.contains("#fffaf0") == true { XCTAssertEqual(owner.window.appearance?.name, .aqua) }
            if text?.contains("#172029") == true { XCTAssertEqual(owner.window.appearance?.name, .darkAqua) }
        }
        try await reload { try "config-file = included.conf\n".write(to: file, atomically: false, encoding: .utf8) }
        try await reload {
            try "kido-unfocused-background-shift = 70%\n".write(to: included, atomically: false, encoding: .utf8)
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_RELOAD_CONFIG
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_APP
            XCTAssertTrue(GhosttyRuntime.action(runtime.app, target, action))
        }
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.7)
        let events = runtime.visualWatchEvents, scheduled = runtime.visualReloadsScheduled
        try "swap".write(to: directory.appendingPathComponent("kido.conf"), atomically: true, encoding: .utf8)
        try await wait("unrelated directory event handled", within: 0.3) { runtime.visualWatchEvents > events }
        XCTAssertEqual(runtime.visualReloadsScheduled, scheduled)
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            try await reload { NSApp.appearance = NSAppearance(named: name) }
            XCTAssertEqual(owner.window.appearance?.name, name)
            XCTAssertEqual(runtime.settings.unfocusedShift, 0.7)
            let actual = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
            let expected = name == .darkAqua ? [14.95, 14.95, 14.95] : [239.7, 234.06, 221.84]
            for (channel, target) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent], expected) {
                XCTAssertEqual(channel, target / 255, accuracy: 0.000001)
            }
        }
        try await reload { try FileManager.default.removeItem(at: file) }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            try await reload { NSApp.appearance = NSAppearance(named: name) }
            XCTAssertEqual(runtime.settings.unfocusedShift, 0.03)
            let actual = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
            let expected = name == .darkAqua ? [14.95, 14.95, 14.95] : [239.7, 234.06, 221.84]
            for (channel, target) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent], expected) {
                XCTAssertEqual(channel, target / 255, accuracy: 0.000001)
            }
        }
    }

    func testSymlinkConfigReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linked-config-\(UUID().uuidString)")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("target-config-\(UUID().uuidString)")
        for path in [directory, targetDirectory] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        defer { for path in [directory, targetDirectory] { try? FileManager.default.removeItem(at: path) } }
        let file = directory.appendingPathComponent("kido-app.conf")
        let target = targetDirectory.appendingPathComponent("target.conf")
        try "kido-unfocused-background-shift = 20%\n".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let board = NSPasteboard(name: .init("linked-config-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file.path, pasteboard: board))
        func reload(_ edit: () throws -> Void) async throws {
            let changed = expectation(description: "symlink target reload")
            runtime.onConfigChange = { changed.fulfill() }
            try edit()
            await fulfillment(of: [changed], timeout: 0.3)
        }
        try await reload { try FileManager.default.moveItem(at: target, to: targetDirectory.appendingPathComponent("old.conf")) }
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.03)
        try await reload { try "kido-unfocused-background-shift = 30%\n".write(to: target, atomically: false, encoding: .utf8) }
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.3)
        try await reload { try "kido-unfocused-background-shift = 40%\n".write(to: target, atomically: false, encoding: .utf8) }
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.4)
        runtime.onConfigChange = {}
    }

    func testConfigDirectoryCreatedAfterLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("missing-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("new/kido-app.conf")
        let board = NSPasteboard(name: .init("missing-config-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file.path, pasteboard: board))
        let changed = expectation(description: "directory and config created")
        runtime.onConfigChange = { changed.fulfill() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "kido-unfocused-background-shift = 30%\n".write(to: file, atomically: false, encoding: .utf8)
        await fulfillment(of: [changed], timeout: 0.3)
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.3)
        runtime.onConfigChange = {}
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
        await mainQueueFence()
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
                let expected = headerPaperRGB["\(hex)-shifted"]!
                if transferred {
                    try assertPaperPixel(image, x: 20, y: 10, expected: headerPaperRGB["white"]!)
                    let snapshot = NSImage(size: view.bounds.size)
                    snapshot.addRepresentation(image)
                    let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                    if let failure = verifySnapshot(of: snapshot, as: .image, named: "fullscreen-switch-\(index)-\(hex)", record: record),
                       !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
                }
                let pixels = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default))
                let scale = CGFloat(pixels.pixelsHigh) / view.bounds.height
                // The trailing 28pt tab-strip slot contains the new-window plus.
                for y in [CGFloat(3), 26, 49] {
                    try assertPaperPixel(pixels, x: pixels.pixelsWide - Int(40 * scale), y: Int(y * scale), expected: expected)
                }
            }
        }
    }

    func testHeaderShiftReload() async throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("header-shift-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: config) }
        let board = NSPasteboard(name: .init("header-shift-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        for hex in ["fffaf0", "172029"] {
            try "background = #\(hex)\n".write(to: config, atomically: true, encoding: .utf8)
            let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
            let owner = WindowOwner(host: .local, runtime: runtime, start: false)
            defer { runtime.onConfigChange = {}; owner.close() }
            for shift in [10, 3] {
                let changed = expectation(description: "header shift-only reload")
                runtime.onConfigChange = { owner.updateAppearance(); changed.fulfill() }
                try "background = #\(hex)\nkido-unfocused-background-shift = \(shift)%\n".write(to: config, atomically: true, encoding: .utf8)
                await fulfillment(of: [changed], timeout: 3)
                owner.window.display()
                let expected = headerPaperRGB["\(hex)-shifted" + (shift == 10 ? "10" : "")]!
                let root = try XCTUnwrap(owner.window.contentView?.superview)
                let image = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: image)
                let pixels = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default))
                let scale = CGFloat(pixels.pixelsHigh) / root.bounds.height
                try assertPaperPixel(pixels, x: pixels.pixelsWide - Int(40 * scale), y: Int(26 * scale), expected: expected, "\(hex) shift-only reload repaints band")
                XCTAssertEqual(owner.sidebar.tabs.theme.background, owner.window.backgroundColor)
                XCTAssertEqual(owner.sidebar.content.layer?.backgroundColor, runtime.background.cgColor)
            }
        }
    }

    func testSeenIsSharedAcrossSameHostWindows() throws {
        let board = NSPasteboard(name: .init("kido-seen-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let host = Kido.Host.remote("seen-\(UUID().uuidString.prefix(8))")
        let publisher = WindowOwner(host: host, runtime: runtime, start: false)
        let peer = WindowOwner(host: host, runtime: runtime, start: false)
        let other = WindowOwner(host: .remote("other-\(UUID().uuidString.prefix(8))"), runtime: runtime, start: false)
        defer { [publisher, peer, other].forEach { $0.close() } }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"server_instance":{"started_at":1791000000,"pid":4242},"error":null,"sessions":[{"id":"$0","name":"s","current":true,"nodes":[{"kind":"pane","id":"%1","pane":"%1","window":"@1","title":"agent","lifecycle":["Live",["Some_agent",{"name":"claude-code","status":{"since":1791000000,"msg":null,"state":["Idle",{"outcome":{"serial":3,"result":"failure"}}]}}]],"program_status":{"serial":3,"records":[]},"run":null,"started":null,"children":[]}]}]}
        """.utf8))
        func status(_ owner: WindowOwner) -> SidebarRow.Status? { owner.sidebar.list.visualRows.first { $0.target != nil }?.status }
        let baseline = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"server_instance":{"started_at":1791000000,"pid":4242},"error":null,"sessions":[]}
        """.utf8))
        for owner in [peer, other] { owner.testReceive(baseline); owner.testReceive(snapshot) }
        XCTAssertEqual([peer, other].map(status), [.error, .error], "unattended windows leave the outcome unseen")
        publisher.testAttended = true
        publisher.testReceive(snapshot)
        XCTAssertEqual(status(publisher), .quiet, "the attended window marks its active pane's outcome seen")
        XCTAssertEqual(status(peer), .quiet, "a same-host window redraws from the shared seen record")
        XCTAssertEqual(status(other), .error, "another host's seen record is separate")
    }

    func testOrphanedTab() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"server_instance":{"started_at":1791000000,"pid":4242},"sessions":[{"id":"$0","name":"s","current":true,"nodes":[{"kind":"pane","id":"%0","pane":"%0","window":"@0","title":"","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[{"kind":"pane","id":"%1","pane":"%1","window":"@1","title":"","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":"bash","started":null,"children":[]}]}]}]}
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

}
