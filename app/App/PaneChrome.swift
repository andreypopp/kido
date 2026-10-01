import AppKit
import TmuxControl

final class PaneChrome: NSView {
    let pane: PaneID
    private let runtime: GhosttyRuntime
    var select: () -> Void = {}
    var hover: (PaneChrome, NSPoint?) -> Void = { _, _ in }
    var grid = CGRect.zero
    var dimmed = false { didSet { needsDisplay = true } }
    var toolbarFrame: CGRect {
        NSRect(x: max(0, bounds.width - 127), y: 8, width: min(119, bounds.width), height: 32)
    }
    var hotZone: CGRect {
        CGRect(x: toolbarFrame.minX - 24, y: toolbarFrame.minY,
               width: toolbarFrame.width + 24, height: toolbarFrame.height + 24).intersection(bounds)
    }

    init(pane: PaneID, runtime: GhosttyRuntime) {
        self.pane = pane
        self.runtime = runtime
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if dimmed { runtime.background.withAlphaComponent(0.45).setFill(); bounds.fill() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if let toolbar = subviews.first, toolbar.alphaValue > 0, toolbar.frame.contains(local) { return super.hitTest(point) }
        return bounds.contains(local) && !grid.contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { select() }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) { hover(self, convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(self, nil) }
}

final class PaneToolbar: NSGlassEffectView {
    private let separator = NSView()
    private let zoom = IconButton("arrow.up.left.and.arrow.down.right", "Zoom pane", size: 15)
    private let right = IconButton("rectangle.split.2x1", "Split right", size: 15)
    private let down = IconButton("rectangle.split.1x2", "Split down", size: 15)
    private let close = IconButton("xmark", "Close pane", size: 15)
    private var zoomed: Bool?
    private static let zoomImages = ["arrow.up.left.and.arrow.down.right", "arrow.down.right.and.arrow.up.left"].map {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    }

    init() {
        super.init(frame: .zero)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 119, height: 32))
        for (button, x) in [(right, 3.0), (down, 29.0), (zoom, 55.0), (close, 90.0)] {
            button.frame = NSRect(x: x, y: 3, width: 26, height: 26)
            content.addSubview(button)
        }
        separator.frame = NSRect(x: 85, y: 9, width: 0.5, height: 14)
        separator.wantsLayer = true
        content.addSubview(separator)
        cornerRadius = 12
        contentView = content
        alphaValue = 0
        updateSeparator()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSeparator()
    }
    private func updateSeparator() {
        effectiveAppearance.performAsCurrentDrawingAppearance { separator.layer?.backgroundColor = NSColor.separatorColor.cgColor }
    }
    func update(command: @escaping (PaneCommand) -> Void, zoomed: Bool) {
        right.invoke = { command(.split(.right)) }
        down.invoke = { command(.split(.down)) }
        zoom.invoke = { command(.zoom) }
        close.invoke = { command(.close) }
        guard self.zoomed != zoomed else { return }
        self.zoomed = zoomed
        zoom.image = Self.zoomImages[zoomed ? 1 : 0]
        zoom.toolTip = zoomed ? "Unzoom pane" : "Zoom pane"
        zoom.setAccessibilityLabel(zoom.toolTip)
    }
    override func layout() {
        super.layout()
        separator.frame.size.width = 1 / (window?.backingScaleFactor ?? 2)
    }
}
