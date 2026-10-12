import AppKit

final class WindowTabs: NSView {
    private final class HeaderBackground: NSView {
        var color = NSColor.windowBackgroundColor
        override var isOpaque: Bool { true }
        override func draw(_ rect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance { color.setFill(); bounds.fill() }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private let headerBackground = HeaderBackground()
    weak var sidebar: Sidebar?
    func refreshHeader() {
        guard let window, let content = headerBackground.superview else { return }
        let left = sidebar?.headerDivider(in: window) ?? 0
        let frame = NSRect(x: left, y: content.bounds.minY, width: max(0, content.bounds.maxX - left), height: content.bounds.height)
        if headerBackground.frame != frame {
            headerBackground.frame = frame
            content.needsDisplay = true
        }
        headerBackground.needsDisplay = true
    }

    let addWindow = IconButton("plus", "New window", size: 11, hoverStyle: .iconOnly)
    let closeButton = IconButton("xmark", "Close window", size: 10, hoverStyle: .close)
    var close: (SessionModel.Tab) -> Void = { _ in }
    private var hovered: Int?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(addWindow)
        addSubview(closeButton)
        closeButton.isHidden = true
        closeButton.invoke = { [weak self] in
            guard let self, let hovered, entries.indices.contains(hovered) else { return }
            close(entries[hovered])
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsLayout = true; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.x - hostWidth + offset) / tabWidth(entries.count, hostWidth: hostWidth))
        let slot = NSRect(x: hostWidth + CGFloat(index) * tabWidth(entries.count, hostWidth: hostWidth) - offset + 9,
                          y: bounds.midY - 8, width: 16, height: 16)
        hovered = slot.minX >= hostWidth && slot.maxX <= bounds.width - 28 && slot.contains(point) && entries.indices.contains(index) ? index : nil
        needsLayout = true; needsDisplay = true
    }
    var entries: [SessionModel.Tab] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var select: (WindowStep) -> Void = { _ in }
    var hostLabel: () -> (text: String, alias: String, connected: Bool)? = { nil }
    var theme: (background: NSColor, appearance: NSAppearance?) = (.windowBackgroundColor, nil) {
        didSet {
            headerBackground.color = theme.background
            synchronizeHost()
            needsDisplay = true
        }
    }
    private var offset: CGFloat = 0

    private func synchronizeHost() {
        guard let window, window !== sidebar?.view.window, let content = window.contentView else {
            headerBackground.removeFromSuperview(); return
        }
        window.appearance = theme.appearance
        if headerBackground.superview !== content {
            headerBackground.autoresizingMask = [.width, .height]
            headerBackground.frame = content.bounds
            content.addSubview(headerBackground, positioned: .below, relativeTo: nil)
        }
        refreshHeader()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeHost()
    }
    private var hostWidth: CGFloat {
        guard let host = hostLabel() else { return 0 }
        let width = (host.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
        return min(bounds.width * 0.35, min(166, ceil(width)) + 25)
    }

    override func layout() {
        super.layout()
        addWindow.frame = NSRect(x: bounds.width - 28, y: 0, width: 28, height: bounds.height)
        closeButton.isHidden = hovered == nil || !entries.indices.contains(hovered ?? -1)
        if let hovered, !closeButton.isHidden {
            closeButton.frame = NSRect(x: hostWidth + CGFloat(hovered) * tabWidth(entries.count, hostWidth: hostWidth) - offset + 9,
                                       y: bounds.midY - 8, width: 16, height: 16)
            closeButton.isHidden = closeButton.frame.minX < hostWidth || closeButton.frame.maxX > bounds.width - 28
            closeButton.setAccessibilityLabel("Close window: " + entries[hovered].name)
        }
        removeAllToolTips()
        if hostLabel() != nil { addToolTip(NSRect(x: 0, y: 0, width: hostWidth, height: bounds.height), owner: self, userData: nil) }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        hostLabel()?.alias ?? ""
    }
    override var mouseDownCanMoveWindow: Bool { false }

    private func tabWidth(_ count: Int, hostWidth: CGFloat) -> CGFloat { max(85, min(220, max(0, bounds.width - hostWidth - 28) / CGFloat(max(1, count)))) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let hostWidth = hostWidth
        let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
        guard !isHidden, bounds.contains(local) else { return nil }
        if local.x >= bounds.width - 28 { return addWindow }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        guard local.x >= hostWidth, local.x - hostWidth + offset < tabWidth * CGFloat(entries.count) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hostWidth = hostWidth
        guard bounds.contains(point), point.x >= hostWidth, point.x < bounds.width - 28 else { return }
        let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
        let index = Int((point.x - hostWidth + offset) / tabWidth)
        guard entries.indices.contains(index) else { return }
        select(.number(index + 1))
    }

    override func scrollWheel(with event: NSEvent) {
        let hostWidth = hostWidth
        let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
        offset = max(0, min(max(0, tabWidth * CGFloat(entries.count) - (bounds.width - hostWidth - 28)),
                            offset + (event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX)))
        needsLayout = true
        needsDisplay = true
    }

    func labelFont(_ tab: SessionModel.Tab) -> NSFont { .systemFont(ofSize: 11, weight: tab.agent ? .semibold : .regular) }

    func labelRect(_ index: Int) -> NSRect {
        let width = tabWidth(entries.count, hostWidth: hostWidth)
        return NSRect(x: hostWidth + CGFloat(index) * width - offset + 28, y: bounds.midY - 8, width: max(0, width - 55), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
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
            NSRect(x: hostWidth, y: 0, width: max(0, bounds.width - hostWidth - 28), height: bounds.height).clip()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let entries = entries
            let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
            offset = min(offset, max(0, tabWidth * CGFloat(entries.count) - (bounds.width - hostWidth - 28)))
            for (index, tab) in entries.enumerated() {
                let rect = NSRect(x: hostWidth + CGFloat(index) * tabWidth - offset + 2, y: bounds.midY - 14, width: tabWidth - 3, height: 28)
                guard rect.intersects(bounds) else { continue }
                if tab.active {
                    NSColor.labelColor.withAlphaComponent(0.075).setFill()
                    let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                    path.fill()
                    NSColor.labelColor.withAlphaComponent(0.075).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
                let dot = tab.status == .error || tab.status == .waiting
                (tab.displayName as NSString).draw(in: labelRect(index),
                    withAttributes: [.font: labelFont(tab), .foregroundColor: tab.active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                                     .paragraphStyle: paragraph])
                if dot && hovered != index {
                    (tab.status == .error ? NSColor.systemRed : NSColor.systemOrange).setFill()
                    NSBezierPath(ovalIn: NSRect(x: rect.minX + 12, y: rect.midY - 3, width: 6, height: 6)).fill()
                }
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let entries = entries
        let hostWidth = hostWidth
        let tabWidth = tabWidth(entries.count, hostWidth: hostWidth)
        let children: [Any] = entries.enumerated().map { index, tab in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: hostWidth + CGFloat(index) * tabWidth - offset, y: bounds.midY - 14, width: tabWidth, height: 28))
            element.setAccessibilityLabel("Window: " + tab.name + (tab.status == .error ? " — error" : tab.status == .waiting ? " — waiting" : ""))
            element.setAccessibilityValue(tab.active ? "selected" : "")
            return element
        }
        return children + [addWindow] + (closeButton.isHidden ? [] : [closeButton])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
