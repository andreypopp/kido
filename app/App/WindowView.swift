import AppKit
import TmuxControl

final class WindowView: NSView {
    private weak var connection: Connection?
    private let runtime: GhosttyRuntime
    private var shown: (layout: Layout, visible: Layout)?
    private var active: PaneID?
    var stale = false
    private var needsReconcile = true
    private var dividers: [NSBox] = []
    private var floatingBoxes: [PaneID: NSBox] = [:]
    private let floatingRadius: CGFloat = 10
    private var toolbar: PaneToolbar?
    override var isHidden: Bool {
        didSet {
            if isHidden { toolbar?.removeFromSuperview(); toolbar = nil }
        }
    }

    init(runtime: GhosttyRuntime, connection: Connection?) {
        self.runtime = runtime
        self.connection = connection
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = runtime.background.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    var panes: [PaneView] { subviews.compactMap { $0 as? PaneView } }

    var hot: Bool { !panes.isEmpty }

    func updateBackground() {
        layer?.backgroundColor = runtime.background.cgColor
        subviews.compactMap { $0 as? PaneChrome }.forEach { $0.needsDisplay = true }
        floatingBoxes.values.forEach { $0.fillColor = runtime.background }
    }

    private var session: SessionView? { superview as? SessionView }

    func update(_ layout: Layout, _ visible: Layout) {
        let changed = shown.map { $0.layout != layout || $0.visible != visible } ?? true
        func sameTopology(_ a: Node, _ b: Node) -> Bool {
            switch (a, b) {
            case (.pane(let a), .pane(let b)): a.id == b.id && a.layer == b.layer
            case (.split(let a, _, let ac), .split(let b, _, let bc)):
                a == b && ac.count == bc.count && zip(ac, bc).allSatisfy { sameTopology($0, $1) }
            default: false
            }
        }
        needsReconcile = needsReconcile || (shown.map { !sameTopology($0.layout.root, layout.root) || !sameTopology($0.visible.root, visible.root) } ?? true)
        shown = (layout, visible)
        active = visible.root.panes.first { $0.focus == .active }?.id ?? active
        guard hot else { return }
        let known = panes.contains { $0.pane == active }
        if changed && !isHidden { relayout() }
        if !known { focusActive(force: false) }
    }

    func present(_ synced: DispatchGroup) -> (created: Int, resynced: Int) {
        let created = !hot
        relayout(created ? synced : nil)
        sizeClient()
        let resync = !created && stale ? panes : []
        stale = false
        for pane in resync {
            synced.enter()
            connection?.sync(pane.pane) { synced.leave() }
        }
        return (created ? panes.count : 0, resync.count)
    }

    func evict() {
        panes.forEach { connection?.detach($0) }
        toolbar?.removeFromSuperview()
        toolbar = nil
        dividers = []
        floatingBoxes = [:]
        needsReconcile = true
        subviews = []
    }

    func focus(_ pane: PaneID) {
        active = pane
        for chrome in subviews.compactMap({ $0 as? PaneChrome }) { chrome.dimmed = chrome.pane != active }
        focusActive(force: false)
    }

    func focusActive(force: Bool) {
        guard !isHidden, let view = panes.first(where: { $0.pane == active }), let window else { return }
        let focused = window.firstResponder
        guard force || focused === window || focused == nil || (focused as? PaneView)?.isDescendant(of: session ?? self) == true
        else { return }
        window.makeFirstResponder(view)
    }

    func close() {
        evict()
        removeFromSuperview()
    }

    private func relayout(_ synced: DispatchGroup? = nil) {
        guard let shown else { return }
        guard !isHidden else { return }
        if !needsReconcile { place(resizeGrids: true); return }
        toolbar?.removeFromSuperview()
        let layoutPanes = shown.layout.root.panes
        let existing = Dictionary(uniqueKeysWithValues: panes.map { ($0.pane, $0) })
        var views: [PaneID: PaneView] = [:]
        for pane in layoutPanes {
            views[pane.id] = existing[pane.id] ?? makePane(pane.id)
        }
        for (id, gone) in existing where views[id] == nil { connection?.detach(gone) }
        let cell = session?.cell ?? views.values.lazy.map(\.cell).first { $0.width > 0 && $0.height > 0 } ?? .zero
        guard cell.width > 0, cell.height > 0 else { return }
        let placement = PaneLayout(root: shown.visible.root, bounds: bounds, cell: cell, pixel: pixel)
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        let overlays = Dictionary(uniqueKeysWithValues: subviews.compactMap { $0 as? PaneChrome }.map { ($0.pane, $0) })
        var tiled: [NSView] = [], floating: [(z: Int, views: [NSView])] = []
        floatingBoxes = [:]
        for pane in layoutPanes {
            guard let view = views[pane.id] else { continue }
            let g = (seen[pane.id] ?? pane).geometry
            view.isHidden = seen[pane.id] == nil
            view.frame = placement.grid(g)
            view.resize(cols: g.width, rows: g.height)
            let chrome = overlays[pane.id] ?? PaneChrome(pane: pane.id, runtime: runtime)
            chrome.select = view.onSelect
            chrome.hover = { [weak self] chrome, point in self?.hover(chrome, point) }
            place(chrome, view, g, placement)
            chrome.isHidden = view.isHidden
            chrome.dimmed = pane.id != active
            switch (seen[pane.id] ?? pane).layer {
            case .tiled:
                tiled += [view, chrome]
            case .floating(let z):
                if view.isHidden { floating.append((z, [view, chrome])) }
                else {
                    let backing = box(chrome.frame, border: pixel, fill: runtime.background)
                    backing.wantsLayer = true
                    backing.cornerRadius = floatingRadius
                    backing.borderColor = .separatorColor
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
                    shadow.shadowBlurRadius = 12
                    shadow.shadowOffset = NSSize(width: 0, height: -3)
                    backing.shadow = shadow
                    floatingBoxes[pane.id] = backing
                    floating.append((z, [backing, view, chrome]))
                }
            }
        }
        dividers = shown.visible.root.dividers.map { d in
            box(placement.line(d, pixel: pixel), border: 0, fill: .separatorColor)
        }
        subviews = dividers + tiled + floating.sorted { $0.z > $1.z }.flatMap(\.views)
        for view in views.values where existing[view.pane] == nil {
            synced?.enter()
            connection?.attach(view) { synced?.leave() }
        }
        window?.invalidateCursorRects(for: self)
        needsReconcile = false
    }

    private func place(resizeGrids: Bool = false) {
        guard !isHidden, let shown, let placement else { return }
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0.geometry) })
        for view in panes where resizeGrids || !view.isHidden {
            guard let g = seen[view.pane] ?? shown.layout.root.panes.first(where: { $0.id == view.pane })?.geometry else { continue }
            if !view.isHidden { view.frame = placement.grid(g) }
            if resizeGrids { view.resize(cols: g.width, rows: g.height) }
        }
        for chrome in subviews.compactMap({ $0 as? PaneChrome }) where !chrome.isHidden {
            guard let g = seen[chrome.pane] else { continue }
            chrome.dimmed = chrome.pane != active
            if let view = panes.first(where: { $0.pane == chrome.pane }) { place(chrome, view, g, placement) }
            floatingBoxes[chrome.pane]?.frame = chrome.frame
            if toolbar?.superview === chrome { toolbar?.frame = chrome.toolbarFrame }
        }
        for (box, divider) in zip(dividers, shown.visible.root.dividers) { box.frame = placement.line(divider, pixel: pixel) }
        window?.invalidateCursorRects(for: self)
    }

    private func place(_ chrome: PaneChrome, _ view: PaneView, _ g: Geometry, _ placement: PaneLayout) {
        chrome.frame = placement.frame(g)
        let grid = placement.grid(g)
        if grid.maxX == placement.rightEdge { chrome.frame.size.width = bounds.maxX - chrome.frame.minX }
        chrome.grid = CGRect(origin: CGPoint(x: placement.before.width, y: placement.before.height), size: grid.size)
        let floating = shown?.visible.root.panes.contains { $0.id == chrome.pane && $0.layer != .tiled } ?? false
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = floating ? floatingRadius : 0
        chrome.layer?.masksToBounds = floating
        if floating {
            let mask = CAShapeLayer()
            let rect = chrome.bounds.offsetBy(dx: chrome.frame.minX - grid.minX, dy: grid.maxY - chrome.frame.maxY)
            mask.path = CGPath(roundedRect: rect, cornerWidth: floatingRadius, cornerHeight: floatingRadius, transform: nil)
            view.layer?.mask = mask
        } else { view.layer?.mask = nil }
        if view.scroller.superview !== chrome { chrome.addSubview(view.scroller, positioned: .below, relativeTo: nil) }
        view.scroller.frame = CGRect(x: max(0, chrome.bounds.maxX - 12),
                                     y: chrome.grid.minY, width: 12, height: chrome.grid.height)
    }

    private func hover(_ chrome: PaneChrome, _ point: NSPoint?) {
        guard !isHidden else { return }
        let show = point.map { chrome.hotZone.contains($0) } ?? false
        if show, let view = panes.first(where: { $0.pane == chrome.pane }) {
            let toolbar = self.toolbar ?? PaneToolbar()
            self.toolbar = toolbar
            if toolbar.superview !== chrome { toolbar.removeFromSuperview(); chrome.addSubview(toolbar) }
            toolbar.frame = chrome.toolbarFrame
            toolbar.update(command: view.onCommand, zoomed: shown?.visible.root.panes.count == 1 && (shown?.layout.root.panes.count ?? 0) > 1)
        }
        guard let toolbar, toolbar.superview === chrome else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            toolbar.animator().alphaValue = show ? 1 : 0
        }
    }

    private var pixel: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    private var placement: PaneLayout? {
        guard let shown, let cell = session?.cell else { return nil }
        return PaneLayout(root: shown.visible.root, bounds: bounds, cell: cell, pixel: pixel)
    }

    func cellChanged() {
        guard hot, !isHidden else { return }
        place(resizeGrids: true)
        sizeClient()
    }

    private func makePane(_ id: PaneID) -> PaneView? {
        guard let view = PaneView(
            runtime: runtime, pane: id, font: session?.font ?? 0,
            onInput: { [weak connection] in connection?.sendKeys(id, $0) })
        else { return nil }
        view.onSelect = { [weak self] in self?.connection?.send([Command("select-pane", "-t", id)]) }
        view.onCommand = { [weak self] command in
            guard let connection = self?.connection,
                let tmux = command.command(id, cell: self?.session?.cell ?? .zero, model: connection.model)
            else { return }
            connection.send([tmux])
        }
        view.onCellChange = { [weak self] in self?.session?.cellChanged() }
        view.onFontChange = { [weak self] in self?.session?.fontChanged($0) }
        view.onResync = { [weak self] in self?.connection?.sync(id) }
        return view
    }

    private func box(_ frame: CGRect, border: CGFloat, fill: NSColor) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = border
        box.borderColor = .gray
        box.fillColor = fill
        return box
    }

    private var drag: (divider: Divider, origin: NSPoint, position: Int)?

    private func hitArea(_ divider: Divider, _ placement: PaneLayout) -> CGRect {
        let line = placement.line(divider, pixel: pixel)
        return divider.direction == .leftRight ? line.insetBy(dx: -(6 - pixel) / 2, dy: 0) : line.insetBy(dx: 0, dy: -(6 - pixel) / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        if let placement, shown?.visible.root.dividers.contains(where: { hitArea($0, placement).contains(local) }) == true { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let placement else { return }
        drag = shown?.visible.root.dividers.first { hitArea($0, placement).contains(point) }
            .map { ($0, point, $0.direction == .leftRight ? $0.geometry.x : $0.geometry.y) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let cell = session?.cell else { return }
        let point = convert(event.locationInWindow, from: nil)
        let position = drag.divider.direction == .leftRight
            ? drag.divider.geometry.x + Int(((point.x - drag.origin.x) / cell.width).rounded())
            : drag.divider.geometry.y + Int(((point.y - drag.origin.y) / cell.height).rounded())
        guard position != drag.position, let command = drag.divider.resize(to: position) else { return }
        self.drag = (drag.divider, drag.origin, position)
        connection?.send([command])
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func resetCursorRects() {
        guard let placement else { return }
        for d in shown?.visible.root.dividers ?? [] {
            addCursorRect(hitArea(d, placement), cursor: d.direction == .leftRight ? .resizeLeftRight : .resizeUpDown)
        }
    }

    private func sizeClient() {
        guard !isHidden, let placement else { return }
        connection?.resize(cols: Int(placement.client.width), rows: Int(placement.client.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        guard !isHidden else { return }
        if hot { place() }
        sizeClient()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(didBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc private func didBecomeKey() {
        guard !isHidden, let pane = window?.firstResponder as? PaneView, pane.pane != active else { return }
        connection?.send([Command("select-pane", "-t", pane.pane)])
    }
}
