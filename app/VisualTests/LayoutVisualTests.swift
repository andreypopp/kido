import AppKit
import KoModel
import SnapshotTesting
import PaneGeometry
import SidebarFeed
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
        let config = dir + "/ghostty.yaml"
        try "app: {font: {size: 13}}\n".write(toFile: config, atomically: true, encoding: .utf8)
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(configFile: config, pasteboard: board)), start: false)
        owner.testServerDir = dir
        self.owner = owner
        addTeardownBlock { @MainActor [dir] in
            owner.close()
            board.releaseGlobally()
            await KoServer.finishLaunches(dir: dir)
            _ = try? await Child.run(tools.ko, ["kill-server", "--server", dir])
            try? FileManager.default.removeItem(atPath: dir)
        }
        _ = try await KoServer.launch(dir: dir)
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
        try await super.tearDown()
    }

    private func put(_ windows: String) async throws {
        let draft = dir + "/draft.json"
        try #"{"revision":0,"layout":{"sessions":[{"name":"visual","windows":\#(windows)}]}}"#.write(toFile: draft, atomically: true, encoding: .utf8)
        let put = try await Child.run(tools.ko, ["api", "--server", dir, "-X", "PUT", "--input", draft, "/layout"])
        XCTAssertEqual(put.status, 0, put.err)
        owner.start()
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
        try XCTUnwrap(terminal?.visualChromes.first { $0.pane == pane })
    }

    // The chrome rectangle in the terminal's coordinates, also for a float that lives in its own window.
    private func rect(_ pane: PaneID) throws -> CGRect {
        try XCTUnwrap(terminal?.visualFloatRect(pane) ?? chrome(pane).frame)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let terminal = try XCTUnwrap(terminal)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: terminal.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                                                windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func cell() throws -> CGSize { try XCTUnwrap(owner.testSession?.cell) }

    private func geometry(_ pane: PaneID) -> Geometry? {
        window.flatMap { Layout($0).root.panes.first { $0.id == pane }?.geometry }
    }

    private func api(_ args: [String]) async throws -> String {
        let run = try await Child.run(tools.ko, ["api", "--server", dir] + args)
        XCTAssertEqual(run.status, 0, run.err)
        return run.out
    }

    // A new float over `parent`, in the window `window`, added to the layout that the server holds.
    private func addFloat(window: String, parent: String) async throws {
        let text = try await api(["/layout"])
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        document["panes"] = nil
        var layout = try XCTUnwrap(document["layout"] as? [String: Any])
        var sessions = try XCTUnwrap(layout["sessions"] as? [[String: Any]])
        var windows = try XCTUnwrap(sessions[0]["windows"] as? [[String: Any]])
        let at = try XCTUnwrap(windows.firstIndex { ($0["id"] as? String) == window })
        let float: [String: Any] = ["pane": ["new": ["parent": parent, "close": "on_exit", "command": ["type": "argv", "argv": ["/bin/sleep", "600"]]]], "border": true, "cols": 20, "rows": 6, "x": 3, "y": 2]
        windows[at]["floats"] = [float]
        sessions[0]["windows"] = windows
        layout["sessions"] = sessions
        document["layout"] = layout
        let draft = dir + "/float.json"
        try JSONSerialization.data(withJSONObject: document).write(to: URL(fileURLWithPath: draft))
        _ = try await api(["-X", "PUT", "--input", draft, "/layout"])
    }

    func testAFloatOverASplitPanesKoaNeverReplacesItsSlot() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep)]}}]"#)
        try await placed("two panes") { Layout($0).root.panes.count == 2 }
        try await addFloat(window: try XCTUnwrap(window).id.description, parent: "pane_2")
        try await placed("the float") { $0.floats.count == 1 }
        let float = try XCTUnwrap(window?.floats.first?.pane)
        let session = try XCTUnwrap(owner.testModel?.layout.layout.sessions.first?.id), id = try XCTUnwrap(window).id
        owner.perform(.jump(Snapshot.Position(session: session, window: id, pane: float)))
        try await wait("the float is selected", within: 5) { self.owner.testModel?.selection.pane == float }
        let shown = try XCTUnwrap(terminal).displayedPanes.map(\.pane)
        XCTAssertEqual(Set(shown), [PaneID(number: 1), PaneID(number: 2), float], "the float is shown with both panes; none is replaced")
        XCTAssertEqual(owner.testModel?.layout.layout.windows.count, 1)
    }

    func testADragOfAChildWindowFloatWritesItsPositionToTheChildWindow() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep)]}}]"#)
        try await placed("two panes") { Layout($0).root.panes.count == 2 }
        let body = dir + "/child.json"
        try #"{"parent":"pane_2","command":{"type":"argv","argv":["/bin/sleep","600"]}}"#.write(toFile: body, atomically: true, encoding: .utf8)
        let created = try await api(["-X", "POST", "--input", body, "/panes"])
        let child = try JSONDecoder().decode(Snapshot.Position.self, from: Data(created.utf8))
        try await addFloat(window: child.window.description, parent: child.pane.description)
        let source = { self.owner.testModel?.layout.layout.window(child.window)?.floats.first }
        try await wait("the child's float", within: 5) { source() != nil }
        let float = try XCTUnwrap(source())
        owner.perform(.jump(child))
        try await wait("the child is shown in the slot", within: 5) {
            let displayed = self.terminal?.displayedPanes.map(\.pane) ?? []
            return self.owner.testModel?.selection.pane == child.pane && displayed.contains(float.pane)
        }
        let terminal = try XCTUnwrap(terminal), cell = try cell()
        let frame = try rect(float.pane)
        let slot = try XCTUnwrap(geometry(PaneID(number: 2)))
        XCTAssertGreaterThan(slot.x, 0)
        XCTAssertEqual(frame.minX, CGFloat(slot.x + float.x) * cell.width, accuracy: cell.width + 6, "the float lies over the slot, offset by it")
        let start = NSPoint(x: frame.midX, y: frame.minY + 4)
        terminal.visualBeginDrag(float.pane, try mouse(.leftMouseDown, start), from: .frame)
        let end = NSPoint(x: start.x + 2 * cell.width, y: start.y + 8 * cell.height)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, end))
        terminal.mouseUp(with: try mouse(.leftMouseUp, end))
        let expected = [float.x + 2, float.y + 8]
        try await wait("the child window has the new position", within: 5) {
            guard let moved = source() else { return false }
            return [moved.x, moved.y] == expected
        }
    }

    func testSplitZoomFloat() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[{"split":"v","children":[\#(sleep),\#(sleep)]},{"split":"v","children":[\#(sleep),\#(sleep)]}]}}]"#)
        try await placed("four panes") { Layout($0).root.panes.count == 4 }
        try snapshot("2x2")

        let session = try XCTUnwrap(owner.testSession)
        session.paneCommand(.zoom, PaneID(number: 1))
        try await placed("zoom") { $0.zoom == PaneID(number: 1) }
        XCTAssertEqual(terminal?.displayedPanes.filter { !$0.isHidden }.map(\.pane), [PaneID(number: 1)])
        try snapshot("zoom")
        session.paneCommand(.zoom, PaneID(number: 1))
        try await placed("the zoom ended") { $0.zoom == nil }

        session.edit(.float(KoSchema.EditFloat(cols: 35, pane: PaneID(number: 4), rows: 10, x: 5, y: 0)), nil)
        try await placed("floating layout") { $0.floats.map(\.pane) == [PaneID(number: 4)] }
        XCTAssertTrue(terminal?.visualLayout.contains("float pane_4") == true)
        let top = try rect(PaneID(number: 4)).minY
        XCTAssertGreaterThanOrEqual(top, 0.5, "a float in the first row stays below the separator")
        try snapshot("float-top")

        let float = PaneID(number: 4)
        let terminal = try XCTUnwrap(terminal)
        (owner.window as? OwnerWindow)?.focusChanged = { [weak terminal] _, _ in terminal?.updateFocusTreatment() }
        session.selectPane(float)
        try await wait("float is active", within: 5) { self.window?.focus == PaneID(number: 4) || terminal.active == float }
        terminal.focus(float)
        XCTAssertEqual(try chrome(float).treatment, .overlay, "with the main window key, the last-active float keeps the overlay")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner.window)
        XCTAssertEqual(try chrome(float).treatment, .overlay)
        try snapshot("float-window-not-key")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: owner.window)
        XCTAssertEqual(try chrome(float).treatment, .overlay)
        let host = try XCTUnwrap(session.pane(float)?.window as? FloatWindow)
        host.testInput(true)
        (owner.window as? OwnerWindow)?.testInput(false)
        terminal.updateFocusTreatment()
        XCTAssertEqual(try chrome(float).treatment, .focus, "the float that has the keyboard has the accent stroke")
    }

    func testADividerDragIsOneResizeOfTheTwoNeighbours() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep),\#(sleep)]}}]"#)
        try await placed("three panes") { Layout($0).root.panes.count == 3 }
        try snapshot("before")
        let first = try XCTUnwrap(geometry(PaneID(number: 1))), third = try XCTUnwrap(geometry(PaneID(number: 3)))
        let left = try rect(PaneID(number: 1)), right = try rect(PaneID(number: 2))
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
        XCTAssertTrue(terminal.displayedPanes.allSatisfy { !$0.visualResizeIntent }, "the settled layout ends the resize intent")
        try snapshot("after")
    }

    func testAFloatDragHoldsItsFrameUntilTheLayoutShowsIt() async throws {
        let new = String(sleep.dropFirst(8).dropLast())
        try await put(#"[{"name":"w","tree":\#(sleep),"floats":[{"pane":\#(new),"x":4,"y":3,"cols":30,"rows":8}]}]"#)
        try await placed("the float") { $0.floats.count == 1 }
        try snapshot("before")
        let float = PaneID(number: 2)
        let frame = try rect(float)
        let start = NSPoint(x: frame.midX, y: frame.minY + 4)
        let terminal = try XCTUnwrap(terminal)
        let cell = try cell()
        terminal.visualBeginDrag(float, try mouse(.leftMouseDown, start), from: .frame)
        XCTAssertTrue(terminal.visualPaneDragging)
        let end = NSPoint(x: start.x + 5 * cell.width, y: start.y + 8 * cell.height)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: start.x + 2 * cell.width, y: start.y + cell.height)))
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, end))
        terminal.mouseUp(with: try mouse(.leftMouseUp, end))
        let moved = try rect(float)
        XCTAssertEqual(moved.minX, frame.minX + 5 * cell.width, accuracy: 0.5, "the released float keeps the drag's frame")
        try await placed("the server moved the float") { $0.floats.first.map { [$0.x, $0.y] } == [9, 11] }
        try await wait("the edits settled", within: 5) { self.owner.testSession?.editing() == false }
        XCTAssertEqual(try rect(float), moved, "the frame of the settled layout is the drag's frame")
        try snapshot("after")
    }

    private func floatWindow() -> String {
        let new = String(sleep.dropFirst(8).dropLast())
        return #"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep)]},"floats":[{"pane":\#(new),"x":4,"y":3,"cols":20,"rows":6}]}]"#
    }

    func testAFloatDroppedOnATiledPaneEdgeDocksThere() async throws {
        try await put(floatWindow())
        try await placed("the float") { $0.floats.count == 1 }
        let terminal = try XCTUnwrap(terminal), float = PaneID(number: 3)
        let target = try rect(PaneID(number: 1)), grip = try rect(float)
        let start = NSPoint(x: grip.midX, y: grip.minY + 4)
        let end = NSPoint(x: target.minX + 2, y: target.midY)
        terminal.visualBeginDrag(float, try mouse(.leftMouseDown, start), from: .grip)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, end))
        XCTAssertNil(terminal.visualGhost, "a float's drag never shows the ghost")
        let bar = try XCTUnwrap(terminal.visualPreview.rect, "the insertion bar shows over the target")
        XCTAssertEqual(bar.minX, target.minX, accuracy: 0.5)
        let dragged = try rect(float)
        terminal.mouseUp(with: try mouse(.leftMouseUp, end))
        XCTAssertEqual(owner.testSession?.editing(), true, "the dock edit is in flight")
        XCTAssertEqual(try rect(float), dragged, "the released float holds its frame while the dock is in flight")
        try await placed("the float docked left of the first pane") { $0.floats.isEmpty && Layout($0).root.panes.map(\.id.number) == [3, 1, 2] }
        XCTAssertNotEqual(try rect(float), dragged, "the docked pane takes its tile")
    }

    func testAFloatDraggedByItsFrameOnlyMoves() async throws {
        try await put(floatWindow())
        try await placed("the float") { $0.floats.count == 1 }
        let terminal = try XCTUnwrap(terminal), float = PaneID(number: 3)
        let first = try rect(PaneID(number: 1)), second = try rect(PaneID(number: 2))
        for end in [NSPoint(x: first.minX + 2, y: first.midY), NSPoint(x: second.maxX - 2, y: second.midY)] {
            let home = try rect(float), before = try XCTUnwrap(window?.floats.first)
            let start = NSPoint(x: home.midX, y: home.minY + 4)
            terminal.visualBeginDrag(float, try mouse(.leftMouseDown, start), from: .frame)
            terminal.mouseDragged(with: try mouse(.leftMouseDragged, end))
            XCTAssertNil(terminal.visualPreview.rect, "a frame drag shows no insertion bar")
            XCTAssertNotEqual(try rect(float).origin, home.origin, "the float follows the drag")
            terminal.mouseUp(with: try mouse(.leftMouseUp, end))
            try await placed("the float moved, not docked") {
                $0.floats.count == 1 && Layout($0).root.panes.filter { $0.layer == .tiled }.map(\.id.number) == [1, 2]
                    && $0.floats.first.map { [$0.x, $0.y] } != [before.x, before.y]
            }
            try await wait("the edits settled", within: 5) { self.owner.testSession?.editing() == false }
            XCTAssertNotEqual(window?.floats.first.map { [$0.x, $0.y] }, [before.x, before.y], "the move stays after settling")
        }
    }

    func testATiledPaneDroppedOverNoTargetPopsOutAtTheGhost() async throws {
        try await put(floatWindow())
        try await placed("the float") { $0.floats.count == 1 }
        let terminal = try XCTUnwrap(terminal), cell = try cell(), source = PaneID(number: 2)
        let frame = try rect(source)
        let grip = try chrome(source).toolbarFrame.minX + 16
        let start = NSPoint(x: frame.minX + grip, y: frame.minY + 14)
        let inside = NSPoint(x: start.x - 2 * cell.width, y: start.y + 3 * cell.height)
        terminal.visualBeginDrag(source, try mouse(.leftMouseDown, start), from: .grip)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, inside))
        XCTAssertNil(terminal.visualGhost, "the source pane is a cancel zone")
        XCTAssertNil(terminal.visualPreview.rect)
        let revision = try XCTUnwrap(owner.testModel?.layout.revision)
        terminal.mouseUp(with: try mouse(.leftMouseUp, inside))
        XCTAssertEqual(owner.testSession?.editing(), false, "a drop on the source sends no edit")
        XCTAssertEqual(owner.testModel?.layout.revision, revision)

        let over = try rect(PaneID(number: 3))
        let end = NSPoint(x: over.midX, y: over.midY)
        terminal.visualBeginDrag(source, try mouse(.leftMouseDown, start), from: .grip)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, end))
        let ghost = try XCTUnwrap(terminal.visualGhost, "over a float the ghost shows")
        XCTAssertNil(terminal.visualPreview.rect)
        XCTAssertEqual(ghost.minX, end.x - grip, accuracy: 8, "the pointer keeps the grip's place in the ghost")
        XCTAssertEqual(ghost.minY, end.y - 14, accuracy: 0.5)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            terminal.visualGhostView.appearance = NSAppearance(named: appearance)
            let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
            if let failure = verifySnapshot(of: terminal.visualGhostView, as: .pixels, named: "ghost-\(name)", record: record),
               !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        }
        terminal.mouseUp(with: try mouse(.leftMouseUp, end))
        try await placed("the pane floats") { $0.floats.map(\.pane).contains(source) }
        let float = try XCTUnwrap(window?.floats.first { $0.pane == source })
        XCTAssertGreaterThanOrEqual(float.cols, 20)
        XCTAssertGreaterThanOrEqual(float.rows, 6)
        let after = try rect(source)
        XCTAssertEqual(after.minX, ghost.minX, accuracy: cell.width, "the float appears where the ghost was")
        XCTAssertEqual(after.minY, ghost.minY, accuracy: cell.height)
        try await wait("the float is the active pane", within: 5) { self.owner.testModel?.selection.pane == source }
    }

    func testAFloatThatLeavesAndReturnsWithoutMovingSendsNothing() async throws {
        let new = String(sleep.dropFirst(8).dropLast())
        try await put(#"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep)]},"floats":[{"pane":\#(new),"x":20,"y":12,"cols":20,"rows":6}]}]"#)
        try await placed("the float") { $0.floats.count == 1 }
        let terminal = try XCTUnwrap(terminal), float = PaneID(number: 3)
        let target = try rect(PaneID(number: 1)), home = try rect(float)
        let start = NSPoint(x: home.midX, y: home.minY + 4)
        terminal.visualBeginDrag(float, try mouse(.leftMouseDown, start), from: .grip)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: target.minX + 2, y: target.midY)))
        XCTAssertNotNil(terminal.visualPreview.rect)
        let revision = try XCTUnwrap(owner.testModel?.layout.revision)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, start))
        XCTAssertNil(terminal.visualPreview.rect, "back within 4pt of the start the bar is gone")
        terminal.mouseUp(with: try mouse(.leftMouseUp, start))
        XCTAssertEqual(owner.testSession?.editing(), false)
        XCTAssertEqual(owner.testModel?.layout.revision, revision)
        XCTAssertEqual(try rect(float).minX, home.minX, accuracy: 0.5)
    }

    func testOptionOverATargetForcesThePopOut() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep)]}}]"#)
        try await placed("two panes") { Layout($0).root.panes.count == 2 }
        let terminal = try XCTUnwrap(terminal), source = PaneID(number: 2)
        let from = try rect(source), over = try rect(PaneID(number: 1))
        let start = NSPoint(x: from.midX, y: from.midY), end = NSPoint(x: over.midX, y: over.midY)
        terminal.visualBeginDrag(source, try mouse(.leftMouseDown, start), from: .grip)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, end))
        XCTAssertNotNil(terminal.visualPreview.rect, "without Option the pane under the pointer is a target")
        XCTAssertNil(terminal.visualGhost)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, end, .option))
        XCTAssertNil(terminal.visualPreview.rect, "Option shows the ghost instead of the bar")
        XCTAssertNotNil(terminal.visualGhost)
        terminal.mouseUp(with: try mouse(.leftMouseUp, end, .option))
        try await placed("the pane floats, no swap") { $0.floats.map(\.pane) == [source] && Layout($0).root.panes.filter { $0.layer == .tiled }.map(\.id.number) == [1] }
    }

    func testTheLastTiledPaneNeverShowsTheGhost() async throws {
        try await put(#"[{"name":"w","tree":\#(sleep)}]"#)
        try await placed("one pane") { Layout($0).root.panes.count == 1 }
        let terminal = try XCTUnwrap(terminal), source = PaneID(number: 1)
        let frame = try rect(source)
        let start = NSPoint(x: frame.midX, y: frame.midY), end = NSPoint(x: frame.midX + 40, y: frame.midY + 40)
        terminal.visualBeginDrag(source, try mouse(.leftMouseDown, start), from: .grip)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, end, .option))
        XCTAssertNil(terminal.visualGhost)
        XCTAssertNil(terminal.visualPreview.rect)
        terminal.mouseUp(with: try mouse(.leftMouseUp, end, .option))
        XCTAssertTrue(window?.floats.isEmpty == true)
    }

    func testADroppedPaneSwapsWithThePaneUnderIt() async throws {
        try await put(#"[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep)]}}]"#)
        try await placed("two panes") { Layout($0).root.panes.count == 2 }
        let terminal = try XCTUnwrap(terminal)
        let from = try rect(PaneID(number: 1)), to = try rect(PaneID(number: 2))
        terminal.visualBeginDrag(PaneID(number: 1), try mouse(.leftMouseDown, NSPoint(x: from.midX, y: from.midY)), from: .grip)
        terminal.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: to.midX, y: to.midY)))
        terminal.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: to.midX, y: to.midY)))
        try await placed("swapped") { Layout($0).root.panes.map(\.id.number) == [2, 1] }
        try snapshot("swapped")
    }
}

