import AppKit
import KoModel
import PaneGeometry

struct CellPoint: Equatable {
    var x: Int
    var y: Int
}

final class FloatWindow: OwnerWindow {
    static var margin: CGFloat { ceil(2 * Chrome.floatShadow.blur + abs(Chrome.floatShadow.offset)) }

    enum Position: Equatable {
        case layout
        case dragging(frame: CGRect, sent: CellPoint?)
        case awaitingMove(frame: CGRect, sent: CellPoint)
        case local(frame: CGRect, sent: CellPoint)
        case awaitingDock(frame: CGRect)
    }

    let content = FloatContent()
    var position = Position.layout
    var rect = CGRect.zero
    var becameKey: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var attachedSheet: NSWindow? { (delegate as? WindowOwner)?.window.attachedSheet }

    init(owner: NSWindowDelegate?) {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false, input: false)
        delegate = owner
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary]
        contentView = content
    }

    override func becomeKey() {
        super.becomeKey()
        becameKey()
    }

    @discardableResult
    func present(_ shown: Bool, over parent: NSWindow?) -> Bool {
        let target = shown ? parent : nil
        guard content.isHidden == shown || self.parent !== target else { return false }
        content.isHidden = !shown
        if let target {
            if self.parent !== target {
                self.parent?.removeChildWindow(self)
                target.addChildWindow(self, ordered: .above)
            }
            if target.isVisible { orderFront(nil) }
        } else {
            self.parent?.removeChildWindow(self)
            orderOut(nil)
        }
        return true
    }

    func raise() {
        if let parent {
            parent.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        if isVisible { orderFront(nil) }
    }

    func detach() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        delegate = nil
        contentView = NSView()
        close()
    }
}

final class FloatContent: NSView {
    enum Zone: Equatable {
        case resize(NSCursor.FrameResizePosition)
        case move
    }

    weak var logical: WindowView?
    var pane: PaneID?
    var chrome = CGRect.zero { didSet { handles.frame = chrome } }
    var grid = CGRect.zero
    let handles = FloatHandles()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(handles)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        handles.frame = chrome
        if subviews.last !== handles { addSubview(handles) }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview !== handles { needsLayout = true }
    }

    static func zones(_ r: CGRect) -> [(Zone, CGRect)] {
        func square(_ x: CGFloat, _ y: CGFloat, in inside: CGFloat, out: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> CGRect {
            CGRect(x: dx > 0 ? x - inside : x - out, y: dy > 0 ? y - inside : y - out, width: inside + out, height: inside + out)
        }
        let corners: [(Zone, CGRect)] = [
            (.resize(.bottomRight), square(r.maxX, r.maxY, in: 12, out: 8, 1, 1)),
            (.resize(.topLeft), square(r.minX, r.minY, in: 6, out: 6, -1, -1)),
            (.resize(.topRight), square(r.maxX, r.minY, in: 6, out: 6, 1, -1)),
            (.resize(.bottomLeft), square(r.minX, r.maxY, in: 6, out: 6, -1, 1)),
        ]
        let edges: [(Zone, CGRect)] = [
            (.resize(.top), CGRect(x: r.minX, y: r.minY - 4, width: r.width, height: 8)),
            (.resize(.bottom), CGRect(x: r.minX, y: r.maxY - 4, width: r.width, height: 8)),
            (.resize(.left), CGRect(x: r.minX - 4, y: r.minY, width: 8, height: r.height)),
            (.resize(.right), CGRect(x: r.maxX - 4, y: r.minY, width: 8, height: r.height)),
        ]
        return corners + edges + [(.move, CGRect(x: r.minX, y: r.minY - 6, width: r.width, height: 16))]
    }

    static func zone(at point: NSPoint, in r: CGRect, grid: CGRect, toolbar: CGRect?) -> Zone? {
        guard !grid.contains(point) else { return nil }
        let zones = zones(r)
        if let hit = zones.first(where: { $0.1.contains(point) && $0.0 != .move }) { return hit.0 }
        if toolbar?.contains(point) == true { return nil }
        return zones.first { $0.1.contains(point) }?.0
    }

    private func toolbar() -> CGRect? { pane.flatMap { logical?.floatToolbar($0) } }

    private func zone(_ point: NSPoint) -> Zone? {
        guard logical?.floatsInteractive == true else { return nil }
        return Self.zone(at: point, in: chrome, grid: grid, toolbar: toolbar())
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        if zone(local) != nil { return self }
        return chrome.contains(local) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let pane, let zone = zone(convert(event.locationInWindow, from: nil)) else { return }
        switch zone {
        case .resize(let edge): logical?.beginEdgeResize(pane, edge, event)
        case .move: logical?.beginDrag(pane, event)
        }
    }
    override func mouseDragged(with event: NSEvent) { logical?.continueDrag(event) }
    override func mouseUp(with event: NSEvent) { logical?.continueDrag(event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        handles.show(float: chrome.insetBy(dx: -4, dy: -4).contains(local), band: Self.zones(chrome).contains { $0.0 == .move && $0.1.contains(local) } && toolbar()?.contains(local) != true)
    }
    override func mouseExited(with event: NSEvent) { handles.show(float: false, band: false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, logical?.cancelsDrag == true { logical?.cancelDrag() } else { super.keyDown(with: event) }
    }

    override func resetCursorRects() {
        guard let pane, let rects = logical?.floatCursorRects(pane) else { return }
        for (rect, cursor) in rects { addCursorRect(rect, cursor: cursor) }
    }
}

final class FloatHandles: NSView {
    static let fade: TimeInterval = 0.12
    var foreground = NSColor.clear { didSet { needsLayout = true } }
    private let pill = CALayer()
    private let mark = CAShapeLayer()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pill.cornerRadius = 2
        pill.opacity = 0
        mark.opacity = 0
        mark.fillColor = nil
        mark.lineWidth = 1
        layer?.addSublayer(pill)
        layer?.addSublayer(mark)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = Chrome.floatPill(foreground).cgColor
            mark.strokeColor = Chrome.floatCornerMark(foreground).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = CGRect(x: bounds.midX - 18, y: 0, width: 36, height: 4)
        mark.frame = bounds
        let corner = CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 3), path = CGMutablePath()
        for (gap, length) in [(CGFloat(0), CGFloat(8)), (4, 4)] {
            path.move(to: CGPoint(x: corner.x - gap, y: corner.y))
            path.addLine(to: CGPoint(x: corner.x - gap - length, y: corner.y - length))
        }
        mark.path = path
        CATransaction.commit()
    }

    func show(float: Bool, band: Bool) {
        for (layer, on) in [(pill as CALayer, band), (mark, float)] {
            let target: Float = on ? 1 : 0
            guard layer.opacity != target else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = target
            fade.duration = Self.fade
            layer.opacity = target
            layer.add(fade, forKey: "fade")
        }
    }

    var visibleMarks: (pill: Bool, mark: Bool) { (pill.opacity > 0, mark.opacity > 0) }
}
