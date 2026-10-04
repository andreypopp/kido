import AppKit
import SidebarFeed
import TmuxControl

final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var send: ([Command], @escaping @MainActor @Sendable ([Reply]?) -> Void) -> Void = { $1(nil) }
    var filter: (String) -> Void = { _ in }
    var leave: () -> Void = {}

    private var items: [SidebarRow] = []
    private var folded: Set<SessionID> = []
    private var revealingWindow = false
    private func entry(_ row: Int) -> SidebarRow? { items.indices.contains(row) ? items[row] : nil }

    var newSession: () -> Void = {}
    var newWindow: (SessionID) -> Void = { _ in }
    private let search = NSSearchField()
    private let table = Table()
    private let scroll = NSScrollView()
    private let statusLine = NSTextField(labelWithString: "")
    private let noMatches = NSTextField(labelWithString: "No matches")
    private var snapshot: Snapshot?
    private var feedNote: (String, NSColor)?
    private var failure: String?
    private var activating: String?
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
        table.target = self
        table.action = #selector(clicked)
        table.focusRingType = .none
        table.selectionHighlightStyle = .none
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
        search.isHidden = true
        for view in [search, scroll, statusLine, noMatches] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
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
        search.frame = CGRect(x: 8, y: max(44, safeAreaInsets.top) + 2, width: inner, height: search.isHidden ? 0 : search.fittingSize.height)
        let note: CGFloat = statusLine.isHidden ? 0 : 16
        statusLine.frame = CGRect(x: 8, y: search.frame.maxY, width: inner, height: note)
        let top = search.frame.maxY + note
        scroll.frame = CGRect(x: 8, y: top, width: inner, height: max(0, bounds.height - top - 10))
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        noMatches.frame = CGRect(x: 10, y: top + 4, width: inner, height: noMatches.fittingSize.height)
    }

    func update(_ status: Feed.Status) {
        switch status {
        case .starting:
            show(nil)
            feedNote = ("Starting…", .secondaryLabelColor)
        case .restarting(let message):
            feedNote = ("The sidebar feed is not running, retrying…\n\(message)", .secondaryLabelColor)
        case .unreadable:
            feedNote = ("The sidebar feed sent a snapshot this app cannot read.", .systemRed)
        case .running(let snapshot):
            feedNote = nil
            if snapshot != self.snapshot { show(snapshot) }
        }
        noteChanged()
    }

    func offline(_ reason: String) {
        show(nil)
        feedNote = (reason, .secondaryLabelColor)
        noteChanged()
    }

    var query: String { search.stringValue }
    var containsFocus: Bool {
        guard let focused = window?.firstResponder else { return false }
        return focused === search.currentEditor() || (focused as? NSView)?.isDescendant(of: self) == true
    }

    func failed(_ message: String?) {
        if message != nil { revealingWindow = false }
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
        let selected = entry(table.selectedRow)?.id
        let origin = scroll.contentView.bounds.origin
        let first = table.rows(in: table.visibleRect).location
        let anchor = first == NSNotFound ? nil : entry(first).map { ($0.id, origin.y - table.rect(ofRow: first).minY) }
        let cleared = next?.filter.isEmpty == true && snapshot?.filter.isEmpty == false
        let recenter = cleared || next.map { $0.client != snapshot?.client } ?? false
        let oldClient = snapshot?.client
        snapshot = next
        noMatches.isHidden = next.map { $0.filter.isEmpty || !$0.sessions.isEmpty } ?? true
        if revealingWindow, next?.client != oldClient, let session = next?.client.session {
            folded.remove(session)
            revealingWindow = false
        }
        items = sidebarRows(next, folded: folded)
        table.reloadData()
        let follow = recenter ? items.first { $0.target == next?.client } : items.first { $0.id == selected }
        if let follow {
            let row = items.firstIndex { $0.id == follow.id }!
            table.selectRowIndexes([row], byExtendingSelection: false)
            if recenter { table.scrollRowToVisible(row) }
        } else { table.deselectAll(nil) }
        if !recenter {
            let y = anchor.flatMap { key, offset in items.firstIndex { $0.id == key }.map { table.rect(ofRow: $0).minY + offset } } ?? origin.y
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if let query = activating, next?.filter == query { activate() }
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
        else if let first = sidebarRows(snapshot, folded: []).first(where: { $0.target != nil }) { jump(first) }
    }

    func focus() {
        if let session = snapshot?.client.session, folded.remove(session) != nil { show(snapshot) }
        if table.selectedRow < 0, let current = snapshot?.client,
            let item = items.first(where: { $0.target == current })
        {
            table.selectRowIndexes([items.firstIndex { $0.id == item.id }!], byExtendingSelection: false)
        }
        window?.makeFirstResponder(table)
        table.scrollRowToVisible(table.selectedRow)
    }

    func revealWindowOnNavigation() { revealingWindow = true }

    func nextAttention(_ delta: Int) {
        let all = sidebarRows(snapshot, folded: [])
        let candidates = all.filter { $0.target != nil }
        guard !candidates.isEmpty else { return }
        let selected = entry(table.selectedRow)?.id
        var index = candidates.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : 0)
        for _ in candidates {
            index = (index + delta + candidates.count) % candidates.count
            if candidates[index].attention { return jump(candidates[index]) }
        }
    }

    private func jump(_ row: SidebarRow) {
        guard let target = row.target else { return }
        if folded.remove(target.session) != nil { show(snapshot) }
        if let index = items.firstIndex(where: { $0.id == row.id }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        performJump(target)
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

    private func performJump(_ target: Snapshot.Position) {
        activating = nil
        failed(nil)
        send([Command("switch-client", "-t", "\(target.session):\(target.window).\(target.pane)")]) { [weak self] replies in
            guard let self else { return }
            switch replies?.first {
            case .success?: break
            case .failure(let lines)?: return failed(lines.joined(separator: "\n"))
            case nil: return failed("the connection to tmux closed before the jump")
            }
            if !search.stringValue.isEmpty {
                search.stringValue = ""
                search.isHidden = true
                needsLayout = true
                filter("")
            }
            leave()
        }
    }

    @objc private func clicked() {
        guard let row = entry(table.clickedRow) else { return }
        if case .header = row.kind {
            if !folded.insert(row.id.session).inserted { folded.remove(row.id.session) }
            show(snapshot)
        } else { jump(row) }
    }

    @objc private func searched() {
        if activating != search.stringValue { activating = nil }
        filter(search.stringValue)
    }

    fileprivate func key(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch (Int(event.keyCode), event.charactersIgnoringModifiers ?? "", mods) {
        case (125, _, []), (_, "j", []), (_, "n", .control): move(1)
        case (126, _, []), (_, "k", []), (_, "p", .control): move(-1)
        case (36, _, []), (76, _, []): jump(table.selectedRow)
        case (53, _, []): leave()
        case (_, "n", []): nextAttention(1)
        case (_, "N", []): nextAttention(-1)
        case (_, "/", []):
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
            searched()
            activating = search.stringValue
            if snapshot?.filter == search.stringValue { activate() }
        case #selector(cancelOperation(_:)):
            search.stringValue = ""
            activating = nil
            filter("")
            search.isHidden = true
            needsLayout = true
            focus()
        default:
            return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { items[row].height }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].target != nil }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarSelectionRow ?? SidebarSelectionRow()
        view.identifier = id
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: SidebarCell.id, owner: nil) as? SidebarCell ?? SidebarCell(fonts)
        cell.configure(item)
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
    func visualFold(_ session: SessionID) {
        if !folded.insert(session).inserted { folded.remove(session) }
        show(snapshot)
    }
    func visualJump(_ row: SidebarRow) { jump(row) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
    #endif
}

private final class Table: NSTableView {
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect { rect(ofRow: row) }
    override func keyDown(with event: NSEvent) {
        if (delegate as? SidebarView)?.key(event) != true { super.keyDown(with: event) }
    }
}
