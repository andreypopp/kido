import AppKit
import TmuxControl

extension CGRect {
    func subtracting(_ cuts: [CGRect]) -> [CGRect] {
        cuts.reduce(isNull || isEmpty ? [] : [self]) { rects, cut in
            rects.flatMap { rect -> [CGRect] in
                let overlap = rect.intersection(cut)
                guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                    CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                    CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
                ].filter { !$0.isNull && !$0.isEmpty }
            }
        }
    }
}

final class PaneChrome: NSView {
    let pane: PaneID
    private let runtime: GhosttyRuntime
    var select: () -> Void = {}
    var drag: ((NSEvent) -> Void)?
    var padding: [CGRect] {
        bounds.insetBy(dx: 5, dy: 5).subtracting(
            [content] + subviews.filter { !$0.isHidden && ($0 is PaneScroller || $0.alphaValue > 0) }.map(\.frame))
    }
    var hover: (PaneChrome, NSPoint?) -> Void = { _, _ in }
    var grid = CGRect.zero { didSet { if grid != oldValue { needsDisplay = true } } }
    var content = CGRect.zero { didSet { if content != oldValue { needsDisplay = true } } }
    private(set) var scrollEdges = (top: false, bottom: false)
    static let scrollEdgeHeight: CGFloat = 12

    func updateScrollEdges(top: Bool, bottom: Bool) {
        guard scrollEdges != (top, bottom) else { return }
        scrollEdges = (top, bottom)
        needsDisplay = true
    }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    var toolbarFrame: CGRect {
        NSRect(x: max(0, bounds.width - 153), y: 8, width: min(145, bounds.width), height: 32)
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard dimmed || scrollEdges.top || scrollEdges.bottom else { return }
            let background = runtime.background
            if dimmed { background.withAlphaComponent(0.45).setFill(); bounds.fill() }
            guard (scrollEdges.top || scrollEdges.bottom), !content.isEmpty else { return }
            let height = min(Self.scrollEdgeHeight, content.height / 2)
            let gradient = NSGradient(
                colors: [1.0, 0.9, 0.6, 0.25, 0.0].map { background.withAlphaComponent($0) },
                atLocations: [0.0, 0.2, 0.45, 0.7, 1.0], colorSpace: .deviceRGB)!
            for (visible, y, direction) in [(scrollEdges.top, content.minY, 1.0), (scrollEdges.bottom, content.maxY, -1.0)] where visible {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: CGRect(x: content.minX, y: min(y, y + direction * height), width: content.width, height: height)).addClip()
                gradient.draw(from: CGPoint(x: content.midX, y: y), to: CGPoint(x: content.midX, y: y + direction * height), options: [])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if subviews.contains(where: { !$0.isHidden && $0.alphaValue > 0 && $0.frame.contains(local) }) { return super.hitTest(point) }
        return bounds.contains(local) && !content.contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        if let drag, padding.contains(where: { $0.contains(convert(event.locationInWindow, from: nil)) }) {
            window?.makeFirstResponder(self)
            drag(event)
        } else { select() }
    }
    override func mouseDragged(with event: NSEvent) { drag?(event) }
    override func mouseUp(with event: NSEvent) { drag?(event) }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if let drag, event.keyCode == 53 { drag(event) } else { super.keyDown(with: event) }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) { hover(self, convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(self, nil) }
}

final class PaneDropPreview: NSView {
    var rect: CGRect? { didSet { if rect != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let rect else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            let bar = rect.width == 4 || rect.height == 4
            NSBezierPath(roundedRect: bar ? rect : rect.insetBy(dx: 3, dy: 3), xRadius: bar ? 2 : 8, yRadius: bar ? 2 : 8).fill()
        }
    }
}

final class PaneToolbar: NSGlassEffectView {
    private let separator = NSView()
    private let grip = IconButton("line.3.horizontal", "Drag pane", size: 15)
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 145, height: 32))
        for (button, x) in [(grip, 3.0), (right, 29.0), (down, 55.0), (zoom, 81.0), (close, 116.0)] {
            button.frame = NSRect(x: x, y: 3, width: 26, height: 26)
            content.addSubview(button)
        }
        separator.frame = NSRect(x: 111, y: 9, width: 0.5, height: 14)
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
    func update(command: @escaping (PaneCommand) -> Void, zoomed: Bool, drag: @escaping (NSEvent) -> Void) {
        grip.isEnabled = !zoomed
        grip.press = zoomed ? nil : drag
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
