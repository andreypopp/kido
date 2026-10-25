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
                if mode.hasPrefix("docked") {
                    let shadow = try XCTUnwrap(paintedBackground.subviews.first as? SidebarShadow)
                    let mainShadow = try XCTUnwrap(root.subviews.compactMap { $0 as? SidebarShadow }.first)
                    let mainEdge = owner.window.convertPoint(toScreen: mainShadow.convert(.zero, to: nil)).x
                    let headerEdge = header.convertPoint(toScreen: shadow.convert(NSPoint(x: 0, y: 32), to: nil)).x
                    XCTAssertEqual(headerEdge, mainEdge, accuracy: 0.01, "fullscreen shadow continues the main-window shadow column")
                    let scale = CGFloat(hostPixels.pixelsWide) / headerContent.bounds.width
                    let x = Int((paintedBackground.frame.minX + 2) * scale)
                    let separator = try XCTUnwrap(owner.sidebar.separatorColor.usingColorSpace(.sRGB))
                    for y in [2, hostPixels.pixelsHigh / 2, hostPixels.pixelsHigh - 3] {
                        try assertPaperPixel(hostPixels, x: Int(paintedBackground.frame.minX * scale), y: y,
                                             expected: [separator.redComponent * 255, separator.greenComponent * 255, separator.blueComponent * 255], "fullscreen band separator")
                        let edge = try XCTUnwrap(hostPixels.colorAt(x: x, y: y))
                        let paper = try XCTUnwrap(hostPixels.colorAt(x: x + Int(36 * scale), y: y))
                        XCTAssertLessThan(edge.redComponent, paper.redComponent - 2 / 255, "\(hex) shadow covers the full fullscreen band at y=\(y)")
                    }
                }
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

    func testSidebarShade() async throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("other"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("kido-app.conf")
        let board = NSPasteboard(name: .init("shade-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let notes = directory.appendingPathComponent("notes.log")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.conf"),
                                                  withDestinationURL: directory.appendingPathComponent("other/theme.conf"))
        for (key, field, fallback, diagnostic) in [
            ("kido-sidebar-shade", \GhosttyRuntime.KidoSettings.sidebarShade, 0.05, "kido-sidebar-shade: not a percentage from -100 to 100: "),
            ("kido-unfocused-background-shift", \GhosttyRuntime.KidoSettings.unfocusedShift, 0.03, "kido-unfocused-background-shift: not a percentage from -100 to 100: ")
        ] {
            for (text, files, shade, note) in [
                ("kido-sidebar-shade = 30%", [:], 0.3, nil),
                ("kido-sidebar-shade = 30", [:], 0.3, nil),
                ("kido-sidebar-shade = 0", [:], 0, nil),
                ("kido-sidebar-shade = -0", [:], 0, nil),
                ("kido-sidebar-shade = -100", [:], 1, nil),
                ("kido-sidebar-shade = \"\"", [:], nil, nil),
                ("kido-sidebar-shade = 20%\nkido-sidebar-shade = 40%", [:], 0.4, nil),
                ("kido-sidebar-shade =   \" 30.5% \"  ", [:], 0.305, nil),
                ("kido-sidebar-shade = +30", [:], nil, "+30"),
                ("kido-sidebar-shade = 1e1", [:], nil, "1e1"),
                ("kido-sidebar-shade = 0x1p4", [:], nil, "0x1p4"),
                ("kido-sidebar-shade = 100%", [:], 1, nil),
                ("kido-sidebar-shade = 101", [:], nil, "101"),
                ("kido-sidebar-shade = -10%", [:], 0.1, nil),
                ("kido-sidebar-shade = -101", [:], nil, "-101"),
                ("kido-sidebar-shade = dark", [:], nil, "dark"),
                ("", [:], nil, nil),
                ("kido-sidebar-shade = 20%\nkido-sidebar-shade =", [:], nil, nil),
                ("kido-sidebar-shade = 20%\nkido-sidebar-shade =   ", [:], nil, nil),
                ("config-file = included.conf", ["included.conf": "kido-sidebar-shade = 30%"], 0.3, nil),
                ("kido-sidebar-shade = 20%\nconfig-file = ?missing.conf\nconfig-file = ?\"included.conf\"",
                 ["included.conf": "config-file = nested.conf", "nested.conf": "kido-sidebar-shade = \"30%\""], 0.3, nil),
                ("kido-sidebar-shade = 20%\nconfig-file = included.conf",
                 ["included.conf": "kido-sidebar-shade ="], nil, nil),
                ("config-file = included.conf\nconfig-file = sibling.conf",
                 ["included.conf": "kido-sidebar-shade = 10%\nconfig-file = nested.conf",
                  "sibling.conf": "kido-sidebar-shade = 20%",
                  "nested.conf": "kido-sidebar-shade = 30%\nconfig-file = included.conf"], 0.3, nil),
                ("config-file = linked.conf",
                 ["other/theme.conf": "config-file = child.conf", "other/child.conf": "kido-sidebar-shade = 40%",
                  "child.conf": "kido-sidebar-shade = 50%"], 0.4, nil)
            ] as [(String, [String: String], Double?, String?)] {
                let text = text.replacingOccurrences(of: "kido-sidebar-shade", with: key)
                try ("background = #172029\nkido-sidebar-shad = 1\n" + text + "\n").write(to: config, atomically: false, encoding: .utf8)
                for (name, contents) in files {
                    try contents.replacingOccurrences(of: "kido-sidebar-shade", with: key).write(to: directory.appendingPathComponent(name), atomically: false, encoding: .utf8)
                }
                FileManager.default.createFile(atPath: notes.path, contents: nil)
                let log = try FileHandle(forWritingTo: notes)
                let saved = dup(STDERR_FILENO)
                dup2(log.fileDescriptor, STDERR_FILENO)
                let loaded = GhosttyRuntime.loadConfig(file: config.path)
                dup2(saved, STDERR_FILENO)
                close(saved)
                try log.close()
                let parsed = try XCTUnwrap(loaded)
                ghostty_config_free(parsed.config)
                XCTAssertEqual(parsed.settings[keyPath: field], shade ?? fallback, text)
                let lines = try String(contentsOf: notes, encoding: .utf8).split(separator: "\n")
                XCTAssertFalse(lines.contains { $0.contains("\(key): unknown field") }, "\(text): \(lines)")
                XCTAssertTrue(lines.contains { $0.contains("kido-sidebar-shad: unknown field") }, text)
                XCTAssertEqual(lines.contains { $0.contains("not a percentage") }, note != nil, text)
                if let note { XCTAssertTrue(lines.contains { $0.hasSuffix(diagnostic + note) }, text) }
            }
        }

        let fixture = try sidebarFixture()
        SidebarView.visualNow = Date(timeIntervalSince1970: 1791131198)
        defer { SidebarView.visualNow = nil }
        for hex in ["fffaf0", "172029"] {
            for value in [nil, "30%", "20%"] as [String?] {
                try ("background = #\(hex)\n" + (value.map { "kido-sidebar-shade = \($0)\n" } ?? "")).write(to: config, atomically: true, encoding: .utf8)
                let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
                let owner = WindowOwner(host: .local, runtime: runtime, start: false)
                defer { owner.close() }
                let list = owner.sidebar.list
                list.update(.running(fixture))
                let root = try XCTUnwrap(owner.window.contentView?.superview)
                let channels: [Double]
                switch (hex, value) {
                case ("fffaf0", nil): channels = [242.25, 237.5, 228]
                case ("fffaf0", "30%"): channels = [178.5, 175, 168]
                case ("fffaf0", _): channels = [204, 200, 192]
                case (_, nil): channels = [34.6, 43.15, 51.7]
                case (_, "30%"): channels = [92.6, 98.9, 105.2]
                default: channels = [69.4, 76.6, 83.8]
                }
                let expected = NSColor(srgbRed: channels[0] / 255, green: channels[1] / 255, blue: channels[2] / 255, alpha: 1)
                XCTAssertEqual(list.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }, expected, "\(hex) \(value ?? "unset")")
                guard let value else { continue }
                for mode in ["docked", "floating"] {
                    owner.sidebar.dismissFloating()
                    owner.sidebar.isCollapsed = mode != "docked"
                    if mode == "docked" { owner.sidebar.splitView.setPosition(236, ofDividerAt: 0) }
                    else { owner.sidebar.focusSidebar(nil) }
                    root.layoutSubtreeIfNeeded()
                    owner.sidebar.viewDidLayout()
                    owner.window.display()
                    await mainQueueFence()
                    let rect = list.convert(list.bounds, to: root)
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: rect))
                    root.cacheDisplay(in: rect, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / rect.width
                    let empty = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - Int(30 * scale)))
                    XCTAssertEqual(empty.redComponent, expected.redComponent, accuracy: 2 / 255, "\(hex) \(value) \(mode) red")
                    XCTAssertEqual(empty.greenComponent, expected.greenComponent, accuracy: 2 / 255, "\(hex) \(value) \(mode) green")
                    XCTAssertEqual(empty.blueComponent, expected.blueComponent, accuracy: 2 / 255, "\(hex) \(value) \(mode) blue")
                    let image = NSImage(size: rect.size)
                    image.addRepresentation(bitmap)
                    let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
                    if let failure = verifySnapshot(of: image, as: .image, named: "\(hex)-\(value == "30%" ? "darker" : "lighter")-\(mode)", record: record),
                       !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
                }
            }
        }
    }

    func testLiveConfigFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("kido-app.conf")
        let included = directory.appendingPathComponent("included.conf")
        try "kido-sidebar-shade = 20%\n".write(to: included, atomically: false, encoding: .utf8)
        let board = NSPasteboard(name: .init("live-config-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file.path, pasteboard: board))
        XCTAssertEqual(runtime.settings.sidebarShade, 0.05)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { runtime.onConfigChange = {}; owner.close() }
        func reload(_ edit: () throws -> Void) async throws {
            let changed = expectation(description: "config reload")
            runtime.onConfigChange = { owner.updateAppearance(); changed.fulfill() }
            try edit()
            await fulfillment(of: [changed], timeout: 0.3)
        }
        for (text, shade, atomic) in [("kido-sidebar-shade = 30%\nbackground = #172029\n", 0.3, false),
                                      ("kido-sidebar-shade = 20%\nbackground = #fffaf0\n", 0.2, true),
                                      ("kido-sidebar-shade = 40%\n", 0.4, false),
                                      ("background = #172029\n", 0.05, false),
                                      ("kido-sidebar-shade =\n", 0.05, false),
                                      ("kido-sidebar-shade = bad\n", 0.05, false),
                                      ("kido-sidebar-shade = -10%\nbackground = #171717\n", 0.1, false),
                                      ("kido-sidebar-shade = 40%\nbackground = #171717\n", 0.4, false),
                                      ("background = #fefaf1\n", 0.05, false),
                                      ("background = #192028\n", 0.05, false),
                                      ("background = #fff9ec\n", 0.05, false),
                                      ("background = #171717\n", 0.05, false),
                                      (nil, 0.05, false)] as [(String?, Double, Bool)] {
            try await reload {
                if let text { try text.write(to: file, atomically: atomic, encoding: .utf8) }
                else { try FileManager.default.removeItem(at: file) }
            }
            XCTAssertEqual(runtime.settings.sidebarShade, shade)
            owner.sidebar.viewDidLayout()
            XCTAssertEqual(owner.sidebar.list.layer?.backgroundColor, owner.sidebar.listBackground?.cgColor)
            if let text, let expected = ["background = #fefaf1\n": [241.3, 237.5, 228.95], "background = #192028\n": [36.5, 43.15, 50.75],
                                        "background = #fff9ec\n": [242.25, 236.55, 224.2], "background = #171717\n": [34.6, 34.6, 34.6]][text] {
                let color = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
                for (actual, target) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
                    XCTAssertEqual(actual, target / 255, accuracy: 0.000001)
                }
            }
            if text == "kido-sidebar-shade = 40%\nbackground = #171717\n" {
                let color = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
                XCTAssertEqual([color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }, [116, 116, 116])
            }
            if text?.contains("#fffaf0") == true { XCTAssertEqual(owner.window.appearance?.name, .aqua) }
            if text?.contains("#172029") == true { XCTAssertEqual(owner.window.appearance?.name, .darkAqua) }
        }
        try await reload { try "config-file = included.conf\n".write(to: file, atomically: false, encoding: .utf8) }
        try await reload {
            try "kido-sidebar-shade = 70%\n".write(to: included, atomically: false, encoding: .utf8)
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_RELOAD_CONFIG
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_APP
            XCTAssertTrue(GhosttyRuntime.action(runtime.app, target, action))
        }
        XCTAssertEqual(runtime.settings.sidebarShade, 0.7)
        let events = runtime.visualWatchEvents, scheduled = runtime.visualReloadsScheduled
        try "swap".write(to: directory.appendingPathComponent("kido.conf"), atomically: true, encoding: .utf8)
        try await wait("unrelated directory event handled", within: 0.3) { runtime.visualWatchEvents > events }
        XCTAssertEqual(runtime.visualReloadsScheduled, scheduled)
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            try await reload { NSApp.appearance = NSAppearance(named: name) }
            XCTAssertEqual(owner.window.appearance?.name, name)
            XCTAssertEqual(runtime.settings.sidebarShade, 0.7)
            let actual = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
            let expected = name == .darkAqua ? [185.4, 185.4, 185.4] : [76.5, 74.7, 70.8]
            for (channel, target) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent], expected) {
                XCTAssertEqual(channel, target / 255, accuracy: 0.000001)
            }
        }
        try await reload { try FileManager.default.removeItem(at: file) }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            try await reload { NSApp.appearance = NSAppearance(named: name) }
            XCTAssertEqual(runtime.settings.sidebarShade, 0.05)
            let actual = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
            let expected = name == .darkAqua ? [34.6, 34.6, 34.6] : [242.25, 236.55, 224.2]
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
        try "kido-sidebar-shade = 20%\n".write(to: target, atomically: false, encoding: .utf8)
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
        XCTAssertEqual(runtime.settings.sidebarShade, 0.05)
        try await reload { try "kido-sidebar-shade = 30%\n".write(to: target, atomically: false, encoding: .utf8) }
        XCTAssertEqual(runtime.settings.sidebarShade, 0.3)
        try await reload { try "kido-sidebar-shade = 40%\n".write(to: target, atomically: false, encoding: .utf8) }
        XCTAssertEqual(runtime.settings.sidebarShade, 0.4)
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
        try "kido-sidebar-shade = 30%\n".write(to: file, atomically: false, encoding: .utf8)
        await fulfillment(of: [changed], timeout: 0.3)
        XCTAssertEqual(runtime.settings.sidebarShade, 0.3)
        runtime.onConfigChange = {}
    }

    func testSidebarContrastDark100() async throws { try await sidebarContrast(hex: "172029", value: "100%", appearance: .aqua) }
    func testSidebarContrastLight100() async throws { try await sidebarContrast(hex: "fffaf0", value: "100%", appearance: .darkAqua) }
    func testSidebarContrastLight60() async throws { try await sidebarContrast(hex: "fffaf0", value: "60%", appearance: .darkAqua) }

    func testSidebarDefaultLight() async throws { try await sidebarContrast(hex: "fff9ec", value: nil, appearance: .aqua) }
    func testSidebarDefaultDark() async throws { try await sidebarContrast(hex: "171717", value: nil, appearance: .darkAqua) }

    private func sidebarContrast(hex: String, value: String?, appearance: NSAppearance.Name, testName: String = #function) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contrast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("kido-app.conf")
        try "background = #\(hex)\nkido-sidebar-shade = 0\n".write(to: config, atomically: false, encoding: .utf8)
        let board = NSPasteboard(name: .init("contrast-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { runtime.onConfigChange = {}; owner.close() }
        let terminalAppearance = owner.window.effectiveAppearance.name
        if value != nil { XCTAssertNotEqual(owner.sidebar.list.effectiveAppearance.name, appearance) }
        let changed = expectation(description: "shade crosses contrast threshold")
        runtime.onConfigChange = { owner.updateAppearance(); changed.fulfill() }
        try ("background = #\(hex)\n" + (value.map { "kido-sidebar-shade = \($0)\n" } ?? "")).write(to: config, atomically: false, encoding: .utf8)
        await fulfillment(of: [changed], timeout: 0.3)
        XCTAssertEqual(owner.sidebar.list.effectiveAppearance.name, appearance)
        XCTAssertEqual(owner.window.effectiveAppearance.name, terminalAppearance)
        if value == nil {
            let color = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
            let rgb = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
            XCTAssertEqual(rgb, hex == "fff9ec" ? [242, 237, 224] : [35, 35, 35])
        }
        let list = owner.sidebar.list
        list.update(.running(try sidebarFixture()))
        SidebarView.visualNow = Date(timeIntervalSince1970: 1791131198)
        defer { SidebarView.visualNow = nil }
        for floating in [false, true] {
            owner.sidebar.dismissFloating()
            owner.sidebar.isCollapsed = floating
            if floating { owner.sidebar.focusSidebar(nil) }
            else { owner.sidebar.splitView.setPosition(236, ofDividerAt: 0) }
            let root = try XCTUnwrap(owner.window.contentView?.superview)
            root.layoutSubtreeIfNeeded()
            owner.sidebar.viewDidLayout()
            owner.window.display()
            await mainQueueFence()
            XCTAssertEqual(list.visualTable.effectiveAppearance.name, appearance)
            for item in owner.window.toolbar?.items ?? [] where ["newSession", "toggleSidebar"].contains(item.itemIdentifier.rawValue) {
                XCTAssertEqual(item.view?.effectiveAppearance.name, appearance)
            }
            XCTAssertEqual(owner.sidebar.tabs.effectiveAppearance.name, terminalAppearance)
            let rect = list.convert(list.bounds, to: root)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: rect))
            root.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
            if let failure = verifySnapshot(of: image, as: .image, named: floating ? "floating" : "docked", record: record, testName: testName),
               !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
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
                    let pixels = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default))
                    let scale = CGFloat(pixels.pixelsWide) / view.bounds.width
                    let edge = try XCTUnwrap(owner.sidebar.headerDivider(in: header))
                    let separator = try XCTUnwrap(owner.sidebar.separatorColor.usingColorSpace(.sRGB))
                    for y in [2, pixels.pixelsHigh / 2, pixels.pixelsHigh - 3] {
                        try assertPaperPixel(pixels, x: Int(edge * scale), y: y,
                                             expected: [separator.redComponent * 255, separator.greenComponent * 255, separator.blueComponent * 255], "live fullscreen band separator")
                    }
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
