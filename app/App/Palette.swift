import AppKit
import GhosttyKit
import SidebarFeed
import TmuxControl

enum PaletteMode: Equatable {
    case root, connect
    case theme(ThemeStep)
    case prompt(PromptSource)
    case sessionName(WindowOwner, ServerInstance, SessionName.Operation)
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.root, .root), (.connect, .connect): true
        case let (.prompt(a), .prompt(b)): a == b
        case let (.theme(a), .theme(b)): a == b
        case let (.sessionName(a, ai, action), .sessionName(b, bi, other)): a === b && ai == bi && action == other
        default: false
        }
    }
}

private final class PaletteChip: NSView {
    var mode: PaletteMode = .root
    var title: String { switch mode { case .prompt: "Prompt"; case .connect: "Connect"; case .theme: "Theme"; case .sessionName(_, _, .create): "New session"; default: "Rename session" } }
    private var symbol: String { switch mode { case .prompt: "bubble.left"; case .connect: "globe"; case .theme: "paintpalette"; case .sessionName(_, _, .create): "plus"; default: "pencil" } }
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
    var theme: PaletteTheme?

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.inkSecondary]
        var x: CGFloat = 16
        if case .theme(let step) = mode, let theme {
            let left = if case .save(let row) = step { theme.foot(row) } else { "↑↓ preview    ↩ use    esc back, restores" }
            let right = if case .save = step { "esc back" } else { theme.foot() }
            (left as NSString).draw(at: NSPoint(x: 16, y: 8), withAttributes: attributes)
            let size = (right as NSString).size(withAttributes: attributes)
            (right as NSString).draw(at: NSPoint(x: bounds.width - 16 - size.width, y: 8), withAttributes: attributes)
            return
        }
        let (keys, session): ([String], String?) = switch mode {
        case .sessionName(_, _, .create): (["↩ create", "esc back"], nil)
        case .sessionName(_, _, .rename(_, let original)): (["↩ rename", "esc back"], original)
        default: (["↩ connect", "⌫ on empty field back", "esc back"], nil)
        }
        for text in keys {
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
    var theme: PaletteTheme?
    private var isError: Bool { theme == nil || theme?.status?.isError == true }
    private var topBorder: Bool { theme != nil }
    private var canReveal: Bool { theme?.status?.canReveal == true }
    override func mouseDown(with event: NSEvent) {
        if canReveal, convert(event.locationInWindow, from: nil).x > bounds.width - 105 { theme?.reveal() }
    }
    override func resetCursorRects() {
        if canReveal { addCursorRect(NSRect(x: bounds.width - 105, y: 0, width: 105, height: bounds.height), cursor: .pointingHand) }
    }
    private var text: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 16
        paragraph.maximumLineHeight = 16
        return NSAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: isError ? Chrome.errorText : Chrome.inkSecondary, .paragraphStyle: paragraph])
    }
    private var textHeight: CGFloat {
        ceil(text.boundingRect(with: NSSize(width: canReveal ? 450 : 550, height: 200), options: [.usesLineFragmentOrigin]).height)
    }
    var height: CGFloat { max(32, textHeight + 16) }

    override func draw(_ dirtyRect: NSRect) {
        if topBorder {
            Chrome.hairline.setFill()
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
        if canReveal {
            let label = "Reveal in Finder" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.linkText]
            label.draw(at: NSPoint(x: bounds.width - 100, y: (bounds.height - label.size(withAttributes: attributes).height) / 2), withAttributes: attributes)
        }
        if !isError {
            text.draw(with: bounds.insetBy(dx: 16, dy: 8), options: [.usesLineFragmentOrigin])
            return
        }
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [Chrome.onError, Chrome.errorText])))!
        image.draw(in: NSRect(x: 16, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1)
        text.draw(with: NSRect(x: 34, y: (bounds.height - textHeight) / 2, width: bounds.width - (canReveal ? 150 : 50), height: textHeight),
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
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            if let status = entry.status { drawStatusMark(status, at: NSPoint(x: 24, y: bounds.midY), flipped: true) }
            if let symbol = entry.symbol.flatMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) }) {
                let image = symbol.withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(hierarchicalColor: Chrome.inkSecondary))) ?? symbol
                image.draw(in: NSRect(x: 24 - image.size.width / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if let theme = entry.theme {
                if theme.problem != nil { NSGraphicsContext.current?.cgContext.setAlpha(Chrome.themeDisabledAlpha) }
                theme.drawSwatch(at: NSPoint(x: 6, y: 8))
            }
            if entry.radio {
                let rect = NSRect(x: 18, y: bounds.midY - 6, width: 12, height: 12)
                (selected ? Chrome.themeRadioSelection : Chrome.themeRadioInk).setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: selected ? 2 : 0.5, dy: selected ? 2 : 0.5))
                ring.lineWidth = selected ? 4 : 1
                ring.stroke()
            }
            var right = bounds.maxX - 16
            let shortcut = entry.radio ? (selected ? "↩" : "") : selected && entry.promptable ? "⌘O prompt" : entry.shortcut
            if !shortcut.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.inkSecondary]
                let size = (shortcut as NSString).size(withAttributes: attributes)
                right -= size.width
                (shortcut as NSString).draw(at: NSPoint(x: right, y: (bounds.height - size.height) / 2), withAttributes: attributes)
                right -= 12
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            if let problem = entry.theme?.problem?.text {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.errorText, .paragraphStyle: paragraph]
                let size = (problem as NSString).size(withAttributes: attributes)
                let width = min(size.width, max(0, right - 230))
                right -= width
                (problem as NSString).draw(with: NSRect(x: right, y: (bounds.height - size.height) / 2, width: width, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
                right -= 12
            }
            func part(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            }
            let line = NSMutableAttributedString()
            if !entry.detail.isEmpty && !entry.radio {
                line.append(part(entry.detail, .systemFont(ofSize: 13), Chrome.inkSecondary))
                line.append(part(" › ", .systemFont(ofSize: 13), Chrome.inkTertiary))
            }
            let titleColor: NSColor = entry.id == .connectTyped ? Chrome.linkText : entry.id == .clearRecent ? Chrome.inkSecondary : Chrome.ink
            let left: CGFloat = entry.id == .clearRecent ? 78 : entry.theme != nil ? 46 : 42
            let titleFont = NSFont.systemFont(ofSize: entry.id == .clearRecent ? 12 : 13, weight: entry.agent ? .semibold : .regular)
            let title = NSMutableAttributedString(attributedString: part(entry.title, titleFont, titleColor))
            if entry.id == .connectTyped {
                title.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: NSRange(location: 11, length: max(0, title.length - 11)))
            }
            line.append(title)
            if entry.radio { line.append(part(entry.detail, .systemFont(ofSize: 13), Chrome.inkSecondary)) }
            if let theme = entry.theme, theme.problem == nil {
                let tag = theme.background.isDark ? "dark" : "light"
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Chrome.inkSecondary]
                let size = (tag as NSString).size(withAttributes: attributes)
                let x = left + line.size().width + 8
                if x + size.width + 10 < right {
                    Chrome.themeTagFill.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - size.height - 2) / 2, width: size.width + 10, height: size.height + 2), xRadius: 4, yRadius: 4).fill()
                    (tag as NSString).draw(at: NSPoint(x: x + 5, y: (bounds.height - size.height) / 2), withAttributes: attributes)
                }
            }
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
            let prefix = entry.detail.isEmpty || entry.radio ? "" : entry.detail + " › "
            highlight(entry.title, offsets: offsets[0], font: titleFont,
                      x: left + (prefix as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)
            line.draw(with: NSRect(x: left, y: (bounds.height - height) / 2, width: max(0, right - left), height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static let entryHeight: CGFloat = 34
    var shown: [(entry: PaletteEntry, offsets: [[Int]])] = []
    var highlightColor = Chrome.ink {
        didSet {
            enumerateAvailableRowViews { _, row in
                if let cell = self.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell {
                    cell.highlightColor = self.highlightColor
                    cell.needsDisplay = true
                }
            }
        }
    }
    var choose: (Int) -> Void = { _ in }
    var hover: (Int?) -> Void = { _ in }
    private var hovered: Int? { didSet { if oldValue != hovered { hover(hovered) } } }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if shown.indices.contains(index), shown[index].entry.theme != nil || shown[index].entry.radio {
            if shown[index].entry.theme?.problem != nil { return }
            selectRowIndexes([index], byExtendingSelection: false)
            choose(index)
        } else { super.mouseDown(with: event) }
    }
    override func mouseMoved(with event: NSEvent) { let index = row(at: convert(event.locationInWindow, from: nil)); hovered = index >= 0 ? index : nil }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let index = visibleRect.contains(point) ? row(at: point) : -1
        hovered = index >= 0 ? index : nil
    }

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
        cell.setAccessibilityLabel([entry.title, entry.detail, entry.shortcut, entry.theme?.problem?.text ?? ""].filter { !$0.isEmpty }.joined(separator: ", ") + status)
        return cell
    }
}

