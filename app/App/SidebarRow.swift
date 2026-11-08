import AppKit
import KoModel
import SidebarFeed

func drawStatusMark(_ status: SidebarRow.Status, at center: NSPoint, flipped: Bool) {
    guard status != .quiet else { return }
    let color: NSColor = switch status {
    case .quiet, .endedClean, .endedFailed: Chrome.inkSecondary
    case .running, .done: Chrome.statusRunning
    case .waiting: Chrome.statusWaiting
    case .error: Chrome.statusError
    }
    if status == .endedFailed {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - 2.2, y: center.y - 2.2))
        path.line(to: NSPoint(x: center.x + 2.2, y: center.y + 2.2))
        path.move(to: NSPoint(x: center.x - 2.2, y: center.y + 2.2))
        path.line(to: NSPoint(x: center.x + 2.2, y: center.y - 2.2))
        path.lineWidth = 2
        path.lineCapStyle = .round
        color.setStroke(); path.stroke()
    } else if status == .done || status == .endedClean {
        let direction: CGFloat = flipped ? 1 : -1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - 2.8, y: center.y + direction * 0.1))
        path.line(to: NSPoint(x: center.x - 0.9, y: center.y + direction * 2))
        path.line(to: NSPoint(x: center.x + 2.8, y: center.y - direction * 2))
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke(); path.stroke()
    } else {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
    }
}

struct SidebarFonts {
    let regular = NSFont.systemFont(ofSize: 13)
    let agent = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let section = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let tail = NSFont.systemFont(ofSize: 11)
    let clock = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
}

final class SidebarDisclosure: MouseButton {
    var invoke: () -> Void = {}
    var content = SidebarRow.Children.leaf { didSet { needsDisplay = true } }
    private let fonts: SidebarFonts
    private let limit = 6
    private var hovered = false
    private var caption: (text: String, x: CGFloat, font: NSFont)? {
        guard case .folded(let children) = content else { return nil }
        if children.count == 1 { return (children[0].title, 14, fonts.tail) }
        if children.count > limit { return ("+\(children.count - limit)", CGFloat(limit * 10 + 4), fonts.clock) }
        return nil
    }
    var naturalWidth: CGFloat {
        if let caption { return caption.x + 2 + (caption.text as NSString).size(withAttributes: [.font: caption.font]).width }
        if case .folded(let children) = content { return CGFloat(min(limit, children.count) * 10) }
        return 12
    }
    override var isFlipped: Bool { true }
    init(_ fonts: SidebarFonts) {
        self.fonts = fonts
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .none
        target = self
        action = #selector(activate)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show child panes")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func activate() { invoke() }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            Chrome.closeHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let opacity: CGFloat = if hovered { 1 } else if case .expanded = content { 0.75 } else { 0.9 }
        NSGraphicsContext.current?.cgContext.setAlpha(opacity)
        switch content {
        case .folded(let children):
            for (index, child) in children.prefix(limit).enumerated() {
                drawStatusMark(child.status, at: NSPoint(x: 5 + index * 10, y: 6), flipped: true)
            }
            guard let caption else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (caption.text as NSString).draw(in: NSRect(x: caption.x, y: -1, width: max(0, bounds.width - caption.x - 2), height: 14), withAttributes: [.font: caption.font, .foregroundColor: Chrome.inkSecondary, .paragraphStyle: paragraph])
        case .expanded:
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(hierarchicalColor: Chrome.inkSecondary))
            if let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                image.draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2, width: image.size.width, height: image.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .leaf: break
        }
    }
}

final class SidebarSelectionRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isSelected: Bool { didSet { subviews.forEach { $0.needsDisplay = true } } }
}

