import AppKit
import SidebarFeed
import TmuxControl

enum PaletteMode: Equatable {
    case root, connect
    case prompt(PromptSource)
    case rename(WindowOwner, ServerInstance, SessionID, original: String)
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.root, .root), (.connect, .connect): true
        case let (.prompt(a), .prompt(b)): a == b
        case let (.rename(a, ai, asid, an), .rename(b, bi, bsid, bn)): a === b && ai == bi && asid == bsid && an == bn
        default: false
        }
    }
}

private final class PaletteChip: NSView {
    var mode: PaletteMode = .root
    private var title: String { switch mode { case .prompt: "Prompt"; case .connect: "Connect"; default: "Rename session" } }
    private var symbol: String { switch mode { case .prompt: "bubble.left"; case .connect: "globe"; default: "pencil" } }
    var width: CGFloat { 33 + (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.modeChipFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(hierarchicalColor: Chrome.modeChipInk)))!
        image.draw(in: NSRect(x: 8, y: 5, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Chrome.ink]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 25, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

private final class PaletteEmpty: NSView {
    var text = ""
    var textSize: NSSize { (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]) }
    override func draw(_ dirtyRect: NSRect) {
        (text as NSString).draw(at: .zero, withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Chrome.inkSecondary])
    }
}

private final class PaletteFoot: NSView {
    var mode: PaletteMode = .root

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.inkSecondary]
        var x: CGFloat = 16
        let session: String? = if case .rename(_, _, _, let original) = mode { original } else { nil }
        for text in session == nil ? ["↩ connect", "⌫ on empty field back", "esc back"] : ["↩ rename", "esc back"] {
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            x += size.width + 12
        }
        if let session {
            let text = NSMutableAttributedString(string: "session ", attributes: attributes)
            text.append(NSAttributedString(string: session, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Chrome.ink]))
            text.append(NSAttributedString(string: " of the key window", attributes: attributes))
            text.draw(at: NSPoint(x: bounds.width - 16 - text.size().width, y: (bounds.height - text.size().height) / 2))
        }
    }
}

private final class PaletteError: NSView {
    var message = ""
    private var text: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 16
        paragraph.maximumLineHeight = 16
        return NSAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.errorText, .paragraphStyle: paragraph])
    }
    private var textHeight: CGFloat {
        ceil(text.boundingRect(with: NSSize(width: 550, height: 100), options: [.usesLineFragmentOrigin]).height)
    }
    var height: CGFloat { max(32, textHeight + 16) }

    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [Chrome.onError, Chrome.errorText])))!
        image.draw(in: NSRect(x: 16, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1)
        text.draw(with: NSRect(x: 34, y: (bounds.height - textHeight) / 2, width: bounds.width - 50, height: textHeight),
                  options: [.usesLineFragmentOrigin])
    }
}

