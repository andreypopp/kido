import AppKit
import SidebarFeed
import PaneGeometry
import KoModel

extension NSPasteboard.PasteboardType {
    static let kidoReorder = Self("com.andreypopp.kido.reorder")
}

final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private enum Source {
        case session(SessionID), window(SessionID, WindowID)
        var session: SessionID { switch self { case .session(let session), .window(let session, _): session } }
    }
    private struct DragItem: Codable, Equatable {
        var v = 1
        let owner: String
        let instance: String
        let session: String
        let window: String?
    }
    private final class DropScroll: NSScrollView {
        weak var list: SidebarView?
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { list?.dropUpdated(sender) ?? [] }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { list?.dropUpdated(sender) ?? [] }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { list?.insertion.isHidden = true }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { list?.dropPerformed(sender) ?? false }
    }
    private final class Insertion: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            Chrome.insertion.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2.75, y: bounds.midY - 2.75, width: 5.5, height: 5.5))
            ring.lineWidth = 1.5
            ring.stroke()
            NSRect(x: 8.5, y: bounds.midY - 1, width: max(0, bounds.width - 10.5), height: 2).fill()
        }
    }
    var reorder = Reorder()
    var move: (ReorderMove) -> Void = { _ in }
    private var dragging: Source?
    private struct DropTarget: Equatable { let row: Int; let move: ReorderMove? }
    private var validated: DropTarget??
    private var collapsed = false
    private var renderedCollapsed = false
    private var heldSelection: SidebarRow.ID?
    private let insertion = Insertion()
    private let dragOwner = UUID().uuidString
    var navigate: (Navigation, SelectionFocus) -> Void = { _, _ in }
    var selectRecord: (PaneID, String) -> Void = { _, _ in }
    var closeRecord: (PaneID, String) -> Void = { _, _ in }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var closeTimeout: TimeInterval = 5
    private var closing: [SidebarRow.ID: TimeInterval] = [:]
    private var closingTimer: Timer?
    var paneCommand: (PaneCommand, PaneID) -> Void = { _, _ in }
    var onIntent: () -> Void = {}
    var commandTarget: () -> PaneView? = { nil }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showRecord(_:)): recordRow(item)?.pick != nil
        case #selector(closeRecordItem(_:)): recordRow(item).map { $0.closing != nil && closing[$0.id] == nil } ?? false
        case #selector(runCommand(_:)):
            (window?.firstResponder === table || window?.firstResponder === runtimeSection) && commandTarget()?.validateMenuItem(item) == true
        default: false
        }
    }
    private func recordRow(_ item: NSMenuItem) -> SidebarRow? {
        (item.representedObject as? SidebarRow.ID).flatMap { id in items.first { $0.id == id } }
    }
    @objc func runCommand(_ sender: NSMenuItem) {
        guard window?.firstResponder === table || window?.firstResponder === runtimeSection, let pane = commandTarget() else { return }
        if case .close? = sender.representedObject as? PaneCommand, window?.firstResponder === table, closeSelectedRecord() { return }
        leave()
        pane.runCommand(sender)
    }
    var leave: () -> Void = {}
    private var rendering = false

    private var items: [SidebarRow] = []
    // A runtime's swatch takes its colour for the terminal's light or dark theme, not the sidebar's own.
    var terminalDark = false { didSet { if terminalDark != oldValue { table.reloadData() } } }
    private func entry(_ row: Int) -> SidebarRow? { items.indices.contains(row) ? items[row] : nil }

    var newSession: () -> Void = {}
    var newWindow: (SessionID) -> Void = { _ in }
    var closePane: (SidebarRow) -> Void = { _ in }
    var renameSession: (SessionID, String, @escaping @MainActor @Sendable (String?) -> Void) -> Void = { _, _, done in done("The control client is not ready.") }
    private var editing: (id: SidebarRow.ID, cell: SidebarCell, original: String, responder: NSResponder?)?
    private var renaming = false

    private func beginRename(_ item: SidebarRow, cell: SidebarCell) {
        guard editing == nil else { return }
        onIntent()
        editing = (item.id, cell, item.title, window?.firstResponder)
        renaming = true
        defer { renaming = false }
        cell.nameField.stringValue = item.title
        cell.nameField.isHidden = false
        cell.needsDisplay = true
        Sidebar.grantFocus(in: window) {
            window?.makeFirstResponder(cell.nameField)
            cell.nameField.selectText(nil)
        }
    }

    private func endRename() {
        guard let edit = editing else { return }
        editing = nil
        renaming = false
        edit.cell.nameField.isHidden = true
        edit.cell.renameError.isHidden = true
        edit.cell.needsDisplay = true
        if let row = items.firstIndex(where: { $0.id == edit.id }) {
            edit.cell.configure(items[row], now: clockNow, closing: isClosing(edit.id))
            resizeRows([row])
        }
        Sidebar.grantFocus(in: window) { window?.makeFirstResponder(edit.responder) }
    }

    private func resizeRows(_ rows: IndexSet) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: rows)
        }
    }

    private func rejectRename(_ message: String) {
        guard let edit = editing else { return }
        renaming = true
        defer { renaming = false }
        edit.cell.renameError.stringValue = message
        edit.cell.renameError.isHidden = false
        edit.cell.needsLayout = true
        if let row = items.firstIndex(where: { $0.id == edit.id }) {
            resizeRows([row])
        }
        edit.cell.needsDisplay = true
        window?.makeFirstResponder(edit.cell.nameField)
        edit.cell.nameField.selectText(nil)
        NSAccessibility.post(element: edit.cell.renameError, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func finishRename(_ commit: Bool) {
        guard let edit = editing, !renaming, !rendering else { return }
        guard commit else { endRename(); return }
        switch SessionName(edit.cell.nameField.stringValue, operation: .rename(edit.id.session, original: edit.original), sessions: snapshot?.sessions ?? []) {
        case .revert: endRename()
        case .reject(let message): rejectRename(message)
        case .accept(let name):
            renaming = true
            renameSession(edit.id.session, name) { [weak self, weak cell = edit.cell] error in
                guard let self, editing?.cell === cell else { return }
                if let error { rejectRename(error) } else { endRename() }
            }
        }
    }
    let runtimeSection = RuntimeSection()
    private let table = Table()
    private let scroll = DropScroll()
    private var snapshot: Snapshot?
    private var projection = PaneProjection(nil)
    private let fonts = SidebarFonts()
    private var captionTimer: Timer?
    private var tick: Timer?
    private var clockNow = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
        }
        updateTick()
    }

    @objc private func windowClosed() {
        tick?.invalidate()
        tick = nil
    }
    private var seededCaptions: SidebarCaptions?
    var captionDelay: TimeInterval = 0.2

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        runtimeSection.selection = nil
        super.mouseDown(with: event)
    }

    init() {
        super.init(frame: .zero)
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.headerView = nil
        table.style = .plain
        table.floatsGroupRows = false
        table.rowSizeStyle = .small
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.tableColumns[0].resizingMask = .autoresizingMask
        table.tableColumns[0].minWidth = 0
        table.autoresizingMask = [.width]
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.focusChanged = { [weak self] in self?.onIntent() }
        table.focusRingType = .none
        table.selectionHighlightStyle = .none
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        insertion.isHidden = true
        table.addSubview(insertion)
        scroll.focusRingType = .none
        scroll.list = self
        scroll.registerForDraggedTypes([.kidoReorder])
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: -8)
        for view in [scroll, runtimeSection] { addSubview(view) }
        runtimeSection.changed = { [weak self] in self?.needsLayout = true }
        runtimeSection.selected = { [weak self] in self?.table.deselectAll(nil) }
        runtimeSection.previous = { [weak self] in
            guard let self else { return }
            focus()
            if let last = items.lastIndex(where: { $0.clickTarget != nil }) {
                table.selectRowIndexes([last], byExtendingSelection: false)
                table.scrollRowToVisible(last)
            }
        }
        runtimeSection.leave = { [weak self] in self?.leave() }
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        table.needsDisplay = true
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = Chrome.floatingListHairline.cgColor
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let top = safeAreaInsets.top + 2
        let footer = runtimeSection.height
        runtimeSection.isHidden = footer == 0
        runtimeSection.frame = CGRect(x: 0, y: max(top, bounds.height - footer - 10), width: bounds.width, height: footer)
        runtimeSection.dark = terminalDark
        scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - 10 - footer))
        table.setFrameSize(NSSize(width: max(0, scroll.contentSize.width - 16), height: table.frame.height))
    }

    var position: Snapshot.Position? { snapshot?.client }

    var containsFocus: Bool {
        Sidebar.focusView(window?.firstResponder)?.isDescendant(of: self) == true
    }

    func show(_ next: Snapshot?, projection supplied: PaneProjection? = nil, pin: SidebarRow.ID? = nil, captionTick: Bool = false) {
        if !captionTick, pin == nil, renderedCollapsed == collapsed, next == snapshot, seededCaptions != nil || next == nil {
            snapshot = next
            return
        }
        renderedCollapsed = collapsed
        rendering = true
        defer { rendering = false }
        let editor = editing?.cell.nameField.currentEditor() as? NSTextView
        let selection = editor?.selectedRange()
        let selected = entry(table.selectedRow)?.id ?? heldSelection
        let origin = scroll.contentView.bounds.origin
        let first = pin.flatMap { id in items.firstIndex { $0.id == id } } ?? table.rows(in: table.visibleRect).location
        let anchor = first == NSNotFound ? nil : entry(first).map { ($0.id, origin.y - table.rect(ofRow: first).minY) }
        let recenter = dragging == nil && next.map { $0.client != snapshot?.client } ?? false
        let previousInstance = snapshot?.serverInstance
        projection = supplied ?? (next == snapshot ? projection : PaneProjection(next))
        snapshot = next
        clockNow = serverNow
        let previous = items
        if next == nil || next?.serverInstance != previousInstance { seededCaptions = nil }
        var renderedCaptions = seededCaptions ?? SidebarCaptions()
        items = renderedCaptions.apply(sidebarRows(snapshot), now: ProcessInfo.processInfo.systemUptime, delay: captionDelay)
        if next != nil, pin == nil || seededCaptions != nil { seededCaptions = renderedCaptions }
        captionTimer?.invalidate()
        captionTimer = nil
        if let deadline = renderedCaptions.deadline {
            let timer = Timer(timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime), target: self,
                              selector: #selector(captionsChanged), userInfo: nil, repeats: false)
            captionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if collapsed {
            switch dragging {
            case .session: items = items.filter { $0.kind == .header }
            case .window(let session, let window): items.removeAll { $0.id.session == session && $0.root == window }
            case nil: break
            }
        }
        items = sidebarDividers(items)
        if !closing.isEmpty {
            let present = Set(items.map(\.id))
            closing = closing.filter { present.contains($0.key) }
            scheduleClosingTimer()
        }
        if let edit = editing, !items.contains(where: { $0.id == edit.id }) { endRename() }
        if let edit = editing {
            if let row = items.first(where: { $0.id == edit.id }) {
                edit.cell.configure(row, now: clockNow, closing: isClosing(row.id))
            }
            let changes = items.map(\.id).difference(from: previous.map(\.id))
            table.beginUpdates()
            for change in changes {
                switch change {
                case .remove(let index, _, _): table.removeRows(at: [index], withAnimation: [])
                case .insert(let index, _, _): table.insertRows(at: [index], withAnimation: [])
                }
            }
            table.endUpdates()
            table.reloadData(forRowIndexes: IndexSet(items.indices.filter { index in
                items[index].id != editing?.id && previous.first(where: { $0.id == items[index].id }) != items[index]
            }), columnIndexes: [0])
            resizeRows(IndexSet(items.indices))
        } else if previous.map(\.id) == items.map(\.id) {
            table.reloadData(forRowIndexes: IndexSet(items.indices.filter { items[$0] != previous[$0] }), columnIndexes: [0])
            resizeRows(IndexSet(items.indices.filter { items[$0].height != previous[$0].height }))
        } else { table.reloadData() }
        if let edit = editing, let selection, window?.firstResponder !== editor {
            window?.makeFirstResponder(edit.cell.nameField)
            (edit.cell.nameField.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        }
        if let row = items.firstIndex(where: { recenter ? $0.target == next?.client : $0.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if recenter { table.scrollRowToVisible(row) }
        } else if let pane = (recenter ? next?.client.pane : previous.first { $0.id == selected }?.target?.pane), let row = visibleSidebarRow(for: pane, in: items, projection: projection) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        if !recenter {
            var y = anchor.flatMap { key, offset in items.firstIndex { $0.id == key }.map { table.rect(ofRow: $0).minY + offset } } ?? origin.y
            if pin != nil {
                let top = dragging == nil ? 0 : max(0, -y)
                if dragging != nil {
                    table.setFrameSize(NSSize(width: table.frame.width, height: max(table.frame.height, y + scroll.contentView.bounds.height)))
                }
                scroll.contentInsets.top = top
                y = min(max(y, -top), max(-top, table.frame.height - scroll.contentView.bounds.height))
            }
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateTick()
    }

    @objc private func captionsChanged() { show(snapshot, captionTick: true) }

    private var serverNow: Int {
        #if KIDO_VISUAL
        if let now = Self.visualNow { return now }
        #endif
        guard let clock = snapshot?.clock else { return 0 }
        return clock.now + Int(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) - clock.local
    }

    private func updateTick() {
        guard window != nil, !isHidden, items.contains(where: { $0.started != nil }) else {
            tick?.invalidate()
            tick = nil
            return
        }
        guard tick == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticked() }
        }
        let delay = 1 - Double(serverNow % 1_000_000_000) / 1e9
        RunLoop.main.add(timer, forMode: .common)
        timer.fireDate = Date(timeIntervalSinceNow: delay)
        tick = timer
    }

    private func ticked() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        clockNow = serverNow
        for row in visible.location..<min(table.numberOfRows, NSMaxRange(visible)) where entry(row)?.started != nil {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.updateClock(now: clockNow)
        }
    }
    func focus() {
        onIntent()
        table.keyboardSelection = true
        if table.selectedRow < 0, let pane = snapshot?.client.pane,
            let index = visibleSidebarRow(for: pane, in: items, projection: projection)
        {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        window?.makeFirstResponder(table)
        table.scrollRowToVisible(table.selectedRow)
    }

    private func move(_ delta: Int) {
        var i = table.selectedRow
        repeat { i += delta } while i >= 0 && i < table.numberOfRows && entry(i)?.clickTarget == nil
        if i >= table.numberOfRows, runtimeSection.height > 0 {
            table.deselectAll(nil)
            runtimeSection.selection = .header
            window?.makeFirstResponder(runtimeSection)
            return
        }
        guard i >= 0, i < table.numberOfRows else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    func press(_ id: SidebarRow.ID) {
        if let index = items.firstIndex(where: { $0.id == id }) { activate(index, focus: .pane) }
    }

    fileprivate func activate(_ index: Int, focus: SelectionFocus) {
        guard let row = entry(index), let target = row.clickTarget else { return }
        navigate(.jump(target), focus)
        if let pick = row.rootPick ?? row.pick { selectRecord(pick.pane.pane, pick.record) }
    }

    func isClosing(_ id: SidebarRow.ID) -> Bool { closing[id] != nil }

    func beginClosing(_ row: SidebarRow) {
        guard let pick = row.closing, closing[row.id] == nil else { return }
        closing[row.id] = uptime() + closeTimeout
        reloadRow(row.id)
        scheduleClosingTimer()
        closeRecord(pick.pane.pane, pick.record)
    }

    func expireClosing() {
        let now = uptime()
        let expired = closing.filter { $0.value <= now }.keys
        for id in expired { closing[id] = nil }
        for id in expired { reloadRow(id) }
        scheduleClosingTimer()
    }

    private func scheduleClosingTimer() {
        closingTimer?.invalidate()
        closingTimer = nil
        guard let deadline = closing.values.min() else { return }
        let timer = Timer(timeInterval: max(0, deadline - uptime()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireClosing() }
        }
        closingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func reloadRow(_ id: SidebarRow.ID) {
        if let index = items.firstIndex(where: { $0.id == id }) { table.reloadData(forRowIndexes: [index], columnIndexes: [0]) }
    }

    // True when the selected row is a record row, which swallows the key whether or not the record closes.
    private func closeSelectedRecord() -> Bool {
        guard let row = entry(table.selectedRow), case .program = row.kind else { return false }
        beginClosing(row)
        return true
    }

    fileprivate func menu(forRowAt index: Int) -> NSMenu? {
        guard let row = entry(index), case .program = row.kind, row.pick != nil || row.closing != nil else { return nil }
        let menu = NSMenu()
        if row.pick != nil {
            let item = menu.addItem(withTitle: "Show", action: #selector(showRecord(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
        }
        if row.closing != nil {
            let item = menu.addItem(withTitle: "Close", action: #selector(closeRecordItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
        }
        return menu
    }

    @objc private func showRecord(_ item: NSMenuItem) {
        if let row = recordRow(item), let index = items.firstIndex(where: { $0.id == row.id }) { activate(index, focus: .pane) }
    }

    @objc private func closeRecordItem(_ item: NSMenuItem) {
        if let row = recordRow(item) { beginClosing(row) }
    }

    func select(_ target: Snapshot.Position) {
        if let index = visibleSidebarRow(for: target.pane, in: items, projection: projection) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
    }

    func refresh() { show(snapshot) }
    func resetCaptions() { seededCaptions = nil }

    fileprivate func key(_ event: NSEvent) -> Bool {
        guard editing == nil else { return true }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch (Int(event.keyCode), event.charactersIgnoringModifiers ?? "", mods) {
        case (125, _, []), (_, "j", []), (_, "n", .control): move(1)
        case (126, _, []), (_, "k", []), (_, "p", .control): move(-1)
        case (36, _, []), (76, _, []): activate(table.selectedRow, focus: .pane)
        case (51, _, []), (117, _, []): return closeSelectedRecord()
        case (53, _, []):
            navigate(.releaseSideFocus, .pane)
        default: return false
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !rendering { runtimeSection.selection = nil; onIntent() }
    }

    private func source(_ row: SidebarRow) -> Source? {
        switch row.kind {
        case .header: .session(row.id.session)
        case .pane where row.topLevel != nil: row.root.map { .window(row.id.session, $0) }
        default: nil
        }
    }

    private func dragItem(_ source: Source) -> DragItem? {
        guard let instance = snapshot?.serverInstance else { return nil }
        let window: String? = if case .window(_, let window) = source { window.description } else { nil }
        return DragItem(owner: dragOwner, instance: instance.description, session: source.session.description, window: window)
    }

    private func blockRows(_ session: SessionID, _ root: WindowID) -> Range<Int> {
        let start = items.firstIndex { $0.id.session == session && $0.root == root } ?? 0
        return start..<(items.lastIndex { $0.id.session == session && $0.root == root }.map { $0 + 1 } ?? start)
    }

    private func dropTarget(_ info: any NSDraggingInfo) -> DropTarget? {
        guard let dragging, !items.isEmpty, let data = info.draggingPasteboard.data(forType: .kidoReorder),
              let item = try? JSONDecoder().decode(DragItem.self, from: data), item == dragItem(dragging) else { return nil }
        let y = table.convert(info.draggingLocation, from: nil).y
        let hit = table.row(at: NSPoint(x: table.bounds.midX, y: y)), above = y < table.rect(ofRow: 0).minY
        switch dragging {
        case .session(let source):
            let slot = hit >= 0 ? (y < table.rect(ofRow: hit).midY ? hit : hit + 1) : above ? 0 : items.count
            return DropTarget(row: slot, move: ReorderMove.placing(source, at: slot, in: items.map(\.id.session)).map { .session(source, relativeTo: $0.anchor, $0.placement) })
        case .window(let session, let source):
            let below = hit >= 0 ? hit : above ? 0 : items.count - 1
            guard items[below].id.session == session else { return nil }
            var roots: [WindowID] = []
            for item in items where item.id.session == session {
                if let root = item.root, roots.last != root { roots.append(root) }
            }
            let row: Int, slot: Int
            if let root = items[below].root, let at = roots.firstIndex(of: root) {
                let block = blockRows(session, root)
                let above = y < (table.rect(ofRow: block.lowerBound).minY + table.rect(ofRow: block.upperBound - 1).maxY) / 2
                (row, slot) = above ? (block.lowerBound, at) : (block.upperBound, at + 1)
            } else if case .divider(_, let following) = items[below].id, let at = roots.firstIndex(of: following) {
                (row, slot) = (below, at)
            } else if case .header = items[below].kind {
                (row, slot) = (roots.first.map { blockRows(session, $0).lowerBound } ?? below + 1, 0)
            } else { (row, slot) = (roots.last.map { blockRows(session, $0).upperBound } ?? below, roots.count) }
            let all = snapshot?.sessions.first { $0.id == session }?.nodes.map(\.window) ?? roots
            let at = slot < roots.count ? all.firstIndex(of: roots[slot]) ?? all.count : all.count
            return DropTarget(row: row, move: ReorderMove.placing(source, at: at, in: all).map { .window(session, source, relativeTo: $0.anchor, $0.placement) })
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard editing == nil, reorder.gesture == nil, reorder.state.pending == nil, let source = entry(row).flatMap(source),
              let data = try? JSONEncoder().encode(dragItem(source)) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: .kidoReorder)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard let row = rowIndexes.first.flatMap(entry), let source = source(row), reorder.claim(.sidebar) else {
            return debug("drag begin refused rows=\(Array(rowIndexes)) row=\(rowIndexes.first.flatMap(entry).map { "\($0.id)" } ?? "-") gesture=\(String(describing: reorder.gesture))")
        }
        dragging = source
        validated = nil
        heldSelection = entry(table.selectedRow)?.id
        debug("drag begin row=\(rowIndexes.first!) \(row.id)")
    }

    fileprivate func dragImage(_ items: [NSDraggingItem]) {
        for item in items {
            let row = table.row(at: NSPoint(x: item.draggingFrame.midX, y: item.draggingFrame.midY))
            guard let source = entry(row).flatMap(source) else { continue }
            let rows = switch source {
            case .session: row..<row + 1
            case .window(let session, let window): blockRows(session, window)
            }
            let frame = table.rect(ofRow: rows.lowerBound).union(table.rect(ofRow: rows.upperBound - 1))
            guard let bitmap = table.bitmapImageRepForCachingDisplay(in: frame) else { continue }
            table.cacheDisplay(in: frame, to: bitmap)
            let image = NSImage(size: frame.size)
            image.addRepresentation(bitmap)
            item.setDraggingFrame(frame, contents: image)
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        insertion.isHidden = true
        guard let source = dragging else { return debug("drag end operation=\(operation.rawValue) without a drag") }
        dragging = nil
        reorder.release(.sidebar)
        if collapsed {
            collapsed = false
            if case .session(let session) = source { show(snapshot, pin: .header(session)) } else { show(snapshot) }
        }
        heldSelection = nil
        debug("drag end operation=\(operation.rawValue) restored rows=\(items.count)")
    }

    private func dropUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
        if !collapsed, let dragging {
            collapsed = true
            if case .session(let session) = dragging { show(snapshot, pin: .header(session)) } else { show(snapshot) }
            debug("drag collapsed rows=\(items.count) inset=\(scroll.contentInsets.top)")
        }
        let clip = scroll.contentView, point = clip.convert(info.draggingLocation, from: nil)
        let step: CGFloat = point.y < clip.bounds.minY + 24 ? -8 : point.y > clip.bounds.maxY - 24 ? 8 : 0
        let y = min(max(clip.bounds.minY + step, -scroll.contentInsets.top), max(-scroll.contentInsets.top, table.frame.height - clip.bounds.height))
        if dragging != nil, y != clip.bounds.minY {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        let target = dropTarget(info)
        if debugging, validated != .some(target) {
            validated = target
            debug("drag validate y=\(Int(table.convert(info.draggingLocation, from: nil).y)) -> \(target.map { "move row=\($0.row) \($0.move.map { "\($0)" } ?? "no-op")" } ?? "none")")
        }
        guard let target else {
            insertion.isHidden = true
            if dragging != nil { NSCursor.operationNotAllowed.set() }
            return []
        }
        let line = target.row < items.count ? table.rect(ofRow: target.row).minY : table.rect(ofRow: items.count - 1).maxY
        insertion.frame = NSRect(x: 0, y: line - 4, width: table.bounds.width, height: 8)
        insertion.isHidden = false
        table.addSubview(insertion, positioned: .above, relativeTo: nil)
        return .move
    }

    private func dropPerformed(_ info: any NSDraggingInfo) -> Bool {
        insertion.isHidden = true
        let target = dropTarget(info)
        debug("drag accept y=\(Int(table.convert(info.draggingLocation, from: nil).y)) -> \(target.map { "row=\($0.row) \($0.move.map { "\($0)" } ?? "no-op")" } ?? "none")")
        guard let move = target?.move else { return false }
        self.move(move)
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items[row].height + (items[row].id == editing?.id ? editing!.cell.errorHeight : 0)
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].clickTarget != nil }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarSelectionRow ?? SidebarSelectionRow()
        view.identifier = id
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        if item.id == editing?.id { return editing?.cell }
        let reused = tableView.makeView(withIdentifier: SidebarCell.id, owner: nil) as? SidebarCell
        let cell = reused === editing?.cell ? SidebarCell(fonts) : reused ?? SidebarCell(fonts)
        cell.beginRename = { [weak self, weak cell] in
            guard let self, let cell, let current = items.first(where: { $0.id == item.id }) else { return }
            beginRename(current, cell: cell)
        }
        cell.press = { [weak self] in self?.press(item.id) }
        cell.finishRename = { [weak self] in self?.finishRename($0) }
        cell.renameChanged = { [weak self, weak cell] in
            guard let self, let cell, editing?.cell === cell else { return }
            cell.renameError.isHidden = true
            if let index = items.firstIndex(where: { $0.id == editing?.id }) {
                resizeRows([index])
            }
        }
        cell.terminalDark = terminalDark
        cell.configure(item, now: clockNow, closing: isClosing(item.id))
        cell.close.invoke = { [weak self] in if item.target != nil { self?.closePane(item) } else { self?.beginClosing(item) } }
        cell.addWindow.invoke = { [weak self] in self?.newWindow(item.id.session) }
        return cell
    }

    #if KIDO_STRESS
    var stressRows: [SidebarRow] { items }
    #endif

    #if KIDO_VISUAL
    static var visualNow: Int?
    var visualTable: NSTableView { table }
    var visualScroll: NSScrollView { scroll }
    var visualRows: [SidebarRow] { items }
    func visualJump(_ row: SidebarRow) { activate(items.firstIndex { $0.id == row.id } ?? -1, focus: .pane) }
    var visualDragging: String? { dragging.map { "\($0)" } }
    var visualInsertion: NSRect? { insertion.isHidden ? nil : insertion.frame }
    override func draw(_ dirtyRect: NSRect) {
        (layer?.backgroundColor.flatMap { NSColor(cgColor: $0) } ?? Chrome.defaultPaper).setFill() // chrome-allow: visual-only layer colour conversion
        bounds.fill()
    }
    #endif
}

final class Table: NSTableView {
    var focusChanged: () -> Void = {}
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { redrawCells(); focusChanged() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { redrawCells(); focusChanged() }
        return accepted
    }
    var keyboardSelection = false {
        didSet { redrawCells() }
    }
    private func redrawCells() {
        enumerateAvailableRowViews { row, _ in row.subviews.forEach { $0.needsDisplay = true } }
    }
    override var acceptsFirstResponder: Bool { Sidebar.allowsFirstResponder(self, in: window) && super.acceptsFirstResponder }
    override func mouseDown(with event: NSEvent) {
        keyboardSelection = false
        super.mouseDown(with: event)
        guard let up = NSApp.currentEvent, up.type == .leftMouseUp,
              hypot(up.locationInWindow.x - event.locationInWindow.x, up.locationInWindow.y - event.locationInWindow.y) < 4 else { return }
        guard let sidebar = delegate as? SidebarView else { return }
        sidebar.activate(row(at: convert(event.locationInWindow, from: nil)), focus: sidebar.containsFocus ? .sidebar : .pane)
    }
    override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource) -> NSDraggingSession {
        (delegate as? SidebarView)?.dragImage(items)
        #if KIDO_VISUAL
        let session = NSDraggingSession.perform(NSSelectorFromString("new")).takeRetainedValue() as! NSDraggingSession
        visualDrag = (items, session, source)
        return session
        #else
        return super.beginDraggingSession(with: items, event: event, source: source)
        #endif
    }
    #if KIDO_VISUAL
    private(set) var visualDrag: (items: [NSDraggingItem], session: NSDraggingSession, source: any NSDraggingSource)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    #endif
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect { rect(ofRow: row) }
    override func menu(for event: NSEvent) -> NSMenu? {
        (delegate as? SidebarView)?.menu(forRowAt: row(at: convert(event.locationInWindow, from: nil))) ?? super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        keyboardSelection = true
        if (delegate as? SidebarView)?.key(event) != true { super.keyDown(with: event) }
    }
}
