import AppKit
import PaneGeometry
import KoModel

final class FocusEdge: NSView {
    var floating = false { didSet { if floating != oldValue { needsDisplay = true } } }
    static func stroke(_ rect: NSRect, floating: Bool = false) {
        Chrome.focusStroke.setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: floating ? 1 : 0.5, dy: floating ? 1 : 0.5),
                     xRadius: floating ? 17 : 0, yRadius: floating ? 17 : 0).stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Self.stroke(bounds, floating: floating)
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

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
    let runtime: GhosttyRuntime
    var select: () -> Void = {}
    var drag: ((NSEvent) -> Void)?
    var overlays: [CGRect] {
        subviews.filter { !$0.isHidden && ($0 is PaneScroller || $0.alphaValue > 0) }.map(\.frame)
    }
    var padding: [CGRect] { bounds.insetBy(dx: 5, dy: 5).subtracting([content] + overlays) }
    var hover: (PaneChrome, NSPoint?) -> Void = { _, _ in }
    var content = CGRect.zero
    enum Treatment { case plain, edge, focus, overlay }
    var treatment = Treatment.plain { didSet { if treatment != oldValue { needsDisplay = true } } }
    // Where the pane runs: its stripe is the top band of the chrome, over the top side of the focus edge.
    static let stripeBand: CGFloat = 3
    var stripeTop: CGFloat = 0 { didSet { if stripeTop != oldValue { needsDisplay = true } } }
    var runtimeMark: RuntimeMark? { didSet { if runtimeMark != oldValue { needsDisplay = true } } }
    var runtimeFocused = true { didSet { if runtimeFocused != oldValue { needsDisplay = true } } }
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch treatment {
            case .plain: break
            case .edge:
                Chrome.focusStroke.setStroke()
                let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
                let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                let tolerance: CGFloat = 0.51
                let windowCorners: (CGRect, [CGFloat])? = {
                    guard #available(macOS 27, *), let window, !window.styleMask.contains(.fullScreen),
                          let content = window.contentView, let radii = content.effectiveCornerRadii else { return nil }
                    return (content.convert(content.bounds, to: nil), [radii.topLeft, radii.topRight, radii.bottomLeft, radii.bottomRight])
                }()
                let path = NSBezierPath()
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                for index in corners.indices {
                    let corner = corners[index]
                    let next = corners[(index + 1) % corners.count]
                    var radius: CGFloat = 0
                    if let (outer, radii) = windowCorners {
                        let point = convert(corner, to: nil)
                        let left = abs(point.x - outer.minX) <= tolerance
                        let bottom = abs(point.y - outer.minY) <= tolerance
                        if (left || abs(point.x - outer.maxX) <= tolerance),
                           (bottom || abs(point.y - outer.maxY) <= tolerance) {
                            let outerRadius = radii[(bottom ? 2 : 0) + (left ? 0 : 1)]
                            radius = max(0, min(outerRadius - 0.5, rect.width / 2, rect.height / 2))
                        }
                    }
                    if radius > 0 { path.appendArc(from: corner, to: next, radius: radius) }
                    else { path.line(to: corner) }
                }
                path.close()
                path.stroke()
            case .focus:
                Chrome.focusStroke.setStroke()
                let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
                path.lineWidth = 1
                path.stroke()
            case .overlay:
                Chrome.floatingOverlay(runtime.background).setFill()
                bounds.fill()
            }
            if let runtimeMark { drawStripe(runtimeMark) }
        }
    }

    // A starting runtime's stripe is dashed: 8pt of colour and 6pt at a third of it, still.
    private func drawStripe(_ mark: RuntimeMark) {
        let tint = Chrome.runtimeStripe(Chrome.runtimeTint(mark, dark: runtime.background.isDark), focused: runtimeFocused)
        let band = NSRect(x: 0, y: stripeTop, width: bounds.width, height: Self.stripeBand)
        guard mark.state == .starting else {
            tint.setFill()
            return band.fill()
        }
        var x: CGFloat = 0
        while x < bounds.width {
            tint.setFill()
            NSRect(x: x, y: stripeTop, width: min(8, bounds.width - x), height: Self.stripeBand).fill()
            if x + 8 < bounds.width {
                Chrome.runtimeStripeGap(tint).setFill()
                NSRect(x: x + 8, y: stripeTop, width: min(6, bounds.width - x - 8), height: Self.stripeBand).fill()
            }
            x += 14
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
    var ghost: CGRect? { didSet { if ghost != oldValue { needsDisplay = true } } }
    var ghostRadius: CGFloat = 10
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if let ghost {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let path = NSBezierPath(roundedRect: ghost.insetBy(dx: 0.5, dy: 0.5), xRadius: ghostRadius, yRadius: ghostRadius)
                Chrome.dropGhostFill.setFill()
                path.fill()
                Chrome.dropGhostStroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        guard let rect else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Chrome.dropPreview.setFill()
            let bar = rect.width == 4 || rect.height == 4
            NSBezierPath(roundedRect: bar ? rect : rect.insetBy(dx: 3, dy: 3), xRadius: bar ? 2 : 8, yRadius: bar ? 2 : 8).fill()
        }
    }
}

