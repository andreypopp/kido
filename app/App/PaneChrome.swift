import AppKit
import TmuxControl

final class PaneChrome: NSView {
    let pane: PaneID
    private let background: NSColor
    private let toolbar = NSGlassEffectView()
    private let separator = NSView()
    private let zoom = IconButton("arrow.up.left.and.arrow.down.right", "Zoom pane", size: 15)
    private var tracking: NSTrackingArea?
    var select: () -> Void = {}
    var grid = CGRect.zero
    var dimmed = false { didSet { needsDisplay = true } }

    init(pane: PaneID, background: NSColor, send: @escaping (Command) -> Void) {
        self.pane = pane
        self.background = background
        super.init(frame: .zero)
        wantsLayer = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 119, height: 32))
        let right = IconButton("rectangle.split.2x1", "Split right", size: 15)
        let down = IconButton("rectangle.split.1x2", "Split down", size: 15)
        let close = IconButton("xmark", "Close pane", size: 15)
        for (button, x) in [(right, 3.0), (down, 29.0), (zoom, 55.0), (close, 90.0)] {
            button.frame = NSRect(x: x, y: 3, width: 26, height: 26)
            content.addSubview(button)
        }
        separator.frame = NSRect(x: 85, y: 9, width: 0.5, height: 14)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        content.addSubview(separator)
        right.invoke = { send(Command("split-window", "-h", "-t", pane)) }
        down.invoke = { send(Command("split-window", "-v", "-t", pane)) }
        zoom.invoke = { send(Command("resize-pane", "-Z", "-t", pane)) }
        close.invoke = { send(Command("kill-pane", "-t", pane)) }
        toolbar.cornerRadius = 12
        toolbar.contentView = content
        toolbar.alphaValue = 0
        addSubview(toolbar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    func update(zoomed: Bool) {
        let label = zoomed ? "Unzoom pane" : "Zoom pane"
        zoom.image = NSImage(systemSymbolName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        zoom.toolTip = label
        zoom.setAccessibilityLabel(label)
    }

    override func layout() {
        super.layout()
        toolbar.frame = NSRect(x: max(0, bounds.width - 127), y: 8, width: min(119, bounds.width), height: 32)
        separator.frame.size.width = 1 / (window?.backingScaleFactor ?? 2)
    }
    override func draw(_ dirtyRect: NSRect) {
        if dimmed { background.withAlphaComponent(0.45).setFill(); bounds.fill() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if toolbar.alphaValue > 0, toolbar.frame.contains(local) { return super.hitTest(point) }
        return bounds.contains(local) && !grid.contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { select() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { showToolbar(true) }
    override func mouseExited(with event: NSEvent) { showToolbar(false) }
    private func showToolbar(_ shown: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            toolbar.animator().alphaValue = shown ? 1 : 0
        }
    }
}
