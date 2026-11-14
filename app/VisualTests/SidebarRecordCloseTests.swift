import AppKit
import KoModel
import SidebarFeed
import XCTest
@testable import Kido

@MainActor final class SidebarRecordCloseTests: VisualTestCase {
    private func shown(records: [KoSchema.ProgramRecord]) -> (NSWindow, SidebarView) {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        let list = SidebarView()
        window.contentView = list
        list.show(fixtureSnapshot(window: 1, pane: 1, [("main", [.item(fixtureItem(1, "parent", piLifecycle(), records: records, serial: 1))])]))
        list.layoutSubtreeIfNeeded()
        return (window, list)
    }

    private let records: [KoSchema.ProgramRecord] = [
        .working(.init(closeable: true, id: "agents/reviewer", selection: .offered, title: "reviewer")),
        .idle(.init(id: "agents/planner", selection: .offered, title: "planner")),
        .done(.init(id: "job/1", title: "build")),
    ]

    private func cell(_ list: SidebarView, _ record: String) throws -> SidebarCell {
        let index = try XCTUnwrap(list.visualRows.firstIndex { $0.title == record })
        let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCell)
        cell.layoutSubtreeIfNeeded()
        cell.updateTrackingAreas()
        return cell
    }

    private func hover(_ cell: SidebarCell, in window: NSWindow) {
        let point = cell.convert(NSPoint(x: cell.close.frame.midX, y: cell.close.frame.midY), to: nil)
        cell.mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!)
        cell.layoutSubtreeIfNeeded()
    }

    private func key(_ code: UInt16, in list: SidebarView, window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: code))
        list.visualTable.keyDown(with: event)
    }

    func testCloseButtonPendingAndTimeout() throws {
        let (window, list) = shown(records: records)
        var closed: [String] = []
        list.closeRecord = { closed.append($1) }
        var clock: TimeInterval = 100
        list.uptime = { clock }
        let reviewer = try cell(list, "reviewer")
        let planner = try cell(list, "planner")
        XCTAssertEqual(reviewer.trackingAreas.first?.rect, reviewer.close.frame)
        XCTAssertTrue(planner.trackingAreas.isEmpty, "a record without closeable has no close slot")
        hover(planner, in: window)
        XCTAssertTrue(planner.close.isHidden)
        hover(reviewer, in: window)
        XCTAssertFalse(reviewer.close.isHidden)
        XCTAssertNil(reviewer.close.toolTip)
        XCTAssertEqual(reviewer.close.accessibilityLabel(), "reviewer")
        reviewer.close.performClick(nil)
        XCTAssertEqual(closed, ["agents/reviewer"])
        XCTAssertTrue(list.isClosing(try XCTUnwrap(list.visualRows.first { $0.title == "reviewer" }).id))
        let pending = try cell(list, "reviewer")
        hover(pending, in: window)
        XCTAssertTrue(pending.close.isHidden, "a pending record shows its indicator, not the close button")
        list.beginClosing(try XCTUnwrap(list.visualRows.first { $0.title == "reviewer" }))
        XCTAssertEqual(closed, ["agents/reviewer"], "a second click does nothing")
        clock += 4.9
        list.expireClosing()
        XCTAssertTrue(list.isClosing(try XCTUnwrap(list.visualRows.first { $0.title == "reviewer" }).id))
        clock += 0.2
        list.expireClosing()
        XCTAssertFalse(list.isClosing(try XCTUnwrap(list.visualRows.first { $0.title == "reviewer" }).id))
        let again = try cell(list, "reviewer")
        hover(again, in: window)
        XCTAssertFalse(again.close.isHidden, "the close button works again after the timeout")
        list.beginClosing(try XCTUnwrap(list.visualRows.first { $0.title == "reviewer" }))
        let id = try XCTUnwrap(list.visualRows.first { $0.title == "reviewer" }).id
        list.show(fixtureSnapshot(window: 1, pane: 1, [("main", [.item(fixtureItem(1, "parent", piLifecycle(), records: Array(records.dropFirst()), serial: 2))])]))
        XCTAssertFalse(list.isClosing(id), "the record's removal ends its pending state")
        XCTAssertFalse(list.visualRows.contains { $0.title == "reviewer" })
    }

    func testDeleteClosesASelectedClosableRecordOnly() throws {
        let (window, list) = shown(records: records)
        var closed: [String] = []
        list.closeRecord = { closed.append($1) }
        for (title, expected) in [("planner", []), ("reviewer", ["agents/reviewer"])] {
            list.visualTable.selectRowIndexes([try XCTUnwrap(list.visualRows.firstIndex { $0.title == title })], byExtendingSelection: false)
            try key(51, in: list, window: window)
            XCTAssertEqual(closed, expected)
        }
    }

    func testRecordContextMenu() throws {
        let (window, list) = shown(records: records)
        var selected: [String] = [], closed: [String] = []
        list.selectRecord = { selected.append($1) }
        list.closeRecord = { closed.append($1) }
        func menu(_ title: String) throws -> NSMenu? {
            let index = try XCTUnwrap(list.visualRows.firstIndex { $0.title == title })
            let rect = list.visualTable.rect(ofRow: index)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: list.visualTable.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let found = list.visualTable.menu(for: event)
            found?.update()
            return found
        }
        let reviewer = try XCTUnwrap(try menu("reviewer"))
        XCTAssertEqual(reviewer.items.map(\.title), ["Show", "Close"])
        XCTAssertEqual(reviewer.items.map(\.isEnabled), [true, true])
        reviewer.performActionForItem(at: 0)
        XCTAssertEqual(selected, ["agents/reviewer"])
        reviewer.performActionForItem(at: 1)
        XCTAssertEqual(closed, ["agents/reviewer"])
        let pending = try XCTUnwrap(try menu("reviewer"))
        XCTAssertEqual(pending.items.map(\.isEnabled), [true, false], "Close is disabled while the close is pending")
        let planner = try XCTUnwrap(try menu("planner"))
        XCTAssertEqual(planner.items.map(\.title), ["Show"])
        XCTAssertEqual(planner.items.map(\.isEnabled), [true])
        XCTAssertNil(try menu("build"))
    }

    func testRecordCloseButtonOnHover() throws {
        let (window, list) = shown(records: records)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hover(try cell(list, "reviewer"), in: window)
            sidebarSnapshot(list, dark ? "dark" : "light")
        }
    }

    func testRecordPendingClose() throws {
        let (window, list) = shown(records: records)
        list.closeRecord = { _, _ in }
        list.beginClosing(try XCTUnwrap(list.visualRows.first { $0.title == "reviewer" }))
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            sidebarSnapshot(list, dark ? "dark" : "light")
        }
    }
}