final class PaletteList: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    private final class Row: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            Chrome.rowSelection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }

    private final class Cell: NSView {
        var entry: PaletteEntry?
        var highlightColor = Chrome.ink
        var offsets: [[Int]] = [[], []]
        var selected = false
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let entry else { return }
            if let status = entry.status { drawStatusMark(status, at: NSPoint(x: 24, y: bounds.midY), flipped: true) }
            if let symbol = entry.symbol.flatMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) }) {
                let image = symbol.withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(hierarchicalColor: Chrome.inkSecondary))) ?? symbol
                image.draw(in: NSRect(x: 24 - image.size.width / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            var right = bounds.maxX - 16
            let shortcut = selected && entry.promptable ? "⌘O prompt" : entry.shortcut
            if !shortcut.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.inkSecondary]
                let size = (shortcut as NSString).size(withAttributes: attributes)
                right -= size.width
                (shortcut as NSString).draw(at: NSPoint(x: right, y: (bounds.height - size.height) / 2), withAttributes: attributes)
                right -= 12
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            func part(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            }
            let line = NSMutableAttributedString()
            if !entry.detail.isEmpty {
                line.append(part(entry.detail, .systemFont(ofSize: 13), Chrome.inkSecondary))
                line.append(part(" › ", .systemFont(ofSize: 13), Chrome.inkTertiary))
            }
            let titleColor: NSColor = entry.id == .connectTyped ? Chrome.linkText : entry.id == .clearRecent ? Chrome.inkSecondary : Chrome.ink
            let left: CGFloat = entry.id == .clearRecent ? 78 : 42
            let titleFont = NSFont.systemFont(ofSize: entry.id == .clearRecent ? 12 : 13, weight: entry.agent ? .semibold : .regular)
            let title = NSMutableAttributedString(attributedString: part(entry.title, titleFont, titleColor))
            if entry.id == .connectTyped {
                title.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: NSRange(location: 11, length: max(0, title.length - 11)))
            }
            line.append(title)
            let height = ceil(line.size().height)
            func highlight(_ text: String, offsets: [Int], font: NSFont, x: CGFloat) {
                let characters = Array(text)
                var start = 0
                while start < offsets.count {
                    var end = start + 1
                    while end < offsets.count, offsets[end] == offsets[end - 1] + 1 { end += 1 }
                    let first = offsets[start], last = offsets[end - 1]
                    if first >= 0, last < characters.count {
                        let attributes: [NSAttributedString.Key: Any] = [.font: font]
                        let prefix = String(characters.prefix(first)) as NSString
                        let run = String(characters[first...last]) as NSString
                        let rect = NSRect(x: x + prefix.size(withAttributes: attributes).width - 1,
                                          y: (bounds.height - height) / 2 - 1,
                                          width: run.size(withAttributes: attributes).width + 2, height: height + 2)
                        Chrome.matchHighlight(highlightColor).setFill()
                        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                    }
                    start = end
                }
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: left - 1, y: 0, width: max(0, right - left + 1), height: bounds.height)).addClip()
            highlight(entry.detail, offsets: offsets[1], font: .systemFont(ofSize: 13), x: left)
            let prefix = entry.detail.isEmpty ? "" : entry.detail + " › "
            highlight(entry.title, offsets: offsets[0], font: titleFont,
                      x: left + (prefix as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)
            line.draw(with: NSRect(x: left, y: (bounds.height - height) / 2, width: max(0, right - left), height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static let entryHeight: CGFloat = 34
    var shown: [(entry: PaletteEntry, offsets: [[Int]])] = []
    var highlightColor = Chrome.ink
    var choose: (Int) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        headerView = nil
        style = .plain
        rowHeight = Self.entryHeight
        intercellSpacing = .zero
        backgroundColor = .clear
        refusesFirstResponder = true
        dataSource = self
        delegate = self
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func clicked() { choose(clickedRow) }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        let old = selectedRow
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        for row in Set([old, selectedRow]).filter({ shown.indices.contains($0) }) {
            if let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell {
                cell.selected = selectedRow == row
                cell.needsDisplay = true
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        shown[row].entry.id == .clearRecent ? 28 : Self.entryHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = Cell()
        cell.entry = shown[row].entry
        cell.selected = selectedRow == row
        cell.highlightColor = highlightColor
        cell.offsets = shown[row].offsets
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.staticText)
        let entry = shown[row].entry
        let status = entry.status?.accessibilitySuffix ?? ""
        cell.setAccessibilityLabel([entry.title, entry.detail, entry.shortcut].filter { !$0.isEmpty }.joined(separator: ", ") + status)
        return cell
    }
}

final class PaletteView: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private(set) var prompt: PalettePrompt?
    var makePrompt: (PromptSource) -> Void = { _ in }
    var modeChanged: () -> Void = {}
    var selectedEntry: PaletteEntry? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].entry : nil }
    private let chip = PaletteChip()
    private let errorLine = PaletteError()
    private let foot = PaletteFoot()
    private let footSeparator = NSBox()
    private(set) var mode: PaletteMode = .root
    private(set) var error: String?
    var modeEntries: (String, Bool) -> [(entry: PaletteEntry, offsets: [[Int]])] = { _, _ in [] }
    var rootEntries: () -> [PaletteEntry] = { [] }
    var rename: (String) -> Void = { _ in }
    private let card: PaneCapsule
    private let separator = NSBox()
    private let scroll = NSScrollView()
    private let table = PaletteList()
    private let empty = PaletteEmpty()
    private var entries: [PaletteEntry]
    private(set) var shown: [(entry: PaletteEntry, offsets: [[Int]])] {
        get { table.shown }
        set { table.shown = newValue }
    }
    var dismiss: () -> Void = {}
    var chooseEntry: (PaletteEntry) -> Void = { _ in }
    override var isFlipped: Bool { true }

    init(runtime: GhosttyRuntime, entries: [PaletteEntry]) {
        self.entries = entries
        card = PaneCapsule(runtime: runtime, radius: 12, surface: Chrome.cardSurface, edgeOutset: 0)
        card.shadow = nil
        super.init(frame: .zero)
        appearance = NSAppearance(named: runtime.background.isDark ? .darkAqua : .aqua)
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
        footSeparator.boxType = .separator
        table.highlightColor = runtime.foreground
        table.choose = { [weak self] in self?.choose($0) }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        for view in [field, separator, scroll, empty, chip, errorLine, foot, footSeparator] { card.addSubview(view) }
        filter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { dismiss() }
    override func rightMouseDown(with event: NSEvent) { dismiss() }

    override func layout() {
        super.layout()
        field.isHidden = prompt != nil
        foot.isHidden = prompt != nil || mode == .root
        footSeparator.isHidden = foot.isHidden
        errorLine.isHidden = prompt != nil || error == nil
        chip.isHidden = mode == .root
        let width: CGFloat = 600
        let chipWidth = mode == .root ? 0 : chip.width
        card.frame = NSRect(x: 0, y: 0, width: width, height: preferredHeight)
        chip.frame = NSRect(x: 16, y: preferredHeight - 34, width: chipWidth, height: 22)
        if let prompt {
            prompt.targetButton.frame = NSRect(x: 16 + chip.width + 10, y: preferredHeight - 34, width: min(460 - chip.width, prompt.targetButton.fittingSize.width), height: 22)
            separator.frame = NSRect(x: 0, y: prompt.preferredHeight, width: 600, height: 1)
            prompt.frame = NSRect(x: 0, y: 0, width: 600, height: prompt.preferredHeight)
            prompt.layoutSubtreeIfNeeded()
            return
        }
        let list = listHeight
        let footer: CGFloat = mode == .root ? 0 : 30
        let errorHeight: CGFloat = error == nil ? 0 : errorLine.height
        field.frame = NSRect(x: 16 + chipWidth + (chipWidth > 0 ? 8 : 0), y: preferredHeight - (mode == .root ? 34 : 35), width: width - 32 - chipWidth - (chipWidth > 0 ? 8 : 0), height: 22)
        separator.frame = NSRect(x: 0, y: list + footer + errorHeight, width: width, height: 1)
        scroll.frame = NSRect(x: 0, y: footer, width: width, height: list)
        errorLine.frame = NSRect(x: 0, y: footer + list, width: width, height: errorHeight)
        footSeparator.frame = NSRect(x: 0, y: footer, width: width, height: 1)
        foot.frame = NSRect(x: 0, y: 0, width: width, height: footer)
        table.tableColumns.first?.width = width
        empty.frame.size = empty.textSize
        empty.frame.origin = NSPoint(x: 36, y: footer + (list - empty.frame.height) / 2)
    }

    private var listHeight: CGFloat {
        if case .rename = mode { return 0 }
        if mode == .connect, shown.isEmpty { return field.stringValue.isEmpty ? 42 : 8 }
        return shown.isEmpty ? PaletteList.entryHeight : CGFloat(min(shown.count, 12)) * PaletteList.entryHeight + 8 - (shown.prefix(12).contains { $0.entry.id == .clearRecent } ? 6 : 0)
    }
    var preferredHeight: CGFloat { if let prompt { 47 + prompt.preferredHeight } else { 45 + listHeight + (mode == .root ? 0 : 30) + (error == nil ? 0 : errorLine.height) } }

    func enter(_ mode: PaletteMode, prompt prepared: PalettePrompt? = nil) {
        guard mode != self.mode else { return }
        if case .prompt(let source) = mode, prepared == nil { return makePrompt(source) }
        modeChanged()
        prompt?.storeDraft()
        prompt?.targetButton.removeFromSuperview()
        prompt?.removeFromSuperview()
        prompt = nil
        self.mode = mode
        error = nil
        field.stringValue = ""
        switch mode {
        case .prompt:
            guard let view = prepared else { return }
            prompt = view
            card.addSubview(view)
            card.addSubview(view.targetButton)
            view.resized = { [weak self] in
                self?.needsLayout = true
                (self?.window as? PalettePanel)?.resizeCard()
            }
        case .root:
            entries = rootEntries()
            field.placeholderString = "Search sessions, panes and commands"
            field.setAccessibilityLabel("Command palette")
        case .connect:
            field.placeholderString = "user@hostname or SSH alias"
            field.setAccessibilityLabel("Connect to remote host")
        case .rename(_, _, _, let original):
            field.placeholderString = ""
            field.stringValue = original
            field.setAccessibilityLabel("Rename session")
        }
        chip.mode = mode
        foot.mode = mode
        chip.needsDisplay = true
        foot.needsDisplay = true
        filter()
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(prompt?.textView ?? field)
        if prompt == nil { field.selectText(nil) }
    }

    func reject(_ message: String) {
        error = message
        errorLine.message = message
        errorLine.setAccessibilityElement(true)
        errorLine.setAccessibilityRole(.staticText)
        errorLine.setAccessibilityLabel(message)
        errorLine.needsDisplay = true
        NSAccessibility.post(element: errorLine, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        filter()
        if case .rename = mode { field.selectText(nil) }
    }

    func refresh(_ entries: [PaletteEntry]) {
        let selected = shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].entry.id : nil
        self.entries = entries
        filter()
        if let selected, let index = shown.firstIndex(where: { $0.entry.id == selected }) { select(index) }
    }

    func reloadMode() { filter() }

    private func filter() {
        switch mode {
        case .root: shown = PaletteEntry.ranked(entries, query: field.stringValue)
        case .connect:
            shown = modeEntries(field.stringValue, error != nil)
        case .rename, .prompt: shown = []
        }
        table.reloadData()
        empty.text = mode == .connect ? "No recent hosts" : "No matches"
        empty.setAccessibilityElement(true)
        empty.setAccessibilityRole(.staticText)
        empty.setAccessibilityLabel(empty.text)
        empty.needsDisplay = true
        if prompt != nil { empty.isHidden = true }
        else if case .rename = mode { empty.isHidden = true }
        else { empty.isHidden = !shown.isEmpty || (mode == .connect && !field.stringValue.isEmpty) }
        scroll.isHidden = shown.isEmpty
        select(0)
        needsLayout = true
        if let panel = window as? PalettePanel { panel.resizeCard() }
    }

    private func select(_ row: Int) {
        guard !shown.isEmpty else { return }
        let row = (row + shown.count) % shown.count
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func choose(_ row: Int) {
        guard shown.indices.contains(row) else { return }
        let entry = shown[row].entry
        chooseEntry(entry)
    }

    func controlTextDidChange(_ notification: Notification) { error = nil; filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)):
            if case .rename = mode { rename(field.stringValue) }
            else { choose(table.selectedRow) }
        case #selector(NSResponder.cancelOperation(_:)):
            if mode == .root { dismiss() } else { enter(.root) }
        case #selector(NSResponder.deleteBackward(_:)):
            guard mode != .root, field.stringValue.isEmpty else { return false }
            enter(.root)
        default: return false
        }
        return true
    }


}

