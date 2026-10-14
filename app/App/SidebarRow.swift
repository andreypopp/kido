import AppKit
import SidebarFeed

func drawStatusMark(_ status: SidebarRow.Status, at center: NSPoint, flipped: Bool) {
    let color: NSColor = switch status {
    case .quiet: .secondaryLabelColor.withAlphaComponent(NSColor.secondaryLabelColor.alphaComponent * 0.45)
    case .running, .done: .systemGreen
    case .waiting: .systemOrange
    case .error, .stalled: .systemRed
    }
    if status == .done {
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
           NSRect(x: 12, y: 6.5, width: max(0, bounds.width - 42), height: 18).contains(convert(event.locationInWindow, from: nil)) {
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
    #if KIDO_VISUAL
    private(set) var visualClockDirtyRect = NSRect.zero
    #endif
    let close = IconButton("xmark", "Close pane", size: 10, hoverStyle: .close)
    private var hovered = false
    override func mouseEntered(with event: NSEvent) { hovered = close.frame.contains(convert(event.locationInWindow, from: nil)); updateClose() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateClose() }
    private func updateClose() { close.isHidden = !hovered || row?.target == nil; needsDisplay = true }
    let addWindow = IconButton("plus", "New window", size: 11, hoverStyle: .iconOnly)
    override var isFlipped: Bool { true }

    init(_ fonts: SidebarFonts) {
        self.fonts = fonts
        super.init(frame: .zero)
        identifier = Self.id
        autoresizingMask = [.width, .height]
        focusRingType = .none
        addSubview(addWindow)
        addSubview(close)
        nameField.cell = SessionNameCell(textCell: "")
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.font = fonts.section
        nameField.textColor = .labelColor
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.focusRingType = .none
        nameField.drawsBackground = false
        nameField.delegate = self
        nameField.setAccessibilityLabel("Session name")
        nameField.isHidden = true
        renameError.font = .systemFont(ofSize: 10)
        renameError.textColor = .systemRed
        renameError.setAccessibilityRole(.group)
        renameError.setAccessibilitySubrole(.init(rawValue: "AXApplicationAlert"))
        renameError.isHidden = true
        addSubview(nameField)
        addSubview(renameError)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: SidebarRow) {
        self.row = row
        updateClose()
        close.setAccessibilityLabel("Close pane: " + row.title)
        addWindow.isHidden = { if case .header = row.kind { return false }; return true }()
        addWindow.toolTip = nil
        addWindow.setAccessibilityLabel("New window in " + row.title)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([row.title, row.tail, row.indicatorDescription].filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityValue(nil)
        updateClock()
        needsLayout = true
        needsDisplay = true
    }

    func updateClock() {
        #if KIDO_VISUAL
        let now = SidebarView.visualNow ?? Date()
        #else
        let now = Date()
        #endif
        let next = row?.started.map { sidebarElapsed(started: $0, now: now) } ?? ""
        guard next != clock else { return }
        let oldWidth = (clock as NSString).size(withAttributes: [.font: fonts.clock]).width
        let size = (next as NSString).size(withAttributes: [.font: fonts.clock])
        clock = next
        let padding = CGFloat(row?.padding ?? 7)
        let leading = CGFloat(row?.leading ?? 36)
        let dirtyRect = oldWidth == size.width
            ? NSRect(origin: NSPoint(x: bounds.width - 12 - size.width, y: padding + 2), size: size)
            : NSRect(x: leading, y: padding, width: max(0, bounds.width - 12 - leading), height: 18)
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
        close.frame = NSRect(x: CGFloat(row?.indicatorX ?? 20) - 8, y: CGFloat(row?.padding ?? 7) + 1, width: 16, height: 16)
        addWindow.frame = NSRect(x: bounds.width - 29, y: 0.5, width: 28, height: 28)
        nameField.frame = NSRect(x: 10, y: 6.5, width: max(0, bounds.width - 40), height: 18)
        renameError.frame = NSRect(x: 12, y: 26.5, width: max(0, bounds.width - 42), height: max(1, errorHeight - 6))
        updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: bounds).addClip()
            let pane = { if case .pane = row.kind { return true }; return false }()
            let leading = pane ? CGFloat(row.leading) : 12
            let selected = row.target != nil && (superview as? NSTableRowView)?.isSelected == true
                && (enclosingScrollView?.documentView as? Table)?.keyboardSelection == true
                && window?.firstResponder === enclosingScrollView?.documentView
            if row.focused || selected {
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: NSRect(x: CGFloat(row.indent) * 15, y: 0,
                                               width: bounds.width - CGFloat(row.indent) * 15, height: bounds.height),
                             xRadius: 7, yRadius: 7).fill()
            }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (dark ? NSColor(srgbRed: 79 / 255, green: 85 / 255, blue: 92 / 255, alpha: 1)
                  : NSColor(srgbRed: 191 / 255, green: 186 / 255, blue: 177 / 255, alpha: 1)).setFill()
            for guide in row.guides {
                let rect = NSRect(x: guide.x - 0.5, y: guide.top, width: 1, height: guide.bottom - guide.top)
                let pixels = convertToBacking(rect)
                convertFromBacking(NSRect(x: pixels.minX.rounded(), y: pixels.minY.rounded(),
                                          width: pixels.width.rounded(), height: pixels.height.rounded())).fill()
            }
            if case .gap = row.kind { return }
            let header = { if case .header = row.kind { return true }; return false }()
            let y: CGFloat = header ? 6.5 : row.padding
            let dotX = CGFloat(row.indicatorX)
            let clockWidth = (clock as NSString).size(withAttributes: [.font: fonts.clock]).width
            let end = header ? bounds.width - 30 : bounds.width - 12 - (clock.isEmpty ? 0 : clockWidth + 6)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleRect = NSRect(x: leading, y: y, width: max(0, end - leading), height: 18)
            if dirtyRect.intersects(titleRect), !header || nameField.isHidden {
                (row.title as NSString).draw(in: titleRect,
                                       withAttributes: [.font: header ? fonts.section : row.agent ? fonts.agent : fonts.regular,
                                                        .foregroundColor: header || row.quietShell ? NSColor.secondaryLabelColor : NSColor.labelColor,
                                                        .paragraphStyle: paragraph])
            }
            let tailRect = NSRect(x: leading, y: row.tailY, width: max(0, bounds.width - leading - 12), height: 15)
            if dirtyRect.intersects(tailRect) {
                (row.tail.split(whereSeparator: \.isNewline).joined(separator: " ") as NSString).draw(in: tailRect,
                                          withAttributes: [.font: fonts.tail, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            }
            (clock as NSString).draw(at: NSPoint(x: bounds.width - 12 - clockWidth, y: y + 2),
                                     withAttributes: [.font: fonts.clock, .foregroundColor: NSColor.secondaryLabelColor])
            if pane && close.isHidden {
                drawStatusMark(row.status, at: NSPoint(x: dotX, y: y + 9), flipped: true)
            }
        }
    }
}

final class SessionNameCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }
    override func draw(withFrame rect: NSRect, in view: NSView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.withAlphaComponent(0.4).setStroke()
            edge.lineWidth = 3
            edge.stroke()
            NSColor.separatorColor.setStroke()
            edge.lineWidth = 0.5
            edge.stroke()
        }
        drawInterior(withFrame: rect, in: view)
    }
}
