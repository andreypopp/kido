import AppKit
import KoModel
import SidebarFeed
import XCTest
@testable import Kido

@MainActor final class SidebarFocusTests: VisualTestCase {
    private var menuCancellation: [Timer]?
    @objc private func menuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        let cancel = [0.0, 1.0].map { Timer(timeInterval: $0, target: menu, selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false) }
        menuCancellation = cancel
        for timer in cancel { RunLoop.main.add(timer, forMode: .eventTracking) }
    }
    @discardableResult private func mouse(_ view: NSView, _ point: NSPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = [], menu: Bool = false) throws -> NSMenu? {
        let window = try XCTUnwrap(view.window)
        let location = view.convert(point, to: nil)
        let type: NSEvent.EventType = menu && !modifiers.contains(.control) ? .rightMouseDown : .leftMouseDown
        let root = try XCTUnwrap(window.contentView?.superview)
        let hit = root.hitTest(root.convert(location, from: nil))
        XCTAssertTrue(hit === view || hit?.isDescendant(of: view) == true, "expected \(view), hit \(String(describing: hit))")
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
        if !menu {
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: clicks, pressure: 0))
            NSApp.postEvent(up, atStart: true)
        }
        NSApp.postEvent(down, atStart: true)
        let event = try XCTUnwrap(NSApp.nextEvent(matching: NSEvent.EventTypeMask(rawValue: 1 << type.rawValue), until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true))
        if menu {
            menuCancellation = nil
            NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            defer {
                NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
                menuCancellation?.forEach { $0.invalidate() }
                menuCancellation = nil
            }
            window.sendEvent(event)
            XCTAssertNotNil(menuCancellation)
            return view.menu(for: event)
        }
        window.sendEvent(event)
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { window.sendEvent(up) }
        return nil
    }

    private func drag(_ view: NSView, from point: NSPoint, by delta: NSPoint) throws {
        let window = try XCTUnwrap(view.window)
        let start = view.convert(point, to: nil)
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        let moves: [(NSEvent.EventType, NSPoint)] = [0.1, 0.4, 1.0].map { (.leftMouseDragged, NSPoint(x: start.x + delta.x * $0, y: start.y + delta.y * $0)) } + [(.leftMouseUp, end)]
        for (type, location) in moves {
            NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)), atStart: false)
        }
        view.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        if view is Table {
            for _ in 0..<moves.count {
                guard NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) != nil else { break }
            }
        }
    }

    func testMouseCannotEnterSidebarFocus() throws {
        let collapsed = UserDefaults.standard.object(forKey: "runtimesCollapsed")
        defer {
            if let collapsed { UserDefaults.standard.set(collapsed, forKey: "runtimesCollapsed") }
            else { UserDefaults.standard.removeObject(forKey: "runtimesCollapsed") }
        }
        let window = OwnerWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = Sidebar()
        window.contentViewController = sidebar
        let pane = NSTextView(frame: sidebar.content.bounds)
        sidebar.content.addSubview(pane)
        sidebar.focusTerminal = { window.makeFirstResponder(pane) }
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        sidebar.isCollapsed = false
        sidebar.list.show(sidebarFixture())
        let section = sidebar.list.runtimeSection
        let key = RuntimeKey(name: "box", source: .config)
        section.rows = [.init(runtime: .init(kind: .ssh, name: key.name, source: .config, state: .down), panes: 0, stopping: false)]
        section.collapsed = false
        sidebar.view.layoutSubtreeIfNeeded()
        window.display()
        XCTAssertTrue(window.makeFirstResponder(pane))
        var sidebarTransitions = 0
        window.focusChanged = { _, next in
            if let view = next as? NSView, view.isDescendant(of: sidebar.list) { sidebarTransitions += 1 }
        }
        var opened = 0
        section.open = { _ in
            XCTAssertTrue(window.firstResponder === pane)
            opened += 1
        }
        for clicks in [1, 2] {
            XCTAssertTrue(window.makeFirstResponder(pane))
            try mouse(section, NSPoint(x: 50, y: 43.5), clicks: clicks)
            XCTAssertTrue(window.firstResponder === pane, "runtime click count \(clicks)")
        }
        XCTAssertEqual(opened, 1)
        for modifiers: NSEvent.ModifierFlags in [[], [.control]] {
            XCTAssertTrue(window.makeFirstResponder(pane))
            let menu = try XCTUnwrap(mouse(section, NSPoint(x: 50, y: 43.5), modifiers: modifiers, menu: true))
            XCTAssertTrue(window.firstResponder === pane, "runtime menu \(modifiers)")
            var started: RuntimeKey?
            section.start = { started = $0 }
            section.selection = nil
            let item = try XCTUnwrap(menu.items.first)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(started, key)
        }
        var actions = 0
        section.start = { _ in actions += 1 }
        section.stop = { _ in actions += 1 }
        for state: KoSchema.LinkState in [.down, .up] {
            section.rows = [.init(runtime: .init(kind: .ssh, name: key.name, source: .config, state: state), panes: 0, stopping: false)]
            try mouse(section, NSPoint(x: section.bounds.width - 28, y: 43.5))
            XCTAssertTrue(window.firstResponder === pane)
        }
        XCTAssertEqual(actions, 2)
        section.configError = "Invalid runtime configuration"
        sidebar.view.layoutSubtreeIfNeeded()
        var selected = 0
        section.selected = { selected += 1 }
        for y: CGFloat in [14, 40, section.bounds.height - 1] {
            XCTAssertTrue(window.makeFirstResponder(pane))
            let collapsed = section.collapsed
            try mouse(section, NSPoint(x: 4, y: y))
            if y == 14 {
                XCTAssertEqual(section.collapsed, !collapsed)
                XCTAssertEqual(selected, 0)
            }
            XCTAssertTrue(window.firstResponder === pane, "runtime footer \(y)")
            section.collapsed = false
            sidebar.view.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(sidebarTransitions, 0)
        let table = try XCTUnwrap(sidebar.list.visualTable as? Table)
        var jumps: [Snapshot.Position] = []
        sidebar.list.navigate = { navigation, _ in if case .jump(let target) = navigation { jumps.append(target) } }
        for floating in [false, true] {
            if floating {
                sidebar.isCollapsed = true
                sidebar.focusSidebar(nil)
                XCTAssertTrue(sidebar.isFloating)
                XCTAssertTrue(window.makeFirstResponder(pane))
            }
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
            sidebar.list.layoutSubtreeIfNeeded()
            table.scrollRowToVisible(0)
            for index in 0..<table.numberOfRows where table.visibleRect.contains(NSPoint(x: table.rect(ofRow: index).midX, y: table.rect(ofRow: index).midY)) {
                let rect = table.rect(ofRow: index)
                let count = jumps.count
                try mouse(table, NSPoint(x: rect.midX, y: rect.midY))
                if let target = sidebar.list.visualRows[index].target {
                    XCTAssertEqual(jumps.count, count + 1)
                    XCTAssertEqual(jumps.last, target)
                }
                XCTAssertTrue(window.firstResponder === pane, "row \(index), floating \(floating)")
            }
            let header = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
            var additions = 0
            sidebar.list.newWindow = { _ in additions += 1 }
            try mouse(header.addWindow, NSPoint(x: header.addWindow.bounds.midX, y: header.addWindow.bounds.midY))
            XCTAssertEqual(additions, 1)
            XCTAssertTrue(window.firstResponder === pane)
            table.scrollRowToVisible(0)
            let first = table.rect(ofRow: 0)
            try drag(table, from: NSPoint(x: first.midX, y: first.midY), by: NSPoint(x: 0, y: -20))
            let session = try XCTUnwrap(table.visualDrag)
            sidebar.list.tableView(table, draggingSession: session.session, endedAt: .zero, operation: [])
            XCTAssertTrue(window.firstResponder === pane)
            let scroll = sidebar.list.visualScroll
            let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -60, wheel2: 0, wheel3: 0))
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
            XCTAssertTrue(window.firstResponder === pane)
            sidebar.splitView.setPosition(256, ofDividerAt: 0)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
            let separator = sidebar.visualSeparator
            let root = try XCTUnwrap(window.contentView?.superview)
            let point = separator.convert(NSPoint(x: separator.bounds.midX, y: separator.bounds.midY), to: root)
            let hit = try XCTUnwrap(root.hitTest(point))
            let width = sidebar.list.bounds.width
            try drag(hit, from: hit.convert(point, from: root), by: NSPoint(x: 24, y: 0))
            root.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(sidebar.list.bounds.width, width)
            XCTAssertTrue(window.firstResponder === pane)
            if floating { sidebar.dismissFloating(); sidebar.isCollapsed = false }
        }
        window.focusChanged = { _, _ in }
        sidebar.focusSidebar(nil)
        XCTAssertTrue(sidebar.list.containsFocus)
        XCTAssertTrue(window.makeFirstResponder(section))
        XCTAssertTrue(window.makeFirstResponder(table))
    }


}
