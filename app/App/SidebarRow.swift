import AppKit
import SidebarFeed

struct SidebarFonts {
    let regular = NSFont.systemFont(ofSize: 12)
    let small = NSFont.systemFont(ofSize: 11)
    let section = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let tail = NSFont.systemFont(ofSize: 10)
    let clock = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
}

final class SidebarSelectionRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isSelected: Bool { didSet { subviews.forEach { $0.needsDisplay = true } } }
}

final class SidebarCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("cell")
    private let fonts: SidebarFonts
    private var row: SidebarRow?
    private var clock = ""
    var fold: () -> Void = {}
    let addWindow = IconButton("plus", "New window", size: 13, hoverStyle: .iconOnly)
    override var isFlipped: Bool { true }

    init(_ fonts: SidebarFonts) {
        self.fonts = fonts
        super.init(frame: .zero)
        identifier = Self.id
        addSubview(addWindow)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: SidebarRow, expanded: Bool) {
        self.row = row
        addWindow.isHidden = { if case .header = row.kind { return false }; return true }()
        addWindow.toolTip = "New window in " + row.title
        toolTip = [row.title, row.tail, row.indicatorDescription].filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityElement(true)
        setAccessibilityRole(addWindow.isHidden ? .staticText : .button)
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(addWindow.isHidden ? nil : expanded ? "expanded" : "collapsed")
        updateClock()
        needsLayout = true
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard case .header? = row?.kind else { return false }
        fold()
        return true
    }

    func updateClock() {
        #if KIDO_VISUAL
        let now = SidebarView.visualNow ?? Date()
        #else
        let now = Date()
        #endif
        let next = row?.started.map { sidebarElapsed(started: $0, now: now) } ?? ""
        guard next != clock, let row else { return }
        let oldWidth = (clock as NSString).size(withAttributes: [.font: fonts.clock]).width
        let width = (next as NSString).size(withAttributes: [.font: fonts.clock]).width
        clock = next
        let y: CGFloat = row.indent == 0 ? 8 : 7
        let leading = oldWidth == width ? bounds.width - 26 - width : 12 + CGFloat(row.indent) * 17
        setNeedsDisplay(NSRect(x: leading, y: y - 1, width: max(0, bounds.width - 26 - leading), height: 17))
    }

    override func layout() {
        super.layout()
        addWindow.frame = NSRect(x: bounds.width - 28, y: 1.5, width: 28, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            for segment in row.segments {
                let x = segment.kind == .card ? 0 : CGFloat(segment.indent) * 17
                let rect = NSRect(x: x, y: segment.top, width: bounds.width - x, height: segment.height)
                let path = NSBezierPath()
                let tl = CGFloat(segment.topLeft), bl = CGFloat(segment.bottomLeft)
                let tr = segment.kind == .card ? tl : 0, br = segment.kind == .card ? bl : 0
                path.move(to: NSPoint(x: rect.minX + tl, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX - tr, y: rect.minY))
                path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + tr), controlPoint1: NSPoint(x: rect.maxX, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - br))
                path.curve(to: NSPoint(x: rect.maxX - br, y: rect.maxY), controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY), controlPoint2: NSPoint(x: rect.maxX, y: rect.maxY))
                path.line(to: NSPoint(x: rect.minX + bl, y: rect.maxY))
                path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - bl), controlPoint1: NSPoint(x: rect.minX, y: rect.maxY), controlPoint2: NSPoint(x: rect.minX, y: rect.maxY))
                path.line(to: NSPoint(x: rect.minX, y: rect.minY + tl))
                path.curve(to: NSPoint(x: rect.minX + tl, y: rect.minY), controlPoint1: NSPoint(x: rect.minX, y: rect.minY), controlPoint2: NSPoint(x: rect.minX, y: rect.minY))
                path.close()
                switch segment.kind {
                case .card:
                    NSColor.labelColor.withAlphaComponent(0.025).setFill(); path.fill()
                    NSColor.labelColor.withAlphaComponent(0.075).setStroke()
                    path.lineWidth = 1; path.stroke()
                case .window(let active):
                    if active { NSColor.labelColor.withAlphaComponent(0.075).setFill(); path.fill() }
                }
                path.addClip()
            }
            let leading = (row.target == nil ? 10 : 12) + CGFloat(row.indent) * 17
            if row.focused {
                NSColor.labelColor.withAlphaComponent(0.10).setFill(); bounds.fill()
                NSColor.labelColor.withAlphaComponent(0.45).setFill()
                NSRect(x: CGFloat(row.indent) * 17 + 1, y: 8, width: 2, height: bounds.height - 16).fill()
            }
            if (superview as? NSTableRowView)?.isSelected == true, window?.firstResponder === enclosingScrollView?.documentView {
                NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.6).setStroke()
                NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
            if case .divider = row.kind {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSRect(x: CGFloat(row.indent) * 17, y: 4, width: bounds.width, height: 0.5).fill()
                return
            }
            if case .gap = row.kind { return }
            let header = { if case .header = row.kind { return true }; return false }()
            let y: CGFloat = header ? 8 : row.indent == 0 ? 7 : 6
            let dotX = bounds.width - 14
            let clockWidth = (clock as NSString).size(withAttributes: [.font: fonts.clock]).width
            let end = header ? bounds.width - 30 : dotX - 12 - (clock.isEmpty ? 0 : clockWidth + 6)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (row.title as NSString).draw(in: NSRect(x: leading, y: y, width: max(0, end - leading), height: 16),
                                       withAttributes: [.font: header ? fonts.section : row.indent == 0 ? fonts.regular : fonts.small,
                                                        .foregroundColor: header ? NSColor.secondaryLabelColor : NSColor.labelColor,
                                                        .paragraphStyle: paragraph])
            (row.tail as NSString).draw(in: NSRect(x: leading, y: y + 18, width: max(0, dotX - leading - 10), height: 14),
                                      withAttributes: [.font: fonts.tail, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            (clock as NSString).draw(at: NSPoint(x: dotX - 12 - clockWidth, y: y + 1),
                                     withAttributes: [.font: fonts.clock, .foregroundColor: NSColor.secondaryLabelColor])
            let color: NSColor? = switch row.status {
            case .quiet: nil; case .running: .systemGreen; case .attention: .systemOrange; case .error: .systemRed
            }
            if let color { color.setFill(); NSBezierPath(ovalIn: NSRect(x: dotX - 3, y: y + 4, width: 6, height: 6)).fill() }
        }
    }
}
