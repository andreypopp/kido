import AppKit
import KoModel
import SnapshotTesting
import PaneGeometry
import XCTest
@testable import Kido

// The layout of a private ko server in a WindowOwner, and the gestures that edit it. The snapshots
// record the placed geometry: pane content comes with the content bridge.
@MainActor final class LayoutVisualTests: VisualTestCase {
    private var dir = ""
    private var owner: WindowOwner!
    private let sleep = #"{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","600"]}}}}"#

    override func setUp() async throws {
        try await super.setUp()
        var template = Array("/tmp/ko-vl-XXXXXX".utf8CString)
        dir = String(cString: try XCTUnwrap(mkdtemp(&template)))
        PaneView.renderOffscreen = true
        let board = NSPasteboard(name: .init("ko-layout-" + UUID().uuidString))
        // The font of the recorded snapshots, so that only the layout differs.
        let config = dir + "/ghostty.conf"
        try "\(ThemeConf.line(.init()))\nfont-family = Menlo\nfont-size = 13\ncursor-style-blink = false\n".write(toFile: config, atomically: true, encoding: .utf8)
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(configFile: config, pasteboard: board)), start: false)
        owner.testServerDir = dir
        self.owner = owner
        addTeardownBlock { @MainActor [dir] in
            owner.close()
            board.releaseGlobally()
            _ = try? await Child.run(tools.ko, ["kill-server", "--server", dir])
            try? FileManager.default.removeItem(atPath: dir)
        }
        owner.start()
        try await wait("the empty server", within: 5) { owner.testBanner.testText.title == "No sessions" }
        // The terminal area of the recorded snapshots: a 700x560 session view.
        let content = try XCTUnwrap(owner.window.contentView)
        content.layoutSubtreeIfNeeded()
        let area = owner.sidebar.content.bounds.size
        owner.window.setContentSize(NSSize(width: content.bounds.width + 700 - area.width, height: content.bounds.height + 560 - area.height))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(owner.sidebar.content.bounds.size, NSSize(width: 700, height: 560))
    }

    override func tearDown() async throws {
        owner = nil
        PaneView.renderOffscreen = false
    }

    private func put(_ windows: String) async throws {
        let draft = dir + "/draft.json"
        try #"{"revision":0,"layout":{"sessions":[{"name":"visual","windows":\#(windows)}]}}"#.write(toFile: draft, atomically: true, encoding: .utf8)
        let put = try await Child.run(tools.ko, ["api", "--server", dir, "-X", "PUT", "--input", draft, "/layout"])
        XCTAssertEqual(put.status, 0, put.err)
    }

    private var terminal: WindowView? { owner.testSession?.windows.values.first { !$0.isHidden } }

    private var window: KoSchema.Window? { owner.testModel?.layout.layout.sessions.first?.windows.first }

    // The server took the client's size and the owner placed what it sent.
    private func placed(_ description: String, _ condition: @escaping @MainActor (KoSchema.Window) -> Bool = { _ in true }) async throws {
        try await wait(description, within: 5) {
            guard let terminal = self.terminal, let window = self.window else { return false }
            return terminal.visualGeometryReady && condition(window)
        }
        owner.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func snapshot(_ name: String, testName: String = #function) throws {
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        let layout = try XCTUnwrap(terminal).visualLayout
        if let failure = verifySnapshot(of: layout, as: .lines, named: name, record: record, testName: testName),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    private func chrome(_ pane: PaneID) throws -> PaneChrome {
        try XCTUnwrap(terminal?.subviews.compactMap { $0 as? PaneChrome }.first { $0.pane == pane })
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        let terminal = try XCTUnwrap(terminal)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: terminal.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func cell() throws -> CGSize { try XCTUnwrap(owner.testSession?.cell) }

    private func geometry(_ pane: PaneID) -> Geometry? {
        window.flatMap { Layout($0).root.panes.first { $0.id == pane }?.geometry }
    }

    func testSplitZoomFloat() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[{"split":"v","children":[\#(sleep),\#(sleep)]},{"split":"v","children":[\#(sleep),\#(sleep)]}]}}]"#)
        try await placed("four panes") { Layout($0).root.panes.count == 4 }
        try snapshot("2x2")

        let session = try XCTUnwrap(owner.testSession)
        session.paneCommand(.zoom, PaneID(number: 1))
        try await placed("zoom") { $0.zoom == PaneID(number: 1) }
        XCTAssertEqual(terminal?.panes.filter { !$0.isHidden }.map(\.pane), [PaneID(number: 1)])
        try snapshot("zoom")
        session.paneCommand(.zoom, PaneID(number: 1))
        try await placed("the zoom ended") { $0.zoom == nil }

        session.edit(.float(KoSchema.EditFloat(cols: 35, pane: PaneID(number: 4), rows: 10, x: 5, y: 0)), nil)
        try await placed("floating layout") { $0.floats.map(\.pane) == [PaneID(number: 4)] }
        XCTAssertTrue(terminal?.visualLayout.contains("float pane_4") == true)
        let top = try chrome(PaneID(number: 4)).frame.minY
        XCTAssertGreaterThanOrEqual(top, 0.5, "a float in the first row stays below the separator")
        try snapshot("float-top")

        let float = PaneID(number: 4)
        let terminal = try XCTUnwrap(terminal)
        (owner.window as? OwnerWindow)?.focusChanged = { [weak terminal] _, _ in terminal?.updateFocusTreatment() }
        session.selectPane(float)
        try await wait("float is active", within: 5) { self.window?.focus == PaneID(number: 4) || terminal.active == float }
        owner.window.makeFirstResponder(try XCTUnwrap(session.pane(float)))
        terminal.focus(float)
        XCTAssertEqual(try chrome(float).treatment, .plain)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner.window)
        XCTAssertEqual(try chrome(float).treatment, .overlay, "the active float takes the inactive overlay while the window is not key")
        try snapshot("float-window-not-key")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: owner.window)
        XCTAssertEqual(try chrome(float).treatment, .plain)
    }

    func testADividerDragIsOneResizeOfTheTwoNeighbours() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep),\#(sleep)]}}]"#)
        try await placed("three panes") { Layout($0).root.panes.count == 3 }
        try snapshot("before")
        let first = try XCTUnwrap(geometry(PaneID(number: 1))), third = try XCTUnwrap(geometry(PaneID(number: 3)))
        let left = try chrome(PaneID(number: 1)).frame, right = try chrome(PaneID(number: 2)).frame
        let terminal = try XCTUnwrap(terminal)
        let start = NSPoint(x: (left.maxX + right.minX) / 2, y: left.midY)
        XCTAssertTrue(terminal.hitTest(terminal.convert(start, to: terminal.superview)) === terminal, "the divider takes the press")
        let step = try cell().width
        terminal.mouseDown(with: try mouse(.leftMouseDown, start))
        for cells in 1...6 { terminal.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: start.x + CGFloat(cells) * step, y: start.y))) }
        terminal.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: start.x + 6 * step, y: start.y)))
        try await placed("the first pane is six cells wider") { _ in self.geometry(PaneID(number: 1))?.width == first.width + 6 }
        try await wait("the edits settled", within: 5) { self.owner.testSession?.editing() == false }
        XCTAssertEqual(geometry(PaneID(number: 3)), third, "the drag moves one divider")
        XCTAssertTrue(terminal.panes.allSatisfy { !$0.visualResizeIntent }, "the settled layout ends the resize intent")
        try snapshot("after")
    }

    func testAFloatDragHoldsItsFrameUntilTheLayoutShowsIt() async throws {
        let new = String(sleep.dropFirst(8).dropLast())
        try await put(#"[{"name":"w","tree":\#(sleep),"floats":[{"pane":\#(new),"x":4,"y":3,"cols":30,"rows":8}]}]"#)
        try await placed("the float") { $0.floats.count == 1 }
        try snapshot("before")
        let float = PaneID(number: 2)
        let frame = try chrome(float).frame
        let start = NSPoint(x: frame.midX, y: frame.minY + 4)
        let terminal = try XCTUnwrap(terminal)
        let cell = try cell()
        terminal.visualBeginDrag(float, try mouse(.leftMouseDown, start))
        XCTAssertTrue(terminal.visualPaneDragging)
        let end = NSPoint(x: start.x + 5 * cell.width, y: start.y + 2 * cell.height)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: start.x + 2 * cell.width, y: start.y + cell.height)))
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, end))
        terminal.mouseUp(with: try mouse(.leftMouseUp, end))
        let moved = try chrome(float).frame
        XCTAssertEqual(moved.minX, frame.minX + 5 * cell.width, accuracy: 0.5, "the released float keeps the drag's frame")
        try await placed("the server moved the float") { $0.floats.first.map { [$0.x, $0.y] } == [9, 5] }
        try await wait("the edits settled", within: 5) { self.owner.testSession?.editing() == false }
        XCTAssertEqual(try chrome(float).frame, moved, "the frame of the settled layout is the drag's frame")
        try snapshot("after")
    }

    func testADroppedPaneSwapsWithThePaneUnderIt() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep)]}}]"#)
        try await placed("two panes") { Layout($0).root.panes.count == 2 }
        let terminal = try XCTUnwrap(terminal)
        let from = try chrome(PaneID(number: 1)).frame, to = try chrome(PaneID(number: 2)).frame
        terminal.visualBeginDrag(PaneID(number: 1), try mouse(.leftMouseDown, NSPoint(x: from.midX, y: from.midY)))
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: to.midX, y: to.midY)))
        terminal.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: to.midX, y: to.midY)))
        try await placed("swapped") { Layout($0).root.panes.map(\.id.number) == [2, 1] }
        try snapshot("swapped")
    }
}

