import AppKit
import SidebarFeed
import TmuxControl

final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    var send: ([Command], @escaping @MainActor @Sendable ([Reply]?) -> Void) -> Void = { $1(nil) }
    var filter: (String) -> Void = { _ in }
    var leave: () -> Void = {}

    fileprivate final class Entry {
        enum Content {
            case section(SessionNodes)
            case spacer(String, CGFloat)
            case pane(SidebarFeed.Item)
        }
        let session: SessionID
        let content: Content
        var guides: [(top: CGFloat, bottom: CGFloat)] = []
        var section: SessionNodes? { if case .section(let s) = content { return s }; return nil }
        var key: String {
            let id: String = switch content { case .section: "section"; case .spacer(let id, _): "space:\(id)"; case .pane(let item): item.id.description }
            return "\(session):\(id)"
        }
        var height: CGFloat {
            switch content { case .section: 28; case .spacer(_, let height): height; case .pane: guides.count > 1 ? 20 : 24 }
        }
        var target: Snapshot.Position? {
            guard case .pane(let item) = content else { return nil }
            return Snapshot.Position(session: session, window: item.window, pane: item.pane)
        }
        init(_ session: SessionID, _ content: Content) { self.session = session; self.content = content }
    }
    private var items: [Entry] = []
    private func entry(_ row: Int) -> Entry? { table.item(atRow: row) as? Entry }

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
    private let fonts = Fonts()
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
        table.style = .sourceList
        table.floatsGroupRows = false
        table.rowSizeStyle = .small
        table.rowHeight = 22
        table.indentationPerLevel = 0
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.tableColumns[0].resizingMask = .autoresizingMask
        table.tableColumns[0].minWidth = 0
        table.autoresizingMask = [.width]
        table.outlineTableColumn = table.tableColumns[0]
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.focusRingType = .none
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
        let selected = entry(table.selectedRow)?.key
        let origin = scroll.contentView.bounds.origin
        let first = table.rows(in: table.visibleRect).location
        let anchor = first == NSNotFound ? nil : entry(first).map { ($0.key, origin.y - table.rect(ofRow: first).minY) }
        let cleared = next?.filter.isEmpty == true && snapshot?.filter.isEmpty == false
        let recenter = cleared || next.map { $0.client != snapshot?.client } ?? false
        snapshot = next
        noMatches.isHidden = next.map { $0.filter.isEmpty || !$0.sessions.isEmpty } ?? true
        items = (next?.sessions ?? []).flatMap { session -> [Entry] in
            func panes(_ nodes: [SidebarFeed.Node], depth: Int) -> [Entry] {
                nodes.flatMap { node -> [Entry] in
                    switch node {
                    case .window:
                        let rows = panes(node.children, depth: depth)
                        rows.first?.guides[depth].top = 5
                        rows.last?.guides[depth].bottom = 5
                        return rows
                    case .item(let item):
                        let row = Entry(session.id, .pane(item))
                        row.guides = Array(repeating: (0, 0), count: depth + 1)
                        let children = panes(item.children, depth: depth + 1)
                        if let last = children.last, last.guides[depth + 1].bottom == 0 { last.guides[depth + 1].bottom = 6 }
                        return [row] + children
                    }
                }
            }
            return [Entry(session.id, .section(session))] + session.nodes.enumerated().flatMap { index, node -> [Entry] in
                let rows = panes([node], depth: 0)
                rows.first?.guides[0].top = 5
                rows.last?.guides[0].bottom = 5
                return [Entry(session.id, .spacer(node.id, index == 0 ? 2 : 10))] + rows
            }
        }
        table.reloadData()
        let follow = recenter ? items.first { $0.target == next?.client } : items.first { $0.key == selected }
        if let follow {
            let row = table.row(forItem: follow)
            table.selectRowIndexes([row], byExtendingSelection: false)
            if recenter { table.scrollRowToVisible(row) }
        } else { table.deselectAll(nil) }
        if !recenter {
            let y = anchor.flatMap { key, offset in items.firstIndex { $0.key == key }.map { table.rect(ofRow: $0).minY + offset } } ?? origin.y
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
            if case .pane(let item) = entry($0)?.content { return item.started != nil }
            return false
        })
    }

    private func updateTick() {
        guard !isHidden, items.contains(where: { if case .pane(let i) = $0.content { return i.started != nil }; return false }) else {
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
        for row in rows { (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell)?.updateClock() }
    }

    private func activate() {
        jump(table.selectedRow >= 0 ? table.selectedRow : (0..<table.numberOfRows).first { entry($0)?.target != nil } ?? -1)
    }

    func focus() {
        if table.selectedRow < 0, let current = snapshot?.client,
            let item = items.first(where: { $0.target == current })
        {
            table.selectRowIndexes([table.row(forItem: item)], byExtendingSelection: false)
        }
        window?.makeFirstResponder(table)
        table.scrollRowToVisible(table.selectedRow)
    }

    func nextAttention(_ delta: Int) {
        let count = table.numberOfRows
        guard count > 0 else { return }
        var row = table.selectedRow >= 0 ? table.selectedRow : (delta > 0 ? -1 : count)
        for _ in 0..<count {
            row = (row + delta + count) % count
            if case .pane(let item) = entry(row)?.content, item.attention {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
                return jump(row)
            }
        }
    }

    private func move(_ delta: Int) {
        var i = table.selectedRow
        repeat { i += delta } while i >= 0 && i < table.numberOfRows && entry(i)?.target == nil
        guard i >= 0, i < table.numberOfRows else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func jump(_ index: Int) {
        activating = nil
        guard let target = entry(index)?.target else { return }
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
        jump(table.clickedRow)
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
        case #selector(cancelOperation(_:)) where search.stringValue.isEmpty:
            search.isHidden = true
            needsLayout = true
            leave()
        default:
            return false
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items[index]
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { (item as! Entry).height }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! Entry).target != nil }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let row = outlineView.makeView(withIdentifier: id, owner: nil) as? SelectionRow ?? SelectionRow()
        row.identifier = id
        return row
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let entry = item as! Entry
        let cell = outlineView.makeView(withIdentifier: Cell.id, owner: nil) as? Cell ?? Cell(fonts)
        cell.configure(entry)
        cell.addWindow.invoke = { [weak self] in self?.newWindow(entry.session) }
        return cell
    }
}

