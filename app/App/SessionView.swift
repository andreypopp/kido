import AppKit
import GhosttyKit
import KoModel
import TmuxControl

final class SessionView: NSView {
    // The client whose views feed the panes.
    weak var client: KoClient?
    var edit: (KoSchema.Edit, LayoutEditor.Key?) -> Void = { _, _ in }
    var editing: () -> Bool = { false }
    var selectPane: (PaneID) -> Void = { _ in }
    var paneCommand: (PaneCommand, PaneID) -> Void = { _, _ in }
    var sizeClient: (Int, Int) -> Void = { _, _ in }
    private var requestedSize: (cols: Int, rows: Int)?
    private var sentSize: (cols: Int, rows: Int)?

    // The size for the server, sent at most once a frame and only when it changed.
    func requestSize(cols: Int, rows: Int, immediately: Bool = false) {
        let queued = requestedSize != nil
        requestedSize = (cols, rows)
        if immediately { return sendRequestedSize() }
        guard !queued else { return }
        DispatchQueue.main.async { [weak self] in self?.sendRequestedSize() }
    }

    private func sendRequestedSize() {
        guard let size = requestedSize else { return }
        requestedSize = nil
        guard sentSize.map({ $0 != size }) ?? true else { return }
        sentSize = size
        sizeClient(size.cols, size.rows)
    }
    #if KIDO_VISUAL
    var visualShown: (WindowID) -> Void = { _ in }
    #endif
    var reorder = Reorder()
    var onPaneChange: () -> Void = {}
    var sidebarFocused: () -> Bool = { false }
    private(set) var updating = false
    let runtime: GhosttyRuntime
    var canPrompt: () -> Bool = { false }
    var onPrompt: (PaneView, String?) -> Void = { _, _ in }
    // The current session's windows, and the hot windows of other sessions.
    private(set) var windows: [WindowID: WindowView] = [:]
    private var others: [WindowID: WindowView] = [:]
    private var recent: [WindowID] = []
    private static let budget = 32

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func close() {
        for view in windows.values { view.close() }
        for view in others.values { view.close() }
        windows = [:]
        others = [:]
        recent = []
        removeFromSuperview()
    }

    func updateBackground() {
        for view in windows.values { view.updateBackground() }
        for view in others.values { view.updateBackground() }
    }

    func reloadConfig(font: Float?) {
        forEachPane { $0.reloadConfig(font: font) }
    }

    func updateColorScheme() {
        forEachPane { ghostty_surface_set_color_scheme($0.surface, runtime.colorScheme) }
    }

    // The windows of the current session, the ids of every window of the server, and the client's selected pane.
    func update(_ listing: [KoSchema.Window], alive: Set<WindowID>, selected: PaneID?) {
        updating = true
        defer { updating = false }
        let old = windows.merging(others) { $1 }
        windows = [:]
        for w in listing {
            let id = w.id
            let view = old[id] ?? WindowView(runtime: runtime)
            view.windowID = id
            view.name = w.name
            if view.superview == nil {
                view.frame = bounds
                view.isHidden = true
                addSubview(view)
            }
            windows[id] = view
            let active = selected.flatMap { w.panes.contains($0) ? $0 : nil }
            view.update(Layout(w, active: active), Layout(w, visible: true, active: active))
        }
        others = old.filter { windows[$0.key] == nil && $0.value.hot && alive.contains($0.key) }
        for (id, gone) in old where windows[id] == nil && others[id] == nil { gone.close() }
        recent.removeAll { windows[$0] == nil && others[$0] == nil }
    }

    func editsSettled() {
        windows.values.forEach { $0.editsSettled() }
    }

    private var shown: WindowView? { windows.values.first { !$0.isHidden } }

    func show(_ window: WindowID?) {
        let start = DispatchTime.now(), before = shown, last = recent.first
        let focused = (self.window?.firstResponder as? PaneView)?.isDescendant(of: self) == true
        defer { DispatchQueue.main.async { [weak self] in self?.evict() } }
        for (id, view) in windows { view.isHidden = id != window }
        others.values.forEach { $0.isHidden = true }
        guard let window, let view = windows[window], view !== before else { return }
        #if KIDO_VISUAL
        visualShown(window)
        #endif
        recent.removeAll { $0 == window }
        recent.insert(window, at: 0)
        let created = view.present()
        view.focusActive(force: focused)
        debug("switch \(last?.description ?? "-")->\(window): created \(created), shown in \(milliseconds(since: start))")
    }

    private func evict() {
        var hot = 0
        for id in recent where hotSurfaces > Self.budget {
            guard let view = windows[id] ?? others[id], view.hot else { continue }
            hot += view.panes.count
            guard hot > Self.budget, view !== shown else { continue }
            debug("evict \(id): \(view.panes.count) of \(hot) hot surfaces")
            hot -= view.panes.count
            if others.removeValue(forKey: id) != nil { view.close() } else { view.evict() }
        }
        recent.removeAll { windows[$0]?.hot != true && others[$0] == nil }
    }

    private var hotSurfaces: Int { (Array(windows.values) + Array(others.values)).filter(\.hot).reduce(0) { $0 + $1.panes.count } }
    #if KIDO_VISUAL
    var visualHotSurfaces: Int { hotSurfaces }
    #endif

    func invalidateClipboard() {
        forEachPane { $0.invalidateClipboard() }
    }

    func focusActive() {
        shown?.focusActive(force: true)
    }

    func pane(_ pane: PaneID) -> PaneView? { windows.values.lazy.flatMap(\.panes).first { $0.pane == pane } }

    func windowName(_ window: WindowID) -> String? { windows[window]?.name }

    private var panes: [PaneView] {
        (windows.values.flatMap(\.panes) + others.values.flatMap(\.panes)).sorted { $0.pane.number < $1.pane.number }
    }

    private func forEachPane(_ body: (PaneView) -> Void) { panes.forEach(body) }

    var cell: CGSize? {
        guard let cell = panes.first?.cell, cell.width > 0, cell.height > 0 else { return nil }
        return cell
    }

    var cellPixels: (width: UInt32, height: UInt32)? {
        guard let pane = panes.first else { return nil }
        let size = ghostty_surface_size(pane.surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        return (size.cell_width_px, size.cell_height_px)
    }

    var font: Float { panes.first?.font ?? 0 }

    func fontChanged(_ points: Float) {
        forEachPane { pane in
            guard pane.font != points else { return }
            pane.reflow { pane.setFontSize(points) }
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