final class SidebarCell: NSTableCellView, NSTextFieldDelegate {
    let nameField = NSTextField()
    let renameError = NSTextField(wrappingLabelWithString: "")
    var beginRename: () -> Void = {}
    var finishRename: (Bool) -> Void = { _ in }
    var renameChanged: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        if case .header = row?.kind, event.clickCount == 2,
           NSRect(x: 12, y: 5, width: max(0, bounds.width - 42), height: 18).contains(convert(event.locationInWindow, from: nil)) {
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
            with: NSSize(width: max(1, bounds.width - 42), height: 1000), options: [.usesLineFragmentOrigin],
            attributes: [.font: renameError.font!]).height) + 6
    }
    static let id = NSUserInterfaceItemIdentifier("cell")
    private let fonts: SidebarFonts
    private var row: SidebarRow?
    private var clock = ""
    private var clockWidth: CGFloat = 0
    private var trailing: CGFloat { if case .expanded? = row?.children { 30 } else { 12 } }
    private var clockRect: NSRect {
        guard let row else { return .zero }
        return NSRect(x: bounds.width - trailing - clockWidth, y: row.padding + 2, width: clockWidth, height: fonts.clock.boundingRectForFont.height)
    }
    #if KIDO_VISUAL
    private(set) var visualClockDirtyRect = NSRect.zero
    #endif
    var terminalDark = false
    private var runtimeText: NSAttributedString?
    let close = IconButton("xmark", "Close pane", size: 8, hoverStyle: .close)
    let disclosure: SidebarDisclosure
    private var hovered = false
    override func mouseEntered(with event: NSEvent) { hovered = close.frame.contains(convert(event.locationInWindow, from: nil)); updateClose() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateClose() }
    private func updateClose() { close.isHidden = !hovered || row?.target == nil; needsDisplay = true }
    let addWindow = IconButton("plus", "New window", size: 11, hoverStyle: .iconOnly)
    override var isFlipped: Bool { true }

    init(_ fonts: SidebarFonts) {
        self.fonts = fonts
        disclosure = SidebarDisclosure(fonts)
        super.init(frame: .zero)
        identifier = Self.id
        autoresizingMask = [.width, .height]
        focusRingType = .none
        addSubview(addWindow)
        addSubview(close)
        addSubview(disclosure)
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

    func configure(_ row: SidebarRow, now: Int) {
        self.row = row
        disclosure.content = row.children
        switch row.children {
        case .folded: disclosure.isHidden = false; disclosure.setAccessibilityLabel("Show children of " + row.title)
        case .expanded: disclosure.isHidden = false; disclosure.setAccessibilityLabel("Hide children of " + row.title)
        case .leaf: disclosure.isHidden = true
        }
        updateClose()
        close.setAccessibilityLabel("Close pane: " + row.title)
        addWindow.isHidden = { if case .header = row.kind { return false }; return true }()
        addWindow.toolTip = nil
        addWindow.setAccessibilityLabel("New window in " + row.title)
        setAccessibilityElement(true)
        setAccessibilityRole(disclosure.isHidden ? .staticText : .group)
        toolTip = row.runtime?.failure
        runtimeText = row.runtime.map(Self.suffixText)
        setAccessibilityLabel([row.title, row.runtime.map { "runtime " + $0.name }, row.tail, row.indicatorDescription].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
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
        let leading = CGFloat(row.leading)
        let dirtyRect = oldWidth == clockWidth
            ? clockRect
            : NSRect(x: leading, y: row.padding, width: max(0, bounds.width - 12 - leading), height: 18)
        #if KIDO_VISUAL
        visualClockDirtyRect = dirtyRect
        #endif
        setNeedsDisplay(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: close.frame, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: CGFloat(row?.indicatorX ?? 18) - 6, y: CGFloat(row?.padding ?? 5) + 3, width: 12, height: 12)
        if let row {
            switch row.children {
            case .folded:
                disclosure.frame = NSRect(x: row.leading - 2, y: row.childrenY, width: min(disclosure.naturalWidth, max(0, bounds.width - row.leading - 10)), height: 12)
            default: disclosure.frame = NSRect(x: bounds.width - 24, y: row.padding + 3, width: 12, height: 12)
            }
        }
        addWindow.frame = NSRect(x: bounds.width - 33, y: 0, width: 26, height: 26)
        nameField.frame = NSRect(x: 10, y: 5, width: max(0, bounds.width - 40), height: 18)
        renameError.frame = NSRect(x: 12, y: 26.5, width: max(0, bounds.width - 42), height: max(1, errorHeight - 6))
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
            let pane: Bool = switch row.kind { case .pane, .program: true; default: false }
            let leading = pane ? CGFloat(row.leading) : 12
            let selected = row.target != nil && (superview as? NSTableRowView)?.isSelected == true
                && (enclosingScrollView?.documentView as? Table)?.keyboardSelection == true
                && window?.firstResponder === enclosingScrollView?.documentView
            if row.focused || selected {
                Chrome.rowSelection.setFill()
                NSBezierPath(roundedRect: NSRect(x: CGFloat(row.indent) * 15, y: 0,
                                               width: bounds.width - CGFloat(row.indent) * 15, height: bounds.height),
                             xRadius: 4, yRadius: 4).fill()
            }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            Chrome.treeGuide(dark: dark).setFill()
            for guide in row.guides {
                let rect = NSRect(x: guide.x - 0.5, y: guide.top, width: 1, height: guide.bottom - guide.top)
                let pixels = convertToBacking(rect)
                convertFromBacking(NSRect(x: pixels.minX.rounded(), y: pixels.minY.rounded(),
                                          width: pixels.width.rounded(), height: pixels.height.rounded())).fill()
            }
            if case .gap = row.kind { return }
            let header = { if case .header = row.kind { return true }; return false }()
            let y: CGFloat = header ? 5 : row.padding
            let dotX = CGFloat(row.indicatorX)
            let end = header ? bounds.width - 28 : bounds.width - trailing - (clock.isEmpty ? 0 : clockWidth + 6)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            var titleRect = NSRect(x: leading, y: y, width: max(0, end - leading), height: 18)
            let titleFont = header ? fonts.section : row.agent ? fonts.agent : fonts.regular
            var suffix = NSRect.zero
            if let text = runtimeText, !header {
                // The title gives way first; the suffix is cut only when the row has no room for it alone.
                let natural = 16 + ceil(text.size().width)
                let titleNatural = ceil((row.title as NSString).size(withAttributes: [.font: titleFont]).width)
                let width = min(natural, titleRect.width)
                titleRect.size.width = max(0, min(titleNatural, titleRect.width - width))
                suffix = NSRect(x: titleRect.maxX, y: y, width: width, height: 18)
            }
            if dirtyRect.intersects(titleRect), !header || nameField.isHidden {
                (row.title as NSString).draw(in: titleRect,
                                       withAttributes: [.font: titleFont,
                                                        .foregroundColor: header || row.quietShell ? Chrome.inkSecondary : Chrome.ink,
                                                        .paragraphStyle: paragraph])
            }
            if let mark = row.runtime, let text = runtimeText, !header, suffix.width > 6 {
                Chrome.drawRuntimeSwatch(mark, at: NSPoint(x: suffix.minX + 9, y: y + 9), dark: terminalDark)
                text.draw(in: NSRect(x: suffix.minX + 16, y: y, width: max(0, suffix.width - 16), height: 18))
            }
            let tailRect = NSRect(x: leading, y: row.tailY, width: max(0, bounds.width - leading - 12), height: 14)
            if dirtyRect.intersects(tailRect) {
                (row.tail.split(whereSeparator: \.isNewline).joined(separator: " ") as NSString).draw(in: tailRect,
                                          withAttributes: [.font: fonts.tail, .foregroundColor: Chrome.inkSecondary, .paragraphStyle: paragraph])
            }
            (clock as NSString).draw(at: clockRect.origin,
                                     withAttributes: [.font: fonts.clock, .foregroundColor: Chrome.inkSecondary])
            if pane && close.isHidden {
                drawStatusMark(row.status, at: NSPoint(x: dotX, y: y + 9), flipped: true)
            }
        }
    }
}

extension SidebarCell {
    // The runtime's name after the title, with its state when it is not up.
    fileprivate static func suffixText(_ mark: RuntimeMark) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Chrome.inkSecondary, .paragraphStyle: paragraph]
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
