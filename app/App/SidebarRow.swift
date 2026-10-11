import AppKit
import SidebarFeed

struct SidebarFonts {
    let regular = NSFont.systemFont(ofSize: 13)
    let section = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let tail = NSFont.systemFont(ofSize: 11)
    let clock = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
}

final class SidebarSelectionRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isSelected: Bool { didSet { subviews.forEach { $0.needsDisplay = true } } }
}

final class SidebarCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("cell")
    private static let icons: [SidebarRow.Icon: NSImage] = Dictionary(uniqueKeysWithValues:
        [SidebarRow.Icon.agent, .terminal].compactMap { icon in
            (NSImage(systemSymbolName: icon.rawValue, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))?
                .withSymbolConfiguration(.init(paletteColors: [.labelColor])))
                .map { (icon, $0) }
        })
    private let fonts: SidebarFonts
    private var row: SidebarRow?
    private var clock = ""
    #if KIDO_VISUAL
    private(set) var visualClockDirtyRect = NSRect.zero
    #endif
    let addWindow = IconButton("plus", "New window", size: 11, hoverStyle: .iconOnly)
    override var isFlipped: Bool { true }

    init(_ fonts: SidebarFonts) {
        self.fonts = fonts
        super.init(frame: .zero)
        identifier = Self.id
        focusRingType = .none
        addSubview(addWindow)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: SidebarRow) {
        self.row = row
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
            ? NSRect(origin: NSPoint(x: bounds.width - 27 - size.width, y: padding + 2), size: size)
            : NSRect(x: leading, y: padding, width: max(0, bounds.width - 27 - leading), height: 18)
        #if KIDO_VISUAL
        visualClockDirtyRect = dirtyRect
        #endif
        setNeedsDisplay(dirtyRect)
    }

    override func layout() {
        super.layout()
        addWindow.frame = NSRect(x: bounds.width - 29, y: 0.5, width: 28, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: bounds).addClip()
            let program = { if case .program = row.kind { return true }; return false }()
            let leading = row.target == nil && !program ? 12 : CGFloat(row.leading)
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
            let dotX = bounds.width - 15
            let iconRect = NSRect(x: leading - 24, y: y + 1, width: 16, height: 16)
            if !header && !program && dirtyRect.intersects(iconRect) {
                Self.icons[row.icon]?.draw(in: iconRect,
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let clockWidth = (clock as NSString).size(withAttributes: [.font: fonts.clock]).width
            let end = header ? bounds.width - 30 : dotX - 12 - (clock.isEmpty ? 0 : clockWidth + 6)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleRect = NSRect(x: leading, y: y, width: max(0, end - leading), height: 18)
            if dirtyRect.intersects(titleRect) {
                (row.title as NSString).draw(in: titleRect,
                                       withAttributes: [.font: header ? fonts.section : fonts.regular,
                                                        .foregroundColor: header || program || row.quietShell ? NSColor.secondaryLabelColor : NSColor.labelColor,
                                                        .paragraphStyle: paragraph])
            }
            let tailRect = NSRect(x: leading, y: row.tailY, width: max(0, bounds.width - leading - (program ? 27 : 24)), height: 15)
            if dirtyRect.intersects(tailRect) {
                (row.tail as NSString).draw(in: tailRect,
                                          withAttributes: [.font: fonts.tail, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            }
            (clock as NSString).draw(at: NSPoint(x: dotX - 12 - clockWidth, y: y + 2),
                                     withAttributes: [.font: fonts.clock, .foregroundColor: NSColor.secondaryLabelColor])
            let indicatorY = y
            let color: NSColor? = switch row.status {
            case .quiet: nil; case .running, .done: .systemGreen; case .waiting: .systemOrange; case .error, .stalled: .systemRed
            }
            if let color {
                if row.status == .done || row.status == .stalled {
                    let image = NSImage(systemSymbolName: row.status == .done ? "checkmark" : "exclamationmark", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))?
                        .withSymbolConfiguration(.init(paletteColors: [color]))
                    image?.draw(in: NSRect(x: dotX - 6, y: indicatorY + 1, width: 12, height: 12),
                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    color.setFill(); NSBezierPath(ovalIn: NSRect(x: dotX - 3, y: indicatorY + 6, width: 6, height: 6)).fill()
                }
            }
        }
    }
}
