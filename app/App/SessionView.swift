import AppKit
import GhosttyKit
import TmuxControl

final class SessionView: NSView {
    weak var connection: Connection?
    private let runtime: GhosttyRuntime
    // The client's session's windows, and the hot windows of other sessions,
    // which tmux sends no output for.
    private(set) var windows: [WindowID: WindowView] = [:]
    private var others: [WindowID: WindowView] = [:]
    private var recent: [WindowID] = []
    private static let budget = 32

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = runtime.background.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func updateBackground() {
        layer?.backgroundColor = runtime.background.cgColor
        for view in windows.values { view.updateBackground() }
        for view in others.values { view.updateBackground() }
    }

    func updateColorScheme() {
        forEachPane { ghostty_surface_set_color_scheme($0.surface, runtime.colorScheme) }
    }

    func update(_ listing: [WindowListing], alive: Set<WindowID>) {
        let old = windows.merging(others) { $1 }
        windows = [:]
        for w in listing {
            let view = old[w.id] ?? WindowView(runtime: runtime, connection: connection)
            if view.superview == nil {
                view.frame = bounds
                view.isHidden = true
                addSubview(view)
            }
            windows[w.id] = view
            view.update(w.layout, w.visible)
        }
        others = old.filter { windows[$0.key] == nil && $0.value.hot && alive.contains($0.key) }
        others.values.forEach { $0.stale = true }
        for (id, gone) in old where windows[id] == nil && others[id] == nil { gone.close() }
        recent.removeAll { windows[$0] == nil && others[$0] == nil }
    }

    private var shown: WindowView? { windows.values.first { !$0.isHidden } }

    func show(_ window: WindowID?) {
        let start = DispatchTime.now(), before = shown, last = recent.first
        let focused = (self.window?.firstResponder as? PaneView)?.isDescendant(of: self) == true
        defer { DispatchQueue.main.async { [weak self] in self?.evict() } }
        for (id, view) in windows { view.isHidden = id != window }
        others.values.forEach { $0.isHidden = true }
        guard let window, let view = windows[window], view !== before else { return }
        recent.removeAll { $0 == window }
        recent.insert(window, at: 0)
        let synced = DispatchGroup()
        let (created, resynced) = view.present(synced)
        view.focusActive(force: focused)
        if debugging {
            synced.notify(queue: .main) {
                debug(
                    "switch \(last?.description ?? "-")->\(window): created \(created), resynced \(resynced), "
                        + "shown in \(milliseconds(since: start))")
            }
        }
    }

    private func evict() {
        var hot = 0
        for id in recent {
            guard let view = windows[id] ?? others[id], view.hot else { continue }
            hot += view.panes.count
            guard hot > Self.budget, view !== shown else { continue }
            debug("evict \(id): \(view.panes.count) of \(hot) hot surfaces")
            hot -= view.panes.count
            if others.removeValue(forKey: id) != nil { view.close() } else { view.evict() }
        }
        recent.removeAll { windows[$0]?.hot != true && others[$0] == nil }
    }

    func focusActive() {
        shown?.focusActive(force: true)
    }

    // tmux has one grid for all panes, so every surface has one font size,
    // and the lowest-numbered pane is the one the cell metric is read from.
    private func forEachPane(_ body: (PaneView) -> Void) {
        for view in windows.values { view.panes.forEach(body) }
        for view in others.values { view.panes.forEach(body) }
    }

    var cell: CGSize? {
        let panes = (windows.values.flatMap(\.panes) + others.values.flatMap(\.panes)).sorted { $0.pane.number < $1.pane.number }
        return panes.lazy.map(\.cell).first { $0.width > 0 && $0.height > 0 }
    }

    var font: Float {
        let panes = windows.values.flatMap(\.panes) + others.values.flatMap(\.panes)
        return panes.min { $0.pane.number < $1.pane.number }?.font ?? 0
    }

    func fontChanged(_ points: Float) {
        let action = "set_font_size:\(points)"
        forEachPane { pane in
            guard pane.font != points else { return }
            pane.reflow { _ = ghostty_surface_binding_action(pane.surface, action, UInt(action.utf8.count)) }
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
