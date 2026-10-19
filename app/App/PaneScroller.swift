import AppKit

final class PaneScroller: NSView {
    var begin: () -> Void = {}
    var jump: (Int) -> Void = { _ in }
    var select: () -> Void = {}
    private var geometry = (history: 0, rows: 1, offset: 0.0)
    private var fadeDeadline: CFTimeInterval?
    private var hovering = false
    private var dragging: CGFloat?
    private let knob = CALayer()
    override var isFlipped: Bool { true }

    #if KIDO_VISUAL
    static var fadeDelay: CFTimeInterval = 1
    private(set) var visualFadeArmings = 0
    #else
    static let fadeDelay: CFTimeInterval = 1
    #endif

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        knob.cornerRadius = 2.5
        knob.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(knob)
        syncColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncColor()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncKnob()
        syncColor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncKnob()
    }

    func update(history: Int, rows: Int, offset: Double, alternate: Bool) {
        let next = (history, max(1, rows), max(0, min(Double(history), offset)))
        let hidden = alternate || history == 0
        guard geometry != next || isHidden != hidden else { return }
        if Double(geometry.history) - geometry.offset != Double(history) - offset { reveal() }
        geometry = next
        if isHidden != hidden {
            isHidden = hidden
            if let view = superview?.superview { window?.invalidateCursorRects(for: view) }
        }
        syncKnob()
    }

    private var knobFrame: NSRect {
        let height = min(bounds.height, max(24, bounds.height * CGFloat(geometry.rows) / CGFloat(geometry.history + geometry.rows)))
        let travel = bounds.height - height
        let y = geometry.history == 0 ? 0 : travel * CGFloat(geometry.offset) / CGFloat(geometry.history)
        return NSRect(x: bounds.maxX - 9, y: y + 2, width: 5, height: max(0, height - 4))
    }

    #if KIDO_STRESS
    var stressThumb: NSPoint { NSPoint(x: knobFrame.midX, y: knobFrame.midY) }
    #endif

    private func syncKnob() {
        guard !isHiddenOrHasHiddenAncestor, alphaValue > 0, window?.isVisible == true else { return }
        let frame = knobFrame
        if knob.frame != frame { knob.frame = frame }
    }

    private func syncColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            knob.backgroundColor = NSColor.labelColor.withAlphaComponent(hovering || dragging != nil ? 0.5 : 0.3).cgColor
        }
    }

    func reveal() {
        alphaValue = 1
        syncKnob()
        guard !hovering, dragging == nil else { return }
        let armed = fadeDeadline != nil
        fadeDeadline = CACurrentMediaTime() + Self.fadeDelay
        if !armed { armFade(after: Self.fadeDelay) }
    }

    private func armFade(after delay: CFTimeInterval) {
        #if KIDO_VISUAL
        visualFadeArmings += 1
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.fadeIfDue() }
    }

    private func fadeIfDue() {
        guard let deadline = fadeDeadline else { return }
        let remaining = deadline - CACurrentMediaTime()
        if remaining > 0 { return armFade(after: remaining) }
        fadeDeadline = nil
        guard !hovering, dragging == nil else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            animator().alphaValue = 0
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; reveal(); syncColor() }
    override func mouseExited(with event: NSEvent) { hovering = false; reveal(); syncColor() }

    override func mouseDown(with event: NSEvent) {
        select()
        begin()
        let point = convert(event.locationInWindow, from: nil)
        dragging = knobFrame.contains(point) ? point.y - knobFrame.minY : knobFrame.height / 2
        syncColor()
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let y = convert(event.locationInWindow, from: nil).y - dragging - 2
        let fraction = max(0, min(1, y / max(1, bounds.height - knobFrame.height - 4)))
        jump(geometry.history - Int((fraction * CGFloat(geometry.history)).rounded()))
        reveal()
    }

    override func mouseUp(with event: NSEvent) { dragging = nil; reveal(); syncColor() }
}
