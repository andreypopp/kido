import AppKit
import SidebarFeed
import TmuxControl

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
        guard dragPoint == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.x - hostWidth + offset) / tabWidth(entries.count, hostWidth: hostWidth))
        let slot = NSRect(x: origin(index, geometry(nil)) + 9, y: bounds.midY - 8, width: 16, height: 16)
        hovered = slot.minX >= hostWidth && slot.maxX <= bounds.width - 28 && slot.contains(point) && entries.indices.contains(index) ? index : nil
        needsLayout = true; needsDisplay = true
    }
    var entries: [SessionModel.Tab] = [] {
        didSet {
            if let press, !entries.contains(where: { $0.id == press.id }) { endDrag(commit: false) }
            needsLayout = true; needsDisplay = true
        }
    }
    var reorder = Reorder()
    struct Scope: Equatable {
        let session: SessionID
        let generation: Int
        let instance: ServerInstance?
    }
    var scope: Scope? {
        didSet { if scope != oldValue, press != nil { endDrag(commit: false) } }
    }
    var move: (ReorderMove) -> Void = { _ in }
    private var press: (id: WindowID, origin: NSPoint, grab: CGFloat, session: SessionID?)?
    private var dragPoint: NSPoint?
    private var escape: Any?
    private var autoscroll: Timer?
    private var settling: [WindowID: CGFloat] = [:]
    private var animating = false
    @objc dynamic private var progress: CGFloat = 1 { didSet { needsDisplay = true } }
    #if KIDO_VISUAL
    static var visualReduceMotion: Bool?
    var visualAnimating: Bool { progress < 1 }
    func visualPresentedLabelRect(_ index: Int) -> NSRect {
        let geometry = geometry(dragPoint)
        return label(presented(index, geometry), geometry.width)
    }
    #endif

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "progress" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    private func presented(_ index: Int, _ geometry: Geometry) -> CGFloat {
        let target = origin(index, geometry)
        guard progress < 1, index != geometry.drop?.from, let start = settling[entries[index].id] else { return target }
        return start - offset + (target - start + offset) * progress
    }

    private func positions(_ geometry: Geometry) -> [WindowID: CGFloat] {
        Dictionary(entries.indices.map { (entries[$0].id, presented($0, geometry) + offset) }) { first, _ in first }
    }

    private func slide(from start: [WindowID: CGFloat]) {
        var reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #if KIDO_VISUAL
        reduce = Self.visualReduceMotion ?? reduce
        #endif
        guard !reduce, Set(start.keys) == Set(entries.map(\.id)), positions(geometry(dragPoint)) != start else { return }
        settling = start
        progress = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().progress = 1
        }
    }

    func animated(_ change: () -> Void) {
        guard !animating else { return change() }
        animating = true
        defer { animating = false }
        let start = positions(geometry(dragPoint))
        change()
        slide(from: start)
    }
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
        endDrag(commit: false)
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
        closeButton.isHidden = dragPoint != nil || hovered == nil || !entries.indices.contains(hovered ?? -1)
        if let hovered, !closeButton.isHidden {
            closeButton.frame = NSRect(x: origin(hovered, geometry(nil)) + 9, y: bounds.midY - 8, width: 16, height: 16)
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

    private struct Geometry {
        let host: CGFloat, width: CGFloat, strip: NSRect, limit: CGFloat
        var drop: (from: Int, to: Int, x: CGFloat)?
    }

    private func geometry(_ point: NSPoint?) -> Geometry {
        let host = hostWidth, width = tabWidth(entries.count, hostWidth: host)
        let strip = NSRect(x: host, y: 0, width: max(0, bounds.width - host - 28), height: bounds.height)
        var geometry = Geometry(host: host, width: width, strip: strip, limit: max(0, width * CGFloat(entries.count) - strip.width))
        if let press, let point, let from = entries.firstIndex(where: { $0.id == press.id }) {
            let x = max(geometry.strip.minX, min(geometry.strip.maxX - width, point.x - press.grab))
            let to = geometry.strip.contains(point) ? max(0, min(entries.count - 1, Int(((point.x - press.grab - host + offset) / width).rounded()))) : from
            geometry.drop = (from, to, x)
        }
        return geometry
    }

    private func origin(_ index: Int, _ geometry: Geometry) -> CGFloat {
        guard let (from, to, x) = geometry.drop else { return geometry.host + CGFloat(index) * geometry.width - offset }
        if index == from { return x }
        let rest = index > from ? index - 1 : index
        return geometry.host + CGFloat(rest >= to ? rest + 1 : rest) * geometry.width - offset
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = geometry(nil)
        guard geometry.strip.contains(point) else { return }
        let index = Int((point.x - geometry.host + offset) / geometry.width)
        guard entries.indices.contains(index) else { return }
        press = (entries[index].id, point, point.x - origin(index, geometry), scope?.session)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        if dragPoint == nil {
            guard hypot(point.x - press.origin.x, point.y - press.origin.y) >= 4, reorder.claim(.tab) else { return }
            hovered = nil
            escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, dragPoint != nil else { return event }
                endDrag(commit: false)
                return nil
            }
        }
        let current = geometry(dragPoint ?? press.origin), next = geometry(point)
        let start = current.drop?.to != next.drop?.to ? positions(current) : nil
        dragPoint = point
        if let start { slide(from: start) }
        if autoscroll == nil, edgeStep(next) != 0 {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.scrollEdge() } }
            RunLoop.main.add(timer, forMode: .common)
            autoscroll = timer
        }
        needsLayout = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        if dragPoint != nil {
            dragPoint = convert(event.locationInWindow, from: nil)
            return endDrag(commit: true)
        }
        self.press = nil
        if let index = entries.firstIndex(where: { $0.id == press.id }) { select(.number(index + 1)) }
    }

    private func edgeStep(_ geometry: Geometry) -> CGFloat {
        guard let dragPoint else { return 0 }
        if dragPoint.x < geometry.strip.minX + 20, offset > 0 { return -6 }
        if dragPoint.x > geometry.strip.maxX - 20, offset < geometry.limit { return 6 }
        return 0
    }

    private func scrollEdge() {
        let geometry = geometry(nil), step = edgeStep(geometry)
        guard step != 0 else { autoscroll?.invalidate(); autoscroll = nil; return }
        offset = max(0, min(geometry.limit, offset + step))
        needsDisplay = true
    }

    private func endDrag(commit: Bool) {
        animated {
            let ids = entries.map(\.id), drop = commit ? geometry(dragPoint).drop : nil, session = press?.session
            if let escape { NSEvent.removeMonitor(escape) }
            escape = nil
            autoscroll?.invalidate()
            autoscroll = nil
            if dragPoint != nil { reorder.release(.tab) }
            dragPoint = nil
            press = nil
            needsLayout = true
            needsDisplay = true
            guard let (from, to, _) = drop, let (anchor, placement) = ReorderMove.placing(ids[from], at: to <= from ? to : to + 1, in: ids) else { return }
            if let session { move(.window(session, ids[from], relativeTo: anchor, placement)) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        offset = max(0, min(geometry(nil).limit, offset + (event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX)))
        needsLayout = true
        needsDisplay = true
    }

    func labelFont(_ tab: SessionModel.Tab) -> NSFont { .systemFont(ofSize: 11, weight: tab.agent ? .semibold : .regular) }

    func labelRect(_ index: Int) -> NSRect {
        let geometry = geometry(dragPoint)
        return label(origin(index, geometry), geometry.width)
    }

    private func label(_ x: CGFloat, _ width: CGFloat) -> NSRect {
        NSRect(x: x + 28, y: bounds.midY - 8, width: max(0, width - 55), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            var geometry = geometry(dragPoint)
            if offset > geometry.limit {
                offset = geometry.limit
                geometry = self.geometry(dragPoint)
            }
            let hostWidth = geometry.host, tabWidth = geometry.width
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
            geometry.strip.clip()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let entries = entries
            let dragged = geometry.drop?.from
            @MainActor func drawTab(_ index: Int) {
                let tab = entries[index]
                let x = presented(index, geometry)
                let rect = NSRect(x: x + 2, y: bounds.midY - 14, width: tabWidth - 3, height: 28)
                guard rect.intersects(bounds) else { return }
                if index == dragged {
                    theme.background.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                }
                if tab.active || index == dragged {
                    NSColor.labelColor.withAlphaComponent(0.075).setFill()
                    let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                    path.fill()
                    NSColor.labelColor.withAlphaComponent(0.075).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
                let dot = tab.status == .error || tab.status == .waiting
                (tab.displayName as NSString).draw(in: label(x, tabWidth),
                    withAttributes: [.font: labelFont(tab), .foregroundColor: tab.active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                                     .paragraphStyle: paragraph])
                if dot && hovered != index {
                    (tab.status == .error ? NSColor.systemRed : NSColor.systemOrange).setFill()
                    NSBezierPath(ovalIn: NSRect(x: rect.minX + 12, y: rect.midY - 3, width: 6, height: 6)).fill()
                }
            }
            for index in entries.indices where index != dragged { drawTab(index) }
            if let dragged { drawTab(dragged) }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let entries = entries
        let geometry = geometry(dragPoint), tabWidth = geometry.width
        let children: [Any] = entries.enumerated().map { index, tab in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: origin(index, geometry), y: bounds.midY - 14, width: tabWidth, height: 28))
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
