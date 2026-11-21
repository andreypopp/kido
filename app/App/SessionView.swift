import AppKit
import GhosttyKit
import KoClientKit
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
            for view in windows.values { view.releaseUnusedPanes() }
        }
    }
    var floatsAllowed: () -> Bool = { true }
    var ownsFloats: () -> Bool = { true }
    var floatTitle: (PaneID, WindowID) -> String = { _, _ in "" }
    var hostFocusChanged: (NSResponder?, NSResponder?) -> Void = { _, _ in }
    func contains(_ pane: PaneView) -> Bool { windows.values.contains { $0.contains(pane) } }
    var hostWindows: [FloatWindow] { windows.values.flatMap(\.hostWindows) }
    var inputWindow: NSWindow? { hostWindows.first { $0.isInputWindow } ?? window }
    var edit: (KoSchema.Edit, LayoutEditor.Key?) -> Void = { _, _ in }
    var editSelecting: (KoSchema.Edit) -> Void = { _ in }
    var floatState: (PaneID) -> PaneFloatState? = { _ in nil }
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
    var onPrompt: (PaneView, String?, KoSchema.PromptTarget?) -> Void = { _, _, _ in }
    // Where the panes run, from the model.
    private(set) var marks: [PaneID: RuntimeMark] = [:]
    private(set) var windows: [WindowID: WindowView] = [:]
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
        windows = [:]
        recent = []
        removeFromSuperview()
    }

    func updateBackground() {
        for view in windows.values { view.updateBackground() }
    }

    func reloadConfig(font: Float?) {
        forEachPane { $0.reloadConfig(font: font) }
        updateWebview()
    }

    func updateColorScheme() {
        forEachPane { ghostty_surface_set_color_scheme($0.surface, runtime.colorScheme) }
    }

    func update(_ listing: [KoSchema.Window], shown window: WindowID?, selected: PaneID?, marks: [PaneID: RuntimeMark]) {
        updating = true
        defer { updating = false }
        let marked = self.marks
        self.marks = marks
        let changed = Set(marked.keys).union(marks.keys).filter { marked[$0] != marks[$0] }
        let old = windows
        windows = [:]
        for w in listing where w.id == window || recent.contains(w.id) || old[w.id]?.hasFloatState == true || ownsFloats() && !w.floats.isEmpty {
            retain(w, reusing: old[w.id], active: selected.flatMap { w.panes.contains($0) ? $0 : nil })
        }
        for (id, gone) in old where windows[id] == nil { gone.close() }
        recent.removeAll { windows[$0] == nil }
        if !changed.isEmpty { windows.values.forEach { $0.marksChanged(changed, banded: Set(marked.keys) != Set(marks.keys)) } }
        for view in windows.values where view.hasFloats && ownsFloats() && !view.hot { _ = view.present() }
        if sentSize == nil { self.shown?.sizeClient() }
    }

    private func retain(_ window: KoSchema.Window, reusing: WindowView?, active: PaneID?) {
        let view = reusing ?? WindowView(runtime: runtime)
        view.windowID = window.id
        view.name = window.name
        if view.superview == nil {
            view.frame = bounds
            view.isHidden = true
            addSubview(view)
        }
        windows[window.id] = view
        view.update(Layout(window, active: active), Layout(window, visible: true, active: active))
    }

    func adoptFloats(from source: SessionView) {
        for (id, view) in source.windows {
            let hosts = view.takeFloatHosts()
            guard !hosts.isEmpty else { continue }
            if windows[id] == nil, let w = try? client?.model().layout.layout.window(id) {
                retain(w, reusing: nil, active: nil)
            }
            if let destination = windows[id] { destination.adoptFloatHosts(hosts) }
            else { hosts.values.forEach { $0.window?.detach() } }
        }
    }

    func refreshFloats() { windows.values.forEach { $0.refreshFloats() } }

    func syncHosts() { windows.values.forEach { $0.syncHosts() } }

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
        let focused = OwnerWindow.focusedPane.map { $0.window === self.window && contains($0) } == true
        defer { updateWebview(); DispatchQueue.main.async { [weak self] in self?.evict() } }
        for (id, view) in windows { view.isHidden = id != window }
        guard let window, let view = windows[window], view !== before else { return }
        #if KIDO_VISUAL
        visualShown(window)
        #endif
        recent.removeAll { $0 == window }
        recent.insert(window, at: 0)
        let created = view.present()
        view.focusActive(force: focused)
        windows.values.forEach { $0.refreshFloatIdentity() }
        debug("switch \(last?.description ?? "-")->\(window): created \(created), shown in \(milliseconds(since: start))")
    }

    private func evict() {
        var hot = 0
        for id in recent where hotSurfaces > Self.budget {
            guard let view = windows[id], view.hot, !view.hasFloatState else { continue }
            let count = view.retainedCount
            hot += count
            guard hot > Self.budget, view !== shown else { continue }
            debug("evict \(id): \(count) of \(hot) hot surfaces")
            hot -= count
            view.evict()
        }
    }

    private var hotSurfaces: Int { windows.values.filter(\.hot).reduce(0) { $0 + $1.retainedCount } }
    #if KIDO_VISUAL
    var visualHotSurfaces: Int { hotSurfaces }
    #endif

    func invalidateClipboard() {
        forEachPane { $0.invalidateClipboard() }
    }

    func focusActive() {
        shown?.focusActive(force: true)
    }

    func focusPane(_ pane: PaneID) {
        guard let view = windows.values.first(where: { $0.active == pane }) else { return }
        if let host = view.hostWindows.first(where: { $0.content.pane == pane }) { host.makeKeyAndOrderFront(nil) }
        view.focusActive(force: true)
    }

    func pane(_ pane: PaneID) -> PaneView? {
        shown?.displayedPanes.first { $0.pane == pane } ?? windows.values.lazy.flatMap(\.displayedPanes).first { $0.pane == pane }
    }

    func windowName(_ window: WindowID) -> String? { windows[window]?.name }

    func retryImages() { retainedPanes.forEach { $0.retryImages() } }

    var retainedPanes: [PaneView] {
        windows.values.flatMap(\.retainedPanes).sorted { $0.pane.number < $1.pane.number }
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