final class PalettePanel: NSPanel {
    let palette: PaletteView
    private let closed: () -> Void
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var toggle: () -> Void = {}
    var connect: () -> Void = {}
    var prompt: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.charactersIgnoringModifiers?.lowercased() == "o", modifiers == .command {
            if palette.mode == .root { prompt() }
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "p", modifiers == .command || modifiers == [.command, .shift] {
            toggle(); return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "k", modifiers == [.command, .shift] {
            connect(); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func resizeCard() {
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - palette.preferredHeight, width: 600, height: palette.preferredHeight), display: false)
        palette.layoutSubtreeIfNeeded()
    }

    func place(over owner: WindowOwner?) {
        let screen = owner?.window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let area: NSRect
        if let owner {
            area = owner.window.convertToScreen(owner.sidebar.content.convert(owner.sidebar.content.bounds, to: nil))
        } else { area = visible }
        let height = palette.preferredHeight
        let x = min(max(area.midX - 300, visible.minX), visible.maxX - 600)
        let y = min(max(area.maxY - area.height * 0.2 - height, visible.minY), visible.maxY - height)
        setFrame(NSRect(x: x, y: y, width: 600, height: height), display: false)
    }

    init(palette: PaletteView, closed: @escaping () -> Void) {
        self.palette = palette
        self.closed = closed
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: palette.preferredHeight),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        setAccessibilitySubrole(.floatingWindow)
        level = .floating
        contentView = palette
        palette.dismiss = {}
        palette.layoutSubtreeIfNeeded()
        makeFirstResponder(palette.field)
    }

    override func resignKey() {
        super.resignKey()
        closed()
    }

}
