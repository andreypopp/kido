import AppKit
import KoModel
import SidebarFeed

func drawStatusMark(_ status: SidebarRow.Status, at center: NSPoint, flipped: Bool, scale k: CGFloat = 1) {
    let color: NSColor = switch status {
    case .quiet: Chrome.sidebarIdleCircle
    case .endedClean, .endedFailed: Chrome.inkSecondary
    case .running, .done: Chrome.statusRunning
    case .waiting: Chrome.statusWaiting
    case .error: Chrome.statusError
    }
    if status == .endedFailed {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - 2.2 * k, y: center.y - 2.2 * k))
        path.line(to: NSPoint(x: center.x + 2.2 * k, y: center.y + 2.2 * k))
        path.move(to: NSPoint(x: center.x - 2.2 * k, y: center.y + 2.2 * k))
        path.line(to: NSPoint(x: center.x + 2.2 * k, y: center.y - 2.2 * k))
        path.lineWidth = 2 * k
        path.lineCapStyle = .round
        color.setStroke(); path.stroke()
    } else if status == .done || status == .endedClean {
        let direction: CGFloat = flipped ? 1 : -1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - 2.8 * k, y: center.y + direction * 0.1 * k))
        path.line(to: NSPoint(x: center.x - 0.9 * k, y: center.y + direction * 2 * k))
        path.line(to: NSPoint(x: center.x + 2.8 * k, y: center.y - direction * 2 * k))
        path.lineWidth = 2 * k
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke(); path.stroke()
    } else {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: center.x - 3 * k, y: center.y - 3 * k, width: 6 * k, height: 6 * k)).fill()
    }
}

struct SidebarFonts {
    static let baseSize: CGFloat = 14
    let scale: CGFloat
    let compact: Bool
    let regular: NSFont
    let selected: NSFont
    let section: NSFont
    let tail: NSFont
    let clock: NSFont
    let suffix: NSFont

    init(size: CGFloat = baseSize, compact: Bool = false) {
        let k = size / Self.baseSize
        scale = k
        self.compact = compact
        regular = .systemFont(ofSize: 14 * k)
        selected = .systemFont(ofSize: 14 * k, weight: .semibold)
        section = .systemFont(ofSize: 11 * k, weight: .semibold)
        tail = .systemFont(ofSize: 11 * k)
        clock = .monospacedDigitSystemFont(ofSize: 10 * k, weight: .regular)
        suffix = .systemFont(ofSize: 13 * k)
    }

    func height(_ row: SidebarRow) -> CGFloat { ((compact ? row.compactHeight : row.height) * scale).rounded() }
    func tailY(_ row: SidebarRow) -> CGFloat { (compact ? row.compactTailY : row.tailY) * scale }
    var radius: CGFloat { (compact ? 5 : 7) * scale }
    var headerY: CGFloat { (compact ? 3.5 : 5) * scale }
}

