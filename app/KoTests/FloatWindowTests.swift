import AppKit
import KoClient
import KoClientKit
import KoModel
import PaneGeometry
import XCTest
@testable import Kido

// A float is a borderless child window of the main window, with its own local position.
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

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0,
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
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host), from: .frame)
        for step in 1...4 {
            let host = try XCTUnwrap(view.window)
            terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, CGPoint(x: start.x + dx * CGFloat(step) / 4, y: start.y + dy * CGFloat(step) / 4), in: host), from: .frame)
        }
        let end = CGPoint(x: start.x + dx, y: start.y + dy)
        terminal.visualBeginDrag(id, try mouse(.leftMouseUp, end, in: try XCTUnwrap(view.window)), from: .frame)
    }

    func testAFloatIsABorderlessChildWindowOfTheMainWindow() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let view = try XCTUnwrap(session.pane(PaneID(number: 2)))
        XCTAssertFalse(view.window === owner.window, "a float lives in its own window")
        XCTAssertTrue(view.window?.parent === owner.window)
        XCTAssertEqual(view.window?.styleMask, .borderless)
        XCTAssertEqual(owner.window.floatChildren.count, 2)
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
        XCTAssertTrue(host.parent === owner.window)
        XCTAssertTrue(owner.inputWindow === owner.window, "without a key float the main window has the input")
        host.testInput(true)
        (owner.window as? OwnerWindow)?.testInput(false)
        host.becameKey()
        wait("its pane is the active pane") { (try? client.model())?.selection.pane == id }
        terminal.updateFocusTreatment()
        XCTAssertEqual(terminal.visualChromes.first { $0.pane == id }?.treatment, .focus)
        XCTAssertEqual(terminal.visualChromes.first { $0.pane == PaneID(number: 2) }?.treatment, .overlay)
        XCTAssertTrue(owner.owns(host))
        XCTAssertTrue(owner.inputWindow === host, "the owner routes input to the key float")
        XCTAssertTrue(owner.inputResponder === host.firstResponder)
        XCTAssertTrue(PaneView.owner(owner.inputResponder) === session.pane(id), "the menu and the palette act on the float's pane")
    }

    func testAnotherTabHidesTheFloatsAndAClosedPaneClosesItsWindow() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let first = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let id = try XCTUnwrap(first.windowID)
        let view = try XCTUnwrap(session.pane(PaneID(number: 2)))
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        session.show(nil)
        XCTAssertTrue(view.isHiddenOrHasHiddenAncestor, "the float's window hides with its logical window")
        XCTAssertEqual(owner.window.floatChildren.count, 0)
        session.show(id)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(owner.window.floatChildren.count, 2)
        try client.delete(KO_DELETE_PANE, PaneID(number: 2))
        wait("the closed float's window is gone") { owner.window.floatChildren.count == 1 && self.floats(client).count == 1 }
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

    func testAnOlderEchoThatArrivesAfterANewerDragFrameLeavesTheNewerFrame() throws {
        let (owner, client) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 2)
        let view = try XCTUnwrap(session.pane(id))
        let terminal = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let host = try XCTUnwrap(view.window)
        let start = CGPoint(x: try screen(view).midX, y: try screen(view).midY)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host), from: .frame)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, CGPoint(x: start.x + 120, y: start.y - 120), in: try XCTUnwrap(view.window)), from: .frame)
        wait("the first edit's echo is shown") { owner.testModel?.layout.layout.windows.first?.floats.first { $0.pane == id }?.x != 2 }
        let older = try XCTUnwrap(owner.testModel?.layout.layout.windows)
        let end = CGPoint(x: start.x + 240, y: start.y - 240)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, end, in: try XCTUnwrap(view.window)), from: .frame)
        let newer = try screen(view)
        session.update(older, alive: Set(older.map(\.id)), selected: nil, marks: [:])
        XCTAssertEqual(try screen(view), newer, "an echo of the earlier edit does not move the float under the pointer")
        terminal.visualBeginDrag(id, try mouse(.leftMouseUp, end, in: try XCTUnwrap(view.window)), from: .frame)
        session.update(older, alive: Set(older.map(\.id)), selected: nil, marks: [:])
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
            owner.window.floatChildren.count == 2 && terminal.hostWindows.allSatisfy { $0.delegate === owner && !$0.content.isHidden && $0.frame.width > 0 }
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
        terminal.visualBeginDrag(id, try mouse(.leftMouseDown, start, in: host), from: .frame)
        terminal.visualBeginDrag(id, try mouse(.leftMouseDragged, CGPoint(x: start.x + 40, y: start.y), in: host), from: .frame)
        XCTAssertTrue(terminal.visualPaneDragging)
        try client.delete(KO_DELETE_PANE, id)
        wait("the float's window closed") { owner.window.floatChildren.count == 1 && !terminal.visualPaneDragging }
        wait("the edits settle") { !session.editing() }
    }

    func testZoomingAndUnzoomingKeepsALocalPosition() throws {
        let (owner, client) = try shown(floatLayout(border: false, tree: split))
        let session = try XCTUnwrap(owner.testSession)
        let id = PaneID(number: 3)
        let view = try XCTUnwrap(session.pane(id))
        try drag(session, id, dx: -3000, dy: 0)
        wait("the position settled") { self.floats(client).first { $0.pane == id }?.x == 0 && !session.editing() }
        let frame = try screen(view)
        XCTAssertLessThan(frame.minX, owner.window.frame.minX - 100)
        session.paneCommand(.zoom, PaneID(number: 1))
        wait("the owner shows the zoom") { owner.testModel?.layout.layout.windows.first?.zoom == PaneID(number: 1) }
        XCTAssertTrue(view.isHiddenOrHasHiddenAncestor, "zoom hides the float")
        session.paneCommand(.zoom, PaneID(number: 1))
        wait("the owner shows the zoom ended") { owner.testModel?.layout.layout.windows.first?.zoom == nil }
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(try screen(view), frame, "the local position survives the zoom")
    }

    func testAMinimizedMainWindowHidesTheFloatsAndTheBannerHidesThemWhileTheOwnerIsDown() throws {
        let (owner, _) = try shown(twoFloats)
        let session = try XCTUnwrap(owner.testSession)
        let view = try XCTUnwrap(session.pane(PaneID(number: 2)))
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        owner.testBanner.isHidden = false
        XCTAssertTrue(view.isHiddenOrHasHiddenAncestor, "the banner covers the floats too")
        XCTAssertEqual(owner.window.floatChildren.count, 0)
        owner.testBanner.isHidden = true
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        owner.window.miniaturize(nil)
        if owner.window.isMiniaturized {
            session.syncHosts()
            XCTAssertTrue(view.isHiddenOrHasHiddenAncestor, "the floats hide with the minimized main window")
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
        var raises = owner.notices.testRaises
        session.pane(PaneID(number: 2))?.onSelect()
        XCTAssertGreaterThan(owner.notices.testRaises, raises, "raising a float raises the notices over it")
        raises = owner.notices.testRaises
        session.show(nil)
        session.show(try XCTUnwrap(session.windows.keys.first))
        XCTAssertGreaterThan(owner.notices.testRaises, raises, "so does placing the floats again")
        let dismissed = owner.notices.testTransients.entries.map(\.id)
        dismissed.forEach(owner.notices.dismiss)
        XCTAssertFalse(overlay.shown, "without cards there is no window")
    }

    private func stackOrder(_ owner: WindowOwner) -> [PaneID] {
        owner.window.floatChildren.compactMap { ($0 as? FloatWindow)?.content.pane }
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

    func testTheHandlesHitInPrecedenceOutsideIn() {
        let r = CGRect(x: 27, y: 27, width: 300, height: 200)
        let grid = CGRect(x: r.minX + 4, y: r.minY + 10, width: r.width - 8, height: r.height - 14)
        let toolbar = CGRect(x: r.maxX - 150, y: r.minY + 8, width: 145, height: 32)
        func zone(_ x: CGFloat, _ y: CGFloat, toolbar: CGRect? = nil) -> FloatContent.Zone? { FloatContent.zone(at: CGPoint(x: x, y: y), in: r, grid: grid, toolbar: toolbar) }
        XCTAssertEqual(zone(r.maxX + 7, r.maxY + 7), .resize(.bottomRight), "the bottom-right corner reaches 8pt out")
        XCTAssertEqual(zone(r.maxX - 3, r.maxY - 3), .resize(.bottomRight), "and 12pt in, outside the grid")
        XCTAssertNil(zone(r.maxX - 11, r.maxY - 11), "no zone covers a grid cell")
        XCTAssertEqual(zone(r.minX + 2, r.minY + 5), .resize(.topLeft), "the other corners are 12pt squares")
        XCTAssertEqual(zone(r.minX + 2, r.maxY - 11), .resize(.left), "the corner square ends 6pt in, where the edge band continues")
        XCTAssertEqual(zone(r.midX, r.minY + 3), .resize(.top), "the top edge band wins over the move band in its 4pt")
        XCTAssertEqual(zone(r.midX, r.minY - 5), .move, "the move band reaches 6pt out")
        XCTAssertEqual(zone(r.midX, r.minY + 9), .move, "and 10pt in")
        XCTAssertNil(zone(r.midX, r.minY + 11), "below the band is the padding and the grid")
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

private extension NSWindow {
    var floatChildren: [NSWindow] { (childWindows ?? []).filter { $0 is FloatWindow } }
}
