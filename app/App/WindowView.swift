import AppKit
import TmuxControl

final class WindowView: NSView {
    weak var connection: Connection?
    private let runtime: GhosttyRuntime
    private var shown: (window: WindowID, layout: Layout, visible: Layout)?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = runtime.background.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private var panes: [PaneView] { subviews.compactMap { $0 as? PaneView } }

    private static func cell(_ panes: some Sequence<PaneView>) -> CGSize? {
        panes.lazy.map(\.cell).first { $0.width > 0 && $0.height > 0 }
    }

    func show(_ window: WindowID, _ layout: Layout, _ visible: Layout) {
        shown = (window, layout, visible)
        relayout()
        if let active = visible.root.panes.first(where: { $0.focus == .active }) { focus(window, active.id) }
    }

    func layoutChanged(_ window: WindowID, _ layout: Layout, _ visible: Layout) {
        if window == shown?.window { show(window, layout, visible) }
    }

    func focus(_ window: WindowID, _ pane: PaneID) {
        guard window == shown?.window, let view = panes.first(where: { $0.pane == pane }) else { return }
        self.window?.makeFirstResponder(view)
    }

    private func relayout() {
        guard let shown else { return }
        let existing = Dictionary(uniqueKeysWithValues: panes.map { ($0.pane, $0) })
        var views: [PaneID: PaneView] = [:]
        for pane in shown.layout.root.panes {
            views[pane.id] = existing[pane.id] ?? makePane(pane.id)
        }
        for gone in existing.keys where views[gone] == nil { connection?.detach(gone) }
        let cell = Self.cell(views.values) ?? .zero
        func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> CGRect {
            CGRect(
                x: CGFloat(x) * cell.width, y: CGFloat(y) * cell.height,
                width: CGFloat(width) * cell.width, height: CGFloat(height) * cell.height)
        }
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        var tiled: [NSView] = [], floating: [(z: Int, views: [NSView])] = []
        for pane in shown.layout.root.panes {
            guard let view = views[pane.id] else { continue }
            let g = (seen[pane.id] ?? pane).geometry
            view.isHidden = seen[pane.id] == nil
            view.frame = rect(g.x, g.y, g.width, g.height)
            view.resize(cols: g.width, rows: g.height)
            switch (seen[pane.id] ?? pane).layer {
            case .tiled:
                tiled.append(view)
            case .floating(let z):
                let ring = rect(g.x - 1, g.y - 1, g.width + 2, g.height + 2)
                let border = box(ring.insetBy(dx: cell.width / 2 - 0.5, dy: cell.height / 2 - 0.5), 1)
                floating.append((z, view.isHidden ? [view] : [border, view]))
            }
        }
        let dividers = shown.visible.root.dividers.map { g in
            let r = rect(g.x, g.y, g.width, g.height)
            return box(g.width == 1 ? r.insetBy(dx: (r.width - 1) / 2, dy: 0) : r.insetBy(dx: 0, dy: (r.height - 1) / 2), 0)
        }
        subviews = dividers + tiled + floating.sorted { $0.z > $1.z }.flatMap(\.views)
        views.values.filter { existing[$0.pane] == nil }.forEach { connection?.attach($0) }
    }

    private func makePane(_ id: PaneID) -> PaneView? {
        guard let view = PaneView(runtime: runtime, pane: id) else { return nil }
        view.onInput = { [weak self] in self?.connection?.sendKeys(id, $0) }
        view.onSelect = { [weak self] in self?.connection?.send([Command("select-pane", "-t", id)]) }
        view.onCellChange = { [weak self] in
            self?.relayout()
            self?.sizeClient()
        }
        return view
    }

    private func box(_ frame: CGRect, _ border: CGFloat) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = border
        box.borderColor = .gray
        box.fillColor = border == 0 ? .gray : runtime.background
        return box
    }

    private func sizeClient() {
        guard let cell = Self.cell(panes) else { return }
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
        center.addObserver(self, selector: #selector(didBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc private func didBecomeKey() {
        guard let shown else { return }
        let pane = (window?.firstResponder as? PaneView).map { [Command("select-pane", "-t", $0.pane)] } ?? []
        connection?.send([Command("select-window", "-t", shown.window)] + pane)
    }
}
