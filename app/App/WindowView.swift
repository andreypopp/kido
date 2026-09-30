import AppKit
import TmuxControl

final class WindowView: NSView {
    let id: WindowID
    private weak var connection: Connection?
    private let runtime: GhosttyRuntime
    private var shown: (layout: Layout, visible: Layout)?
    private var active: PaneID?

    init(runtime: GhosttyRuntime, connection: Connection?, id: WindowID) {
        self.runtime = runtime
        self.connection = connection
        self.id = id
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

    private var session: SessionView? { superview as? SessionView }

    func update(_ layout: Layout, _ visible: Layout) {
        shown = (layout, visible)
        active = visible.root.panes.first { $0.focus == .active }?.id ?? active
        let known = panes.contains { $0.pane == active }
        relayout()
        if !known { focusActive(force: false) }
    }

    func focus(_ pane: PaneID) {
        active = pane
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
        panes.forEach { connection?.detach($0) }
        removeFromSuperview()
    }

    private func relayout() {
        guard let shown else { return }
        let existing = Dictionary(uniqueKeysWithValues: panes.map { ($0.pane, $0) })
        var views: [PaneID: PaneView] = [:]
        for pane in shown.layout.root.panes {
            views[pane.id] = existing[pane.id] ?? makePane(pane.id)
        }
        for (id, gone) in existing where views[id] == nil { connection?.detach(gone) }
        let cell = session?.cell ?? views.values.lazy.map(\.cell).first { $0.width > 0 && $0.height > 0 } ?? .zero
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        var tiled: [NSView] = [], floating: [(z: Int, views: [NSView])] = []
        for pane in shown.layout.root.panes {
            guard let view = views[pane.id] else { continue }
            let g = (seen[pane.id] ?? pane).geometry
            view.isHidden = seen[pane.id] == nil
            view.frame = Self.rect(g, cell)
            view.resize(cols: g.width, rows: g.height)
            switch (seen[pane.id] ?? pane).layer {
            case .tiled:
                tiled.append(view)
            case .floating(let z):
                let ring = view.frame.insetBy(dx: -cell.width / 2 - 0.5, dy: -cell.height / 2 - 0.5)
                floating.append((z, view.isHidden ? [view] : [box(ring, border: 1, fill: runtime.background), view]))
            }
        }
        let dividers = shown.visible.root.dividers.map { d in
            let r = Self.rect(d.geometry, cell)
            let line = d.geometry.width == 1 ? r.insetBy(dx: (r.width - 1) / 2, dy: 0) : r.insetBy(dx: 0, dy: (r.height - 1) / 2)
            return box(line, border: 0, fill: .gray)
        }
        subviews = dividers + tiled + floating.sorted { $0.z > $1.z }.flatMap(\.views)
        views.values.filter { existing[$0.pane] == nil }.forEach { connection?.attach($0) }
        window?.invalidateCursorRects(for: self)
    }

    private static func rect(_ g: Geometry, _ cell: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(g.x) * cell.width, y: CGFloat(g.y) * cell.height,
            width: CGFloat(g.width) * cell.width, height: CGFloat(g.height) * cell.height)
    }

    func cellChanged() {
        relayout()
        sizeClient()
    }

    private func makePane(_ id: PaneID) -> PaneView? {
        guard let view = PaneView(runtime: runtime, pane: id, font: session?.font ?? 0) else { return nil }
        view.onInput = { [weak self] in self?.connection?.sendKeys(id, $0) }
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

    private var drag: (divider: Divider, position: Int)?

    private func cell(at event: NSEvent) -> (x: Int, y: Int)? {
        guard let cell = session?.cell else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return (Int(point.x / cell.width), Int(point.y / cell.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard let (x, y) = cell(at: event) else { return }
        drag = shown?.visible.root.dividers.first { d in
            let g = d.geometry
            return (g.x..<g.x + g.width).contains(x) && (g.y..<g.y + g.height).contains(y)
        }.map { ($0, $0.direction == .leftRight ? x : y) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let (x, y) = cell(at: event) else { return }
        let position = drag.divider.direction == .leftRight ? x : y
        guard position != drag.position, let command = drag.divider.resize(to: position) else { return }
        self.drag = (drag.divider, position)
        connection?.send([command])
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func resetCursorRects() {
        guard let cell = session?.cell else { return }
        for d in shown?.visible.root.dividers ?? [] {
            addCursorRect(Self.rect(d.geometry, cell), cursor: d.direction == .leftRight ? .resizeLeftRight : .resizeUpDown)
        }
    }

    private func sizeClient() {
        guard let cell = session?.cell else { return }
        connection?.resize(cols: Int(bounds.width / cell.width), rows: Int(bounds.height / cell.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
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
