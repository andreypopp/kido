import AppKit

final class WindowTabs: NSView {
    var entries: [SessionModel.Tab] = [] { didSet { needsDisplay = true } }
    var select: (WindowStep) -> Void = { _ in }
    private var offset: CGFloat = 0
    override var mouseDownCanMoveWindow: Bool { false }

    private func tabWidth(_ count: Int) -> CGFloat { max(85, min(220, bounds.width / CGFloat(max(1, count)))) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let tabWidth = tabWidth(entries.count)
        guard !isHidden, bounds.contains(local), local.x + offset < tabWidth * CGFloat(entries.count) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let tabWidth = tabWidth(entries.count)
        let index = Int((point.x + offset) / tabWidth)
        guard entries.indices.contains(index) else { return }
        select(.number(index + 1))
    }

    override func scrollWheel(with event: NSEvent) {
        let tabWidth = tabWidth(entries.count)
        offset = max(0, min(max(0, tabWidth * CGFloat(entries.count) - bounds.width),
                            offset + (event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            (window?.backgroundColor ?? .windowBackgroundColor).setFill()
            bounds.fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let entries = entries
            let tabWidth = tabWidth(entries.count)
            offset = min(offset, max(0, tabWidth * CGFloat(entries.count) - bounds.width))
            for (index, tab) in entries.enumerated() {
                let rect = NSRect(x: CGFloat(index) * tabWidth - offset + 2, y: 8, width: tabWidth - 3, height: bounds.height - 16)
                guard rect.intersects(bounds) else { continue }
                if tab.active {
                    NSColor.labelColor.withAlphaComponent(0.075).setFill()
                    let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                    path.fill()
                    NSColor.labelColor.withAlphaComponent(0.075).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
                let dot = tab.status == .error || tab.status == .attention
                (tab.name as NSString).draw(in: NSRect(x: rect.minX + 12, y: rect.midY - 8, width: rect.width - (dot ? 38 : 24), height: 16),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: tab.active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                                     .paragraphStyle: paragraph])
                if dot {
                    (tab.status == .error ? NSColor.systemRed : NSColor.systemOrange).setFill()
                    NSBezierPath(ovalIn: NSRect(x: rect.maxX - 18, y: rect.midY - 3, width: 6, height: 6)).fill()
                }
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let entries = entries
        let tabWidth = tabWidth(entries.count)
        return entries.enumerated().map { index, tab in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: CGFloat(index) * tabWidth - offset, y: 8, width: tabWidth, height: 28))
            element.setAccessibilityLabel("Window: " + tab.name + (tab.status == .error ? " — error" : tab.status == .attention ? " — attention" : ""))
            element.setAccessibilityValue(tab.active ? "selected" : "")
            return element
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
