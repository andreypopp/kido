import AppKit
import KoModel
import SidebarFeed
import XCTest
@testable import Kido

@MainActor final class SidebarLingeringTests: VisualTestCase {
    func testNestedWindowAndLingeringRows() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarView()
        window.contentView = list
        list.update(fixtureSnapshot(window: 1, pane: 1, [("main", [
            fixtureNode(1, "parent", piLifecycle(), children: [fixtureNode(2, "helper", shellLifecycle())]),
            fixtureNode(3, "exit 0, on_exit", .lingering(.exited(.init(code: 0)))),
            fixtureNode(4, "exit 2, on_exit", .lingering(.exited(.init(code: 2)))),
            fixtureNode(5, "signal, on_exit", .lingering(.signaled(.init(signal: 9)))),
            fixtureNode(6, "exit 0, keep", .ended(.completed)),
            fixtureNode(7, "exit 2, keep", .ended(.failed)),
        ])]))
        let rows = list.visualRows.filter { $0.target != nil }
        XCTAssertEqual(rows.map(\.indent), [0, 1, 0, 0, 0, 0, 0])
        XCTAssertEqual(rows.map(\.status), [.quiet, .quiet, .endedClean, .endedFailed, .endedFailed, .done, .error])
        XCTAssertEqual(rows.map(\.indicatorDescription).suffix(5),
                       ["gone, exited", "gone, exited with code 2", "gone, killed by signal 9", "gone, completed", "gone, failed"])
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            sidebarSnapshot(list, dark ? "dark" : "light")
        }
    }
}