final class SidebarChildren: NSView {
    var content: [SidebarRow.HiddenChild] = [] { didSet { needsDisplay = true } }
    var fonts: SidebarFonts { didSet { needsDisplay = true } }
    private let limit = 6
    private var name: String? { content.count == 1 ? content[0].title : nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(_ fonts: SidebarFonts) { self.fonts = fonts; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func width(showing count: Int) -> CGFloat {
        if content.isEmpty { return 0 }
        if let name, count == 1 { return ceil((name as NSString).size(withAttributes: [.font: fonts.tail]).width) + 12 * fonts.scale }
        let extra = content.count - count
        return (CGFloat(count * 10) + (extra > 0 ? (count > 0 ? 2 : 0) + 2 : 0)) * fonts.scale + (extra > 0 ? ceil(("+\(extra)" as NSString).size(withAttributes: [.font: fonts.clock]).width) : 0)
    }
    func fittingWidth(_ available: CGFloat) -> CGFloat {
        guard !content.isEmpty else { return 0 }
        if name != nil { return available >= 8 * fonts.scale ? min(available, width(showing: 1)) : 0 }
        for count in stride(from: min(limit, content.count), through: 0, by: -1) {
            let width = width(showing: count)
            if width <= available { return width }
        }
        return 0
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !content.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let k = fonts.scale
        func caption(_ text: String, x: CGFloat, width: CGFloat, font: NSFont) {
            guard width >= ceil(("…" as NSString).size(withAttributes: [.font: font]).width) else { return }
            (text as NSString).draw(in: NSRect(x: x, y: -k, width: max(0, width), height: 14 * k),
                                   withAttributes: [.font: font, .foregroundColor: Chrome.inkSecondary, .paragraphStyle: paragraph])
        }
        var count = min(limit, content.count)
        if name == nil { while count > 0 && width(showing: count) > bounds.width { count -= 1 } }
        for (index, child) in content.prefix(count).enumerated() {
            let center = NSPoint(x: name != nil ? bounds.width - 5 * k : CGFloat(5 + index * 10) * k, y: 6 * k)
            drawStatusMark(child.status, at: center, flipped: true, scale: k)
        }
        if let name { caption(name, x: 0, width: bounds.width - 12 * k, font: fonts.tail) }
        else if content.count > count {
            let x = CGFloat(count > 0 ? count * 10 + 2 : 0) * k
            caption("+\(content.count - count)", x: x, width: bounds.width - x - 2 * k, font: fonts.clock)
        }
    }
}

final class SidebarSelectionRow: NSTableRowView {
    override var frame: NSRect {
        get { super.frame }
        set { super.frame = superview?.backingAlignedRect(newValue, options: .alignAllEdgesNearest) ?? newValue }
    }
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isSelected: Bool { didSet { subviews.forEach { $0.needsDisplay = true } } }
}

final class SidebarCell: NSTableCellView, NSTextFieldDelegate {
    let nameField = NSTextField()
    let renameError = NSTextField(wrappingLabelWithString: "")
    var beginRename: () -> Void = {}
    var finishRename: (Bool) -> Void = { _ in }
    var renameChanged: () -> Void = {}
    var press: () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        guard row?.pick != nil else { return false }
        press()
        return true
    }

    private var k: CGFloat { fonts.scale }

    override func mouseDown(with event: NSEvent) {
        if case .header = row?.kind, event.clickCount == 2,
           NSRect(x: 5 * k, y: fonts.headerY, width: max(0, bounds.width - 29 * k), height: 18 * k).contains(convert(event.locationInWindow, from: nil)) {
            beginRename()
        } else { super.mouseDown(with: event) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) { finishRename(true); return true }
        if selector == #selector(cancelOperation(_:)) { finishRename(false); return true }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) { finishRename(true) }
    func controlTextDidChange(_ notification: Notification) { renameChanged() }

    var errorHeight: CGFloat {
        guard !renameError.isHidden else { return 0 }
        return ceil((renameError.stringValue as NSString).boundingRect(
            with: NSSize(width: max(1, bounds.width - 29 * k), height: 1000), options: [.usesLineFragmentOrigin],
            attributes: [.font: renameError.font!]).height) + 6 * k
    }
    static let id = NSUserInterfaceItemIdentifier("cell")
    var fonts: SidebarFonts {
        didSet {
            children.fonts = fonts
            nameField.font = fonts.section
            needsLayout = true
            needsDisplay = true
        }
    }
    private var row: SidebarRow?
    private var clock = ""
    private var clockWidth: CGFloat = 0
    private var trailing: CGFloat { 18 * k }
    private var clockRect: NSRect {
        guard let row else { return .zero }
        return NSRect(x: bounds.width - trailing - clockWidth, y: (row.padding + 2) * k, width: clockWidth, height: fonts.clock.boundingRectForFont.height)
    }
    #if KIDO_VISUAL
    private(set) var visualClockDirtyRect = NSRect.zero
    #endif
    var terminalDark = false
    private var second = ""
    private var pending = false
    private var closable: Bool { row?.target != nil || row?.closing != nil }
    private var runtimeText: NSAttributedString?
    let close = IconButton("xmark", "Close pane", size: 8, hoverStyle: .close)
    let children: SidebarChildren
    private var hovered = false
    override func mouseEntered(with event: NSEvent) { hovered = close.frame.contains(convert(event.locationInWindow, from: nil)); updateClose() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateClose() }
    private func updateClose() { close.isHidden = !hovered || !closable || pending; needsDisplay = true }
    let addWindow = IconButton("plus", "New window", size: 11, hoverStyle: .iconOnly)
    override var isFlipped: Bool { true }

    init(_ fonts: SidebarFonts) {
        self.fonts = fonts
        children = SidebarChildren(fonts)
        super.init(frame: .zero)
        identifier = Self.id
        autoresizingMask = [.width, .height]
        focusRingType = .none
        addSubview(addWindow)
        addSubview(close)
        addSubview(children)
        nameField.cell = SessionNameCell(textCell: "")
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.font = fonts.section
        nameField.textColor = Chrome.ink
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.focusRingType = .none
        nameField.drawsBackground = false
        nameField.delegate = self
        nameField.setAccessibilityLabel("Session name")
        nameField.isHidden = true
        renameError.font = .systemFont(ofSize: 10)
        renameError.textColor = Chrome.errorText
        renameError.setAccessibilityRole(.group)
        renameError.setAccessibilitySubrole(.init(rawValue: "AXApplicationAlert"))
        renameError.isHidden = true
        addSubview(nameField)
        addSubview(renameError)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: SidebarRow, now: Int, closing: Bool = false) {
        self.row = row
        pending = closing
        children.content = row.hidden
        children.isHidden = row.hidden.isEmpty
        let folded = row.hidden.isEmpty ? "" : "\(row.hidden.count) folded children"
        second = secondLine(row.second, status: row.status)
        updateClose()
        close.setAccessibilityLabel(row.target != nil ? "Close pane: " + row.title : row.title)
        close.toolTip = row.target != nil ? "Close pane" : nil
        close.setAccessibilityCustomActions(row.target != nil ? [] : [NSAccessibilityCustomAction(name: "Close") { [weak self] in self?.close.invoke(); return true }])
        addWindow.isHidden = { if case .header = row.kind { return false }; return true }()
        addWindow.toolTip = nil
        addWindow.setAccessibilityLabel("New window in " + row.title)
        setAccessibilityElement(row.kind != .divider && row.kind != .gap)
        setAccessibilityRole(row.pick == nil ? .staticText : .button)
        toolTip = row.runtime?.failure
        runtimeText = row.runtime.map { Self.suffixText($0, font: fonts.suffix) }
        setAccessibilityLabel([row.title, row.runtime.map { "runtime " + $0.name }, second, folded, row.indicatorDescription].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityValue(nil)
        updateClock(now: now)
        needsLayout = true
        needsDisplay = true
    }

    func updateClock(now: Int) {
        guard let row else { return }
        let next = row.started.map { sidebarElapsed(started: $0, now: now) } ?? ""
        guard next != clock else { return }
        let oldWidth = clockWidth
        clockWidth = (next as NSString).size(withAttributes: [.font: fonts.clock]).width
        clock = next
        let leading = CGFloat(row.leading) * k
        let dirtyRect = oldWidth == clockWidth
            ? clockRect
            : NSRect(x: leading, y: row.padding * k, width: max(0, bounds.width - 12 * k - leading), height: 19 * k)
        #if KIDO_VISUAL
        visualClockDirtyRect = dirtyRect
        #endif
        setNeedsDisplay(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if closable {
            addTrackingArea(NSTrackingArea(rect: close.frame, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }
    }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: bounds.width - 17 * k, y: CGFloat((row?.padding ?? 5) + 3) * k, width: 12 * k, height: 12 * k)
        if let row {
            let width = children.fittingWidth(max(0, bounds.width - row.leading * k - 6 * k))
            children.isHidden = children.content.isEmpty || width == 0
            children.frame = NSRect(x: bounds.width - 6 * k - width, y: fonts.tailY(row), width: width, height: 12 * k)
        }
        addWindow.frame = NSRect(x: bounds.width - 22 * k, y: 0, width: 22 * k, height: (fonts.compact ? 22 : 28) * k)
        nameField.frame = NSRect(x: 3 * k, y: fonts.headerY, width: max(0, bounds.width - 27 * k), height: 18 * k)
        renameError.frame = NSRect(x: 5 * k, y: fonts.headerY + 21.5 * k, width: max(0, bounds.width - 29 * k), height: max(1, errorHeight - 6 * k))
        updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: bounds).addClip()
            let selected = row.clickTarget != nil && (superview as? NSTableRowView)?.isSelected == true
                && (enclosingScrollView?.documentView as? Table)?.keyboardSelection == true
                && window?.firstResponder === enclosingScrollView?.documentView
            let rowFill = NSBezierPath(roundedRect: NSRect(x: CGFloat(row.indent) * 15 * k, y: 0,
                                                         width: bounds.width - CGFloat(row.indent) * 15 * k, height: bounds.height),
                                       xRadius: fonts.radius, yRadius: fonts.radius)
            if let block = row.block {
                let top: CGFloat = block == .last || block == .middle ? -fonts.radius : 0
                let bottom: CGFloat = block == .first || block == .middle ? fonts.radius : 0
                let slice = NSBezierPath(roundedRect: NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top + bottom), xRadius: fonts.radius, yRadius: fonts.radius)
                slice.addClip()
                NSGraphicsContext.saveGraphicsState()
                if row.focused || selected {
                    let outside = NSBezierPath(rect: bounds)
                    outside.append(rowFill)
                    outside.windingRule = .evenOdd
                    outside.addClip()
                }
                Chrome.windowSelection.setFill()
                bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if case .divider = row.kind {
                Chrome.sidebarDivider.setFill()
                NSRect(x: 5 * k, y: 4 * k, width: max(0, bounds.width - 10 * k), height: 1).fill()
                return
            }
            let pane: Bool = switch row.kind { case .pane, .program: true; default: false }
            let leading = (pane ? CGFloat(row.leading) : 5) * k
            if row.focused || selected {
                Chrome.rowSelection.setFill()
                rowFill.fill()
            }
            if case .gap = row.kind { return }
            let header = { if case .header = row.kind { return true }; return false }()
            let y: CGFloat = header ? fonts.headerY : row.padding * k
            let line: CGFloat = (header ? 18 : 19) * k
            let dotX = bounds.width - 11 * k
            let end = header ? addWindow.frame.minX : bounds.width - (clock.isEmpty ? 23 * k : trailing + clockWidth + 6 * k)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let context = NSGraphicsContext.current?.cgContext
            let dim: CGFloat = pending ? 0.5 : 1
            context?.setAlpha(dim)
            var titleRect = NSRect(x: leading, y: y, width: max(0, end - leading), height: line)
            let titleFont = header ? fonts.section : (row.focused || selected) ? fonts.selected : fonts.regular
            var suffix = NSRect.zero
            if let text = runtimeText, !header {
                // The title gives way first; the suffix is cut only when the row has no room for it alone.
                let natural = 16 * k + ceil(text.size().width)
                let titleNatural = ceil((row.title as NSString).size(withAttributes: [.font: titleFont]).width)
                let width = min(natural, titleRect.width)
                titleRect.size.width = max(0, min(titleNatural, titleRect.width - width))
                suffix = NSRect(x: titleRect.maxX, y: y, width: width, height: line)
            }
            if titleRect.width >= ceil(("…" as NSString).size(withAttributes: [.font: titleFont]).width),
               dirtyRect.intersects(titleRect), !header || nameField.isHidden {
                (row.title as NSString).draw(in: titleRect,
                                       withAttributes: [.font: titleFont,
                                                        .foregroundColor: header || row.quietShell ? Chrome.inkSecondary : Chrome.ink,
                                                        .paragraphStyle: paragraph])
            }
            if let mark = row.runtime, let text = runtimeText, !header, suffix.width > 6 * k {
                Chrome.drawRuntimeSwatch(mark, at: NSPoint(x: suffix.minX + 9 * k, y: y + line / 2), dark: terminalDark)
                text.draw(in: NSRect(x: suffix.minX + 16 * k, y: y, width: max(0, suffix.width - 16 * k), height: line))
            }
            let tailEnd = children.isHidden ? bounds.width - 5 * k : children.frame.minX - 6 * k
            let tailRect = NSRect(x: leading, y: fonts.tailY(row), width: max(0, tailEnd - leading), height: 14 * k)
            if tailRect.width >= 16 * k, dirtyRect.intersects(tailRect) {
                (second as NSString).draw(in: tailRect,
                                          withAttributes: [.font: fonts.tail, .foregroundColor: Chrome.inkSecondary, .paragraphStyle: paragraph])
            }
            context?.setAlpha(1)
            (clock as NSString).draw(at: clockRect.origin,
                                     withAttributes: [.font: fonts.clock, .foregroundColor: Chrome.inkSecondary])
            if pane && close.isHidden {
                context?.setAlpha(dim)
                drawStatusMark(row.status, at: NSPoint(x: dotX, y: y + line / 2), flipped: true, scale: k)
            }
        }
    }
}

extension SidebarRow.Status {
    var recordWord: String {
        switch self {
        case .running: "working"
        case .waiting: "needs your input"
        case .error, .endedFailed: "error"
        case .done, .endedClean: "done"
        case .quiet: "idle"
        }
    }
}

extension SidebarCell {
    fileprivate func secondLine(_ line: SidebarRow.SecondLine, status: SidebarRow.Status) -> String {
        let text: String = switch line {
        case .none: ""
        case .activity(let text): text
        case .record(let msg): msg.flatMap { $0.isEmpty ? nil : $0 } ?? status.recordWord
        }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    // The runtime's name after the title, with its state when it is not up.
    fileprivate static func suffixText(_ mark: RuntimeMark, font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Chrome.inkSecondary, .paragraphStyle: paragraph]
        let text = NSMutableAttributedString(string: mark.name + (mark.state == .starting ? " · " + mark.stateWord : ""), attributes: attributes)
        if mark.failure != nil {
            text.append(NSAttributedString(string: " · " + mark.stateWord, attributes: attributes.merging([.foregroundColor: Chrome.errorText]) { $1 }))
        }
        return text
    }
}

final class SessionNameCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }
    override func draw(withFrame rect: NSRect, in view: NSView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            Chrome.renameEdge.setStroke()
            edge.lineWidth = 3
            edge.stroke()
            Chrome.hairline.setStroke()
            edge.lineWidth = 0.5
            edge.stroke()
        }
        drawInterior(withFrame: rect, in: view)
    }
}
