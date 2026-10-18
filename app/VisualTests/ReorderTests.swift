import AppKit
import XCTest
import SidebarFeed
import TmuxControl
@testable import Kido

@MainActor private final class Drop: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    let draggingSource: Any?
    init(_ pasteboard: NSPasteboard, _ location: NSPoint, _ window: NSWindow?, source: Any? = nil) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
        draggingSource = source
    }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor final class ReorderTests: VisualTestCase {
    private let board = NSPasteboard(name: .init("kido-reorder-test-\(UUID().uuidString)"))
    private var sent: [(request: RPCRequest, reply: @MainActor @Sendable (Result<RPCEvent.Reply.Value, Failure>) -> Void)] = []
    private var requests: [RPCRequest] { sent.map(\.request) }

    override func tearDown() async throws {
        board.releaseGlobally()
        try await super.tearDown()
    }

    private func fixture(sessions count: Int? = nil) throws -> Snapshot {
        try sidebarFixture { object in
            guard let count else { return }
            let original = (object["sessions"] as! [[String: Any]])[0]
            object["sessions"] = (0..<count).map { i -> [String: Any] in
                var session = original
                session["id"] = "$\(i)"
                session["name"] = "session-\(i)"
                return session
            }
        }
    }

    private func owner(_ snapshot: Snapshot, host: Kido.Host = .local) throws -> WindowOwner {
        let owner = try XCTUnwrap(delegate.open(host, start: false))
        addTeardownBlock { @MainActor in owner.close() }
        owner.request = { [weak self] request, done in
            self?.sent.append((request, done))
        }
        owner.testReceive(snapshot)
        owner.window.contentView?.superview?.layoutSubtreeIfNeeded()
        owner.sidebar.list.layoutSubtreeIfNeeded()
        XCTAssertFalse(owner.window.isVisible || owner.window.isKeyWindow || NSApp.isActive)
        return owner
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func send(_ tabs: WindowTabs, _ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat = 18) {
        let event = mouse(type, tabs.convert(NSPoint(x: x, y: y), to: nil), tabs.window!)
        switch type {
        case .leftMouseDown: tabs.mouseDown(with: event)
        case .leftMouseDragged: tabs.mouseDragged(with: event)
        default: tabs.mouseUp(with: event)
        }
    }

    private func center(_ table: NSTableView, _ row: Int, dy: CGFloat = 0) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return table.convert(NSPoint(x: rect.midX, y: rect.midY + dy), to: nil)
    }

    private func press(_ table: Table, _ row: Int, drag: Bool) throws {
        let window = try XCTUnwrap(table.window)
        let start = center(table, row)
        let down = mouse(.leftMouseDown, start, window)
        if drag {
            for dy in [2.0, 8, 20] { NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - dy), window), atStart: false) }
        }
        NSApp.postEvent(mouse(.leftMouseUp, NSPoint(x: start.x, y: start.y - (drag ? 20 : 0)), window), atStart: false)
        table.mouseDown(with: down)
    }

    private func drop(_ list: SidebarView, at point: NSPoint) throws -> Drop {
        let table = list.visualTable as! Table
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(try XCTUnwrap((table.visualDrag?.items.first?.item as? NSPasteboardItem)?.data(forType: .kidoReorder)), forType: .kidoReorder)
        board.writeObjects([item])
        return Drop(board, point, table.window)
    }

    private func viewportY(_ list: SidebarView, _ id: SidebarRow.ID) -> CGFloat? {
        list.visualRows.firstIndex { $0.id == id }.map { list.visualTable.rect(ofRow: $0).minY - list.visualScroll.contentView.bounds.minY }
    }

    func testHeadingDragCollapsesToHeadingsAndReorders() async throws {
        let snapshot = try fixture(sessions: 20)
        let owner = try owner(snapshot)
        let list = owner.sidebar.list, table = list.visualTable as! Table
        let source = SessionID(number: 4), anchor = SessionID(number: 8)
        let selected = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .pane(SessionID(number: 13), PaneID(number: 905)) })
        table.selectRowIndexes([selected], byExtendingSelection: false)
        let header = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .header(source) })
        XCTAssertFalse(list.tableView(table, shouldSelectRow: header), "headings stay nonselectable")
        list.visualScroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: header).minY - 60))
        let pinned = try XCTUnwrap(viewportY(list, .header(source)))
        XCTAssertEqual(pinned, 60, accuracy: 0.5)

        try press(table, header, drag: true)
        let drag = try XCTUnwrap(table.visualDrag, "AppKit's own row drag starts from a nonselectable heading")
        XCTAssertEqual(drag.items.count, 1)
        let payload = try XCTUnwrap((drag.items[0].item as? NSPasteboardItem)?.data(forType: .kidoReorder))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["session"] as? String, "$4")
        XCTAssertNil(object["window"] as? String)
        XCTAssertNil(object["row"], "the pasteboard carries ids, not row indexes")

        let rows = list.visualRows.map(\.id)
        table.draggingSession(drag.session, willBeginAt: .zero)
        XCTAssertEqual(list.visualRows.map(\.id), rows, "the table is untouched while AppKit starts the session")
        XCTAssertNotNil(drag.items[0].imageComponents?.first?.contents, "the drag image is fixed before any row changes")
        let grabbed = try drop(list, at: center(table, header))
        _ = list.visualScroll.draggingUpdated(grabbed)
        XCTAssertEqual(list.visualRows.map(\.id), snapshot.sessions.map { .header($0.id) }, "only headings remain once the drag moves")
        for row in 0..<table.numberOfRows { XCTAssertEqual(list.tableView(table, heightOfRow: row), 29) }
        XCTAssertEqual(try XCTUnwrap(viewportY(list, .header(source))), pinned, accuracy: 0.5, "the dragged heading stays where it was grabbed")
        XCTAssertFalse(owner.reorder.claim(.tab))
        XCTAssertFalse(owner.reorder.claim(.pane))

        let target = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .header(anchor) })
        let info = try drop(list, at: center(table, target - 1, dy: 6))
        XCTAssertEqual(list.visualScroll.draggingUpdated(info), .move)
        let line = try XCTUnwrap(list.visualInsertion)
        XCTAssertEqual(line.midY, table.rect(ofRow: target).minY, accuracy: 0.5)
        XCTAssertEqual(line.width, table.bounds.width)
        XCTAssertTrue(list.visualScroll.performDragOperation(info))
        let move = ReorderMove.session(source, relativeTo: anchor, .before)
        XCTAssertEqual(requests, [.reorder(move)])
        let moved = try XCTUnwrap(snapshot.reordered(move))
        XCTAssertEqual(list.visualRows.map(\.id), moved.sessions.map { .header($0.id) }, "the drop reorders the headings before children return")
        let dropped = try XCTUnwrap(viewportY(list, .header(source)))

        list.tableView(table, draggingSession: drag.session, endedAt: .zero, operation: .move)
        XCTAssertNil(list.visualDragging)
        XCTAssertNil(list.visualInsertion)
        XCTAssertEqual(list.visualRows.map(\.id), sidebarRows(moved).map(\.id))
        XCTAssertEqual(try XCTUnwrap(viewportY(list, .header(source))), dropped, accuracy: 0.5, "children return around the dropped heading")
        XCTAssertEqual(list.visualRows[table.selectedRow].id, .pane(SessionID(number: 13), PaneID(number: 905)), "selection survives by id")
        XCTAssertEqual(requests.count, 1, "no activation from the drag")
        XCTAssertFalse(owner.reorder.claim(.tab), "no new reorder gesture while a drop is pending")
        XCTAssertTrue(owner.reorder.claim(.pane))
        owner.reorder.release(.pane)

        let row = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .header(anchor) })
        XCTAssertNil(list.tableView(table, pasteboardWriterForRow: row), "no new drag while a drop is pending")
        sent[0].reply(.success(.reordered))
        owner.testReceive(snapshot)
        XCTAssertEqual(list.visualRows.map(\.id), sidebarRows(moved).map(\.id), "a stale snapshot keeps the optimistic order")
        owner.testReceive(moved)
        XCTAssertNil(owner.reorder.state.pending)
        XCTAssertEqual(list.visualRows.map(\.id), sidebarRows(moved).map(\.id))
        XCTAssertNotNil(list.tableView(table, pasteboardWriterForRow: row))
        XCTAssertTrue(owner.reorder.claim(.tab))
        XCTAssertEqual(list.visualDiagnostic, "")
    }

    private func destination(_ window: NSWindow, at point: NSPoint) -> NSView? {
        let root = window.contentView!.superview!
        var view = root.hitTest(root.convert(point, from: nil))
        while let current = view, !current.registeredDraggedTypes.contains(.kidoReorder) { view = current.superview }
        return view
    }

    private func nativeDrop(_ list: SidebarView, start row: Int, cancel: Bool = false, midway: () throws -> Void = {}, at target: () -> NSPoint) async throws -> (NSDragOperation, Bool) {
        let table = list.visualTable as! Table
        table.scrollRowToVisible(row)
        try press(table, row, drag: true)
        let drag = try XCTUnwrap(table.visualDrag, "a drag starts")
        table.draggingSession(drag.session, willBeginAt: .zero)
        XCTAssertNotNil(list.visualDragging, "AppKit forwards the drag start")
        try await Task.sleep(for: .milliseconds(50))
        let moving = center(table, row, dy: row == 0 ? 20 : -20)
        let info = try drop(list, at: moving)
        let live = Drop(info.draggingPasteboard, moving, table.window, source: table)
        let start = destination(table.window!, at: moving)
        XCTAssertTrue(start === list.visualScroll, "the sidebar takes the drag where it starts")
        _ = start?.draggingEntered(live)
        try midway()
        live.draggingLocation = target()
        let view = destination(table.window!, at: live.draggingLocation)
        if view !== start {
            start?.draggingExited(live)
            _ = view?.draggingEntered(live)
        }
        let operation = view?.draggingUpdated(live) ?? []
        let accepted = !cancel && !operation.isEmpty && view?.prepareForDragOperation(live) == true && view?.performDragOperation(live) == true
        if !accepted { view?.draggingExited(live) } else { view?.concludeDragOperation(live) }
        table.draggingSession(drag.session, endedAt: .zero, operation: accepted ? .move : [])
        XCTAssertNil(list.visualDragging, "AppKit forwards the drag end")
        XCTAssertTrue(list.visualRows.contains { $0.target != nil }, "the rows return after the drag")
        return (operation, accepted)
    }

    func testTopDropZoneAboveTheFirstHeading() async throws {
        let snapshot = try fixture(sessions: 3)
        let owner = try owner(snapshot)
        owner.window.setContentSize(NSSize(width: 900, height: 700))
        owner.window.contentView?.superview?.layoutSubtreeIfNeeded()
        let list = owner.sidebar.list, table = list.visualTable
        let first = SessionID(number: 0), last = SessionID(number: 2)
        func header() -> Int { list.visualRows.firstIndex { $0.id == .header(last) }! }
        let inset = try await nativeDrop(list, start: header()) {
            XCTAssertGreaterThan(list.visualScroll.contentInsets.top, 40, "the collapse leaves room above the first heading: rows=\(list.visualRows.count) dragging=\(list.visualDragging ?? "nil") grabbed=\(header())")
            return table.convert(NSPoint(x: table.bounds.midX, y: -30), to: nil)
        }
        XCTAssertEqual(inset.0, .move, "the space above the first heading takes the drop")
        XCTAssertTrue(inset.1)
        XCTAssertEqual(requests, [.reorder(.session(last, relativeTo: first, .before))])
        sent.forEach { $0.reply(.failure(.terminal("revert"))) }; sent.removeAll()

        let upper = try await nativeDrop(list, start: header()) {
            table.convert(NSPoint(x: table.bounds.midX, y: table.rect(ofRow: 0).minY + 4), to: nil)
        }
        XCTAssertEqual(upper.0, .move)
        XCTAssertTrue(upper.1, "the first heading's upper half means before it")
        XCTAssertEqual(requests, [.reorder(.session(last, relativeTo: first, .before))])
        sent.forEach { $0.reply(.failure(.terminal("revert"))) }; sent.removeAll()

        let bottom = try await nativeDrop(list, start: 0) {
            table.convert(NSPoint(x: table.bounds.midX, y: table.rect(ofRow: list.visualRows.count - 1).maxY + 40), to: nil)
        }
        XCTAssertTrue(bottom.1, "the space under the last heading means after it")
        XCTAssertEqual(requests, [.reorder(.session(first, relativeTo: last, .after))])
    }

    func testWindowDragCarriesAndHidesItsWholeGroup() async throws {
        let snapshot = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            var nodes = sessions[0]["nodes"] as! [[String: Any]]
            var group = nodes[1]
            var children = group["children"] as! [[String: Any]]
            var extra = children[1]
            extra["id"] = "%1458"; extra["pane"] = "%1458"; extra["children"] = []
            children.append(extra)
            group["children"] = children
            nodes[1] = group
            sessions[0]["nodes"] = nodes
            object["sessions"] = sessions
        }
        let owner = try owner(snapshot)
        let list = owner.sidebar.list, table = list.visualTable as! Table
        let main = SessionID(number: 0), group = WindowID(number: 458), last = WindowID(number: 797)
        let rows = list.visualRows
        let block = rows.indices.filter { rows[$0].id.session == main && rows[$0].root == group }
        XCTAssertEqual(block.filter { rows[$0].indent == 0 }.count, 3, "three panes")
        let grabbed = try XCTUnwrap(block.dropFirst().first { rows[$0].indent == 0 })
        try press(table, grabbed, drag: true)
        let item = try XCTUnwrap(table.visualDrag?.items.first)
        let span = table.rect(ofRow: block.first!).union(table.rect(ofRow: block.last!))
        XCTAssertEqual(item.draggingFrame.minY, span.minY, accuracy: 0.5, "the image starts at the window's first row")
        XCTAssertEqual(item.draggingFrame.height, span.height, accuracy: 0.5, "the image covers every row of the window")
        XCTAssertEqual(item.imageComponents?.first?.frame.height ?? 0, span.height, accuracy: 0.5)

        let session = try XCTUnwrap(table.visualDrag?.session)
        table.draggingSession(session, willBeginAt: .zero)
        XCTAssertEqual(list.visualRows, rows, "no row changes while AppKit starts the session")
        let live = Drop(try drop(list, at: center(table, grabbed, dy: -20)).draggingPasteboard, center(table, grabbed, dy: -20), table.window, source: table)
        let scroll = list.visualScroll
        _ = scroll.draggingEntered(live)
        XCTAssertEqual(list.visualRows.map(\.id), rows.indices.filter { !block.contains($0) }.map { rows[$0].id }, "the dragged window leaves the list")
        let gap = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .gap(main) })
        live.draggingLocation = center(table, gap)
        XCTAssertEqual(scroll.draggingUpdated(live), .move)
        XCTAssertEqual(try XCTUnwrap(list.visualInsertion).midY, table.rect(ofRow: gap).minY, accuracy: 0.5)
        live.draggingLocation = center(table, list.visualRows.firstIndex { $0.id == .header(main) }!)
        XCTAssertEqual(scroll.draggingUpdated(live), .move)
        live.draggingLocation = center(table, gap)
        XCTAssertEqual(scroll.draggingUpdated(live), .move)
        XCTAssertTrue(scroll.prepareForDragOperation(live) && scroll.performDragOperation(live))
        table.draggingSession(session, endedAt: .zero, operation: .move)
        XCTAssertEqual(requests, [.reorder(.window(main, group, relativeTo: last, .after))])
        XCTAssertEqual(list.visualRows.map(\.id), sidebarRows(try XCTUnwrap(snapshot.reordered(.window(main, group, relativeTo: last, .after)))).map(\.id))
        sent[0].reply(.failure(.terminal("no such top-level window in session")))
        XCTAssertEqual(list.visualRows.map(\.id), rows.map(\.id), "a failure brings the rows back")

        let cancelled = try await nativeDrop(list, start: grabbed, cancel: true) { self.center(table, 0) }
        XCTAssertFalse(cancelled.1)
        XCTAssertEqual(list.visualRows, rows, "a cancel brings the rows back")
        XCTAssertEqual(requests.count, 1)
    }

    func testWindowDragKeepsTheKeyboardSelection() async throws {
        let owner = try owner(try fixture())
        let list = owner.sidebar.list, table = list.visualTable as! Table
        let main = SessionID(number: 0), group = WindowID(number: 458)
        let rows = list.visualRows
        let pane = try XCTUnwrap(rows.indices.filter { rows[$0].root == group && rows[$0].indent == 0 }.last)
        let id = rows[pane].id
        func selectPane() {
            list.focus()
            table.selectRowIndexes([list.visualRows.firstIndex { $0.id == id }!], byExtendingSelection: false)
        }
        selectPane()
        _ = try await nativeDrop(list, start: pane, cancel: true) { self.center(table, 0) }
        XCTAssertEqual(list.visualRows.indices.contains(table.selectedRow) ? list.visualRows[table.selectedRow].id : nil, id, "a cancelled window drag keeps the selection")

        selectPane()
        let start = list.visualRows.firstIndex { $0.id == id }!
        let dropped = try await nativeDrop(list, start: start) {
            self.center(table, list.visualRows.firstIndex { $0.id == .gap(main) }!)
        }
        XCTAssertTrue(dropped.1)
        XCTAssertEqual(list.visualRows.indices.contains(table.selectedRow) ? list.visualRows[table.selectedRow].id : nil, id, "a dropped window drag keeps the selection")
        let selected = table.selectedRow
        let next = try XCTUnwrap(list.visualRows.indices.first { $0 > selected && list.visualRows[$0].target != nil })
        table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: table.window!.windowNumber,
                                             context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!)
        XCTAssertEqual(table.selectedRow, next, "Down moves on from the restored selection")
        table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: table.window!.windowNumber,
                                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        XCTAssertEqual(requests.last, .jump(list.visualRows[next].target!), "Enter activates from it")
    }

    func testHeadingStaysUnderThePointerWhenFewSessionsCollapse() async throws {
        let snapshot = try fixture(sessions: 3)
        let owner = try owner(snapshot)
        owner.window.setContentSize(NSSize(width: 900, height: 700))
        owner.window.contentView?.superview?.layoutSubtreeIfNeeded()
        let list = owner.sidebar.list, table = list.visualTable
        let last = SessionID(number: 2), middle = SessionID(number: 1)
        let header = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .header(last) })
        let grab = center(table, header)
        XCTAssertGreaterThan(table.convert(grab, from: nil).y, 3 * 29, "the heading starts below where three headings collapse to")
        var under: SidebarRow.ID?
        let (operation, accepted) = try await nativeDrop(list, start: header, midway: {
            let row = table.row(at: table.convert(grab, from: nil))
            under = list.visualRows.indices.contains(row) ? list.visualRows[row].id : nil
        }) { NSPoint(x: grab.x, y: grab.y + 29 + 8) }
        XCTAssertEqual(under, .header(last), "the dragged heading stays under the pointer")
        XCTAssertEqual(operation, .move)
        XCTAssertTrue(accepted, "a drop on the heading above is accepted")
        XCTAssertEqual(requests, [.reorder(.session(last, relativeTo: middle, .before))])
        XCTAssertEqual(list.visualScroll.contentInsets.top, 0, "the drag leaves no inset behind")
    }

    func testNativeTableDropReordersSessionsAndWindows() async throws {
        let snapshot = try fixture()
        let owner = try owner(snapshot)
        let list = owner.sidebar.list, table = list.visualTable
        let header = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .header(SessionID(number: 3)) })
        let busy = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            sessions[1]["name"] = "renamed while dragging"
            object["sessions"] = sessions
        }
        let cancelled = try await nativeDrop(list, start: header, cancel: true) { self.center(table, 0, dy: -6) }
        XCTAssertEqual(cancelled.0, .move)
        XCTAssertEqual(requests, [], "a cancelled heading drag sends nothing")
        XCTAssertEqual(list.visualRows.map(\.id), sidebarRows(snapshot).map(\.id), "a cancelled drag restores every row")
        let (operation, accepted) = try await nativeDrop(list, start: header, midway: { owner.testReceive(busy) }) {
            let first = list.visualRows.firstIndex { $0.id == .header(SessionID(number: 0)) }!
            return self.center(table, first, dy: -6)
        }
        XCTAssertEqual(operation, .move, "AppKit's own drag update must allow the heading drop")
        XCTAssertTrue(accepted, "AppKit's own perform must accept the heading drop")
        XCTAssertEqual(requests, [.reorder(.session(SessionID(number: 3), relativeTo: SessionID(number: 0), .before))])
        sent.first?.reply(.success(.reordered))
        owner.testReceive(try XCTUnwrap(snapshot.reordered(.session(SessionID(number: 3), relativeTo: SessionID(number: 0), .before))))
        XCTAssertNil(owner.reorder.state.pending)

        let rows = list.visualRows
        let pane = try XCTUnwrap(rows.firstIndex { $0.id == .pane(SessionID(number: 0), PaneID(number: 905)) })
        let window = try await nativeDrop(list, start: pane) {
            let first = list.visualRows.firstIndex { $0.id == .header(SessionID(number: 0)) }!
            return self.center(table, first)
        }
        XCTAssertEqual(window.0, .move)
        XCTAssertTrue(window.1)
        XCTAssertEqual(requests.last, .reorder(.window(SessionID(number: 0), WindowID(number: 797), relativeTo: WindowID(number: 0), .before)))
    }

    func testWindowDragStaysInItsSessionAndRevertsOnFailure() async throws {
        let snapshot = try fixture()
        let owner = try owner(snapshot)
        let list = owner.sidebar.list, table = list.visualTable as! Table
        let main = SessionID(number: 0), group = WindowID(number: 458), last = WindowID(number: 797)
        let rows = list.visualRows
        let block = rows.indices.filter { rows[$0].id.session == main && rows[$0].root == group }
        XCTAssertGreaterThan(block.count, 2, "a multi-pane window with nested rows")
        let pane = try XCTUnwrap(block.last { rows[$0].indent == 0 })
        XCTAssertNotEqual(pane, block.first, "any top-level pane row moves its whole window")
        let nested = try XCTUnwrap(rows.indices.first { rows[$0].indent > 0 && rows[$0].target != nil })
        XCTAssertNil(list.tableView(table, pasteboardWriterForRow: nested), "nested rows do not start a drag")
        if let record = rows.indices.first(where: { rows[$0].target == nil && rows[$0].root != nil }) {
            XCTAssertNil(list.tableView(table, pasteboardWriterForRow: record), "program records do not start a drag")
        }

        try press(table, pane, drag: true)
        let drag = try XCTUnwrap(table.visualDrag)
        list.tableView(table, draggingSession: drag.session, willBeginAt: .zero, forRowIndexes: [pane])
        XCTAssertEqual(list.visualRows, rows, "AppKit starts the session on unchanged rows")
        XCTAssertEqual(list.visualDragging, "window($0, @458)")
        let other = try XCTUnwrap(rows.firstIndex { $0.id == .header(SessionID(number: 3)) })
        XCTAssertEqual(list.visualScroll.draggingUpdated(try drop(list, at: center(table, other + 1))), [],
                       "another session refuses the drop")
        XCTAssertFalse(list.visualRows.contains { $0.root == group }, "the dragged window leaves the list")
        XCTAssertNil(list.visualInsertion)
        var hidden = list.visualRows
        let first = try XCTUnwrap(hidden.firstIndex { $0.id.session == main && $0.root != nil })
        XCTAssertEqual(list.visualScroll.draggingUpdated(try drop(list, at: center(table, 0))), .move)
        XCTAssertEqual(try XCTUnwrap(list.visualInsertion).midY, table.rect(ofRow: first).minY, accuracy: 0.5, "a heading drop goes before the first window")
        let inside = try XCTUnwrap(hidden.lastIndex { $0.id.session == main && $0.root == WindowID(number: 0) })
        let noop = try drop(list, at: center(table, inside))
        XCTAssertEqual(list.visualScroll.draggingUpdated(noop), .move)
        XCTAssertEqual(try XCTUnwrap(list.visualInsertion).midY, table.rect(ofRow: inside + 1).minY, accuracy: 0.5, "the line snaps to a window boundary")
        XCTAssertFalse(list.visualScroll.performDragOperation(noop), "dropping where the window was sends nothing")
        XCTAssertEqual(requests, [])
        hidden = list.visualRows
        let gap = try XCTUnwrap(hidden.firstIndex { $0.id == .gap(main) })
        let info = try drop(list, at: center(table, gap))
        XCTAssertEqual(list.visualScroll.draggingUpdated(info), .move)
        XCTAssertEqual(try XCTUnwrap(list.visualInsertion).midY, table.rect(ofRow: gap).minY, accuracy: 0.5)
        XCTAssertTrue(list.visualScroll.performDragOperation(info))
        let move = ReorderMove.window(main, group, relativeTo: last, .after)
        XCTAssertEqual(requests, [.reorder(move)])
        let moved = try XCTUnwrap(snapshot.reordered(move))
        list.tableView(table, draggingSession: drag.session, endedAt: .zero, operation: .move)
        XCTAssertEqual(list.visualRows.map(\.id), sidebarRows(moved).map(\.id), "the whole block moves, children included")

        sent[0].reply(.failure(.terminal("no such top-level window in session")))
        XCTAssertEqual(list.visualRows.map(\.id), rows.map(\.id), "a failure reverts to the latest snapshot")
        XCTAssertEqual(list.visualDiagnostic, "no such top-level window in session")
        XCTAssertNil(owner.reorder.state.pending)

        let reorderTimeout = WindowOwner.reorderTimeout
        defer { WindowOwner.reorderTimeout = reorderTimeout }
        try press(table, pane, drag: true)
        let again = try XCTUnwrap(table.visualDrag)
        list.tableView(table, draggingSession: again.session, willBeginAt: .zero, forRowIndexes: [pane])
        _ = list.visualScroll.draggingUpdated(try drop(list, at: center(table, 0)))
        let retry = try drop(list, at: center(table, gap))
        XCTAssertEqual(list.visualScroll.draggingUpdated(retry), .move)
        WindowOwner.reorderTimeout = 0.1
        XCTAssertTrue(list.visualScroll.performDragOperation(retry))
        list.tableView(table, draggingSession: again.session, endedAt: .zero, operation: .move)
        XCTAssertEqual(list.visualDiagnostic, "", "a new drop clears the old error")
        XCTAssertEqual(list.visualRows.map(\.id), sidebarRows(moved).map(\.id))
        try await wait("an unanswered drop times out") { owner.reorder.state.pending == nil }
        WindowOwner.reorderTimeout = reorderTimeout
        XCTAssertEqual(list.visualRows.map(\.id), rows.map(\.id))
        XCTAssertEqual(list.visualDiagnostic, "The server did not answer the reorder request")
        sent[1].reply(.success(.reordered))
        XCTAssertEqual(list.visualRows.map(\.id), rows.map(\.id), "a late reply is never replayed")
        XCTAssertEqual(requests.count, 2)
    }

    func testSidebarClickActivatesOnceAndDragsNever() async throws {
        let snapshot = try fixture()
        let owner = try owner(snapshot)
        let list = owner.sidebar.list, table = list.visualTable as! Table
        let row = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .pane(SessionID(number: 0), PaneID(number: 905)) })
        let target = try XCTUnwrap(list.visualRows[row].target)
        func jumps() -> Int { requests.filter { if case .jump = $0 { true } else { false } }.count }

        try press(table, row, drag: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests, [.jump(target)], "a click activates exactly once")
        sent[0].reply(.failure(.terminal("not this time")))

        let nested = try XCTUnwrap(list.visualRows.firstIndex { $0.indent > 0 && $0.target != nil })
        try press(table, nested, drag: true)
        XCTAssertNil(table.visualDrag, "a nested row is not a drag source")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(jumps(), 1, "a press that crosses the threshold is not a click")

        try press(table, row, drag: true)
        var drag = try XCTUnwrap(table.visualDrag)
        list.tableView(table, draggingSession: drag.session, willBeginAt: .zero, forRowIndexes: [row])
        list.tableView(table, draggingSession: drag.session, endedAt: .zero, operation: [])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(jumps(), 1, "a cancelled drag activates nothing")

        try press(table, row, drag: true)
        drag = try XCTUnwrap(table.visualDrag)
        list.tableView(table, draggingSession: drag.session, willBeginAt: .zero, forRowIndexes: [row])
        let header = try XCTUnwrap(list.visualRows.firstIndex { $0.id == .header(SessionID(number: 0)) })
        let info = try drop(list, at: center(table, header))
        XCTAssertEqual(list.visualScroll.draggingUpdated(info), .move)
        XCTAssertTrue(list.visualScroll.performDragOperation(info))
        list.tableView(table, draggingSession: drag.session, endedAt: .zero, operation: .move)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(jumps(), 1, "a successful drag activates nothing")
        XCTAssertEqual(requests.last, .reorder(.window(SessionID(number: 0), WindowID(number: 797), relativeTo: WindowID(number: 0), .before)))
    }

    func testTabDragReflowsAndCommitsOnce() async throws {
        let sidebar = Sidebar()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = sidebar
        let toolbar = NSToolbar(identifier: "ReorderTabs")
        toolbar.delegate = sidebar
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 900, height: 560))
        let root = try XCTUnwrap(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        sidebar.splitView.setPosition(236, ofDividerAt: 0)
        sidebar.viewDidLayout()
        let tabs = sidebar.tabs, reorder = Reorder()
        tabs.reorder = reorder
        sidebar.list.reorder = reorder
        sidebar.list.update(.running(try fixture()))
        let ids = (1...4).map { WindowID(number: $0) }
        tabs.entries = ids.map { SessionModel.Tab(id: $0, name: "Window \($0.number)", active: $0.number == 1, status: .quiet) }
        root.layoutSubtreeIfNeeded()
        tabs.layoutSubtreeIfNeeded()
        var moves: [String] = [], selected: [String] = [], added = 0
        tabs.scope = .init(session: SessionID(number: 0), generation: 1, instance: nil)
        tabs.move = { if case .window(_, let source, let anchor, let placement) = $0 { moves.append("\(source) \(placement) \(anchor)") } }
        tabs.select = { selected.append("\($0)") }
        tabs.addWindow.invoke = { added += 1 }
        let frame = window.frame
        let labels = ids.indices.map { tabs.labelRect($0) }
        let width = labels[1].minX - labels[0].minX
        func at(_ x: CGFloat, _ y: CGFloat = 18) -> NSPoint { tabs.convert(NSPoint(x: x, y: y), to: nil) }
        for index in ids.indices {
            let hit = root.hitTest(root.convert(at(labels[index].midX), from: nil))
            XCTAssertTrue(hit === tabs, "tab bodies hit the strip, never the titlebar")
        }
        XCTAssertFalse(tabs.mouseDownCanMoveWindow)
        XCTAssertTrue(root.hitTest(root.convert(at(tabs.bounds.maxX - 14), from: nil)) === tabs.addWindow)

        send(tabs, .leftMouseDown, labels[1].midX)
        XCTAssertEqual(selected, [], "a press alone selects nothing")
        send(tabs, .leftMouseUp, labels[1].midX)
        XCTAssertEqual(selected, ["number(2)"])

        send(tabs, .leftMouseDown, labels[0].midX)
        send(tabs, .leftMouseDragged, labels[0].midX + 3)
        XCTAssertEqual(tabs.labelRect(1), labels[1], "no reflow below the 4pt threshold")
        XCTAssertNil(reorder.gesture)
        send(tabs, .leftMouseDragged, labels[0].midX + 2 * width)
        XCTAssertEqual(reorder.gesture, .tab)
        XCTAssertEqual(tabs.labelRect(1).minX, labels[0].minX, accuracy: 0.5, "neighbours reflow live")
        XCTAssertEqual(tabs.labelRect(2).minX, labels[1].minX, accuracy: 0.5)
        XCTAssertEqual(tabs.labelRect(0).minX, labels[2].minX, accuracy: 0.5)
        XCTAssertTrue(tabs.closeButton.isHidden)
        XCTAssertFalse(reorder.claim(.sidebar), "one gesture at a time")
        XCTAssertNil(sidebar.list.tableView(sidebar.list.visualTable, pasteboardWriterForRow: 0))
        send(tabs, .leftMouseUp, labels[0].midX + 2 * width)
        XCTAssertEqual(moves, ["@1 before @4"])
        XCTAssertEqual(selected.count, 1, "a drag never selects")
        XCTAssertNil(reorder.gesture)
        XCTAssertEqual(tabs.labelRect(1), labels[1])
        XCTAssertNotNil(sidebar.list.tableView(sidebar.list.visualTable, pasteboardWriterForRow: 0))

        send(tabs, .leftMouseDown, labels[3].midX)
        send(tabs, .leftMouseDragged, labels[0].midX)
        XCTAssertEqual(tabs.labelRect(0).minX, labels[1].minX, accuracy: 0.5)
        NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!, atStart: false)
        try await wait("Escape cancels the tab drag") { reorder.gesture == nil }
        XCTAssertEqual(tabs.labelRect(0), labels[0])
        send(tabs, .leftMouseDragged, labels[1].midX)
        send(tabs, .leftMouseUp, labels[1].midX)

        send(tabs, .leftMouseDown, labels[1].midX)
        send(tabs, .leftMouseDragged, labels[3].midX)
        send(tabs, .leftMouseDragged, labels[3].midX, -40)
        XCTAssertEqual(tabs.labelRect(2), labels[2], "outside the strip the tabs fall back")
        send(tabs, .leftMouseUp, labels[3].midX, -40)
        send(tabs, .leftMouseDown, labels[2].midX)
        send(tabs, .leftMouseDragged, tabs.bounds.maxX - 14)
        send(tabs, .leftMouseUp, tabs.bounds.maxX - 14)
        XCTAssertEqual(moves.count, 1, "Escape or a drop outside the strip cancels")
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(added, 0, "a drag over + never triggers it")
        XCTAssertEqual(window.frame, frame, "a tab drag never moves the window")

        tabs.entries = (1...12).map { SessionModel.Tab(id: WindowID(number: $0), name: "Window \($0)", active: false, status: .quiet) }
        tabs.layoutSubtreeIfNeeded()
        let start = tabs.labelRect(0).minX
        let limit = 12 * (tabs.labelRect(1).minX - start) - (tabs.bounds.width - 28)
        XCTAssertGreaterThan(limit, 0, "twelve tabs overflow the strip")
        send(tabs, .leftMouseDown, tabs.labelRect(0).midX)
        send(tabs, .leftMouseDragged, tabs.bounds.maxX - 30)
        XCTAssertEqual(reorder.gesture, .tab)
        try await wait("edge autoscroll") { tabs.labelRect(1).minX < start - 50 }
        try await wait("autoscroll stops at the end") { abs(tabs.labelRect(1).minX - (start - limit)) < 0.5 }
        let settled = tabs.labelRect(1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(tabs.labelRect(1), settled, "autoscroll is bounded")
        send(tabs, .leftMouseUp, tabs.bounds.maxX - 30, -40)
        XCTAssertEqual(moves.count, 1)
        XCTAssertNil(reorder.gesture)
        XCTAssertFalse(window.isVisible || window.isKeyWindow || NSApp.isActive)
    }

    func testTabReflowSlidesWhileTargetsStayExact() async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); WindowTabs.visualReduceMotion = nil }
        WindowTabs.visualReduceMotion = false
        let tabs = WindowTabs(frame: NSRect(x: 0, y: 120, width: 700, height: 36))
        window.contentView!.addSubview(tabs)
        let ids = (1...4).map { WindowID(number: $0) }
        func entries(_ ids: [WindowID]) -> [SessionModel.Tab] { ids.map { .init(id: $0, name: "W\($0.number)", active: false, status: .quiet) } }
        tabs.entries = entries(ids)
        var moves: [String] = []
        tabs.scope = .init(session: SessionID(number: 0), generation: 1, instance: nil)
        tabs.move = { if case .window(_, let source, let anchor, let placement) = $0 { moves.append("\(source) \(placement) \(anchor)") } }
        let labels = ids.indices.map { tabs.labelRect($0) }
        let width = labels[1].minX - labels[0].minX
        // AppKit's animator stops while the display sleeps, so only the first slide is awaited, and only on an awake display.
        func settled() {
            tabs.visualFinishAnimation()
            for index in ids.indices { XCTAssertEqual(tabs.visualPresentedLabelRect(index), tabs.labelRect(index)) }
        }

        send(tabs, .leftMouseDown, labels[0].midX)
        send(tabs, .leftMouseDragged, labels[0].midX + width)
        XCTAssertTrue(tabs.visualAnimating, "the first drag step already slides the neighbour aside")
        XCTAssertEqual(tabs.labelRect(1).minX, labels[0].minX, accuracy: 0.5, "targets are the final layout while the slide runs")
        XCTAssertEqual(tabs.visualPresentedLabelRect(1).minX, labels[1].minX, accuracy: 0.5, "the drawn tab starts where it was")
        XCTAssertTrue(tabs.hitTest(tabs.superview!.convert(NSPoint(x: labels[0].midX, y: 18), from: tabs)) === tabs)
        send(tabs, .leftMouseUp, labels[0].midX + width)
        XCTAssertEqual(moves, ["@1 before @3"], "the drop uses the target layout, not the in-flight frames")
        XCTAssertTrue(tabs.visualAnimating, "the dropped tab settles into its slot")
        if CGDisplayIsAsleep(CGMainDisplayID()) == 0 { try await wait("animation ends") { !tabs.visualAnimating } }
        settled()

        send(tabs, .leftMouseDown, labels[3].midX)
        send(tabs, .leftMouseDragged, labels[1].midX)
        settled()
        tabs.animated { tabs.entries = entries([ids[0], ids[3], ids[1], ids[2]]) }
        XCTAssertFalse(tabs.visualAnimating, "a press without its drag is ended by the change")
        tabs.entries = entries(ids)
        send(tabs, .leftMouseDown, labels[3].midX)
        send(tabs, .leftMouseDragged, labels[3].midX - 10)
        send(tabs, .leftMouseDragged, labels[1].midX)
        settled()
        send(tabs, .leftMouseUp, labels[1].midX, -40)
        XCTAssertTrue(tabs.visualAnimating, "a cancel slides the tabs back")
        XCTAssertEqual(tabs.labelRect(1), labels[1])
        settled()

        tabs.animated { tabs.entries = entries([ids[1], ids[0], ids[2], ids[3]]) }
        XCTAssertTrue(tabs.visualAnimating, "a reorder revert slides")
        settled()
        tabs.entries = entries(ids)
        XCTAssertFalse(tabs.visualAnimating, "a snapshot update outside a drag is instant")
        tabs.animated { tabs.entries = entries(ids + [WindowID(number: 9)]) }
        XCTAssertFalse(tabs.visualAnimating, "added or removed tabs are instant")
        tabs.entries = entries(ids)

        WindowTabs.visualReduceMotion = true
        send(tabs, .leftMouseDown, labels[0].midX)
        send(tabs, .leftMouseDragged, labels[0].midX + 10)
        send(tabs, .leftMouseDragged, labels[0].midX + width)
        XCTAssertFalse(tabs.visualAnimating, "reduce motion jumps")
        XCTAssertEqual(tabs.visualPresentedLabelRect(1), tabs.labelRect(1))
        send(tabs, .leftMouseUp, labels[0].midX + width, -40)
        XCTAssertFalse(tabs.visualAnimating)
        XCTAssertEqual(moves.count, 1)
        XCTAssertFalse(window.isVisible || window.isKeyWindow || NSApp.isActive)
    }

    func testTabDragKeepsTheSessionItStartedIn() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tabs = WindowTabs(frame: NSRect(x: 0, y: 120, width: 700, height: 36))
        window.contentView!.addSubview(tabs)
        let reorder = Reorder()
        tabs.reorder = reorder
        let ids = (1...3).map { WindowID(number: $0) }
        tabs.entries = ids.map { .init(id: $0, name: "W\($0.number)", active: false, status: .quiet) }
        var moves: [String] = []
        tabs.move = { if case .window(let session, let source, let anchor, let placement) = $0 { moves.append("\(session) \(source) \(placement) \(anchor)") } }
        let labels = ids.indices.map { tabs.labelRect($0) }
        tabs.scope = .init(session: SessionID(number: 0), generation: 1, instance: nil)
        send(tabs, .leftMouseDown, labels[0].midX)
        send(tabs, .leftMouseDragged, labels[2].midX)
        tabs.scope = .init(session: SessionID(number: 1), generation: 1, instance: nil)
        XCTAssertNil(reorder.gesture, "a session switch cancels the drag")
        XCTAssertEqual(tabs.labelRect(0), labels[0], "the tabs restore")
        send(tabs, .leftMouseUp, labels[2].midX)
        XCTAssertEqual(moves, [], "a drop never reorders another session that links the window")

        send(tabs, .leftMouseDown, labels[0].midX)
        send(tabs, .leftMouseDragged, labels[2].midX)
        tabs.scope = .init(session: SessionID(number: 1), generation: 2, instance: nil)
        send(tabs, .leftMouseUp, labels[2].midX)
        XCTAssertEqual(moves, [], "a reconnect cancels the drag too")

        send(tabs, .leftMouseDown, labels[0].midX)
        send(tabs, .leftMouseDragged, labels[2].midX)
        send(tabs, .leftMouseUp, labels[2].midX)
        XCTAssertEqual(moves, ["$1 @1 after @3"], "an unchanged scope drops in the session it started in")
    }

    func testRemoteHostLabelAndEmptyTitlebarStillMoveTheWindow() throws {
        let owner = try owner(try fixture(), host: .remote("buildbox"))
        let tabs = owner.sidebar.tabs, window = owner.window!
        let root = try XCTUnwrap(window.contentView?.superview)
        tabs.entries = [SessionModel.Tab(id: WindowID(number: 1), name: "Only", active: true, status: .quiet)]
        root.layoutSubtreeIfNeeded()
        tabs.layoutSubtreeIfNeeded()
        let label = tabs.labelRect(0)
        for x in [4, label.maxX + 60] {
            let hit = try XCTUnwrap(root.hitTest(root.convert(tabs.convert(NSPoint(x: x, y: 18), to: nil), from: nil)))
            XCTAssertFalse(hit === tabs)
            XCTAssertTrue(hit.mouseDownCanMoveWindow, "\(x): \(hit)")
        }
        XCTAssertTrue(root.hitTest(root.convert(tabs.convert(NSPoint(x: label.midX, y: 18), to: nil), from: nil)) === tabs)
    }

    func testNavigationHidesUnknownNonCurrentWindows() throws {
        let snapshot = try fixture()
        var model = SessionModel(session: SessionID(number: 0),
                                 windows: [0, 786, 5].map { .init(id: WindowID(number: $0), name: "w\($0)") }, window: WindowID(number: 0))
        XCTAssertEqual(model.navigation(snapshot).tabs.map(\.id.number), [0])
        model.window = WindowID(number: 5)
        let navigation = model.navigation(snapshot)
        XCTAssertEqual(navigation.tabs.map(\.id.number), [0, 5])
        XCTAssertEqual(navigation.tabs.filter(\.active).map(\.id.number), [5])
        XCTAssertEqual(navigation.model.title, "Kido — w5")
        XCTAssertEqual(navigation.model.select(.number(2)), .selectWindow(SessionID(number: 0), WindowID(number: 5)))
        XCTAssertEqual(model.navigation(nil).tabs.map(\.id.number), [0, 786, 5])
    }

    func testNavigationFollowsProjectedRootOrder() throws {
        let snapshot = try fixture()
        let main = SessionID(number: 0)
        let model = SessionModel(sessions: [try XCTUnwrap(SessionListing("$1\u{1F}@11\u{1F}visa")), try XCTUnwrap(SessionListing("$0\u{1F}@0\u{1F}main"))],
                                 session: main,
                                 windows: [797, 0, 5, 458].map { .init(id: WindowID(number: $0), name: "w\($0)") }, window: WindowID(number: 0))
        let navigation = model.navigation(snapshot).model
        XCTAssertEqual(navigation.windows.map(\.id.number), [0, 458, 797], "snapshot roots order the tabs; an unreported non-current window is hidden")
        XCTAssertEqual(navigation.sessions.map(\.id), [main, SessionID(number: 1)])
        XCTAssertEqual(model.navigation(snapshot).tabs.map(\.id.number), [0, 458, 797])
        XCTAssertEqual(navigation.select(.number(1)), .selectWindow(main, WindowID(number: 0)))
        XCTAssertEqual(model.navigation(nil).model.windows.map(\.id.number), [797, 0, 5, 458], "inventory order before the first snapshot")

        var state = ReorderState()
        XCTAssertNotNil(state.submit(.window(main, WindowID(number: 797), relativeTo: WindowID(number: 0), .before), to: snapshot))
        let projected = model.navigation(state.project(snapshot)).model
        XCTAssertEqual(projected.windows.map(\.id.number), [797, 0, 458])
        let menus = SessionMenus()
        var sent: [RPCRequest] = []
        menus.send = { sent.append($0) }
        menus.update(projected)
        XCTAssertEqual(menus.window.items.dropFirst(3).map(\.title), ["w797", "w0", "w458"])
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
        XCTAssertTrue(menus.window.performKeyEquivalent(with: key))
        XCTAssertEqual(sent, [.selectWindow(main, WindowID(number: 797))], "Cmd-1 uses the projected order")
    }
}