final class PaletteView: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let runtime: GhosttyRuntime
    private(set) var theme: PaletteTheme?
    private let themeChip = ThemeChoiceChip()
    func themeChanged() {
        appearance = NSAppearance(named: runtime.background.isDark ? .darkAqua : .aqua)
        table.highlightColor = runtime.foreground
        if case .theme(let step) = mode {
            if theme?.configChanged() == true {
                shown = theme?.entries(step) ?? []
                let selection = table.selectedRowIndexes
                table.reloadData()
                table.selectRowIndexes(selection, byExtendingSelection: false)
            }
            themeStatus()
        }
        needsDisplay = true
        for view in [card, chip, themeChip, foot, errorLine] { view.needsDisplay = true }
    }
    func endPreview() {
        runtime.endThemePreview()
        theme = nil
        foot.theme = nil
        errorLine.theme = nil
    }
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
    var sessionName: (String) -> Void = { _ in }
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
        self.runtime = runtime
        card = PaneCapsule(runtime: runtime, radius: 12, surface: Chrome.cardSurface, edgeOutset: 0)
        card.shadow = nil
        super.init(frame: .zero)
        appearance = NSAppearance(named: runtime.background.isDark ? .darkAqua : .aqua)
        autoresizingMask = [.width, .height]
        addSubview(card)
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.placeholderString = "Search panes and commands"
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel("Command palette")
        separator.boxType = .separator
        footSeparator.boxType = .separator
        table.highlightColor = runtime.foreground
        table.choose = { [weak self] in self?.choose($0) }
        table.hover = { [weak self] index in
            guard let self, case .theme(.pick) = mode else { return }
            previewTheme(at: index ?? table.selectedRow)
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        for view in [field, separator, scroll, empty, chip, themeChip, errorLine, foot, footSeparator] { card.addSubview(view) }
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
        themeChip.isHidden = true
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
        if case .theme(.save(let row)) = mode {
            themeChip.row = row
            themeChip.isHidden = false
            themeChip.frame = NSRect(x: chip.frame.maxX + 8, y: preferredHeight - 34, width: themeChip.width, height: 22)
            field.frame.origin.x = themeChip.frame.maxX + 8
            field.frame.size.width = width - field.frame.minX - 16
        }
        separator.frame = NSRect(x: 0, y: list + footer + errorHeight, width: width, height: 1)
        let themeMode: Bool = if case .theme = mode { true } else { false }
        scroll.frame = NSRect(x: 0, y: footer + (themeMode ? errorHeight : 0), width: width, height: list)
        errorLine.frame = NSRect(x: 0, y: footer + (themeMode ? 0 : list), width: width, height: errorHeight)
        footSeparator.frame = NSRect(x: 0, y: footer, width: width, height: 1)
        foot.frame = NSRect(x: 0, y: 0, width: width, height: footer)
        table.tableColumns.first?.width = width
        empty.frame.size = empty.textSize
        empty.frame.origin = NSPoint(x: 36, y: scroll.frame.minY + (list - empty.frame.height) / 2)
    }

    private var listHeight: CGFloat {
        if case .sessionName = mode { return 0 }
        if mode == .connect, shown.isEmpty { return field.stringValue.isEmpty ? 42 : 8 }
        return shown.isEmpty ? PaletteList.entryHeight : CGFloat(min(shown.count, 12)) * PaletteList.entryHeight + 8 - (shown.prefix(12).contains { $0.entry.id == .clearRecent } ? 6 : 0)
    }
    var preferredHeight: CGFloat { if let prompt { 47 + prompt.preferredHeight } else { 45 + listHeight + (mode == .root ? 0 : 30) + (error == nil ? 0 : errorLine.height) } }

    func enter(_ mode: PaletteMode, prompt prepared: PalettePrompt? = nil) {
        guard mode != self.mode else { return }
        if case .prompt(let source) = mode, prepared == nil { return makePrompt(source) }
        (field.currentEditor() as? NSTextView)?.insertionPointColor = Chrome.insertion
        if case .theme = self.mode, case .theme = mode {} else { endPreview() }
        modeChanged()
        prompt?.storeDraft()
        prompt?.targetButton.removeFromSuperview()
        prompt?.removeFromSuperview()
        prompt = nil
        self.mode = mode
        error = nil
        field.stringValue = ""
        field.isEditable = true
        field.textColor = Chrome.fieldInk
        switch mode {
        case .theme(let step):
            if theme == nil { theme = PaletteTheme(runtime: runtime) }
            foot.theme = theme
            field.setAccessibilityLabel("Theme")
            switch step {
            case .pick:
                field.stringValue = theme?.query ?? ""
                field.placeholderString = "Search themes"
            case .save:
                runtime.flushTheme()
                if case .save(let row) = step { theme?.beginSave(row) }
                field.stringValue = "Use for…"
                field.textColor = Chrome.inkSecondary
            }
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
            field.placeholderString = "Search panes and commands"
            field.setAccessibilityLabel("Command palette")
        case .connect:
            field.placeholderString = "user@hostname or SSH alias"
            field.setAccessibilityLabel("Connect to remote host")
        case .sessionName(_, _, .create):
            field.placeholderString = "Session name"
        case .sessionName(_, _, .rename(_, let original)):
            field.placeholderString = ""
            field.stringValue = original
        }
        chip.mode = mode
        if case .sessionName = mode { field.setAccessibilityLabel(chip.title) }
        foot.mode = mode
        chip.needsDisplay = true
        foot.needsDisplay = true
        filter()
        if case .theme(let step) = mode {
            select(step == .pick ? theme?.selection ?? 0 : 0, preview: false)
            themeStatus()
        }
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(prompt?.textView ?? field)
        if prompt == nil { field.selectText(nil) }
        if let editor = field.currentEditor() as? NSTextView {
            let saving = if case .theme(.save) = mode { true } else { false }
            editor.insertionPointColor = saving ? .clear : Chrome.insertion
            if saving { editor.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
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
        if case .sessionName = mode { field.selectText(nil) }
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
        case .sessionName, .prompt: shown = []
        case .theme(let step):
            shown = theme?.entries(step) ?? []
        }
        table.reloadData()
        empty.text = mode == .connect ? "No recent hosts" : "No matches"
        empty.setAccessibilityElement(true)
        empty.setAccessibilityRole(.staticText)
        empty.setAccessibilityLabel(empty.text)
        empty.needsDisplay = true
        if prompt != nil { empty.isHidden = true }
        else if case .sessionName = mode { empty.isHidden = true }
        else { empty.isHidden = !shown.isEmpty || (mode == .connect && !field.stringValue.isEmpty) }
        scroll.isHidden = shown.isEmpty
        if case .theme = mode { table.selectRowIndexes([], byExtendingSelection: false) }
        else { select(0) }
        needsLayout = true
        if let panel = window as? PalettePanel { panel.resizeCard() }
    }

    private func select(_ row: Int, preview: Bool = true) {
        guard !shown.isEmpty else { return }
        let row = (row + shown.count) % shown.count
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        if case .theme(let step) = mode {
            if step == .pick {
                theme?.selection = row
                if preview { previewTheme(at: row) }
            } else if case .save(let choice) = step {
                if preview { theme?.selectRadio(row, row: choice) }
                foot.needsDisplay = true
            }
        }
    }

    private func previewTheme(at index: Int) {
        guard shown.indices.contains(index), let row = shown[index].entry.theme else { return }
        if theme?.preview(row) == true {
            shown = theme?.entries() ?? []
            table.reloadData()
        }
        themeStatus()
    }
    private func themeStatus() {
        error = if case .theme(.save) = mode { nil } else { theme?.status?.message }
        errorLine.message = error ?? ""
        errorLine.setAccessibilityElement(true)
        errorLine.setAccessibilityRole(.staticText)
        errorLine.setAccessibilityLabel(error ?? "")
        errorLine.theme = theme
        errorLine.needsDisplay = true
        window?.invalidateCursorRects(for: errorLine)
        needsLayout = true
        (window as? PalettePanel)?.resizeCard()
    }

    func choose(_ row: Int) {
        guard shown.indices.contains(row) else { return }
        let entry = shown[row].entry
        if case .theme(let step) = mode, let theme {
            switch step {
            case .pick:
                guard let value = entry.theme?.value else { return }
                let choice = theme.check(value)
                select(row)
                guard choice.problem == nil else { return }
                enter(.theme(.save(choice)))
            case .save(let choice):
                if row != theme.radio { theme.selectRadio(row, row: choice) }
                if theme.write(choice) { dismiss() }
                else { enter(.theme(.pick)); themeStatus() }
            }
        } else { chooseEntry(entry) }
    }

    func controlTextDidChange(_ notification: Notification) {
        if case .theme(.save) = mode { field.stringValue = "Use for…"; return }
        error = nil
        if case .theme(.pick) = mode { theme?.query = field.stringValue }
        filter()
        if case .theme(.pick) = mode { select(0); themeStatus() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)):
            if case .sessionName = mode { sessionName(field.stringValue) }
            else { choose(table.selectedRow) }
        case #selector(NSResponder.cancelOperation(_:)):
            if case .theme(.save) = mode { enter(.theme(.pick)) }
            else if mode == .root { dismiss() } else { enter(.root) }
        case #selector(NSResponder.deleteBackward(_:)):
            if case .theme(.save) = mode { enter(.theme(.pick)); return true }
            guard mode != .root, field.stringValue.isEmpty else { return false }
            enter(.root)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            if case .theme = mode { return true }; return false
        default:
            if case .theme(.save) = mode { return true }; return false
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

    override func close() {
        palette.endPreview()
        super.close()
    }

    override func resignKey() {
        super.resignKey()
        closed()
    }

}
