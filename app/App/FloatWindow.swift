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

    func detach() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        delegate = nil
        contentView = NSView()
        close()
    }
}

final class FloatContent: NSView {
    weak var logical: WindowView?
    var pane: PaneID?
    var chrome = CGRect.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static func edges(_ r: CGRect) -> [(NSCursor.FrameResizePosition, CGRect)] {
        [
            (.topLeft, CGRect(x: r.minX, y: r.minY, width: 5, height: 5)),
            (.bottomLeft, CGRect(x: r.minX, y: r.maxY - 5, width: 5, height: 5)),
            (.topRight, CGRect(x: r.maxX - 5, y: r.minY, width: 5, height: 5)),
            (.bottomRight, CGRect(x: r.maxX - 5, y: r.maxY - 5, width: 5, height: 5)),
            (.left, CGRect(x: r.minX, y: r.minY + 5, width: 5, height: max(0, r.height - 10))),
            (.right, CGRect(x: r.maxX - 5, y: r.minY + 5, width: 5, height: max(0, r.height - 10))),
            (.top, CGRect(x: r.minX + 5, y: r.minY, width: max(0, r.width - 10), height: 5)),
            (.bottom, CGRect(x: r.minX + 5, y: r.maxY - 5, width: max(0, r.width - 10), height: 5)),
        ]
    }

    private func edge(_ point: NSPoint) -> NSCursor.FrameResizePosition? {
        guard logical?.floatsInteractive == true, chrome.contains(point) else { return nil }
        return Self.edges(chrome).first { $0.1.contains(point) }?.0
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, chrome.contains(local) else { return nil }
        return edge(local) != nil ? self : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let pane, let edge = edge(convert(event.locationInWindow, from: nil)) else { return }
        logical?.beginEdgeResize(pane, edge, event)
    }
    override func mouseDragged(with event: NSEvent) { logical?.continueDrag(event) }
    override func mouseUp(with event: NSEvent) { logical?.continueDrag(event) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, logical?.cancelsDrag == true { logical?.cancelDrag() } else { super.keyDown(with: event) }
    }

    override func resetCursorRects() {
        guard let pane, let rects = logical?.floatCursorRects(pane) else { return }
        for (rect, cursor) in rects { addCursorRect(rect, cursor: cursor) }
    }
}
