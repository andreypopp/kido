import AppKit
import TmuxControl

final class SessionView: NSView {
    weak var connection: Connection?
    private let runtime: GhosttyRuntime
    private var windows: [WindowID: WindowView] = [:]
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
        if view !== shown { view?.focusActive() }
        shown = view
    }

    func layoutChanged(_ window: WindowID, _ layout: Layout, _ visible: Layout) {
        windows[window]?.update(layout, visible)
    }

    func focus(_ window: WindowID, _ pane: PaneID) {
        windows[window]?.focus(pane)
    }
}
