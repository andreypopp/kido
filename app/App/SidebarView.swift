import AppKit
import SidebarFeed
import TmuxControl

final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var navigate: (RPCRequest) -> Void = { _ in }
    var onIntent: () -> Void = {}
    var leave: () -> Void = {}
    private var rendering = false

    private var items: [SidebarRow] = []
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
        window?.makeFirstResponder(cell.nameField)
        cell.nameField.selectText(nil)
    }

    private func endRename() {
        guard let edit = editing else { return }
        editing = nil
        renaming = false
        edit.cell.nameField.isHidden = true
        edit.cell.renameError.isHidden = true
        edit.cell.needsDisplay = true
        if let row = items.firstIndex(where: { $0.id == edit.id }) {
            edit.cell.configure(items[row])
            resizeRows([row])
        }
        window?.makeFirstResponder(edit.responder)
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
        switch SessionRename(edit.cell.nameField.stringValue, session: edit.id.session, original: edit.original, sessions: snapshot?.sessions ?? []) {
        case .revert: endRename()
        case .reject(let message): rejectRename(message)
        case .rename(let name):
            renaming = true
            renameSession(edit.id.session, name) { [weak self, weak cell = edit.cell] error in
                guard let self, editing?.cell === cell else { return }
                if let error { rejectRename(error) } else { endRename() }
            }
        }
    }
    private let search = NSSearchField()
    private let table = Table()
    private let scroll = NSScrollView()
    private let statusLine = NSTextField(labelWithString: "")
    private let noMatches = NSTextField(labelWithString: "No matches")
    private var snapshot: Snapshot?
    var seen = SeenRecord()
    private var renderedSeen = SidebarSeen()
    private var renderedQuery = ""
    private var feedNote: (String, NSColor)?
    private var failure: String?
    private var visibleSnapshot: Snapshot? { sidebarSearch(snapshot, query: query) }
    private let fonts = SidebarFonts()
    private var tick: Timer?

    override var isFlipped: Bool { true }

    override var isHidden: Bool {
        didSet { updateTick() }
    }

    init() {
        super.init(frame: .zero)
        search.placeholderString = "Filter"
        search.controlSize = .small
        search.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        search.delegate = self
        search.target = self
        search.action = #selector(searched)
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
        table.target = self
        table.action = #selector(clicked)
        table.focusRingType = .none
        table.selectionHighlightStyle = .none
        scroll.focusRingType = .none
        search.focusRingType = .none
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        statusLine.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLine.isSelectable = true
        statusLine.lineBreakMode = .byTruncatingTail
        statusLine.maximumNumberOfLines = 1
        noMatches.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noMatches.textColor = .secondaryLabelColor
        noMatches.isHidden = true
        search.isHidden = true
        for view in [search, scroll, statusLine, noMatches] { addSubview(view) }
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 16
        search.frame = CGRect(x: 8, y: safeAreaInsets.top + 2, width: inner, height: search.isHidden ? 0 : search.fittingSize.height)
        let note: CGFloat = statusLine.isHidden ? 0 : 16
        statusLine.frame = CGRect(x: 8, y: search.frame.maxY, width: inner, height: note)
        let top = search.frame.maxY + note
        scroll.frame = CGRect(x: 8, y: top, width: inner, height: max(0, bounds.height - top - 10))
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        noMatches.frame = CGRect(x: 10, y: top + 4, width: inner, height: noMatches.fittingSize.height)
    }

    func update(_ status: Feed.Status) {
        switch status {
        case .invalidBundle, .protocolMismatch: break
        case .starting:
            show(nil)
            feedNote = ("Starting…", .secondaryLabelColor)
        case .restarting(let message):
            feedNote = ("The sidebar feed is not running, retrying…\n\(message)", .secondaryLabelColor)
        case .running(let snapshot):
            feedNote = nil
            show(snapshot)
        }
        noteChanged()
    }

    func offline(_ reason: String) {
        show(nil)
        feedNote = (reason, .secondaryLabelColor)
        noteChanged()
    }

    var position: Snapshot.Position? { snapshot?.client }

    var query: String { search.stringValue }
    var containsFocus: Bool {
        guard let focused = window?.firstResponder else { return false }
        return focused === search.currentEditor() || (focused as? NSView)?.isDescendant(of: self) == true
    }

    func failed(_ message: String?) {
        failure = message
        noteChanged()
    }

    private func noteChanged() {
        let note = failure.map { ($0, NSColor.systemRed) } ?? feedNote ?? snapshot?.error.map { ($0, NSColor.systemRed) }
        statusLine.stringValue = note?.0.replacingOccurrences(of: "\n", with: " ") ?? ""
        statusLine.toolTip = note?.0
        statusLine.textColor = note?.1
        statusLine.isHidden = note == nil
        needsLayout = true
    }

    private func show(_ next: Snapshot?) {
        if renderedQuery == query, renderedSeen == seen.value, next.map({ snapshot?.sameSidebarContent(as: $0) == true }) ?? (snapshot == nil) {
            snapshot = next
            return
        }
        renderedQuery = query
        renderedSeen = seen.value
        rendering = true
        defer { rendering = false }
        let editor = editing?.cell.nameField.currentEditor() as? NSTextView
        let selection = editor?.selectedRange()
        let selected = entry(table.selectedRow)?.id
        let origin = scroll.contentView.bounds.origin
        let first = table.rows(in: table.visibleRect).location
        let anchor = first == NSNotFound ? nil : entry(first).map { ($0.id, origin.y - table.rect(ofRow: first).minY) }
        let recenter = next.map { $0.client != snapshot?.client } ?? false
        snapshot = next
        let visible = visibleSnapshot
        noMatches.isHidden = query.isEmpty || visible?.sessions.isEmpty != true
        let previous = items
        items = sidebarRows(visible, seen: seen.value)
        if let edit = editing, !items.contains(where: { $0.id == edit.id }) { endRename() }
        if editing != nil {
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
        } else if previous.map(\.id) == items.map(\.id), previous.map(\.height) == items.map(\.height) {
            table.reloadData(forRowIndexes: IndexSet(items.indices.filter { items[$0] != previous[$0] }), columnIndexes: [0])
        } else { table.reloadData() }
        if let edit = editing, let selection, window?.firstResponder !== editor {
            window?.makeFirstResponder(edit.cell.nameField)
            (edit.cell.nameField.currentEditor() as? NSTextView)?.setSelectedRange(selection)
        }
        if let row = items.firstIndex(where: { recenter ? $0.target == next?.client : $0.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if recenter { table.scrollRowToVisible(row) }
        } else { table.deselectAll(nil) }
        if !recenter {
            let y = anchor.flatMap { key, offset in items.firstIndex { $0.id == key }.map { table.rect(ofRow: $0).minY + offset } } ?? origin.y
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateTick()
    }

    private var startedRows: IndexSet {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return [] }
        return IndexSet((visible.location..<min(table.numberOfRows, NSMaxRange(visible))).filter {
            return entry($0)?.started != nil
        })
    }

    private func updateTick() {
        guard !isHidden, items.contains(where: { $0.started != nil }) else {
            tick?.invalidate()
            tick = nil
            return
        }
        guard tick == nil else { return }
        let delay = 1 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(ticked), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        timer.fireDate = Date(timeIntervalSinceNow: delay)
        tick = timer
    }

    @objc private func ticked() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        let rows = startedRows
        guard !rows.isEmpty else { return updateTick() }
        for row in rows { (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.updateClock() }
    }

    private func activate() {
        if table.selectedRow >= 0 { jump(table.selectedRow) }
        else if let target = items.lazy.compactMap(\.target).first { jump(target) }
    }

    func focus() {
        onIntent()
        table.keyboardSelection = true
        if table.selectedRow < 0, let current = snapshot?.client,
            let index = items.firstIndex(where: { $0.target == current })
        {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        window?.makeFirstResponder(table)
        table.scrollRowToVisible(table.selectedRow)
    }

    private func jump(_ row: SidebarRow) {
        guard let target = row.target else { return }
        jump(target)
    }

    private func move(_ delta: Int) {
        var i = table.selectedRow
        repeat { i += delta } while i >= 0 && i < table.numberOfRows && entry(i)?.target == nil
        guard i >= 0, i < table.numberOfRows else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func jump(_ index: Int) {
        guard let row = entry(index) else { return }
        jump(row)
    }

    private func jump(_ target: Snapshot.Position) { navigate(.jump(target)) }

    func select(_ target: Snapshot.Position) {
        if let index = items.firstIndex(where: { $0.target == target }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
    }

    func completedActivation() {
        search.stringValue = ""
        search.isHidden = true
        needsLayout = true
        show(snapshot)
        leave()
    }

    @objc private func clicked() {
        guard let row = entry(table.clickedRow) else { return }
        jump(row)
    }

    @objc private func searched() { show(snapshot) }

    func refresh() { show(snapshot) }

    fileprivate func key(_ event: NSEvent) -> Bool {
        guard editing == nil else { return true }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch (Int(event.keyCode), event.charactersIgnoringModifiers ?? "", mods) {
        case (125, _, []), (_, "j", []), (_, "n", .control): move(1)
        case (126, _, []), (_, "k", []), (_, "p", .control): move(-1)
        case (36, _, []), (76, _, []): jump(table.selectedRow)
        case (53, _, []):
            navigate(.releaseSideFocus)
        case (_, "/", []):
            onIntent()
            search.isHidden = false
            needsLayout = true
            layoutSubtreeIfNeeded()
            window?.makeFirstResponder(search)
        default: return false
        }
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveDown(_:)):
            focus()
            move(table.selectedRow < 0 ? 1 : 0)
        case #selector(insertNewline(_:)):
            show(snapshot)
            activate()
        case #selector(cancelOperation(_:)):
            onIntent()
            search.stringValue = ""
            show(snapshot)
            search.isHidden = true
            needsLayout = true
            focus()
        default:
            return false
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !rendering { onIntent() }
    }

    func controlTextDidChange(_ notification: Notification) { onIntent(); show(snapshot) }
    func controlTextDidBeginEditing(_ notification: Notification) { onIntent() }
    func controlTextDidEndEditing(_ notification: Notification) { onIntent() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items[row].height + (items[row].id == editing?.id ? editing!.cell.errorHeight : 0)
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].target != nil }
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
        cell.finishRename = { [weak self] in self?.finishRename($0) }
        cell.renameChanged = { [weak self, weak cell] in
            guard let self, let cell, editing?.cell === cell else { return }
            cell.renameError.isHidden = true
            if let index = items.firstIndex(where: { $0.id == editing?.id }) {
                resizeRows([index])
            }
        }
        cell.configure(item)
        cell.close.invoke = { [weak self] in self?.closePane(item) }
        cell.addWindow.invoke = { [weak self] in self?.newWindow(item.id.session) }
        return cell
    }

    #if KIDO_VISUAL
    static var visualNow: Date?
    var visualTable: NSTableView { table }
    var visualScroll: NSScrollView { scroll }
    var visualRows: [SidebarRow] { items }
    var visualSearch: NSSearchField { search }
    var visualDiagnostic: String { statusLine.stringValue }
    func visualJump(_ row: SidebarRow) { jump(row) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
    #endif
}

@MainActor final class SeenRecord {
    var value = SidebarSeen()
}

final class Table: NSTableView {
    var focusChanged: () -> Void = {}
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged() }
        return accepted
    }
    var keyboardSelection = false {
        didSet { enumerateAvailableRowViews { row, _ in row.subviews.forEach { $0.needsDisplay = true } } }
    }
    override func mouseDown(with event: NSEvent) {
        keyboardSelection = false
        super.mouseDown(with: event)
    }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect { rect(ofRow: row) }
    override func keyDown(with event: NSEvent) {
        keyboardSelection = true
        if (delegate as? SidebarView)?.key(event) != true { super.keyDown(with: event) }
    }
}
