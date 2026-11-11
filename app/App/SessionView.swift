import AppKit
import GhosttyKit
import KoModel
import PaneGeometry
import SidebarFeed

final class SessionView: NSView {
    // The client whose views feed the panes.
    weak var client: KoClient?
    var host = Host.local
    var webview: (PaneID) -> KoSchema.Webview? = { _ in nil }
    private var hiddenWebview: [PaneID] = []
    private var webviewQueued = false

    func updateWebview() {
        guard !webviewQueued else { return }
        webviewQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            webviewQueued = false
            let live = retainedPanes
            let hidden = live.filter { $0.isHiddenOrHasHiddenAncestor && $0.webviewView != nil }
            let ids = Set(hidden.map(\.pane))
            hiddenWebview.removeAll { !ids.contains($0) }
            hiddenWebview.append(contentsOf: hidden.map(\.pane).filter { !hiddenWebview.contains($0) })
            let release = Set(hiddenWebview.prefix(max(0, hiddenWebview.count - runtime.values.webview.keepHidden)))
            for pane in live {
                if release.contains(pane.pane) { pane.releaseWebview() }
                else { pane.updateWebview(webview(pane.pane)) }
            }
            hiddenWebview.removeAll { release.contains($0) }
            for view in Array(windows.values) + Array(others.values) { view.releaseUnusedPanes() }
        }
    }
    var edit: (KoSchema.Edit, LayoutEditor.Key?) -> Void = { _, _ in }
    var editing: () -> Bool = { false }
    var selectPane: (PaneID) -> Void = { _ in }
    var paneCommand: (PaneCommand, PaneID) -> Void = { _, _ in }
    var sizeClient: (KoSize, [KoWindowSize]) -> Bool = { _, _ in false }
    private struct Report: Equatable {
        let viewport: KoSize
        let windows: [KoWindowSize]
    }
    private var requestedSize: KoSize?
    private var sentSize: Report?

    func resetSizeReport() { sentSize = nil }

    // The size for the server, sent at most once a frame and only when it or the cell's pixels changed.
    func requestSize(cols: Int, rows: Int, immediately: Bool = false) {
        let queued = requestedSize != nil
        requestedSize = KoSize(cols: cols, rows: rows, cell: cellPixels)
        if immediately { return sendRequestedSize() }
        guard !queued else { return }
        DispatchQueue.main.async { [weak self] in self?.sendRequestedSize() }
    }

    private func sendRequestedSize() {
        guard let size = requestedSize else { return }
        requestedSize = nil
        let windows = shown?.sizeReport(viewport: size) ?? []
        let report = Report(viewport: size, windows: windows)
        guard sentSize != report else { return }
        if sizeClient(size, windows) { sentSize = report }
    }
    #if KIDO_VISUAL
    var visualShown: (WindowID) -> Void = { _ in }
    var visualReconciled: (WindowView) -> Void = { _ in }
    #endif
    var reorder = Reorder()
    var onPaneChange: () -> Void = {}
    var sidebarFocused: () -> Bool = { false }
    private(set) var updating = false
    let runtime: GhosttyRuntime
    var canPrompt: () -> Bool = { false }
    var onURL: (String) -> Void = { _ in }
    var onPrompt: (PaneView, String?) -> Void = { _, _ in }
    // Where the panes run, from the model.
    private(set) var marks: [PaneID: RuntimeMark] = [:]
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
        updateWebview()
    }

    func updateColorScheme() {
        forEachPane { ghostty_surface_set_color_scheme($0.surface, runtime.colorScheme) }
    }

    // The windows of the current session, the ids of every window of the server, and the client's selected pane.
    func update(_ listing: [KoSchema.Window], alive: Set<WindowID>, selected: PaneID?, marks: [PaneID: RuntimeMark], shown: [PaneID: ShownPane] = [:], children: [ChildFloats] = []) {
        updating = true
        defer { updating = false }
        let marked = self.marks
        self.marks = marks
        let changed = Set(marked.keys).union(marks.keys).filter { marked[$0] != marks[$0] }
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
            let here = children.filter { w.panes.contains($0.slot) }
            let active = selected.flatMap { selected in w.panes.contains(selected) || here.contains { $0.floats.contains { $0.pane == selected } } ? selected : nil }
            view.update(Layout(w, active: active, children: here), Layout(w, visible: true, active: active, children: here), shown: shown)
        }
        others = old.filter { windows[$0.key] == nil && $0.value.hot && alive.contains($0.key) }
        for (id, gone) in old where windows[id] == nil && others[id] == nil { gone.close() }
        recent.removeAll { windows[$0] == nil && others[$0] == nil }
        if !changed.isEmpty { (Array(windows.values) + Array(others.values)).forEach { $0.marksChanged(changed, banded: Set(marked.keys) != Set(marks.keys)) } }
        if sentSize == nil { self.shown?.sizeClient() }
    }

    func editsSettled() {
        windows.values.forEach { $0.editsSettled() }
    }

    private var shown: WindowView? { windows.values.first { !$0.isHidden } }
    var activePane: PaneView? { shown?.activePane }

    func show(_ window: WindowID?) {
        let previousUpdate = updating
        updating = true
        defer { updating = previousUpdate }
        let start = DispatchTime.now(), before = shown, last = recent.first
        let focused = PaneView.owner(self.window?.firstResponder)?.isDescendant(of: self) == true
        defer { updateWebview(); DispatchQueue.main.async { [weak self] in self?.evict() } }
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
            let count = view.retainedCount
            hot += count
            guard hot > Self.budget, view !== shown else { continue }
            debug("evict \(id): \(count) of \(hot) hot surfaces")
            hot -= count
            if others.removeValue(forKey: id) != nil { view.close() } else { view.evict() }
        }
        recent.removeAll { windows[$0]?.hot != true && others[$0] == nil }
    }

    private var hotSurfaces: Int { (Array(windows.values) + Array(others.values)).filter(\.hot).reduce(0) { $0 + $1.retainedCount } }
    #if KIDO_VISUAL
    var visualHotSurfaces: Int { hotSurfaces }
    #endif

    func invalidateClipboard() {
        forEachPane { $0.invalidateClipboard() }
    }

    func focusActive() {
        shown?.focusActive(force: true)
    }

    func pane(_ pane: PaneID) -> PaneView? {
        shown?.displayedPanes.first { $0.pane == pane } ?? windows.values.lazy.flatMap(\.displayedPanes).first { $0.pane == pane }
    }

    func windowName(_ window: WindowID) -> String? { windows[window]?.name }

    func retryImages() { retainedPanes.forEach { $0.retryImages() } }

    private var retainedPanes: [PaneView] {
        (windows.values.flatMap(\.retainedPanes) + others.values.flatMap(\.retainedPanes)).sorted { $0.pane.number < $1.pane.number }
    }

    private func forEachPane(_ body: (PaneView) -> Void) { retainedPanes.forEach(body) }

    var cell: CGSize? {
        guard let cell = retainedPanes.first?.cell, cell.width > 0, cell.height > 0 else { return nil }
        return cell
    }

    var cellPixels: KoSchema.CellPixels? {
        guard let pane = retainedPanes.first else { return nil }
        let size = ghostty_surface_size(pane.surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        return KoSchema.CellPixels(height: Int(size.cell_height_px), width: Int(size.cell_width_px))
    }

    var font: Float { retainedPanes.first?.font ?? 0 }

    func fontChanged(_ points: Float) {
        forEachPane { pane in
            guard pane.font != points else { return }
            pane.reflow { pane.setFontSize(points) }
        }
        cellChanged()
        updateWebview()
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
            retainedPanes.forEach { $0.webviewView?.updateTheme() }
            windows.values.forEach { $0.cellChanged() }
        }
    }
}
