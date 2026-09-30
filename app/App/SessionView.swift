import AppKit
import GhosttyKit
import TmuxControl

final class SessionView: NSView {
    weak var connection: Connection?
    private let runtime: GhosttyRuntime
    private(set) var windows: [WindowID: WindowView] = [:]
    private weak var shown: WindowView?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = runtime.background.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ listing: [WindowListing], shown: WindowID?) {
        let old = windows
        windows = [:]
        for w in listing {
            let view = old[w.id] ?? WindowView(runtime: runtime, connection: connection, id: w.id)
            if view.superview == nil {
                view.frame = bounds
                view.isHidden = true
                addSubview(view)
            }
            windows[w.id] = view
            view.update(w.layout, w.visible)
        }
        for (id, gone) in old where windows[id] == nil { gone.close() }
        show(shown)
    }

    func show(_ window: WindowID?) {
        for (id, view) in windows { view.isHidden = id != window }
        let view = window.flatMap { windows[$0] }
        if view !== shown { view?.focusActive(force: false) }
        shown = view
    }

    func focusActive() {
        shown?.focusActive(force: true)
    }

    // tmux has one grid for all panes, so every surface has one font size,
    // and the lowest-numbered pane is the one the cell metric is read from.
    private var panes: [PaneView] { windows.values.flatMap(\.panes).sorted { $0.pane.number < $1.pane.number } }

    var cell: CGSize? {
        panes.lazy.map(\.cell).first { $0.width > 0 && $0.height > 0 }
    }

    var font: Float { panes.first?.font ?? 0 }

    func fontChanged(_ points: Float) {
        let action = "set_font_size:\(points)"
        for pane in panes where pane.font != points {
            _ = ghostty_surface_binding_action(pane.surface, action, UInt(action.utf8.count))
        }
        cellChanged()
    }

    // Every surface reports its own font and cell changes; one pass lays
    // them all out.
    private var relayoutQueued = false

    func cellChanged() {
        guard !relayoutQueued else { return }
        relayoutQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            relayoutQueued = false
            windows.values.forEach { $0.cellChanged() }
        }
    }
}
