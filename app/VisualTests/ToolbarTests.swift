import AppKit
import XCTest
import SnapshotTesting
import SidebarFeed
import TmuxControl
@testable import Kido

@MainActor final class ToolbarTests: VisualTestCase {
    func testHostLabel() throws {
        let owner = try XCTUnwrap(delegate.open(.remote("buildbox"), start: false))
        defer { owner.close() }
        let tabs = owner.sidebar.tabs
        XCTAssertEqual(tabs.hostLabel()?.alias, "buildbox")
        XCTAssertFalse(try XCTUnwrap(tabs.hostLabel()).connected)
        tabs.entries = SessionModel(session: SessionID(number: 0), windows: [.init(id: WindowID(number: 0), name: "Shell"), .init(id: WindowID(number: 1), name: "Editor")], window: WindowID(number: 0)).navigation(nil).tabs
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
                if let failure = verifySnapshot(of: tabs, as: .image, named: "\(name)-\(mode)", record: record),
                   !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
            }
        }
    }

    func testOrphanedTab() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"filter":"","client":{"session":"$0","window":"@1","pane":"%1"},"sessions":[{"id":"$0","name":"s","current":true,"nodes":[{"kind":"shell","id":"%0","pane":"%0","window":"@0","title":[],"tail":[],"attention":false,"children":[{"kind":"run","id":"%1","pane":"%1","window":"@1","title":[],"tail":[],"attention":false,"children":[]}]}]}]}
        """.utf8))
        let model = SessionModel(session: SessionID(number: 0), windows: [.init(id: WindowID(number: 1), name: "Child")], window: WindowID(number: 1))
        XCTAssertEqual(model.navigation(snapshot).tabs.map(\.id), [WindowID(number: 1)], "orphan child must retain a tab")
    }

    func testWindowSelectionTargetsSession() {
        let model = SessionModel(session: SessionID(number: 3), windows: [.init(id: WindowID(number: 7), name: "w")], window: WindowID(number: 7))
        XCTAssertEqual(model.select(.number(1)), Command("switch-client", "-t", "$3:@7"), "selection must target the tab's session")
        XCTAssertEqual(PaneCommand.window(.number(1)).command(PaneID(number: 0), cell: .zero, model: model), model.select(.number(1)))
        for step in [WindowStep.next, .previous, .last] {
            XCTAssertEqual(model.select(step), model.select(.number(1)))
        }
        let menus = SessionMenus()
        var commands: [Command] = []
        menus.send = { commands = $0 }
        menus.update(model)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        XCTAssertTrue(menus.window.performKeyEquivalent(with: key))
        XCTAssertEqual(commands, [model.select(.number(1))!])
    }

    func testSessionShortcutsUseRPCNavigationOnce() {
        let menus = SessionMenus()
        var directions: [Bool] = []
        var commands: [Command] = []
        menus.selectSession = { directions.append($0) }
        menus.send = { commands += $0 }
        menus.update(SessionModel())
        for (key, code, next) in [("]", UInt16(30), true), ("[", UInt16(33), false)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            XCTAssertTrue(menus.session.performKeyEquivalent(with: event))
            XCTAssertEqual(directions.last, next)
        }
        XCTAssertEqual(directions, [true, false])
        XCTAssertTrue(commands.isEmpty)
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
