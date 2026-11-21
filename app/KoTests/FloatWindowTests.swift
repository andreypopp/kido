import AppKit
import KoClient
import KoClientKit
import KoModel
import PaneGeometry
import SidebarFeed
import XCTest
@testable import Kido

@MainActor final class FloatWindowTests: KoTestCase {
    private let sleep = #"{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}"#
    private let child = #"{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}},"x":2,"y":2,"cols":20,"rows":6}"#

    private func shown(_ windows: String) throws -> (WindowOwner, KoClient) {
        let dir = try server()
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"s","windows":\#(windows)}]}}"#, dir: dir)
        let board = NSPasteboard(name: .init("ko-float-" + UUID().uuidString))
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        owner.testServerDir = dir
        addTeardownBlock { @MainActor in
            owner.close()
            board.releaseGlobally()
        }
        owner.start()
        wait("the owner shows the layout at its own size") {
            owner.testBanner.isHidden && owner.testSession?.windows.values.contains { !$0.isHidden && $0.visualGeometryReady } == true
        }
        return (owner, try XCTUnwrap(owner.testClient))
    }

    private func floats(_ client: KoClient) -> [KoSchema.Float] {
        (try? client.model())?.layout.layout.windows.first?.floats ?? []
    }

    private func screen(_ view: NSView) throws -> CGRect {
        let window = try XCTUnwrap(view.window)
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func floatLayout(border: Bool, tree: String? = nil) -> String {
        let pane = String(sleep.dropFirst(8).dropLast())
        let flag = border ? #","border":true"# : ""
        return #"[{"name":"w","tree":\#(tree ?? sleep),"floats":[{"pane":\#(pane),"x":2,"y":2,"cols":20,"rows":6\#(flag)},{"pane":\#(pane),"x":10,"y":4,"cols":20,"rows":6\#(flag)}]}]"#
    }

    private var twoFloats: String { floatLayout(border: false) }
    private var split: String { #"{"split":"h","children":[\#(sleep),\#(sleep)]}"# }

    private func edgeDrag(_ session: SessionView, _ id: PaneID, _ edge: NSCursor.FrameResizePosition, from: CGPoint, dx: CGFloat, dy: CGFloat) throws {
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let host = try XCTUnwrap(session.pane(id)?.window)
        terminal.beginEdgeResize(id, edge, try mouse(.leftMouseDown, from, in: host))
        for step in 1...4 {
            terminal.continueDrag(try mouse(.leftMouseDragged, CGPoint(x: from.x + dx * CGFloat(step) / 4, y: from.y + dy * CGFloat(step) / 4), in: try XCTUnwrap(session.pane(id)?.window)))
        }
        terminal.continueDrag(try mouse(.leftMouseUp, CGPoint(x: from.x + dx, y: from.y + dy), in: try XCTUnwrap(session.pane(id)?.window)))
    }

    // Drags the float by `dx`, `dy` screen points (y grows up) with the given events, then releases.
    private func drag(_ session: SessionView, _ id: PaneID, dx: CGFloat, dy: CGFloat) throws {
        let view = try XCTUnwrap(session.pane(id)), host = try XCTUnwrap(view.window)
        let start = CGPoint(x: try screen(view).midX, y: try screen(view).midY)
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host))
        for step in 1...4 {
            let host = try XCTUnwrap(view.window)
            terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, CGPoint(x: start.x + dx * CGFloat(step) / 4, y: start.y + dy * CGFloat(step) / 4), in: host))
        }
        let end = CGPoint(x: start.x + dx, y: start.y + dy)
        terminal.visualBeginDrag(id, try mouse(.leftMouseUp, end, in: try XCTUnwrap(view.window)))
    }

    func testFloatAgainRestoresTheLastFrameAndCellSize() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        session.edit(.float(KoSchema.EditFloat(cols: 31, pane: id, rows: 9)), nil)
        wait("the resize settles") { self.floats(client).first { $0.pane == id }?.cols == 31 && !session.editing() }
        try drag(session, id, dx: 95, dy: -65)
        wait("the move settles") { !session.editing() }
        let frame = try screen(view)
        let geometry = try XCTUnwrap(floats(client).first { $0.pane == id })
        owner.paneCommand(.float, id)
        wait("the pane docks") { view.window === owner.window && !session.editing() }
        var sent: KoSchema.EditFloat?
        owner.testEditor { edit in
            if case .float(let value) = edit, value.pane == id, value.z == nil { DispatchQueue.main.sync { sent = value } }
            return try client.edit(edit)
        }
        owner.paneCommand(.float, id)
        wait("the pane floats again") { view.window is FloatWindow && !session.editing() }
        XCTAssertEqual(sent?.cols, geometry.cols)
        XCTAssertEqual(sent?.rows, geometry.rows)
        XCTAssertEqual(sent?.x, geometry.x)
        XCTAssertEqual(sent?.y, geometry.y)
        XCTAssertEqual(try screen(view), frame)

        owner.paneCommand(.float, id)
        wait("the pane docks again") { view.window === owner.window && !session.editing() }
        _ = try client.edit(.float(KoSchema.EditFloat(cols: 23, pane: id, rows: 7, x: 1, y: 1)))
        wait("an explicit placement floats it") { view.window is FloatWindow && !session.editing() }
        let newer = try screen(view)
        owner.paneCommand(.float, id)
        wait("the new float docks") { view.window === owner.window && !session.editing() }
        owner.paneCommand(.float, id)
        wait("the new frame returns") { view.window is FloatWindow && !session.editing() }
        XCTAssertEqual(sent?.cols, 23)
        XCTAssertEqual(sent?.rows, 7)
        XCTAssertEqual(try screen(view), newer)
    }

    func testFloatAgainMemorySurvivesEvictionAndAdoption() throws {
        let (owner, client) = try shown(twoFloats)
        let source = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2), window = WindowID(number: 1)
        try drag(source, id, dx: 80, dy: -40)
        wait("the move settles") { !source.editing() }
        let geometry = try XCTUnwrap(floats(client).first { $0.pane == id })
        owner.paneCommand(.float, id)
        wait("the float docks") { source.pane(id)?.window === owner.window && !source.editing() }
        try XCTUnwrap(source.windows[window]).evict()
        let destination = SessionView(runtime: source.runtime)
        destination.client = client
        destination.frame = source.frame
        try XCTUnwrap(source.superview).addSubview(destination)
        defer { destination.close() }
        destination.adoptFloats(from: source)
        destination.show(window)
        let terminal = try XCTUnwrap(destination.windows[window])
        let edit = try XCTUnwrap(terminal.floatAgainEdit(id))
        guard case .float(let value) = edit else { return XCTFail("expected a float edit") }
        XCTAssertEqual(value.cols, geometry.cols)
        XCTAssertEqual(value.rows, geometry.rows)
        XCTAssertEqual(value.x, geometry.x)
        XCTAssertEqual(value.y, geometry.y)
        terminal.editsSettled()
        XCTAssertNotNil(terminal.floatAgainEdit(id), "a failed edit keeps the saved frame")
    }

    func testFloatPaneWithoutMemorySendsNoGeometry() throws {
        let (owner, client) = try shown(floatLayout(border: false, tree: split))
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 1)
        var sent: KoSchema.EditFloat?
        owner.testEditor { edit in
            if case .float(let value) = edit, value.pane == id, value.z == nil { DispatchQueue.main.sync { sent = value } }
            return try client.edit(edit)
        }
        owner.paneCommand(.float, id)
        wait("the pane floats") { session.pane(id)?.window is FloatWindow && !session.editing() }
        let edit = try XCTUnwrap(sent)
        XCTAssertNil(edit.cols)
        XCTAssertNil(edit.rows)
        XCTAssertNil(edit.x)
        XCTAssertNil(edit.y)
    }

    func testAMainWindowResizeKeepsTheLocalScreenOriginThroughTheServerClamp() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        session.edit(.float(KoSchema.EditFloat(pane: id, x: 10000)), nil)
        wait("the float reaches the room's right edge") { !session.editing() }
        try drag(session, id, dx: 40, dy: -40)
        wait("the move settles") { !session.editing() }
        let host = try XCTUnwrap(view.window as? FloatWindow)
        let before = try screen(view)
        let oldPoint = try XCTUnwrap(floats(client).first { $0.pane == id }).x
        let oldCols = try XCTUnwrap(client.model().layout.layout.windows.first).cols
        let submit = session.edit
        var floatEdits = 0
        session.edit = { edit, key in
            if case .float = edit { floatEdits += 1 }
            submit(edit, key)
        }
        var frame = owner.window.frame
        frame.size.width -= 160
        owner.window.setFrame(frame, display: true)
        wait("the server receives the smaller room") {
            ((try? client.model().layout.layout.windows.first?.cols) ?? oldCols) < oldCols
        }
        wait("the resize settles") { !session.editing() }
        XCTAssertEqual(try screen(view).origin, before.origin)
        let acknowledged = try XCTUnwrap(floats(client).first { $0.pane == id })
        XCTAssertLessThan(acknowledged.x, oldPoint)
        XCTAssertEqual(view.bounds.width, CGFloat(acknowledged.cols) * view.cell.width)
        XCTAssertEqual(floatEdits, 0)
        let held = host.frame
        session.edit(.float(KoSchema.EditFloat(pane: PaneID(number: 3), x: 4)), nil)
        wait("the unrelated edit settles") { !session.editing() }
        XCTAssertEqual(host.frame, held)
        if case .local(_, let sent) = host.position { XCTAssertEqual(sent.x, acknowledged.x) }
        else { XCTFail("the clamp keeps the local screen origin") }
        session.edit(.float(KoSchema.EditFloat(pane: id, x: 1)), nil)
        wait("the remote move releases the local origin") { host.position == .layout }
    }

    func testAFloatIsAnIndependentWindow() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let view = try XCTUnwrap(session.pane(PaneID(number: 2)))
        XCTAssertFalse(view.window === owner.window, "a float lives in its own window")
        XCTAssertNil(view.window?.parent)
        XCTAssertEqual(view.window?.styleMask, .borderless)
        XCTAssertEqual(session.hostWindows.count, 2)
        XCTAssertEqual(view.window?.level, .normal)
        XCTAssertTrue(view.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        XCTAssertFalse(try XCTUnwrap(view.window).isExcludedFromWindowsMenu)
        XCTAssertTrue(try XCTUnwrap(session.pane(PaneID(number: 1))).window === owner.window, "a tiled pane stays in the main window")
        XCTAssertTrue(owner.owns(view.window))
    }

    func testADragPastTheEdgeKeepsItsLocalFrameAndSendsTheClampedPosition() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        try drag(session, id, dx: -3000, dy: 0)
        wait("the clamped position reaches the server") { self.floats(client).first { $0.pane == id }?.x == 0 }
        wait("the edit settles") { !session.editing() }
        let frame = try screen(view)
        XCTAssertLessThan(frame.minX, owner.window.frame.minX - 100, "the float is past the main window's edge")
        let other = try XCTUnwrap(session.pane(PaneID(number: 3)))
        let otherBefore = try screen(other)
        session.edit(.float(KoSchema.EditFloat(pane: PaneID(number: 3), x: 14, y: 6)), nil)
        wait("the owner shows the unrelated edit") {
            owner.testModel?.layout.layout.windows.first?.floats.first { $0.pane == PaneID(number: 3) }?.x == 14 && !session.editing()
        }
        XCTAssertNotEqual(try screen(other).minX, otherBefore.minX, "the unrelated update was applied")
        XCTAssertEqual(try screen(view).minX, frame.minX, "an unrelated layout update does not snap the float back")
    }

    func testARemoteMoveReleasesTheLocalPosition() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        try drag(session, id, dx: -3000, dy: 0)
        wait("settled at the edge") { self.floats(client).first { $0.pane == id }?.x == 0 && !session.editing() }
        XCTAssertLessThan(try screen(view).minX, owner.window.frame.minX - 100, "the float is past the main window's edge")
        session.edit(.float(KoSchema.EditFloat(pane: id, x: 15, y: 1)), nil)
        wait("another client moved it") { self.floats(client).first { $0.pane == id }?.x == 15 }
        wait("the float follows the layout") { ((try? self.screen(view).minX) ?? 0) > owner.window.frame.minX }
    }

    // The pane of a float that has the keyboard is the active pane, with the accent stroke; the tiled panes
    // are not key and the other floats keep their overlay.
    func testAFloatThatBecomesKeyIsTheActivePaneWithTheStroke() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let id = PaneID(number: 3)
        let host = try XCTUnwrap(session.pane(id)?.window as? FloatWindow)
        XCTAssertFalse(host.canBecomeMain)
        XCTAssertTrue(host.canBecomeKey)
        XCTAssertNil(host.parent)
        XCTAssertTrue(owner.inputWindow === owner.window, "without a key float the main window has the input")
        host.testInput(true)
        (owner.window as? OwnerWindow)?.testInput(false)
        host.becameKey()
        wait("its pane is the active pane") { (try? client.model())?.selection.pane == id }
        wait("the owner's window shows its pane as active") { terminal.active == id }
        terminal.updateFocusTreatment()
        XCTAssertEqual(terminal.visualChromes.first { $0.pane == id }?.treatment, .focus)
        XCTAssertEqual(terminal.visualChromes.first { $0.pane == PaneID(number: 2) }?.treatment, .overlay)
        XCTAssertTrue(owner.owns(host))
        XCTAssertTrue(owner.inputWindow === host, "the owner routes input to the key float")
        XCTAssertTrue(owner.inputResponder === host.firstResponder)
        XCTAssertTrue(PaneView.owner(owner.inputResponder) === session.pane(id), "the menu and the palette act on the float's pane")
    }

    func testKeyFloatShiftsEveryTiledPaneButNeverFloatPaper() throws {
        for tree in [sleep, split] {
            let (owner, _) = try shown(floatLayout(border: false, tree: tree))
            let session = try XCTUnwrap(owner.testSession)
            let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
            let host = try XCTUnwrap(session.hostWindows.first)
            let pane = try XCTUnwrap(host.content.pane.flatMap(session.pane))
            host.makeFirstResponder(pane)
            host.testInput(true)
            (owner.window as? OwnerWindow)?.testInput(false)
            terminal.updateFocusTreatment()
            for tiled in terminal.displayedPanes.filter(\.transparentPaper) {
                XCTAssertTrue(tiled.shiftedBackground, "a key float shifts every tiled pane, including a sole pane")
                XCTAssertEqual(terminal.visualChromes.first { $0.pane == tiled.pane }?.treatment, .plain)
                XCTAssertFalse(tiled.runtimeFocused)
            }
            for floating in terminal.displayedPanes.filter({ !$0.transparentPaper }) {
                XCTAssertFalse(floating.shiftedBackground, "float paper is never shifted")
                XCTAssertEqual(terminal.visualChromes.first { $0.pane == floating.pane }?.treatment, floating === pane ? .focus : .overlay)
            }
            let main = try XCTUnwrap(owner.window as? OwnerWindow)
            let tiled = try XCTUnwrap(terminal.displayedPanes.first { $0.transparentPaper })
            main.makeFirstResponder(tiled)
            main.testInput(true)
            terminal.updateFocusTreatment()
            XCTAssertFalse(tiled.shiftedBackground)
            XCTAssertTrue(tiled.runtimeFocused)
            XCTAssertEqual(terminal.visualChromes.first { $0.pane == pane.pane }?.treatment, .overlay)
            main.testInput(false)
            terminal.updateFocusTreatment()
            XCTAssertTrue(terminal.displayedPanes.filter(\.transparentPaper).allSatisfy(\.shiftedBackground))
            XCTAssertFalse(pane.shiftedBackground)
            owner.close()
        }
    }

    func testFindKeepsThePanePaperFocusedButNotTheTerminalCursor() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let pane = try XCTUnwrap(session.pane(PaneID(number: 1)))
        let host = try XCTUnwrap(owner.window as? OwnerWindow)
        host.testInput(true)
        host.makeFirstResponder(pane)
        XCTAssertTrue(pane.visualSurfaceFocused)
        pane.showFind()
        let find = try XCTUnwrap(pane.find)
        XCTAssertTrue(find.field.currentEditor() === host.firstResponder)
        XCTAssertTrue(OwnerWindow.focusedPane === pane)
        XCTAssertFalse(pane.shiftedBackground)
        XCTAssertFalse(pane.visualSurfaceFocused, "Find takes keyboard input, not the terminal surface")
        find.close()
        host.makeFirstResponder(pane)
        XCTAssertTrue(pane.visualSurfaceFocused, "returning to the terminal restores its cursor focus")
    }

    func testALateKeySheetRestoresItsMainWindowsPaperButNotItsCursor() throws {
        class Sheet: NSWindow {
            weak var host: NSWindow?
            override var sheetParent: NSWindow? { host }
        }
        let (owner, _) = try shown(floatLayout(border: false, tree: split))
        let main = try XCTUnwrap(owner.window as? OwnerWindow)
        let session = try XCTUnwrap(owner.testSession)
        let pane = try XCTUnwrap(session.pane(PaneID(number: 1)))
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        main.testInput(true)
        main.makeFirstResponder(pane)
        let center = NotificationCenter.default
        center.post(name: NSWindow.didResignKeyNotification, object: main)
        var turnFinished = false
        DispatchQueue.main.async { turnFinished = true }
        wait("the resign repaint finishes before the sheet becomes key") { turnFinished }
        XCTAssertNil(OwnerWindow.inputWindow)
        XCTAssertTrue(pane.shiftedBackground)
        let sheet = Sheet(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.host = main
        defer { sheet.close() }
        let repaint = main.focusChanged
        var repaints = 0
        main.focusChanged = { old, next in repaints += 1; repaint(old, next) }
        center.post(name: NSWindow.didBecomeKeyNotification, object: sheet)
        XCTAssertTrue(OwnerWindow.inputWindow === main, "a late key sheet restores its Kido owner")
        XCTAssertFalse(pane.shiftedBackground, "the late key sheet restores the active pane's pure paper")
        XCTAssertEqual(terminal.visualChromes.first { $0.pane == pane.pane }?.treatment, .edge)
        XCTAssertFalse(pane.visualSurfaceFocused, "the sheet, not the terminal, has keyboard focus")
        XCTAssertEqual(repaints, 1)
        center.post(name: NSWindow.didBecomeKeyNotification, object: sheet)
        XCTAssertEqual(repaints, 1, "an unchanged key sheet must not repaint again")
    }

    func testKeyHandoffDoesNotRepaintTheIntermediateNotKeyState() throws {
        let main = OwnerWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false, input: true)
        let float = OwnerWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false, input: false)
        main.isReleasedWhenClosed = false
        float.isReleasedWhenClosed = false
        defer { main.close(); float.close() }
        var paints: [String] = []
        let paint: (NSResponder?, NSResponder?) -> Void = { _, _ in
            paints.append(main.isInputWindow ? "main" : float.isInputWindow ? "float" : "none")
        }
        main.focusChanged = paint
        float.focusChanged = paint
        let center = NotificationCenter.default
        center.post(name: NSWindow.didResignKeyNotification, object: main)
        XCTAssertEqual(paints, [], "resign must not paint before the next window becomes key")
        center.post(name: NSWindow.didBecomeKeyNotification, object: float)
        XCTAssertFalse(paints.isEmpty)
        XCTAssertTrue(paints.allSatisfy { $0 == "float" }, "the handoff paints only the new key state")
        paints.removeAll()
        center.post(name: NSWindow.didResignKeyNotification, object: float)
        XCTAssertEqual(paints, [])
        center.post(name: NSWindow.didBecomeKeyNotification, object: main)
        XCTAssertFalse(paints.isEmpty)
        XCTAssertTrue(paints.allSatisfy { $0 == "main" })
        paints.removeAll()
        var turnFinished = false
        DispatchQueue.main.async { turnFinished = true }
        wait("the deferred resign callbacks finish") { turnFinished }
        XCTAssertEqual(paints, [], "a Kido become-key cancels the deferred resign paint")
        center.post(name: NSWindow.didResignKeyNotification, object: main)
        XCTAssertEqual(paints, [], "leaving Kido also waits one turn")
        wait("leaving Kido paints the not-key state") { paints.contains("none") }
        XCTAssertTrue(paints.allSatisfy { $0 == "none" })
    }

    func testAnotherTabKeepsTheFloatsAndAClosedPaneClosesItsWindow() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let first = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let id = try XCTUnwrap(first.windowID)
        let view = try XCTUnwrap(session.pane(PaneID(number: 2)))
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        session.show(nil)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(session.hostWindows.count, 2)
        session.show(id)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(session.hostWindows.count, 2)
        try client.delete(KO_DELETE_PANE, PaneID(number: 2))
        wait("the closed float's window is gone") { session.hostWindows.count == 1 && self.floats(client).count == 1 }
    }

    // The owner keeps one cell free on each side of a bordered float, so the sent position stays in that room and
    // the local frame stays where the pointer left it.
    func testABorderedFloatMovedPastEachEdgeKeepsItsFrameAndTheOwnersBounds() throws {
        let (owner, client) = try shown(floatLayout(border: true))
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        let size = try XCTUnwrap(client.model().layout.layout.windows.first)
        for (dx, dy) in [(CGFloat(-3000), CGFloat(0)), (3000, 0), (0, 3000), (0, -3000)] {
            try drag(session, id, dx: dx, dy: dy)
            wait("the edit settles") { !session.editing() }
            let sent = try XCTUnwrap(floats(client).first { $0.pane == id })
            if dx < 0 { XCTAssertEqual(sent.x, 1, "the left edge keeps the border cell") }
            if dx > 0 { XCTAssertEqual(sent.x, size.cols - sent.cols - 1) }
            if dy > 0 { XCTAssertEqual(sent.y, 1) }
            if dy < 0 { XCTAssertEqual(sent.y, size.rows - sent.rows - 1) }
            let frame = try screen(view)
            session.edit(.float(KoSchema.EditFloat(pane: PaneID(number: 3), x: 12, y: 4)), nil)
            wait("the owner shows the update") { owner.testModel?.layout.layout.windows.first?.floats.first { $0.pane == PaneID(number: 3) }?.x == 12 && !session.editing() }
            XCTAssertEqual(try screen(view), frame, "the bordered float keeps its local frame after the position settled")
            let out = try screen(view)
            let main = owner.window.frame
            XCTAssertTrue(out.minX < main.minX || out.maxX > main.maxX || out.minY < main.minY || out.maxY > main.maxY, "the frame is past an edge of the main window")
            session.edit(.float(KoSchema.EditFloat(pane: id, x: 10, y: 4)), nil)
            wait("back inside") { self.floats(client).first { $0.pane == id }?.x == 10 && !session.editing() }
        }
    }

    func testResizingPastTheEdgesKeepsTheOwnersSizeLimitAndTheFrame() throws {
        let (owner, client) = try shown(floatLayout(border: true))
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        let size = try XCTUnwrap(client.model().layout.layout.windows.first)
        let area = try screen(view)
        try edgeDrag(session, id, .right, from: CGPoint(x: area.maxX + 4, y: area.midY), dx: 4000, dy: 0)
        wait("the width is the owner's room") { self.floats(client).first { $0.pane == id }?.cols == size.cols - 2 && !session.editing() }
        let left = try screen(view)
        try edgeDrag(session, id, .bottom, from: CGPoint(x: left.midX, y: left.minY - 4), dx: 0, dy: -4000)
        wait("the height is the owner's room") { self.floats(client).first { $0.pane == id }?.rows == size.rows - 2 && !session.editing() }
        XCTAssertEqual(floats(client).first { $0.pane == id }?.cols, size.cols - 2)
    }

    func testALayoutDuringALocalMoveLeavesTheNewerDragFrame() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let host = try XCTUnwrap(view.window)
        let start = CGPoint(x: try screen(view).midX, y: try screen(view).midY)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host))
        terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, CGPoint(x: start.x + 120, y: start.y - 120), in: try XCTUnwrap(view.window)))
        XCTAssertEqual(floats(client).first { $0.pane == id }?.x, 2, "a band move does not stream edits")
        let older = try XCTUnwrap(owner.testModel?.layout.layout.windows)
        let end = CGPoint(x: start.x + 240, y: start.y - 240)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, end, in: try XCTUnwrap(view.window)))
        let newer = try screen(view)
        session.update(older, shown: terminal.windowID, selected: nil, marks: [:])
        XCTAssertEqual(try screen(view), newer, "an echo of the earlier edit does not move the float under the pointer")
        terminal.visualBeginDrag(id, try mouse(.leftMouseUp, end, in: try XCTUnwrap(view.window)))
        session.update(older, shown: terminal.windowID, selected: nil, marks: [:])
        XCTAssertEqual(try screen(view), newer, "the released float holds its frame until the edits settle")
        wait("the edit settles") { !session.editing() }
        XCTAssertEqual(try screen(view), newer)
        XCTAssertEqual(floats(client).first { $0.pane == id }.map { [$0.x, $0.y] }, owner.testModel?.layout.layout.windows.first?.floats.first { $0.pane == id }.map { [$0.x, $0.y] })
    }

    func testAFloatThatIsPresentedBeforeItsWindowAttachesGetsItsHostWhenItDoes() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let id = try XCTUnwrap(terminal.windowID)
        let parent = try XCTUnwrap(session.superview)
        session.show(nil)
        session.removeFromSuperview()
        session.show(id)
        XCTAssertEqual(terminal.hostWindows.count, 2, "the hosts exist; nothing is placed without a window")
        parent.addSubview(session)
        wait("the hosts are presented over the main window") {
            session.hostWindows.count == 2 && terminal.hostWindows.allSatisfy { $0.delegate === owner && !$0.content.isHidden && $0.frame.width > 0 }
        }
    }

    func testRemovingTheFloatMidDragEndsTheGestureAndClosesItsWindow() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let host = try XCTUnwrap(view.window)
        let start = CGPoint(x: try screen(view).midX, y: try screen(view).midY)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host))
        terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, CGPoint(x: start.x + 40, y: start.y), in: host))
        XCTAssertTrue(terminal.visualPaneDragging)
        try client.delete(KO_DELETE_PANE, id)
        wait("the float's window closed") { session.hostWindows.count == 1 && !terminal.visualPaneDragging }
        wait("the edits settle") { !session.editing() }
    }

    func testZoomingAndUnzoomingKeepsALocalPosition() throws {
        let (owner, client) = try shown(floatLayout(border: false, tree: split))
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 3)
        let view = try XCTUnwrap(session.pane(id))
        let visible = try XCTUnwrap(view.window?.screen?.visibleFrame)
        let initial = try screen(view)
        try drag(session, id, dx: visible.minX - initial.minX - initial.width / 2, dy: 0)
        wait("the position settled") { self.floats(client).first { $0.pane == id }?.x == 0 && !session.editing() }
        let frame = try screen(view)
        XCTAssertLessThan(frame.minX, visible.minX)
        XCTAssertGreaterThan(frame.maxX, visible.minX)
        session.paneCommand(.zoom, PaneID(number: 1))
        wait("the owner shows the zoom") { owner.testModel?.layout.layout.windows.first?.zoom == PaneID(number: 1) }
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "zoom keeps the float")
        session.paneCommand(.zoom, PaneID(number: 1))
        wait("the owner shows the zoom ended") { owner.testModel?.layout.layout.windows.first?.zoom == nil }
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(try screen(view), frame, "the local position survives the zoom")
    }

    func testAMinimizedMainWindowKeepsTheFloatsAndTheBannerHidesThemWhileTheOwnerIsDown() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let view = try XCTUnwrap(session.pane(PaneID(number: 2)))
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        owner.testBanner.isHidden = false
        XCTAssertTrue(view.isHiddenOrHasHiddenAncestor, "the banner covers the floats too")
        XCTAssertTrue(session.hostWindows.allSatisfy { $0.content.isHidden })
        owner.testBanner.isHidden = true
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        owner.window.miniaturize(nil)
        if owner.window.isMiniaturized {
            session.syncHosts()
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "the floats stay independent of the minimized main window")
            owner.window.deminiaturize(nil)
            session.syncHosts()
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        }
    }

    func testTheNoticesWindowCoversOnlyTheCardsAndIsRaisedWithTheFloats() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        owner.notices.testTime = 0
        owner.notices.show("Could not open a window", "window refused")
        let overlay = try XCTUnwrap(owner.notices.testWindow)
        XCTAssertTrue(overlay.shown)
        XCTAssertTrue(overlay.parent === owner.window, "the notices are a child of the main window")
        XCTAssertFalse(overlay.canBecomeKey)
        XCTAssertFalse(overlay.canBecomeMain)
        let column = owner.window.convertToScreen(owner.sidebar.content.convert(owner.sidebar.content.bounds, to: nil))
        XCTAssertLessThan(overlay.frame.width, column.width, "the window is the cards' size, so a click elsewhere reaches the window below")
        XCTAssertLessThan(overlay.frame.height, column.height / 2)
        let raises = owner.notices.testRaises
        session.pane(PaneID(number: 2))?.onSelect()
        XCTAssertEqual(owner.notices.testRaises, raises, "a float does not raise the main window's notices")
        let dismissed = owner.notices.testTransients.entries.map(\.id)
        dismissed.forEach(owner.notices.dismiss)
        XCTAssertFalse(overlay.shown, "without cards there is no window")
    }

    private func stackOrder(_ owner: WindowOwner) -> [PaneID] {
        NSApp.orderedWindows.reversed().compactMap { ($0 as? FloatWindow).flatMap { owner.owns($0) ? $0.content.pane : nil } }
    }

    private final class Recorded { var raises: [PaneID] = [] }

    private func record(_ session: SessionView) -> Recorded {
        let recorded = Recorded(), original = session.edit
        session.edit = { edit, key in
            if case .float(let float) = edit, float.z != nil { recorded.raises.append(float.pane) }
            original(edit, key)
        }
        return recorded
    }

    private func floatOrder(_ owner: WindowOwner) -> [PaneID] {
        owner.testSession?.windows.values.first { !$0.isHidden }?.visualFloatHosts.compactMap(\.content.pane) ?? []
    }

    func testAPressOnTheLowerFloatRaisesItOnce() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        wait("the windows follow the z order") { self.stackOrder(owner) == self.floatOrder(owner) && self.floatOrder(owner).count == 2 }
        let initial = floatOrder(owner), lower = initial[0], upper = initial[1]
        let recorded = record(session)
        try XCTUnwrap(session.pane(lower)).onSelect()
        wait("the server orders the pressed float on top") { self.floatOrder(owner) == [upper, lower] }
        wait("its window is ordered over the other") { self.stackOrder(owner) == [upper, lower] }
        XCTAssertEqual(recorded.raises, [lower])
        try XCTUnwrap(session.pane(lower)).onSelect()
        session.edit(.float(KoSchema.EditFloat(pane: upper, x: 12, y: 5)), nil)
        wait("an unrelated layout update shows") { owner.testModel?.layout.layout.windows.first?.floats.first { $0.pane == upper }?.x == 12 && !session.editing() }
        XCTAssertEqual(recorded.raises, [lower], "a press on the top float and an unrelated update send no new raise")
    }

    func testKeyboardNavigationToTheLowerFloatRaisesIt() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        wait("the windows follow the z order") { self.stackOrder(owner) == self.floatOrder(owner) && self.floatOrder(owner).count == 2 }
        let initial = floatOrder(owner), lower = initial[0], upper = initial[1]
        let recorded = record(session)
        session.selectPane(lower)
        wait("the server orders the focused float on top") { self.floatOrder(owner) == [upper, lower] }
        wait("its window is ordered over the other") { self.stackOrder(owner) == [upper, lower] }
        XCTAssertEqual(recorded.raises, [lower])
    }

    func testFocusingATiledPaneLeavesTheFloatOrder() throws {
        let (owner, client) = try shown(floatLayout(border: false, tree: split))
        let session = try XCTUnwrap(owner.testSession)
        let tiled = PaneID(number: 1)
        let lower = floatOrder(owner)[0]
        session.selectPane(lower)
        wait("the lower float is active and on top") { self.floatOrder(owner).last == lower && self.stackOrder(owner).last == lower }
        let order = stackOrder(owner)
        session.selectPane(tiled)
        wait("the tiled pane is active") { (try? client.model())?.selection.pane == tiled }
        XCTAssertEqual(stackOrder(owner), order)
        XCTAssertEqual(floatOrder(owner), order)
    }

    func testTheScreenRuleUsesTheLeastTranslationWithoutResizing() {
        let visible = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let frame = CGRect(x: -300, y: 700, width: 300, height: 200)
        let moved = FloatWindow.reachable(frame, in: visible)
        XCTAssertEqual(moved, CGRect(x: -140, y: 594, width: 300, height: 200))
        XCTAssertEqual(FloatWindow.reachable(moved, in: visible), moved)
        XCTAssertEqual(FloatWindow.reachable(CGRect(x: 200, y: -200, width: 300, height: 200), in: visible), CGRect(x: 200, y: -78, width: 300, height: 200))
    }

    func testAMainWindowMoveDoesNotMoveItsFloats() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let host = try XCTUnwrap(session.pane(PaneID(number: 2))?.window as? FloatWindow)
        XCTAssertEqual(host.position, .layout)
        let frame = host.frame
        owner.window.setFrameOrigin(NSPoint(x: owner.window.frame.minX + 80, y: owner.window.frame.minY - 30))
        session.edit(.float(KoSchema.EditFloat(pane: PaneID(number: 3), x: 4)), nil)
        wait("the unrelated edit settles") { !session.editing() }
        XCTAssertEqual(host.frame, frame)
    }

    func testAResizeWithoutALocalFrameStillFollowsTheLayout() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let host = try XCTUnwrap(session.pane(PaneID(number: 2))?.window as? FloatWindow)
        let oldCols = try XCTUnwrap(client.model().layout.layout.windows.first).cols
        var frame = owner.window.frame
        frame.size.width -= 160
        owner.window.setFrame(frame, display: true)
        wait("the resize reaches the server") { ((try? client.model().layout.layout.windows.first?.cols) ?? oldCols) < oldCols }
        XCTAssertEqual(host.position, .layout)
    }

    func testSidebarResizeAndFullscreenKeepTheLocalOrigin() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        let visible = try XCTUnwrap(view.window?.screen?.visibleFrame)
        let initial = try screen(view)
        try drag(session, id, dx: visible.minX - initial.minX - initial.width / 2, dy: 0)
        wait("the move settles") { !session.editing() }
        let host = try XCTUnwrap(view.window as? FloatWindow)
        let outside = host.frame
        XCTAssertLessThan(outside.minX, visible.minX)
        let cols = try XCTUnwrap(client.model().layout.layout.windows.first).cols
        owner.sidebar.splitView.setPosition(owner.sidebar.splitView.subviews[0].frame.width + 48, ofDividerAt: 0)
        wait("the sidebar's new room reaches the server") { ((try? client.model().layout.layout.windows.first?.cols) ?? cols) != cols }
        XCTAssertEqual(host.frame, outside)
        try drag(session, id, dx: visible.midX - host.frame.midX, dy: visible.midY - host.frame.midY)
        wait("the float returns inside the screen") { !session.editing() }
        let origin = host.frame.origin
        let entered = expectation(forNotification: NSWindow.didEnterFullScreenNotification, object: owner.window)
        owner.window.toggleFullScreen(nil)
        wait(for: [entered], timeout: 5)
        XCTAssertEqual(host.frame.origin, origin, "position=\(host.position), screen=\(String(describing: host.screen?.visibleFrame)), main=\(owner.window.frame)")
        XCTAssertFalse(host.content.isHidden)
        let exited = expectation(forNotification: NSWindow.didExitFullScreenNotification, object: owner.window)
        owner.window.toggleFullScreen(nil)
        wait(for: [exited], timeout: 5)
    }

    func testADelayedMoveEchoAndAWindowResizeKeepTheLatestScreenOrigin() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        let host = try XCTUnwrap(view.window as? FloatWindow)
        let start = CGPoint(x: host.frame.midX, y: host.frame.midY)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host))
        let older = try XCTUnwrap(owner.testModel?.layout.layout.windows)
        let end = CGPoint(x: start.x + 80, y: start.y - 80)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, end, in: host))
        let origin = host.frame.origin
        terminal.visualBeginDrag(id, try mouse(.leftMouseUp, end, in: host))
        XCTAssertEqual(host.frame.origin, origin)
        session.update(older, shown: terminal.windowID, selected: id, marks: [:])
        XCTAssertEqual(host.frame.origin, origin)
        var frame = owner.window.frame
        frame.size.width -= 160
        owner.window.setFrame(frame, display: true)
        wait("the smaller room and completed move are acknowledged") {
            ((try? client.model().layout.layout.windows.first?.cols) ?? older[0].cols) < older[0].cols
                && self.floats(client).first { $0.pane == id }?.x != older[0].floats.first { $0.pane == id }?.x
                && !session.editing()
        }
        XCTAssertEqual(host.frame.origin, origin)
        session.edit(.float(KoSchema.EditFloat(pane: PaneID(number: 3), x: 4)), nil)
        wait("an unrelated update settles") { !session.editing() }
        XCTAssertEqual(host.frame.origin, origin)
    }

    func testThePaletteFindsAFloatingChildWithoutASidebarRow() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        _ = try client.edit(.split(.init(axis: .h, new: .init(parent: PaneID(number: 1)), pane: PaneID(number: 1))))
        wait("the child is projected") { owner.projection.items.values.contains { $0.item.pane.parent == PaneID(number: 1) } }
        let child = try XCTUnwrap(owner.projection.items.values.first { $0.item.pane.parent == PaneID(number: 1) }?.item.id)
        session.edit(.float(.init(pane: child)), nil)
        wait("the child floats") { !session.editing() && owner.projection.items[child]?.item.placement == .floating }
        XCTAssertFalse(sidebarRows(owner.snapshot).contains { $0.target?.pane == child })
        let row = try XCTUnwrap(PaletteEntry.panes(owner).first { if case .pane(let target) = $0.id { target.pane == child } else { false } })
        XCTAssertEqual(row.detail, "s › w")
        XCTAssertNil(row.check())
    }

    func testAKeyFloatBlocksMainWindowMenusAndTheirKeys() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let pane = try XCTUnwrap(session.pane(PaneID(number: 2)))
        let host = try XCTUnwrap(pane.window as? FloatWindow)
        host.testInput(true)
        let shell = try XCTUnwrap(PaneCommand.menu.submenu)
        let allowed = Set(["Close Pane", "Float Pane", "Dock Pane"])
        for item in shell.items where !item.isSeparatorItem {
            XCTAssertEqual(pane.canPerformMenuItem(item), allowed.contains(item.title), item.title)
        }
        let menus = SessionMenus()
        menus.update(SessionModel())
        for item in menus.window.items + menus.session.items where !item.isSeparatorItem {
            XCTAssertFalse(menus.validateMenuItem(item), item.title)
        }
        for action in [#selector(Sidebar.toggleSidebar(_:)), #selector(Sidebar.focusSidebar(_:)), #selector(NSWindow.toggleFullScreen(_:)), #selector(AppDelegate.closeWindow)] {
            let item = NSMenuItem(title: "main", action: action, keyEquivalent: "")
            XCTAssertFalse(owner.validateMenuItem(item))
        }
        for action in [#selector(PaneView.showFind(_:)), #selector(PaneView.findNext(_:)), #selector(PaneView.toggleCopyMode(_:))] {
            XCTAssertTrue(pane.canPerformMenuItem(NSMenuItem(title: "pane", action: action, keyEquivalent: "")))
        }
        let menu = NSMenu()
        let windows = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windows.submenu = menus.window
        menu.addItem(windows)
        let shellItem = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        shellItem.submenu = shell
        menu.addItem(shellItem)
        for (title, action, key, flags) in [("Sidebar", #selector(Sidebar.focusSidebar(_:)), "s", NSEvent.ModifierFlags.command), ("Hide Sidebar", #selector(Sidebar.toggleSidebar(_:)), "S", [.command, .shift]), ("Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
        }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: host.windowNumber, context: nil, characters: "}", charactersIgnoringModifiers: "}", isARepeat: false, keyCode: 30))
        XCTAssertTrue(CommandScope.consumes(key, menu: menu))
        let shown = session.windows.first { !$0.value.isHidden }?.key
        let originalMenu = NSApp.mainMenu
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = originalMenu }
        for webview in [false, true] {
            if webview { pane.updateWebview(.init(page: .init(path: "/"), serving: false)) }
            XCTAssertEqual(pane.webviewView != nil, webview)
            host.makeFirstResponder(pane.inputResponder)
            let before = pane.visualKeyEvents
            let browserBefore = pane.webviewView?.visualKeyEvents
            if webview { XCTAssertEqual(browserBefore, 0) }
            let layout = owner.testModel?.layout.layout
            for (characters, flags, code) in [("}", NSEvent.ModifierFlags.command.union(.shift), UInt16(30)), ("{", [.command, .shift], 33), ("s", .command, 1), ("S", [.command, .shift], 1), ("d", .command, 2), ("\u{f702}", [.command, .option], 123), ("[", [.command, .control], 33), ("f", [.command, .control], 3)] {
                let blocked = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: host.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                XCTAssertTrue(host.performKeyEquivalent(with: blocked), characters)
                host.sendEvent(blocked)
            }
            XCTAssertEqual(owner.testModel?.layout.layout, layout)
            XCTAssertEqual(session.windows.first { !$0.value.isHidden }?.key, shown)
            XCTAssertEqual(pane.visualKeyEvents, before)
            XCTAssertEqual(pane.webviewView?.visualKeyEvents, browserBefore)
        }
        var sent = false
        menus.send = { _ in sent = true }
        menus.run(try XCTUnwrap(menus.window.items.first))
        XCTAssertFalse(sent)
        XCTAssertEqual(session.windows.first { !$0.value.isHidden }?.key, shown)
        for item in shell.items where item.action == #selector(PaneView.runCommand(_:)) { item.target = pane }
        let close = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: host.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertFalse(CommandScope.consumes(close, menu: menu))
        XCTAssertTrue(host.performKeyEquivalent(with: close))
        XCTAssertTrue(owner.preparedAlert?.host === host)
        owner.respondToAlert(.alertSecondButtonReturn)
        wait("the close confirmation is dismissed") { owner.sheet == nil }
        let dock = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: host.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertFalse(CommandScope.consumes(dock, menu: menu))
        XCTAssertTrue(host.performKeyEquivalent(with: dock))
        wait("the allowed shortcut docks the focused float") { owner.projection.items[pane.pane]?.item.placement == .tiled && !session.editing() }
        (owner.window as? OwnerWindow)?.testInput(true)
        XCTAssertFalse(CommandScope.consumes(key, menu: menu))
    }

    func testBandEscapeRestoresTerminalAndWebviewResponders() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let pane = try XCTUnwrap(session.pane(PaneID(number: 2)))
        let host = try XCTUnwrap(pane.window as? FloatWindow)
        host.testInput(true)
        for webview in [false, true] {
            if webview { pane.updateWebview(.init(page: .init(path: "/"), serving: false)) }
            XCTAssertEqual(pane.webviewView != nil, webview)
            host.makeFirstResponder(pane.inputResponder)
            let initial = host.frame
            let start = local(host, CGPoint(x: host.content.chrome.midX, y: host.content.chrome.minY + 12))
            terminal.visualBeginDrag(pane.pane, try mouse(.leftMouseDown, start, in: host))
            terminal.continueDrag(try mouse(.leftMouseDragged, CGPoint(x: start.x + 80, y: start.y - 80), in: host))
            XCTAssertTrue(host.firstResponder === host.content)
            XCTAssertTrue(PaneView.owner(host.firstResponder) === pane)
            terminal.updateFocusTreatment()
            XCTAssertEqual(terminal.visualChromes.first { $0.pane == pane.pane }?.treatment, .focus)
            XCTAssertNotEqual(host.frame.origin, initial.origin)
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            host.sendEvent(escape)
            XCTAssertFalse(terminal.visualPaneDragging)
            XCTAssertEqual(host.frame, initial)
            XCTAssertTrue(host.firstResponder === pane.inputResponder)
        }
    }

    func testFloatChromeHasOnlyDockAndCloseAboveTheGrid() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let view = try XCTUnwrap(session.pane(PaneID(number: 2)))
        let host = try XCTUnwrap(view.window as? FloatWindow)
        let chrome = try XCTUnwrap(session.windows.values.flatMap(\.visualChromes).first { $0.pane == view.pane })
        XCTAssertEqual(chrome.content.minY, 22)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(chrome.subviews.first { $0 is RuntimePill }).frame.minY, 30)
        XCTAssertEqual(chrome.stripeTop, 19)
        XCTAssertEqual(chrome.toolbarFrame.width, 67)
        chrome.hover(chrome, CGPoint(x: chrome.toolbarFrame.midX, y: chrome.toolbarFrame.midY))
        let toolbar = try XCTUnwrap(chrome.subviews.first { $0 is PaneToolbar })
        XCTAssertEqual(toolbar.subviews.compactMap { $0 as? IconButton }.filter { !$0.isHidden }.map { $0.frame.minX }, [3, 38])
        host.content.handles.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.content.handles.layer?.sublayers?.first?.frame, CGRect(x: host.content.chrome.width / 2 - 18, y: 9, width: 36, height: 4))
        view.showFind()
        view.layoutSubtreeIfNeeded()
        let find = try XCTUnwrap(view.find)
        XCTAssertEqual(find.frame.minY, 30)
        XCTAssertEqual(find.frame.maxX, chrome.bounds.width - 8)
        XCTAssertEqual(chrome.toolbarFrame.minY, 70)
        let bar = chrome.toolbarFrame.offsetBy(dx: chrome.frame.minX, dy: chrome.frame.minY)
        XCTAssertNil(FloatContent.zone(at: CGPoint(x: bar.midX, y: bar.midY), in: host.content.chrome, grid: host.content.grid, toolbar: bar))
        view.find?.close()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.toolbarFrame.minY, 8)
    }

    func testTheHandlesHitInPrecedenceOutsideIn() {
        let r = CGRect(x: 27, y: 27, width: 300, height: 200)
        let grid = CGRect(x: r.minX + 4, y: r.minY + 22, width: r.width - 8, height: r.height - 26)
        let toolbar = CGRect(x: r.maxX - 75, y: r.minY + 8, width: 67, height: 32)
        func zone(_ x: CGFloat, _ y: CGFloat, toolbar: CGRect? = nil) -> FloatContent.Zone? { FloatContent.zone(at: CGPoint(x: x, y: y), in: r, grid: grid, toolbar: toolbar) }
        XCTAssertEqual(zone(r.maxX + 7, r.maxY + 7), .resize(.bottomRight), "the bottom-right corner reaches 8pt out")
        XCTAssertEqual(zone(r.maxX - 3, r.maxY - 3), .resize(.bottomRight), "and 12pt in, outside the grid")
        XCTAssertNil(zone(r.maxX - 11, r.maxY - 11), "no zone covers a grid cell")
        XCTAssertEqual(zone(r.minX + 2, r.minY + 5), .resize(.topLeft), "the other corners are 12pt squares")
        XCTAssertEqual(zone(r.minX + 2, r.maxY - 11), .resize(.left), "the corner square ends 6pt in, where the edge band continues")
        XCTAssertEqual(zone(r.midX, r.minY + 3), .resize(.top), "the top edge band wins over the move band in its 4pt")
        XCTAssertEqual(zone(r.midX, r.minY - 5), .move, "the move band reaches 6pt out")
        XCTAssertEqual(zone(r.midX, r.minY + 21), .move, "and 22pt in")
        XCTAssertNil(zone(r.midX, r.minY + 23), "below the band is the padding and the grid")
        XCTAssertNil(zone(r.maxX - 50, r.minY + 9, toolbar: toolbar), "the toolbar wins over the move band")
        XCTAssertEqual(zone(r.maxX - 50, r.minY - 5, toolbar: toolbar), .move)
        XCTAssertEqual(zone(r.maxX - 2, r.minY + 9, toolbar: toolbar), .resize(.right), "the edges win over the toolbar")
    }

    func testAPressInAGridCornerCellGoesToTheTerminal() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let host = try XCTUnwrap(session.pane(PaneID(number: 2))?.window as? FloatWindow)
        let content = host.content, grid = content.grid
        XCTAssertFalse(grid.isEmpty)
        for point in [CGPoint(x: grid.minX + 1, y: grid.minY + 1), CGPoint(x: grid.maxX - 1, y: grid.minY + 1),
                      CGPoint(x: grid.minX + 1, y: grid.maxY - 1), CGPoint(x: grid.maxX - 1, y: grid.maxY - 1)] {
            XCTAssertFalse(content.hitTest(content.convert(point, to: content.superview)) === content, "\(point) is a terminal cell")
        }
    }

    private func local(_ host: FloatWindow, _ point: CGPoint) -> CGPoint { host.convertPoint(toScreen: host.content.convert(point, to: nil)) }

    func testBandMovesCancelAndOnlyOptionOffersPaneEdgeDocking() throws {
        let (owner, client) = try shown(floatLayout(border: false, tree: split))
        let session = try XCTUnwrap(owner.testSession)
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let id = PaneID(number: 3)
        let host = try XCTUnwrap(session.pane(id)?.window as? FloatWindow)
        let target = try XCTUnwrap(terminal.visualChromes.first { $0.pane == PaneID(number: 1) })
        let targetPoint = owner.window.convertPoint(toScreen: target.convert(CGPoint(x: 8, y: target.bounds.midY), to: nil))
        let initial = host.frame
        let submit = session.edit
        var edits: [KoSchema.Edit] = []
        session.edit = { edit, key in edits.append(edit); submit(edit, key) }
        let start = local(host, CGPoint(x: host.content.chrome.midX, y: host.content.chrome.minY + 12))
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host))
        terminal.continueDrag(try mouse(.leftMouseDragged, targetPoint, in: host))
        XCTAssertNil(terminal.visualPreview.rect)
        XCTAssertNotEqual(host.frame.origin, initial.origin)
        terminal.cancelDrag()
        XCTAssertEqual(host.frame, initial)
        XCTAssertTrue(edits.isEmpty, "a cancelled band move sends no edit")
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host))
        terminal.continueDrag(try mouse(.leftMouseDragged, targetPoint, in: host, flags: .option))
        XCTAssertNotNil(terminal.visualPreview.rect)
        XCTAssertNil(terminal.visualGhost)
        terminal.continueDrag(try mouse(.leftMouseDragged, targetPoint, in: host))
        XCTAssertNil(terminal.visualPreview.rect)
        terminal.continueDrag(try mouse(.leftMouseUp, targetPoint, in: host, flags: .option))
        XCTAssertEqual(edits, [.dock(.init(edge: .left, pane: id, target: PaneID(number: 1)))])
        wait("Option docks the float") { !session.editing() && !self.floats(client).contains { $0.pane == id } }
        XCTAssertFalse(session.editing(), "submitted edits: \(edits)")
        XCTAssertFalse(floats(client).contains { $0.pane == id }, "server floats: \(floats(client)); client layout: \(String(describing: owner.testModel?.layout.layout.windows))")
        XCTAssertTrue(session.pane(id)?.window === owner.window)
    }

    func testADragFromTheMoveBandMovesTheFloat() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let host = try XCTUnwrap(session.pane(id)?.window as? FloatWindow)
        let chrome = host.content.chrome, before = try XCTUnwrap(floats(client).first { $0.pane == id })
        let start = local(host, CGPoint(x: chrome.midX, y: chrome.minY - 5))
        XCTAssertTrue(host.content.hitTest(host.content.convert(CGPoint(x: chrome.midX, y: chrome.minY - 5), to: host.content.superview)) === host.content, "the band outside the float is the float window's")
        host.content.mouseDown(with: try mouse(.leftMouseDown, start, in: host))
        XCTAssertTrue(try XCTUnwrap(session.windows.values.first { !$0.isHidden }).visualPaneDragging, "the band starts the move")
        for step in 1...4 { host.content.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: start.x, y: start.y - 20 * CGFloat(step)), in: host)) }
        host.content.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: start.x, y: start.y - 80), in: host))
        wait("the float moved down") { (self.floats(client).first { $0.pane == id }?.y ?? 0) > before.y }
    }

    func testADragFromTheBottomRightCornerResizesTheFloat() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let host = try XCTUnwrap(session.pane(id)?.window as? FloatWindow)
        let chrome = host.content.chrome, before = try XCTUnwrap(floats(client).first { $0.pane == id })
        let start = local(host, CGPoint(x: chrome.maxX + 6, y: chrome.maxY + 6))
        host.content.mouseDown(with: try mouse(.leftMouseDown, start, in: host))
        for step in 1...4 { host.content.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: start.x + 20 * CGFloat(step), y: start.y - 20 * CGFloat(step)), in: host)) }
        host.content.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: start.x + 80, y: start.y - 80), in: host))
        wait("the float grew") { (self.floats(client).first { $0.pane == id }.map { $0.cols > before.cols && $0.rows > before.rows }) == true }
    }

}