class PaneCapsule: NSView {
    enum ShadowStyle { case contact, float, none }
    // A label draws its text 2pt inside its frame on each side.
    static let labelInset: CGFloat = 2
    static let floatShadowOffset: CGFloat = 10
    weak var pane: PaneView?
    let runtime: GhosttyRuntime
    private let radius: CGFloat
    private let surface: (Bool) -> (fillMix: Double, edgeAlpha: CGFloat)
    private let shadowStyle: ShadowStyle
    private var shadowDark: Bool?
    private let edgeOutset: CGFloat
    private let edge = CALayer()
    private let separators: [CALayer]
    private let ring = CALayer()
    private var focus: NSKeyValueObservation?
    var separatorX: [CGFloat] = [] { didSet { needsLayout = true } }
    var focused: Bool { false }

    init(runtime: GhosttyRuntime, radius: CGFloat, separators: Int = 0, surface: @escaping (Bool) -> (fillMix: Double, edgeAlpha: CGFloat) = Chrome.capsuleSurface, edgeOutset: CGFloat = 0.5, shadowStyle: ShadowStyle = .contact) {
        self.runtime = runtime
        self.radius = radius
        self.surface = surface
        self.shadowStyle = shadowStyle
        self.edgeOutset = edgeOutset
        self.separators = (0..<separators).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        edge.borderWidth = 0.5
        edge.cornerRadius = radius + edgeOutset
        ring.borderWidth = 3
        ring.cornerRadius = radius + 3
        for sublayer in [edge] + self.separators + [ring] { layer?.addSublayer(sublayer) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var wantsUpdateLayer: Bool { true }
    override var nextResponder: NSResponder? { get { pane } set { super.nextResponder = pane } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focus = window?.observe(\.firstResponder) { [weak self] _, _ in MainActor.assumeIsolated { self?.needsLayout = true; self?.needsDisplay = true } }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }
    override func updateLayer() { updateSurface() }
    private func updateSurface() {
        let background = runtime.background, foreground = runtime.foreground
        let dark = background.isDark
        let surface = surface(dark)
        if shadowDark != dark {
            shadowDark = dark
            let style: (color: NSColor, offset: CGFloat, blur: CGFloat)? = switch shadowStyle {
            case .contact: Chrome.capsuleShadow(dark: dark)
            case .float: (Chrome.floatShadow.color, -Self.floatShadowOffset, Chrome.floatShadow.blur)
            case .none: nil
            }
            shadow = style.map {
                let shadow = NSShadow()
                shadow.shadowColor = $0.color
                shadow.shadowOffset = NSSize(width: 0, height: $0.offset)
                shadow.shadowBlurRadius = $0.blur
                return shadow
            }
        }
        layer?.backgroundColor = background.mixed(toward: foreground, amount: surface.fillMix).cgColor
        edge.borderColor = Chrome.capsuleEdge(foreground, alpha: surface.edgeAlpha).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for separator in separators { separator.backgroundColor = Chrome.hairline.cgColor }
            ring.borderColor = Chrome.capsuleRing.cgColor
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !wantsUpdateLayer { updateSurface() }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        edge.frame = bounds.insetBy(dx: -edgeOutset, dy: -edgeOutset)
        for (separator, x) in zip(separators, separatorX) {
            separator.frame = CGRect(x: x, y: (bounds.height - 14) / 2, width: 1 / (window?.backingScaleFactor ?? 2), height: 14)
        }
        ring.frame = bounds.insetBy(dx: -3, dy: -3)
        ring.isHidden = !focused
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
    #if KIDO_VISUAL
    var visualAnimationsEnded = 0
    #endif
    private static let zoomImages = ["arrow.up.left.and.arrow.down.right", "arrow.down.right.and.arrow.up.left"].map {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    }

    init(runtime: GhosttyRuntime) {
        super.init(runtime: runtime, radius: 12, separators: 1)
        for (button, x) in [(grip, 3.0), (right, 29.0), (down, 55.0), (zoom, 81.0), (close, 116.0)] {
            button.frame = NSRect(x: x, y: 3, width: 26, height: 26)
            button.acceptsFirstClick = false
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
