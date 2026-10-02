import AppKit

final class PaneScroller: NSView {
    var jump: (Int) -> Void = { _ in }
    var select: () -> Void = {}
    private var geometry = (history: 0, rows: 1, offset: 0.0)
    private var unavailable = 0
    private var fade: DispatchWorkItem?
    private var hovering = false
    private var dragging: CGFloat?
    override var isFlipped: Bool { true }

    func update(history: Int, rows: Int, offset: Double, alternate: Bool, unavailable: Int = 0) {
        let next = (history, max(1, rows), max(0, min(Double(history), offset)))
        let hidden = alternate || history == 0
        guard geometry != next || self.unavailable != unavailable || isHidden != hidden else { return }
        if Double(geometry.history) - geometry.offset != Double(history) - offset { reveal() }
        geometry = next
        self.unavailable = unavailable
        if isHidden != hidden {
            isHidden = hidden
            if let view = superview?.superview { window?.invalidateCursorRects(for: view) }
        }
        needsDisplay = true
    }

    private var knob: NSRect {
        let height = min(bounds.height, max(24, bounds.height * CGFloat(geometry.rows) / CGFloat(geometry.history + geometry.rows)))
        let travel = bounds.height - height
        let y = geometry.history == 0 ? 0 : travel * CGFloat(geometry.offset) / CGFloat(geometry.history)
        return NSRect(x: bounds.maxX - 9, y: y + 2, width: 5, height: max(0, height - 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if unavailable > 0, geometry.history > 0 {
                let travel = bounds.height - knob.height - 4
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: NSRect(x: knob.minX - 1, y: 0, width: 7,
                    height: travel * CGFloat(unavailable) / CGFloat(geometry.history)), xRadius: 3, yRadius: 3).fill()
            }
            NSColor.labelColor.withAlphaComponent(hovering || dragging != nil ? 0.5 : 0.3).setFill()
            NSBezierPath(roundedRect: knob, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }

    func reveal() {
        fade?.cancel()
        alphaValue = 1
        guard !hovering, dragging == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self?.animator().alphaValue = 0
            }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; reveal(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; reveal(); needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        select()
        let point = convert(event.locationInWindow, from: nil)
        dragging = knob.contains(point) ? point.y - knob.minY : knob.height / 2
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let y = convert(event.locationInWindow, from: nil).y - dragging - 2
        let fraction = max(0, min(1, y / max(1, bounds.height - knob.height - 4)))
        jump(geometry.history - Int((fraction * CGFloat(geometry.history)).rounded()))
        reveal()
    }

    override func mouseUp(with event: NSEvent) { dragging = nil; reveal(); needsDisplay = true }
}
