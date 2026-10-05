import AppKit

final class WindowTabs: NSView {
    var entries: [SessionModel.Tab] = [] { didSet { needsDisplay = true } }
    var select: (WindowStep) -> Void = { _ in }
    var hostLabel: () -> (text: String, alias: String, connected: Bool)? = { nil }
    private var offset: CGFloat = 0
    private var hostWidth: CGFloat {
        guard let host = hostLabel() else { return 0 }
        let width = (host.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
        return min(bounds.width * 0.35, min(166, ceil(width)) + 25)
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        if hostLabel() != nil { addToolTip(NSRect(x: 0, y: 0, width: hostWidth, height: bounds.height), owner: self, userData: nil) }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        hostLabel()?.alias ?? ""
    }
    override var mouseDownCanMoveWindow: Bool { false }

    private func tabWidth(_ count: Int, hostWidth: CGFloat) -> CGFloat { max(85, min(220, max(0, bounds.width - hostWidth) / CGFloat(max(1, count)))) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let hostWidth = hostWidth
        let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
        guard !isHidden, bounds.contains(local), local.x >= hostWidth, local.x - hostWidth + offset < tabWidth * CGFloat(entries.count) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hostWidth = hostWidth
        guard bounds.contains(point), point.x >= hostWidth else { return }
        let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
        let index = Int((point.x - hostWidth + offset) / tabWidth)
        guard entries.indices.contains(index) else { return }
        select(.number(index + 1))
    }

    override func scrollWheel(with event: NSEvent) {
        let hostWidth = hostWidth
        let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
        offset = max(0, min(max(0, tabWidth * CGFloat(entries.count) - (bounds.width - hostWidth)),
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
            let hostWidth = hostWidth
            if let host = hostLabel(), hostWidth > 25 {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(host.connected ? 1 : 0.45)
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                (host.text as NSString).draw(in: NSRect(x: 2, y: bounds.midY - 8, width: hostWidth - 25, height: 16),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
                NSColor.separatorColor.setFill()
                NSRect(x: hostWidth - 11, y: bounds.midY - 8, width: 1, height: 16).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: hostWidth, y: 0, width: bounds.width - hostWidth, height: bounds.height).clip()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let entries = entries
            let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
            offset = min(offset, max(0, tabWidth * CGFloat(entries.count) - (bounds.width - hostWidth)))
            for (index, tab) in entries.enumerated() {
                let rect = NSRect(x: hostWidth + CGFloat(index) * tabWidth - offset + 2, y: 8, width: tabWidth - 3, height: bounds.height - 16)
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
        let hostWidth = hostWidth
        let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
        return entries.enumerated().map { index, tab in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: hostWidth + CGFloat(index) * tabWidth - offset, y: 8, width: tabWidth, height: 28))
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