private final class Table: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect { rect(ofRow: row) }
    override func keyDown(with event: NSEvent) {
        if (delegate as? SidebarView)?.key(event) != true { super.keyDown(with: event) }
    }
}

private struct Fonts {
    let regular = NSFont.systemFont(ofSize: 12)
    let small = NSFont.systemFont(ofSize: 11)
    let section = NSFont.systemFont(ofSize: 11, weight: .semibold)
}

private final class SelectionRow: NSTableRowView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(contrastChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func contrastChanged() { needsDisplay = true }
    override func drawSelection(in dirtyRect: NSRect) {
        let color = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? NSColor.selectedContentBackgroundColor
            : NSColor.labelColor.withAlphaComponent(isEmphasized && window?.isKeyWindow == true ? 0.10 : 0.06)
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override var isSelected: Bool { didSet { subviews.forEach { $0.needsDisplay = true } } }
}

private final class Label: NSTextField {
    override var allowsVibrancy: Bool { false }
}

private final class Cell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("cell")
    private let fonts: Fonts
    private let title = Label(labelWithString: "")
    private let tail = Label(labelWithString: "")
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    let addWindow = IconButton("plus", "New window")
    private var entry: SidebarView.Entry?
    override var isFlipped: Bool { true }

    init(_ fonts: Fonts) {
        self.fonts = fonts
        super.init(frame: .zero)
        identifier = Self.id
        for field in [title, tail] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.wraps = false
            field.cell?.usesSingleLineMode = true
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [title, tail, glyph, spinner, addWindow] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard let entry else { return }
        if entry.section != nil {
            title.frame = CGRect(x: 6, y: bounds.height - 18, width: max(0, bounds.width - 34), height: 14)
            addWindow.frame = CGRect(x: bounds.width - 26, y: bounds.height - 24, width: 20, height: 20)
            return
        }
        let size: CGFloat = entry.guides.count > 1 ? 11 : 14
        glyph.frame = CGRect(x: bounds.width - 6 - size, y: (bounds.height - size) / 2, width: size, height: size)
        spinner.frame = glyph.frame
        let leading = 6 + CGFloat(entry.guides.count) * 12 + 5
        let end = glyph.frame.minX - 5
        let desired = tail.attributedStringValue.size().width + (tail.stringValue.isEmpty ? 0 : 4)
        let width = min(bounds.width * 0.5, desired, max(0, end - leading - title.attributedStringValue.size().width - 9))
        tail.isHidden = width < min(18, desired)
        tail.frame = CGRect(x: end - width, y: (bounds.height - 14) / 2, width: width, height: 14)
        title.frame = CGRect(x: leading, y: (bounds.height - 16) / 2,
                             width: max(0, end - leading - (width > 0 ? width + 5 : 0)), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let selected = (superview as? NSTableRowView)?.isSelected == true
        NSColor.labelColor.withAlphaComponent(selected ? 0.30 : 0.16).setFill()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        for (index, guide) in (entry?.guides ?? []).enumerated() {
            CGRect(x: 12 + CGFloat(index) * 12, y: guide.top, width: pixel,
                   height: max(0, bounds.height - guide.top - guide.bottom)).fill()
        }
    }

    func updateClock() {
        guard case .pane(let row) = entry?.content, let started = row.started else { return }
        let s = max(0, Int(Date().timeIntervalSince(started)))
        tail.stringValue = s < 60 ? "\(s)s" : s < 3600 ? String(format: "%dm%02ds", s / 60, s % 60) : String(format: "%dh%02dm", s / 3600, (s / 60) % 60)
        needsLayout = true
    }

    func configure(_ entry: SidebarView.Entry) {
        self.entry = entry
        title.stringValue = ""
        tail.stringValue = ""
        title.textColor = .labelColor
        tail.textColor = .secondaryLabelColor
        title.font = entry.guides.count > 1 ? fonts.small : fonts.regular
        tail.font = fonts.small
        glyph.image = nil
        spinner.stopAnimation(nil)
        addWindow.isHidden = entry.section == nil
        var status = ""
        switch entry.content {
        case .section(let section):
            title.stringValue = section.name
            title.font = fonts.section
            title.textColor = .secondaryLabelColor
            addWindow.toolTip = "New window in " + section.name
            addWindow.setAccessibilityLabel(addWindow.toolTip)
        case .spacer: break
        case .pane(let row):
            title.stringValue = row.title.map(\.text).joined()
            if row.started != nil { updateClock() }
            else { tail.stringValue = row.tail.map(\.text).joined() }
            let symbol: String?
            let failed: Bool = switch row.indicator { case .failed, .gone(.failed), .gone(.died): true; default: false }
            if failed {
                symbol = "xmark.circle.fill"
                status = "Error"
                glyph.contentTintColor = .systemRed
                tail.textColor = .systemRed
            } else if row.attention || row.indicator == .waiting || row.indicator == .stalled {
                symbol = "exclamationmark.circle.fill"
                status = "Needs attention"
                glyph.contentTintColor = .systemOrange
                tail.textColor = .systemOrange
            } else {
                symbol = nil
                if row.indicator == .running || row.indicator == .compacting {
                    status = "Running"
                    spinner.startAnimation(nil)
                }
            }
            if let symbol { glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status) }
        }
        toolTip = [title.stringValue, tail.stringValue, status].filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityLabel(toolTip)
        needsLayout = true
        needsDisplay = true
    }
}
