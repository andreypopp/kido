import AppKit
import XCTest
import SnapshotTesting
import SidebarFeed
import TmuxControl
@testable import Kido

@MainActor final class AccentTests: VisualTestCase {
    static let themes = [("light", "fff9ec", "424242"), ("dark", "171717", "c9c9c9")]

    private func runtime(_ background: String, _ foreground: String, in directory: URL) throws -> GhosttyRuntime {
        let config = directory.appendingPathComponent("accent-\(UUID().uuidString).conf")
        try "background = #\(background)\nforeground = #\(foreground)\n".write(to: config, atomically: true, encoding: .utf8)
        return try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: NSPasteboard(name: .init("accent-" + UUID().uuidString))))
    }

    private func suite() throws -> (UserDefaults, () -> Void) {
        let name = "accent-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        return (preferences, { preferences.removePersistentDomain(forName: name) })
    }

    private func snapshot(_ view: NSView, _ name: String, testName: String) {
        view.layoutSubtreeIfNeeded()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: view, as: .image, named: name, record: record, testName: testName),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    func testAccentRoundTripsThroughJSON() throws {
        let accents: [String: Accent] = ["a": .system, "b": .preset(.teal), "c": .custom(red: 0.1, green: 0.5, blue: 0.9)]
        XCTAssertEqual(try JSONDecoder().decode([String: Accent].self, from: JSONEncoder().encode(accents)), accents)
    }

    func testLeastUsedPresetIsTheFirstUnusedOne() {
        XCTAssertEqual(Preset.leastUsed([]), .red)
        XCTAssertEqual(Preset.leastUsed([.red, .orange]), .green)
        XCTAssertEqual(Preset.leastUsed([.orange]), .red)
        XCTAssertEqual(Preset.leastUsed(Preset.allCases), .red)
        XCTAssertEqual(Preset.leastUsed(Preset.allCases + [.red]), .orange)
    }

    func testStoreIsKeyedByHostAndSurvivesRecreation() throws {
        let (preferences, cleanup) = try suite()
        defer { cleanup() }
        let store = HostAccents(preferences: preferences)
        XCTAssertEqual(store.accent(for: .local), .preset(.blue), "Local defaults to the dimmed blue")
        XCTAssertEqual(store.suggestion, .preset(.red), "Local's default counts blue as used")
        store.set(.system, for: .local)
        XCTAssertEqual(store.suggestion, .preset(.red), "an explicit System choice does not count blue")
        XCTAssertEqual(store.accent(for: .local), .system)
        XCTAssertNil(store.known(.remote("devbox")))
        store.set(.preset(.teal), for: .remote("devbox"))
        store.set(.custom(red: 0.2, green: 0.4, blue: 0.6), for: .local)
        let again = HostAccents(preferences: preferences)
        XCTAssertEqual(again.accent(for: .remote("devbox")), .preset(.teal))
        XCTAssertEqual(again.accent(for: .local), .custom(red: 0.2, green: 0.4, blue: 0.6))
        XCTAssertEqual(again.accent(for: .remote("other")), .system)
        again.set(.system, for: .remote("devbox"))
        XCTAssertEqual(HostAccents(preferences: preferences).accent(for: .remote("devbox")), .system)
    }

    func testAssignStoresTheFirstUnusedPresetOnceAndNeverForLocal() throws {
        let (preferences, cleanup) = try suite()
        defer { cleanup() }
        let store = HostAccents(preferences: preferences)
        store.set(.preset(.blue), for: .local)
        XCTAssertEqual(store.suggestion, .preset(.red))
        store.assign(.remote("a"))
        store.assign(.remote("b"))
        store.assign(.remote("a"))
        XCTAssertEqual(store.known(.remote("a")), .preset(.red))
        XCTAssertEqual(store.known(.remote("b")), .preset(.orange))
        store.assign(.remote("c"), chosen: .preset(.pink))
        XCTAssertEqual(store.known(.remote("c")), .preset(.pink))
        store.assign(.remote("a"), chosen: .preset(.green))
        XCTAssertEqual(store.known(.remote("a")), .preset(.green))
        XCTAssertEqual(store.suggestion, .preset(.red))
        let local = HostAccents(preferences: nil)
        local.assign(.local)
        XCTAssertNil(local.known(.local))
    }

    func testLegibleColorsReachTheirContrastOnBothThemes() throws {
        let directory = FileManager.default.temporaryDirectory
        let customs: [Accent] = [.custom(red: 1, green: 1, blue: 0), .custom(red: 0.98, green: 0.98, blue: 0.98), .custom(red: 0.05, green: 0.05, blue: 0.05)]
        for (_, background, foreground) in Self.themes {
            let runtime = try runtime(background, foreground, in: directory)
            for accent in Preset.allCases.map(Accent.preset) + customs {
                XCTAssertGreaterThanOrEqual(accent.legible(on: runtime.canvas, minimum: 4.5).contrast(with: runtime.canvas), 4.5, "\(accent) text on \(background)")
                XCTAssertGreaterThanOrEqual(accent.legible(on: runtime.background, minimum: 3).contrast(with: runtime.background), 3, "\(accent) ring on \(background)")
            }
            XCTAssertEqual(Accent.system.legible(on: runtime.canvas, minimum: 4.5), .controlAccentColor)
        }
    }

    func testWindowsOfOneHostChangeColorTogetherAndOthersDoNot() throws {
        let (preferences, cleanup) = try suite()
        defer { cleanup() }
        let runtime = try runtime("fff9ec", "424242", in: FileManager.default.temporaryDirectory)
        let app = AppDelegate(runtime: runtime, routes: WindowRoutes(preferences: preferences))
        let first = try XCTUnwrap(app.open(.remote("alpha"), start: false)), second = try XCTUnwrap(app.open(.remote("alpha"), start: false))
        let other = try XCTUnwrap(app.open(.remote("beta"), start: false)), local = try XCTUnwrap(app.open(.local, start: false))
        defer { [first, second, other, local].forEach { $0.close() } }
        let untouched = other.sidebar.visualTitle.textColor
        XCTAssertEqual(first.sidebar.visualTitle.textColor, .controlAccentColor)
        app.routes.accents.set(.preset(.teal), for: .remote("alpha"))
        let text = Accent.preset(.teal).legible(on: runtime.canvas, minimum: 4.5)
        let ring = Accent.preset(.teal).legible(on: runtime.background, minimum: 3)
        for owner in [first, second] {
            XCTAssertEqual(owner.sidebar.visualTitle.textColor, text)
            XCTAssertEqual(owner.sidebar.list.accent, text)
            XCTAssertEqual(owner.sidebar.visualFocusEdge.color, ring)
        }
        XCTAssertEqual(other.sidebar.visualTitle.textColor, untouched)
        XCTAssertEqual(other.sidebar.list.accent, untouched)
        XCTAssertEqual(local.sidebar.visualTitle.textColor, Accent.preset(.blue).legible(on: runtime.canvas, minimum: 4.5))
        let later = try XCTUnwrap(app.open(.remote("alpha"), start: false))
        defer { later.close() }
        XCTAssertEqual(later.sidebar.visualTitle.textColor, text)
        XCTAssertEqual(HostAccents(preferences: preferences).accent(for: .remote("alpha")), .preset(.teal))
        XCTAssertEqual(first.window.title, "alpha")
        XCTAssertEqual(local.window.title, "Local")
    }

    func testRingAndSidebarEdgeSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
        for (theme, background, foreground) in Self.themes {
            let runtime = try runtime(background, foreground, in: directory)
            for (name, accent) in [("teal", Accent.preset(.teal)), ("red", .preset(.red)), ("purple", .preset(.purple)), ("blue", .preset(.blue))] {
                let ring = accent.legible(on: runtime.background, minimum: 3)
                let scene = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
                scene.wantsLayer = true
                scene.appearance = NSAppearance(named: runtime.background.isDark ? .darkAqua : .aqua)
                scene.layer?.backgroundColor = runtime.canvas.cgColor
                for (index, focused) in [true, false].enumerated() {
                    let frame = NSRect(x: 8 + CGFloat(index) * 216, y: 8, width: 208, height: 184)
                    let paper = NSView(frame: frame)
                    paper.wantsLayer = true
                    paper.layer?.cornerRadius = 12
                    paper.layer?.backgroundColor = (focused ? runtime.background : runtime.unfocusedPaper).cgColor
                    scene.addSubview(paper)
                    let chrome = PaneChrome(pane: PaneID(number: UInt32(index)), runtime: runtime)
                    chrome.frame = frame
                    chrome.card = 12
                    chrome.ring = ring
                    chrome.treatment = focused ? .edge : .plain
                    scene.addSubview(chrome)
                }
                snapshot(scene, "ring-\(name)-\(theme)", testName: "connection-color")
                let edge = FocusEdge(frame: NSRect(x: 0, y: 0, width: 190, height: 120))
                edge.appearance = scene.appearance
                edge.color = ring
                let backdrop = NSView(frame: edge.frame)
                backdrop.wantsLayer = true
                backdrop.layer?.backgroundColor = runtime.canvas.cgColor
                backdrop.appearance = scene.appearance
                backdrop.addSubview(edge)
                snapshot(backdrop, "sidebar-edge-\(name)-\(theme)", testName: "connection-color")
            }
        }
    }

    func testTitleAndSessionNamesSnapshots() throws {
        SidebarView.visualNow = Date(timeIntervalSince1970: 1791131198)
        defer { SidebarView.visualNow = nil }
        let directory = FileManager.default.temporaryDirectory
        for (theme, background, foreground) in Self.themes {
            let runtime = try runtime(background, foreground, in: directory)
            for (name, host, accent) in [("teal", Host.remote("devbox"), Accent.preset(.teal)), ("red", .remote("devbox"), .preset(.red)),
                                         ("purple", .remote("devbox"), .preset(.purple)), ("local", .local, .preset(.blue))] {
                let (preferences, cleanup) = try suite()
                defer { cleanup() }
                let app = AppDelegate(runtime: runtime, routes: WindowRoutes(preferences: preferences))
                if host != .local { app.routes.accents.set(accent, for: host) }
                let owner = try XCTUnwrap(app.open(host, start: false))
                defer { owner.close() }
                owner.window.setFrame(NSRect(origin: owner.window.frame.origin, size: NSSize(width: 560, height: 340)), display: false)
                owner.testReceive(try sidebarFixture())
                let sidebar = owner.sidebar
                let root = try XCTUnwrap(owner.window.contentView?.superview)
                sidebar.isCollapsed = false
                root.layoutSubtreeIfNeeded()
                sidebar.viewDidLayout()
                XCTAssertEqual(sidebar.windowTitle, host.label)
                XCTAssertEqual(owner.accents.accent(for: host), accent)
                XCTAssertTrue(sidebar.visualFocusEdge.isHidden)
                snapshot(root, "title-docked-\(name)-\(theme)", testName: "connection-color")
                sidebar.list.focus()
                root.layoutSubtreeIfNeeded()
                sidebar.viewDidLayout()
                sidebar.updateFocusEdge()
                XCTAssertFalse(sidebar.visualFocusEdge.isHidden)
                snapshot(root, "title-sidebar-focus-\(name)-\(theme)", testName: "connection-color")
                owner.window.makeFirstResponder(nil)
                sidebar.isCollapsed = true
                root.layoutSubtreeIfNeeded()
                sidebar.viewDidLayout()
                snapshot(root, "title-collapsed-\(name)-\(theme)", testName: "connection-color")
            }
        }
    }
}
