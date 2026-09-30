import AppKit
import SidebarFeed
import TmuxControl

final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var send: ([Command], @escaping @MainActor @Sendable ([Reply]?) -> Void) -> Void = { $1(nil) }
    var filter: (String) -> Void = { _ in }
    var leave: () -> Void = {}

    fileprivate enum Item {
        case session(SessionRows)
        case row(SessionID, Row)

        var target: Snapshot.Position? {
            guard case .row(let session, let row) = self, let target = row.target else { return nil }
            return Snapshot.Position(session: session, window: target.window, pane: target.pane)
        }
    }

    private let search = NSSearchField()
    private let table = Table()
    private let scroll = NSScrollView()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let noMatches = NSTextField(labelWithString: "No matches")
    private var snapshot: Snapshot?
    private var items: [Item] = []
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
        table.style = .plain
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
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.isSelectable = true
        noMatches.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noMatches.textColor = .secondaryLabelColor
        for view in [search, scroll, footer, noMatches] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 16
        search.frame = CGRect(x: 8, y: 8, width: inner, height: search.fittingSize.height)
        let note = footer.isHidden ? 0 : footer.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: inner, height: 200)).height
        footer.frame = CGRect(x: 8, y: bounds.height - note - 6, width: inner, height: note)
        let top = search.frame.maxY + 6
        scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: footer.frame.minY - top - (footer.isHidden ? 0 : 6))
        table.tableColumns[0].width = scroll.contentSize.width
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

    func failed(_ message: String?) {
        failure = message
        noteChanged()
    }

    private func noteChanged() {
        let note = failure.map { ($0, NSColor.systemRed) } ?? feedNote ?? snapshot?.error.map { ($0, NSColor.systemRed) }
        footer.stringValue = note?.0 ?? ""
        footer.textColor = note?.1
        footer.isHidden = note == nil
        needsLayout = true
    }

    private func show(_ next: Snapshot?) {
        let selected = items.indices.contains(table.selectedRow) ? items[table.selectedRow].target : nil
        let cleared = next?.filter.isEmpty == true && snapshot?.filter.isEmpty == false
        let recenter = cleared || next.map { $0.client != snapshot?.client } ?? false
        snapshot = next
        noMatches.isHidden = next.map { $0.filter.isEmpty || !$0.sessions.isEmpty } ?? true
        items = next?.sessions.flatMap { s in [.session(s)] + s.rows.map { .row(s.id, $0) } } ?? []
        table.reloadData()
        let follow = recenter ? next?.client : selected
        if let follow, let row = items.firstIndex(where: { $0.target == follow }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if recenter { table.scrollRowToVisible(row) }
        } else {
            table.deselectAll(nil)
        }
        if let query = activating, next?.filter == query { activate() }
        updateTick()
    }

    private var startedRows: IndexSet {
        IndexSet(items.indices.filter { if case .row(_, let row) = items[$0] { return row.started != nil } else { return false } })
    }

    private func updateTick() {
        guard !isHidden, !startedRows.isEmpty else {
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
        let rows = startedRows
        guard !rows.isEmpty else { return updateTick() }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    private func activate() {
        jump(table.selectedRow >= 0 ? table.selectedRow : items.firstIndex { $0.target != nil } ?? -1)
    }

    func focus() {
        if table.selectedRow < 0, let current = snapshot?.client,
            let row = items.firstIndex(where: { $0.target == current })
        {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        window?.makeFirstResponder(table)
        table.scrollRowToVisible(table.selectedRow)
    }

    func nextAttention(_ delta: Int) {
        let n = items.count
        var i = table.selectedRow >= 0 ? table.selectedRow : delta > 0 ? -1 : n
        for _ in 0..<n {
            i = (i + delta + n) % n
            if case .row(_, let row) = items[i], row.attention, items[i].target != nil {
                table.selectRowIndexes([i], byExtendingSelection: false)
                table.scrollRowToVisible(i)
                return jump(i)
            }
        }
    }

    private func move(_ delta: Int) {
        var i = table.selectedRow
        repeat { i += delta } while items.indices.contains(i) && items[i].target == nil
        guard items.indices.contains(i) else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func jump(_ index: Int) {
        activating = nil
        guard items.indices.contains(index), let target = items[index].target else { return }
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
        case (_, "/", []): window?.makeFirstResponder(search)
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
            leave()
        default:
            return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard case .session = items[row] else { return 20 }
        return row == 0 ? 20 : 28
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].target != nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = RowBackground()
        view.current = items[row].target != nil && items[row].target == snapshot?.client
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Cell.id, owner: nil) as? Cell ?? Cell(fonts)
        cell.item = items[row]
        return cell
    }
}

private final class Table: NSTableView {
    override func keyDown(with event: NSEvent) {
        if (delegate as? SidebarView)?.key(event) != true { super.keyDown(with: event) }
    }
}

private final class RowBackground: NSTableRowView {
    var current = false

    override func drawBackground(in dirtyRect: NSRect) {
        guard current else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: CGRect(x: 4, y: 3, width: 2, height: bounds.height - 6), xRadius: 1, yRadius: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.35 : 0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

// AppKit's system-font constructors intermittently return nil, their
// signature notwithstanding, while libghostty creates surfaces: the sidebar's
// fonts are made once, before libghostty starts, and held.
private struct Fonts {
    let regular = NSFont.systemFont(ofSize: 12)
    let bold = NSFont.boldSystemFont(ofSize: 12)
    let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}

private final class Cell: NSView {
    static let id = NSUserInterfaceItemIdentifier("cell")
    private static let column: CGFloat = 10
    private static let field: CGFloat = 16
    private let fonts: Fonts

    var item: SidebarView.Item? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(_ fonts: Fonts) {
        self.fonts = fonts
        super.init(frame: .zero)
        identifier = Self.id
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        switch item {
        case .session(let session):
            let text = NSAttributedString(
                string: session.name,
                attributes: [
                    .font: session.current ? fonts.bold : fonts.regular,
                    .foregroundColor: session.current ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .paragraphStyle: Self.truncating,
                ])
            text.draw(
                with: CGRect(x: 10, y: bounds.height - 18, width: bounds.width - 20, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        case .row(_, let row):
            drawTree(row.tree)
            let x = 10 + CGFloat(row.tree.count) * Self.column
            if let symbol = row.indicator.flatMap(Self.symbol) {
                let size = symbol.size
                symbol.draw(
                    in: CGRect(
                        x: x + (Self.field - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
                        height: size.height))
            }
            let text = NSMutableAttributedString()
            let tail: [(String, Span.Role)] =
                if let started = row.started {
                    [(Self.elapsed(Date().timeIntervalSince(started)), .dim)]
                } else {
                    row.tail.map { ($0.text, $0.role) }
                }
            let gap: [(String, Span.Role)] = tail.isEmpty ? [] : [("  ", .plain)]
            for (string, role) in row.title.map({ ($0.text, $0.role) }) + gap + tail {
                text.append(NSAttributedString(string: string, attributes: style(role)))
            }
            let right = bounds.width - (row.attention ? 22 : 8)
            let height = text.size().height
            text.draw(
                with: CGRect(x: x + Self.field + 2, y: (bounds.height - height) / 2, width: right - x - Self.field - 2, height: height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if row.attention {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: CGRect(x: bounds.width - 16, y: bounds.midY - 3, width: 6, height: 6)).fill()
            }
        case nil:
            break
        }
    }

    private func drawTree(_ tree: String) {
        let path = NSBezierPath()
        let mid = bounds.midY.rounded(.down) + 0.5
        for (k, glyph) in tree.enumerated() {
            let left = 10 + CGFloat(k) * Self.column
            let x = (left + Self.column / 2).rounded(.down) + 0.5
            let (top, bottom, across): (CGFloat?, CGFloat?, Bool) =
                switch glyph {
                case "│": (0, bounds.height, false)
                case "├": (0, bounds.height, true)
                case "┌": (mid, bounds.height, true)
                case "└": (0, mid, true)
                case "╶": (nil, nil, true)
                default: (nil, nil, false)
                }
            if let top, let bottom {
                path.move(to: CGPoint(x: x, y: top))
                path.line(to: CGPoint(x: x, y: bottom))
            }
            if across {
                path.move(to: CGPoint(x: x, y: mid))
                path.line(to: CGPoint(x: left + Self.column + 2, y: mid))
            }
        }
        NSColor.tertiaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // Matches kido's lib/ui.ml `elapsed`.
    private static func elapsed(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm%02ds", s / 60, s % 60) }
        return String(format: "%dh%02dm", s / 3600, (s / 60) % 60)
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private func style(_ role: Span.Role) -> [NSAttributedString.Key: Any] {
        let (color, font): (NSColor, NSFont) =
            switch role {
            case .plain: (.labelColor, fonts.regular)
            case .current: (.labelColor, fonts.bold)
            case .proc: (.labelColor, fonts.mono)
            case .dim: (.secondaryLabelColor, fonts.regular)
            case .err: (.systemRed, fonts.regular)
            case .running: (.systemGreen, fonts.regular)
            case .waiting: (.systemOrange, fonts.bold)
            case .compacting: (.systemPurple, fonts.regular)
            case .done: (.systemGreen, fonts.bold)
            case .stalled: (.systemRed, fonts.bold)
            }
        return [.foregroundColor: color, .font: font, .paragraphStyle: Self.truncating]
    }

    // The TUI's glyphs (lib/ui.ml `indicator`): idle draws nothing, a gone
    // subagent a dim ✓ when it completed and a dim × otherwise.
    private static func symbol(_ indicator: Indicator) -> NSImage? {
        let glyph: (name: String, color: NSColor, weight: NSFont.Weight)? =
            switch indicator {
            case .idle: nil
            case .running: ("square.fill", .systemGreen, .regular)
            case .waiting: ("diamond.fill", .systemOrange, .regular)
            case .compacting: ("circle.dotted", .systemPurple, .bold)
            case .done: ("checkmark", .systemGreen, .heavy)
            case .failed: ("square.fill", .systemRed, .regular)
            case .unknown: ("questionmark", .secondaryLabelColor, .bold)
            case .stalled: ("exclamationmark", .systemRed, .heavy)
            case .gone(.completed): ("checkmark", .tertiaryLabelColor, .bold)
            case .gone: ("xmark", .tertiaryLabelColor, .bold)
            }
        guard let glyph else { return nil }
        return NSImage(systemSymbolName: glyph.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 9, weight: glyph.weight).applying(.init(paletteColors: [glyph.color])))
    }
}
