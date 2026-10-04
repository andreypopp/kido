import AppKit
import XCTest
@testable import Kido

@MainActor final class ToolbarTests: XCTestCase {
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
