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
    var overlays: [CGRect] {
        subviews.filter { !$0.isHidden && ($0 is PaneScroller || $0.alphaValue > 0) }.map(\.frame)
    }
    var padding: [CGRect] { bounds.insetBy(dx: 5, dy: 5).subtracting([content] + overlays) }
    var hover: (PaneChrome, NSPoint?) -> Void = { _, _ in }
    var content = CGRect.zero
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    var toolbarFrame: CGRect {
        NSRect(x: max(0, bounds.width - 153), y: subviews.contains { $0 is PaneFind } ? 48 : 8, width: min(145, bounds.width), height: 32)
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
        guard dimmed else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            runtime.background.withAlphaComponent(0.45).setFill()
            bounds.fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if subviews.contains(where: { !$0.isHidden && $0.alphaValue > 0 && $0.frame.contains(local) }), let hit = super.hitTest(point), hit !== self { return hit }
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

class PaneCapsule: NSView {
    private let runtime: GhosttyRuntime
    private let radius: CGFloat
    private let edge = CALayer()
    private let highlight = CAShapeLayer()
    private let separators: [CALayer]
    var separatorX: [CGFloat] = [] { didSet { needsLayout = true } }

    init(runtime: GhosttyRuntime, radius: CGFloat, separators: Int = 0) {
        self.runtime = runtime
        self.radius = radius
        self.separators = (0..<separators).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.2)
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 9
        self.shadow = shadow
        edge.borderWidth = 0.5
        edge.cornerRadius = radius + 0.5
        highlight.fillColor = CGColor(gray: 1, alpha: 0.12)
        highlight.fillRule = .evenOdd
        highlight.cornerRadius = radius
        highlight.masksToBounds = true
        for sublayer in [edge, highlight] + self.separators { layer?.addSublayer(sublayer) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateLayer() {
        let background = runtime.background, foreground = runtime.foreground
        layer?.backgroundColor = NSColor(srgbRed: background.redComponent * 0.92 + foreground.redComponent * 0.08,
                                         green: background.greenComponent * 0.92 + foreground.greenComponent * 0.08,
                                         blue: background.blueComponent * 0.92 + foreground.blueComponent * 0.08, alpha: 1).cgColor
        edge.borderColor = foreground.withAlphaComponent(0.12).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for separator in separators { separator.backgroundColor = NSColor.separatorColor.cgColor }
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        edge.frame = bounds.insetBy(dx: -0.5, dy: -0.5)
        highlight.frame = bounds
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
        path.addRoundedRect(in: bounds.offsetBy(dx: 0, dy: -0.5), cornerWidth: radius, cornerHeight: radius)
        highlight.path = path
        for (separator, x) in zip(separators, separatorX) {
            separator.frame = CGRect(x: x, y: (bounds.height - 14) / 2, width: 1 / (window?.backingScaleFactor ?? 2), height: 14)
        }
        CATransaction.commit()
    }
}

final class PaneToolbar: PaneCapsule {
    private let grip = IconButton("line.3.horizontal", "Drag pane", size: 15)
    private let zoom = IconButton("arrow.up.left.and.arrow.down.right", "Zoom pane", size: 15)
    private let right = IconButton("rectangle.split.2x1", "Split right", size: 15)
    private let down = IconButton("rectangle.split.1x2", "Split down", size: 15)
    private let close = IconButton("xmark", "Close pane", size: 15)
    private var zoomed: Bool?
    private static let zoomImages = ["arrow.up.left.and.arrow.down.right", "arrow.down.right.and.arrow.up.left"].map {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    }

    init(runtime: GhosttyRuntime) {
        super.init(runtime: runtime, radius: 12, separators: 1)
        for (button, x) in [(grip, 3.0), (right, 29.0), (down, 55.0), (zoom, 81.0), (close, 116.0)] {
            button.frame = NSRect(x: x, y: 3, width: 26, height: 26)
            addSubview(button)
        }
        separatorX = [111]
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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
}
