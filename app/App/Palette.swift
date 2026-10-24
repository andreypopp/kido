import AppKit
import SidebarFeed

struct PaletteEntry {
    enum Action { case request(RPCRequest), menu(NSMenuItem) }
    let title: String
    let detail: String
    var shortcut = ""
    var status: SidebarRow.Status?
    var agent = false
    let action: Action

    static func panes(_ snapshot: Snapshot?, seen: SidebarSeen) -> [PaletteEntry] {
        var session = ""
        return sidebarRows(snapshot, seen: seen).compactMap { row in
            if case .header = row.kind { session = row.title }
            guard let target = row.target else { return nil }
            return PaletteEntry(title: row.title, detail: session, status: row.status, agent: row.agent, action: .request(.jump(target)))
        }
    }

    @MainActor static func commands(_ menu: NSMenu, path: [String] = []) -> [PaletteEntry] {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var titles: Set<String> = []
        return menu.items.flatMap { item -> [PaletteEntry] in
            if let submenu = item.submenu { return commands(submenu, path: path + [item.title].filter { !$0.isEmpty }) }
            guard let action = item.action, action != #selector(AppDelegate.togglePalette), !item.isHidden, item.isEnabled,
                  titles.insert(item.title).inserted else { return [] }
            return [PaletteEntry(title: item.title, detail: path.joined(separator: " › "), shortcut: shortcut(item), action: .menu(item))]
        }
    }

    private static let keys: [String: String] = [
        String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
        String(UnicodeScalar(NSRightArrowFunctionKey)!): "→", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓", "\r": "↩",
    ]

    private static func shortcut(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var modifiers = item.keyEquivalentModifierMask
        if key != key.lowercased() { modifiers.insert(.shift) }
        let glyphs: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + (keys[key] ?? key.uppercased())
    }

    static func ranked(_ entries: [PaletteEntry], query: String) -> [(entry: PaletteEntry, offsets: [[Int]])] {
        entries.enumerated().compactMap { index, entry -> (score: Int, index: Int, entry: PaletteEntry, offsets: [[Int]])? in
            fuzzyMatch(query, fields: [entry.title, entry.detail]).map { ($0.score, index, entry, $0.offsets) }
        }
        .sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
        .map { ($0.entry, $0.offsets) }
    }
}

final class Palette: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private final class Row: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }

    private final class Cell: NSView {
        var entry: PaletteEntry?
        var offsets: [[Int]] = [[], []]
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let entry else { return }
            if let status = entry.status { drawStatusMark(status, at: NSPoint(x: 22, y: bounds.midY), flipped: true) }
            var right = bounds.maxX - 16
            if !entry.shortcut.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
                let size = (entry.shortcut as NSString).size(withAttributes: attributes)
                right -= size.width
                (entry.shortcut as NSString).draw(at: NSPoint(x: right, y: (bounds.height - size.height) / 2), withAttributes: attributes)
                right -= 12
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            func part(_ text: String, _ font: NSFont, _ color: NSColor, _ offsets: [Int]) -> NSAttributedString {
                let part = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
                let indices = Array(text.indices)
                for offset in offsets where offset < indices.count {
                    part.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: NSRange(indices[offset]..<text.index(after: indices[offset]), in: text))
                }
                return part
            }
            let line = NSMutableAttributedString()
            if !entry.detail.isEmpty {
                line.append(part(entry.detail, .systemFont(ofSize: 13), .secondaryLabelColor, offsets[1]))
                line.append(part(" › ", .systemFont(ofSize: 13), .tertiaryLabelColor, []))
            }
            line.append(part(entry.title, .systemFont(ofSize: 13, weight: entry.agent ? .semibold : .regular), .labelColor, offsets[0]))
            let height = ceil(line.size().height)
            line.draw(with: NSRect(x: 36, y: (bounds.height - height) / 2, width: max(0, right - 36), height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    static let rowHeight: CGFloat = 34
    let field = NSTextField()
    private let card: PaneCapsule
    private let separator = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "No matches")
    private let entries: [PaletteEntry]
    private(set) var shown: [(entry: PaletteEntry, offsets: [[Int]])] = []
    var run: (PaletteEntry.Action) -> Void = { _ in }
    var dismiss: () -> Void = {}
    override var isFlipped: Bool { true }

    init(runtime: GhosttyRuntime, entries: [PaletteEntry]) {
        self.entries = entries
        card = PaneCapsule(runtime: runtime, radius: 12)
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        addSubview(card)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.placeholderString = "Search sessions, panes and commands"
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Command palette")
        separator.boxType = .separator
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        for view in [field, separator, scroll, empty] { card.addSubview(view) }
        filter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { dismiss() }
    override func rightMouseDown(with event: NSEvent) { dismiss() }

    override func layout() {
        super.layout()
        let rows = CGFloat(min(shown.count, 9))
        let list = shown.isEmpty ? Self.rowHeight : rows * Self.rowHeight + 8
        let width = min(600, bounds.width - 32)
        card.frame = NSRect(x: round((bounds.width - width) / 2), y: 12, width: width, height: 45 + list)
        field.frame = NSRect(x: 16, y: list + 1 + 11, width: width - 32, height: 22)
        separator.frame = NSRect(x: 0, y: list, width: width, height: 1)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: list)
        table.tableColumns.first?.width = width
        empty.sizeToFit()
        empty.frame.origin = NSPoint(x: 36, y: (list - empty.frame.height) / 2)
    }

    private func filter() {
        shown = PaletteEntry.ranked(entries, query: field.stringValue)
        table.reloadData()
        empty.isHidden = !shown.isEmpty
        scroll.isHidden = shown.isEmpty
        select(0)
        needsLayout = true
    }

    private func select(_ row: Int) {
        guard !shown.isEmpty else { return }
        let row = (row + shown.count) % shown.count
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func choose(_ row: Int) {
        guard shown.indices.contains(row) else { return }
        run(shown[row].entry.action)
    }

    @objc private func clicked() { choose(table.clickedRow) }

    func controlTextDidChange(_ notification: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)): choose(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = Cell()
        cell.entry = shown[row].entry
        cell.offsets = shown[row].offsets
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.staticText)
        cell.setAccessibilityLabel([shown[row].entry.title, shown[row].entry.detail, shown[row].entry.shortcut].filter { !$0.isEmpty }.joined(separator: ", "))
        return cell
    }
}
