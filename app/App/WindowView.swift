import AppKit
import TmuxControl

final class WindowView: NSView {
    private weak var connection: Connection?
    private let runtime: GhosttyRuntime
    private var shown: (layout: Layout, visible: Layout)?
    private var active: PaneID?
    var stale = false

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

    private var session: SessionView? { superview as? SessionView }

    func update(_ layout: Layout, _ visible: Layout) {
        let changed = shown.map { $0.layout != layout || $0.visible != visible } ?? true
        shown = (layout, visible)
        active = visible.root.panes.first { $0.focus == .active }?.id ?? active
        guard hot else { return }
        let known = panes.contains { $0.pane == active }
        if changed { relayout() }
        if !known { focusActive(force: false) }
    }

    func present(_ synced: DispatchGroup) -> (created: Int, resynced: Int) {
        let resync = stale ? panes : []
        stale = false
        for pane in resync {
            synced.enter()
            connection?.sync(pane.pane) { synced.leave() }
        }
        guard !hot else { return (0, resync.count) }
        relayout(synced)
        return (panes.count, 0)
    }

    func evict() {
        panes.forEach { connection?.detach($0) }
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
        let focused = (window?.firstResponder as? PaneView)?.isDescendant(of: self) == true
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
        for pane in layoutPanes {
            guard let view = views[pane.id] else { continue }
            let g = (seen[pane.id] ?? pane).geometry
            view.isHidden = seen[pane.id] == nil
            view.frame = placement.grid(g)
            view.resize(cols: g.width, rows: g.height)
            let chrome = overlays[pane.id] ?? PaneChrome(pane: pane.id, background: runtime.background) { [weak connection] command in
                connection?.send([command])
            }
            chrome.select = { [weak connection] in connection?.send([Command("select-pane", "-t", pane.id)]) }
            chrome.frame = placement.frame(g)
            chrome.grid = CGRect(origin: CGPoint(x: placement.before.width, y: placement.before.height), size: view.frame.size)
            chrome.isHidden = view.isHidden
            chrome.dimmed = pane.id != active
            chrome.update(zoomed: seen.count == 1 && layoutPanes.count > 1)
            switch (seen[pane.id] ?? pane).layer {
            case .tiled:
                tiled += [view, chrome]
            case .floating(let z):
                floating.append((z, view.isHidden ? [view, chrome] : [box(chrome.frame, border: pixel, fill: runtime.background), view, chrome]))
            }
        }
        let dividers = shown.visible.root.dividers.map { d in
            box(placement.line(d, pixel: pixel), border: 0, fill: .white.withAlphaComponent(0.12))
        }
        subviews = dividers + tiled + floating.sorted { $0.z > $1.z }.flatMap(\.views)
        for view in views.values where existing[view.pane] == nil {
            synced?.enter()
            connection?.attach(view) { synced?.leave() }
        }
        window?.invalidateCursorRects(for: self)
        if focused { focusActive(force: true) }
    }

    private var pixel: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    private var placement: PaneLayout? {
        guard let shown, let cell = session?.cell else { return nil }
        return PaneLayout(root: shown.visible.root, bounds: bounds, cell: cell, pixel: pixel)
    }

    func cellChanged() {
        guard hot else { return }
        relayout()
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

    private func hitArea(_ divider: Divider) -> CGRect {
        guard let placement else { return .zero }
        let line = placement.line(divider, pixel: pixel)
        return divider.direction == .leftRight ? line.insetBy(dx: -(6 - pixel) / 2, dy: 0) : line.insetBy(dx: 0, dy: -(6 - pixel) / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        if shown?.visible.root.dividers.contains(where: { hitArea($0).contains(local) }) == true { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        drag = shown?.visible.root.dividers.first { hitArea($0).contains(point) }
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
        for d in shown?.visible.root.dividers ?? [] {
            addCursorRect(hitArea(d), cursor: d.direction == .leftRight ? .resizeLeftRight : .resizeUpDown)
        }
    }

    private func sizeClient() {
        guard !isHidden, let placement else { return }
        connection?.resize(cols: Int(placement.client.width), rows: Int(placement.client.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if hot { relayout() }
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
