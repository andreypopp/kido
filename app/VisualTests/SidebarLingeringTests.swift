import AppKit
import KoModel
import SidebarFeed
import XCTest
@testable import Kido

@MainActor final class SidebarLingeringTests: VisualTestCase {
    func testJobRecordsAlignWithSubagent() throws {
        SidebarView.visualNow = 3720_000_000_000
        defer { SidebarView.visualNow = nil }
        var child = fixtureItem(2, "subagent", piLifecycle(.running(.init())), mark: .running)
        child.pane.started = 3708_000_000_000
        child.pane.parent = .init(number: 1)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarView()
        window.contentView = list
        list.show(fixtureSnapshot(window: 1, pane: 1, [("main", [
            .item(fixtureItem(1, "parent", piLifecycle(.running(.init())), records: [
                .working(.init(id: "job/42", started: 3535_000_000_000, title: "Build app")),
                .done(.init(id: "job/43", started: 0, title: "Run tests")),
                .blocked(.init(id: "review", started: 0, title: "Review")),
                .working(.init(id: "review/missing/check", started: 3710_000_000_000, title: "Check guides")),
            ], serial: 1, mark: .running, children: [
                .item(child),
            ])),
        ])]))
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            sidebarSnapshot(list, dark ? "dark" : "light")
        }
    }

    func testClockWidthChangeInvalidatesTitle() throws {
        defer { SidebarView.visualNow = nil }
        var child = fixtureItem(2, String(repeating: "Long title ", count: 20), piLifecycle(.running(.init()), msg: "Activity"))
        child.pane.started = 0
        child.pane.parent = .init(number: 1)
        let snapshot = fixtureSnapshot(window: 1, pane: 1, [("main", [
            fixtureNode(1, "parent", piLifecycle(), children: [.item(child)]),
        ])])
        let row = try XCTUnwrap(sidebarRows(snapshot).first { $0.started != nil })
        let cell = SidebarCell(SidebarFonts())
        cell.frame = NSRect(x: 0, y: 0, width: 292, height: row.height)
        for (before, after) in [(9, 10), (59, 60), (3599, 3600)] {
            SidebarView.visualNow = before * 1_000_000_000
            cell.configure(row, now: SidebarView.visualNow!)
            SidebarView.visualNow = after * 1_000_000_000
            cell.updateClock(now: SidebarView.visualNow!)
            XCTAssertEqual(cell.visualClockDirtyRect.minX, 51)
            XCTAssertEqual(cell.visualClockDirtyRect.minY, 7)
        }
        SidebarView.visualNow = 11_000_000_000
        cell.configure(row, now: SidebarView.visualNow!)
        SidebarView.visualNow = 12_000_000_000
        cell.updateClock(now: SidebarView.visualNow!)
        XCTAssertGreaterThan(cell.visualClockDirtyRect.minX, 200)
        XCTAssertFalse(cell.visualClockDirtyRect.intersects(NSRect(x: row.leading, y: row.tailY, width: 200, height: 15)))
    }

    func testNestedWindowAndLingeringRows() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarView()
        window.contentView = list
        list.show(fixtureSnapshot(window: 1, pane: 1, [("main", [
            fixtureNode(1, "parent", piLifecycle(), children: [fixtureNode(2, "helper", shellLifecycle())]),
            fixtureNode(3, "exit 0, on_exit", .lingering(.exited(.init(code: 0)))),
            fixtureNode(4, "exit 2, on_exit", .lingering(.exited(.init(code: 2)))),
            fixtureNode(5, "signal, on_exit", .lingering(.signaled(.init(signal: 9)))),
            fixtureNode(6, "exit 0, keep", .ended(.exited(.init(code: 0)))),
            fixtureNode(7, "exit 2, keep", .ended(.exited(.init(code: 2)))),
        ])]))
        let rows = list.visualRows.filter { $0.target != nil }
        XCTAssertEqual(rows.map(\.indent), [0, 1, 0, 0, 0, 0, 0])
        XCTAssertEqual(rows.map(\.status), [.quiet, .quiet, .endedClean, .endedFailed, .endedFailed, .done, .error])
        XCTAssertEqual(rows.map(\.indicatorDescription).suffix(5),
                       ["gone, exited", "gone, exited with code 2", "gone, killed by signal 9", "gone, completed", "gone, exited with code 2"])
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            sidebarSnapshot(list, dark ? "dark" : "light")
        }
    }
}
