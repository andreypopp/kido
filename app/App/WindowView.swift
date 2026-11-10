import AppKit
import GhosttyKit
import KoModel
import PaneGeometry
import SidebarFeed

private extension NSCursor.FrameResizePosition {
    var layoutEdge: PaneLayout.ResizeEdge {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        @unknown default: fatalError("Unknown resize edge")
        }
    }
}

final class WindowView: NSView {
    #if KIDO_VISUAL
    @MainActor static var toolbarFadeDuration: TimeInterval = 0.15
    #else
    static let toolbarFadeDuration: TimeInterval = 0.15
    #endif
    private let runtime: GhosttyRuntime
    var windowID: WindowID?
    var name = ""
    private var shown: (layout: Layout, visible: Layout)?
    private struct RetainedPane {
        let view: PaneView
        let chrome: PaneChrome
    }
    private var displayedPaneIDs: [PaneID: PaneID] = [:]
    private var retainedPaneViews: [PaneID: RetainedPane] = [:]
    private var shownPanes: [PaneID: ShownPane] = [:]
    private var displayedSlots: [PaneID: RetainedPane] { displayedPaneIDs.compactMapValues { retainedPaneViews[$0] } }
    private func displayed(_ id: PaneID) -> RetainedPane? { displayedPaneIDs[id].flatMap { retainedPaneViews[$0] } }
    var retainedCount: Int { retainedPaneViews.count }
    var retainedPanes: [PaneView] { retainedPaneViews.values.map(\.view) }

    func releaseUnusedPanes() {
        let shown = Set(displayedPaneIDs.values)
        for (id, slot) in retainedPaneViews where !shown.contains(id) && slot.view.webviewView == nil {
            slot.view.chromeViews.forEach { $0.removeFromSuperview() }
            slot.chrome.removeFromSuperview()
            slot.view.scroller.removeFromSuperview()
            slot.view.dispose()
            slot.view.removeFromSuperview()
            retainedPaneViews.removeValue(forKey: id)
        }
    }
    var activeSlot: PaneID? {
        shown?.layout.root.panes.first { $0.id == active || shownPanes[$0.id]?.shown.position.pane == active }?.id
    }
    var paneIDs: [PaneID] {
        guard let shown else { return [] }
        return shown.layout.root.panes.map(\.id) + shown.visible.root.panes.map(\.id)
    }
    private(set) var active: PaneID? {
        didSet {
            if active != oldValue, let session, !session.updating { session.onPaneChange() }
        }
    }
    private var needsReconcile = true
    private var dividers: [NSBox] = []
    private var backings: [PaneID: NSBox] = [:]
    private var freeFrames: [PaneID: CGRect] = [:]
    private var placed: PaneLayout?
    // A float's frame from the drag, held after the release until the layout shows the edit.
    private enum FloatFrame { case dragging(PaneID, CGRect), held(PaneID, CGRect) }
    private var liveFrame: FloatFrame?
    private let floatingRadius: CGFloat = 10
    private var toolbar: PaneToolbar?
    private let preview = PaneDropPreview()
    override var isHidden: Bool {
        didSet {
            if isHidden { endDrag(); toolbar?.removeFromSuperview(); toolbar = nil }
        }
    }

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = runtime.background.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    var displayedPanes: [PaneView] { displayedSlots.values.map(\.view) }

    #if KIDO_VISUAL
    var visualGeometryReady: Bool {
        guard let shown, let placement else { return false }
        let geometry = switch shown.visible.root {
        case .pane(let p): p.geometry
        case .split(_, let g, _): g
        }
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        let fitted = displayedPanes.allSatisfy { view in
            guard !view.isHidden, let pane = seen[view.pane] else { return true }
            return (Int(view.geometry.columns), Int(view.geometry.rows)) == (pane.geometry.width, pane.geometry.height)
        }
        return fitted && geometry.width == Int(placement.client.width) && geometry.height == Int(placement.client.height)
    }
    var visualLayout: String {
        func rect(_ r: CGRect) -> String {
            [r.minX, r.minY, r.width, r.height].map { String(format: "%.2f", Double($0)) }.joined(separator: ",")
        }
        func bannerVisible(_ view: NSView) -> Bool {
            !view.isHidden && (view is Banner || view.subviews.contains(where: bannerVisible))
        }
        var lines = ["bounds=\(rect(bounds)) separator=\(placed.map { rect($0.topLine) } ?? "-") banner=\(window?.contentView.map(bannerVisible) ?? false)"]
        for pane in displayedPanes.filter({ !$0.isHidden }).sorted(by: { $0.pane.number < $1.pane.number }) {
            let chrome = retainedPaneViews[pane.pane]?.chrome
            let geometry = shown?.visible.root.panes.first { $0.id == chrome?.pane }
            let grid = CGRect(x: pane.frame.minX, y: pane.frame.minY + pane.renderInsets.top,
                              width: pane.frame.width, height: pane.frame.height - pane.renderInsets.top - pane.renderInsets.bottom)
            lines.append("\(pane.pane) cells=\(geometry.map { String(describing: $0.geometry) } ?? "-") layer=\(geometry.map { String(describing: $0.layer) } ?? "-") grid=\(rect(grid)) content=\(rect(pane.frame)) chrome=\(chrome.map { rect($0.frame) } ?? "-") \(pane.visualState)")
        }
        lines += dividers.map { "divider=\(rect($0.frame))" }.sorted()
        lines += backings.filter { pair in shown?.visible.root.panes.contains { $0.id == pair.key && $0.layer != .tiled } == true }
            .sorted { $0.key.number < $1.key.number }.map { "float \($0.key)=\(rect($0.value.frame))" }
        return lines.joined(separator: "\n")
    }
    var visualPaneDragging: Bool { paneDrag != nil }
    func visualBeginDrag(_ pane: PaneID, _ event: NSEvent) { beginDrag(pane, event) }
    #endif

    var hot: Bool { !retainedPaneViews.isEmpty }

    var defersRestore: Bool {
        paneDrag != nil || drag != nil || liveFrame != nil || session?.editing() == true || window?.inLiveResize == true
    }

    func updateBackground() {
        layer?.backgroundColor = runtime.background.cgColor
        updateFocusTreatment(forcePaper: true)
        for chrome in displayedSlots.values.map(\.chrome) {
            chrome.needsDisplay = true
            for overlay in chrome.subviews { overlay.needsDisplay = true }
        }
        dividers.forEach { $0.fillColor = runtime.separator }
    }

    private var session: SessionView? { superview as? SessionView }

    func update(_ layout: Layout, _ visible: Layout, shown selected: [PaneID: ShownPane] = [:]) {
        shownPanes = selected
        let replacements = layout.root.panes.contains { displayedPaneIDs[$0.id] != (shownPanes[$0.id]?.shown.position.pane ?? $0.id) }
        let changed = replacements || (shown.map { $0.layout != layout || $0.visible != visible } ?? true)
        func sameTopology(_ a: PaneGeometry.Node, _ b: PaneGeometry.Node) -> Bool {
            switch (a, b) {
            case (.pane(let a), .pane(let b)): a.id == b.id && a.layer == b.layer
            case (.split(let a, _, let ac), .split(let b, _, let bc)):
                a == b && ac.count == bc.count && zip(ac, bc).allSatisfy { sameTopology($0, $1) }
            default: false
            }
        }
        needsReconcile = needsReconcile || replacements || (shown.map { !sameTopology($0.layout.root, layout.root) || !sameTopology($0.visible.root, visible.root) } ?? true)
        shown = (layout, visible)
        if let paneDrag {
            let valid: Bool = switch paneDrag {
            case .tiled(let id, _): visible.root.panes.contains { $0.id == id && $0.layer == .tiled }
            case .floating(let pane, _, _, _): visible.root.panes.contains { $0.id == pane.id && $0.layer != .tiled }
            }
            if zoomed || !valid {
                #if KIDO_STRESS
                stressEvent("drag-layout-cancelled", zoomed ? "zoomed" : "source removed or changed layer")
                #endif
                cancelDrag()
            }
        }
        if let placement { validateFrames(placement) }
        else { freeFrames = [:] }
        // Hiding the focused pane gives the focus to the next key view, so read it before the relayout.
        let paneFocused = PaneView.owner(window?.firstResponder).map { focused in displayedPanes.contains { $0 === focused } } == true
        let previous = active
        active = visible.root.panes.first { $0.active }.map { shownPanes[$0.id]?.shown.position.pane ?? $0.id } ?? active
        guard hot else { return }
        let known = displayedPanes.contains { $0.pane == active }
        if changed, !isHidden { relayout() } else { updateBreadcrumbs() }
        if paneFocused && active != previous { focusActive(force: true) }
        else if !known { focusActive(force: false) }
    }

    func present() -> Int {
        let created = !hot
        relayout()
        sizeClient(immediately: true)
        return created ? retainedPanes.count : 0
    }

    func evict() {
        endDrag()
        retainedPaneViews.values.forEach { $0.view.dispose() }
        retainedPaneViews = [:]
        toolbar?.removeFromSuperview()
        toolbar = nil
        dividers = []
        backings = [:]
        freeFrames = [:]
        liveFrame = nil
        placed = nil
        needsReconcile = true
        subviews = []
        displayedPaneIDs = [:]
    }

    func focus(_ pane: PaneID) {
        active = pane
        updateFocusTreatment()
        focusActive(force: false)
    }

    var activePane: PaneView? { displayedPanes.first { $0.pane == active } }

    func focusActive(force: Bool) {
        guard !isHidden, let view = activePane, let window else { return }
        let focused = window.firstResponder
        guard force || focused === window || focused == nil || PaneView.owner(focused)?.isDescendant(of: session ?? self) == true
        else { return }
        window.makeFirstResponder(view.inputResponder)
    }

    func close() {
        evict()
        removeFromSuperview()
    }

    private func relayout() {
        guard let shown else { return }
        guard !isHidden else { return }
        if !needsReconcile { place(); return }
        let layoutPanes = shown.layout.root.panes
        let existing = retainedPaneViews.mapValues(\.view)
        var views: [PaneID: PaneView] = [:]
        for pane in layoutPanes {
            let actual = shownPanes[pane.id]?.shown.position.pane ?? pane.id
            views[pane.id] = existing[actual] ?? makePane(actual)
        }
        let actual = Set(views.values.lazy.map(\.pane))
        let removed = existing.values.filter { !actual.contains($0.pane) }
        if !removed.isEmpty { toolbar?.removeFromSuperview(); toolbar = nil }
        for gone in removed {
            gone.isHidden = true
            gone.scroller.removeFromSuperview()
            retainedPaneViews[gone.pane]?.chrome.isHidden = true
        }
        let cell = session?.cell ?? views.values.lazy.map(\.cell).first { $0.width > 0 && $0.height > 0 } ?? .zero
        guard cell.width > 0, cell.height > 0 else { return }
        let placement = PaneLayout(root: shown.visible.root, bounds: bounds, cell: cell, pixel: pixel)
        validateFrames(placement)
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        if let client = session?.client {
            for view in views.values where existing[view.pane] == nil { view.attach(client) }
        }
        var tiled: [NSView] = [], floating: [(z: Int, views: [NSView])] = []
        backings = [:]
        var nextDisplayedPaneIDs: [PaneID: PaneID] = [:]
        for pane in layoutPanes {
            guard let view = views[pane.id] else { continue }
            let g = (seen[pane.id] ?? pane).geometry
            view.isHidden = seen[pane.id] == nil
            let chrome = retainedPaneViews[view.pane].flatMap { $0.chrome.pane == pane.id ? $0.chrome : nil }
                ?? PaneChrome(pane: pane.id, runtime: runtime)
            let slot = RetainedPane(view: view, chrome: chrome)
            nextDisplayedPaneIDs[pane.id] = view.pane
            retainedPaneViews[view.pane] = slot
            chrome.select = view.onSelect
            chrome.hover = { [weak self] chrome, point in self?.hover(chrome, point) }
            let isFloating = (seen[pane.id] ?? pane).layer != .tiled
            chrome.wantsLayer = true
            chrome.layer?.cornerRadius = isFloating ? floatingRadius : 0
            chrome.layer?.masksToBounds = isFloating
            place(chrome, view, g, placement, floating: isFloating)
            chrome.isHidden = view.isHidden
            view.transparentPaper = !isFloating
            switch (seen[pane.id] ?? pane).layer {
            case .tiled:
                let backing = box(chrome.frame, border: 0, fill: view.paperColor)
                backing.isHidden = view.isHidden
                backings[pane.id] = backing
                tiled += [backing, view, chrome]
            case .floating(let z):
                if view.isHidden { floating.append((z, [view, chrome])) }
                else {
                    let backing = box(chrome.frame, border: pixel, fill: runtime.background)
                    backing.wantsLayer = true
                    backing.cornerRadius = floatingRadius
                    backing.borderColor = Chrome.hairline
                    let shadow = NSShadow()
                    shadow.shadowColor = Chrome.floatShadow.color
                    shadow.shadowBlurRadius = Chrome.floatShadow.blur
                    shadow.shadowOffset = NSSize(width: 0, height: -3)
                    backing.shadow = shadow
                    backings[pane.id] = backing
                    floating.append((z, [backing, view, chrome]))
                }
            }
        }
        dividers = (shown.visible.root.dividers.map { drawnLine($0, placement, root: shown.visible.root) } + [placement.topLine]).map {
            box($0, border: 0, fill: runtime.separator)
        }
        preview.frame = bounds
        preview.autoresizingMask = [.width, .height]
        let hidden = retainedPaneViews.values.filter { !actual.contains($0.view.pane) }.flatMap { [$0.view, $0.chrome] as [NSView] }
        subviews = hidden + dividers + tiled + floating.sorted { $0.z < $1.z }.flatMap(\.views) + [preview]
        displayedPaneIDs = nextDisplayedPaneIDs
        for view in views.values where existing[view.pane] == nil {
            view.updateWebview(session?.webview(view.pane))
        }
        updateBreadcrumbs()
        updateFocusTreatment()
        session?.updateWebview()
        invalidateCursorRects()
        needsReconcile = false
        sizeClient()
        #if KIDO_VISUAL
        session?.visualReconciled(self)
        #endif
    }

    private func updateBreadcrumbs() {
        for (root, slot) in displayedSlots {
            let shown = shownPanes[root]
            slot.view.breadcrumbPath = shown.flatMap { $0.ancestors.isEmpty ? nil : $0.ancestors + [$0.shown] } ?? []
        }
    }

    private func place() {
        guard !isHidden, let shown, let placement else { return }
        validateFrames(placement)
        #if KIDO_STRESS
        stressEvent("place-window", "")
        #endif
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        var changed = false
        for (id, entry) in displayedSlots where !entry.chrome.isHidden {
            guard let pane = seen[id] else { continue }
            let view = entry.view, chrome = entry.chrome
            let previous = chrome.frame
            place(chrome, view, pane.geometry, placement, floating: pane.layer != .tiled)
            changed = changed || previous != chrome.frame
        }
        for (box, frame) in zip(dividers, shown.visible.root.dividers.map { drawnLine($0, placement, root: shown.visible.root) } + [placement.topLine]) {
            if box.frame != frame { box.frame = frame; changed = true }
        }
        updateFocusTreatment()
        if changed { invalidateCursorRects() }
        sizeClient()
    }

    private func placeFloat(_ id: PaneID, _ placement: PaneLayout) {
        guard let pane = shown?.visible.root.panes.first(where: { $0.id == id && $0.layer != .tiled }),
              let entry = displayed(id),
              entry.chrome.frame != floatFrame(id, pane.geometry, placement) else { return }
        place(entry.chrome, entry.view, pane.geometry, placement, floating: true)
        invalidateCursorRects()
        #if KIDO_STRESS
        stressEvent("place-float", id.description)
        #endif
    }

    private func drawnLine(_ divider: Divider, _ placement: PaneLayout, root: PaneGeometry.Node) -> CGRect {
        let geometry: Geometry = switch root {
        case .pane(let pane): pane.geometry
        case .split(_, let geometry, _): geometry
        }
        let g = divider.geometry
        var line = placement.line(divider, pixel: pixel)
        if divider.direction == .leftRight {
            if g.y + g.height == geometry.y + geometry.height { line.size.height = bounds.maxY - line.minY }
        } else {
            let right = g.x + g.width == geometry.x + geometry.width ? bounds.maxX : line.maxX
            if g.x == geometry.x { line.origin.x = bounds.minX }
            line.size.width = right - line.minX
        }
        return line
    }

    func updateFocusTreatment(forcePaper: Bool = false) {
        let active = activeSlot
        let entries = displayedSlots.values
        let multiple = entries.filter { !$0.chrome.isHidden && $0.view.transparentPaper }.count > 1
        let notKey = (window as? OwnerWindow)?.isInputWindow == false
        let unfocused = notKey || (session?.sidebarFocused() ?? false)
        for entry in entries {
            let pane = entry.view, chrome = entry.chrome
            pane.syncFocus()
            let tiled = pane.transparentPaper
            let shifted = tiled && (notKey || multiple && (unfocused || chrome.pane != active))
            chrome.treatment = tiled
                ? (multiple && !unfocused && chrome.pane == active ? .edge : .plain)
                : (chrome.pane == active && !notKey ? .plain : .overlay)
            let focused = tiled ? !shifted : chrome.pane == active && !notKey
            chrome.runtimeFocused = focused
            pane.runtimeFocused = focused
            let changed = shifted != pane.shiftedBackground
            if changed { pane.shiftedBackground = shifted }
            else if forcePaper { pane.updatePaper() }
            if changed || forcePaper { backings[chrome.pane]?.fillColor = pane.paperColor }
        }
    }

    // A pane that gains or loses its mark gains or loses the stripe's band, which places the window again. A
    // change of colour, state or name only redraws the pane's stripe and pill.
    func marksChanged(_ changed: Set<PaneID>, banded: Bool) {
        if banded { return isHidden ? () : place() }
        for slot in displayedSlots.values where changed.contains(slot.view.pane) {
            let mark = session?.marks[slot.view.pane]
            slot.chrome.runtimeMark = mark
            slot.view.runtimeMark = mark
        }
    }

    private func place(_ chrome: PaneChrome, _ view: PaneView, _ g: Geometry, _ placement: PaneLayout, floating: Bool) {
        let mark = session?.marks[view.pane]
        view.runtimeMark = mark
        chrome.runtimeMark = mark
        let frame: CGRect, grid: CGRect, content: CGRect, insets: PaneLayout.RenderInsets
        if floating {
            frame = floatFrame(chrome.pane, g, placement)
            grid = CGRect(origin: CGPoint(x: frame.minX + placement.before.width, y: frame.minY + placement.before.height),
                          size: placement.grid(g).size)
            content = grid
            insets = .init()
        } else {
            let tiled = placement.tiled(g, alternate: view.alternate, band: mark == nil ? 0 : PaneChrome.stripeBand)
            (frame, grid, content, insets) = (tiled.chrome, tiled.grid, tiled.content, tiled.insets)
        }
        if chrome.frame != frame { chrome.frame = frame; view.needsLayout = true }
        if backings[chrome.pane]?.frame != frame { backings[chrome.pane]?.frame = frame }
        for overlay in view.chromeViews where overlay.superview !== chrome { chrome.addSubview(overlay); view.needsLayout = true }
        if toolbar?.superview === chrome, toolbar?.frame != chrome.toolbarFrame { toolbar?.frame = chrome.toolbarFrame }
        view.renderInsets = insets
        if view.frame != content { view.frame = content }
        chrome.content = content.offsetBy(dx: -frame.minX, dy: -frame.minY)
        chrome.drag = floating && !zoomed ? { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0) } : nil
        if floating || content.minY < placement.topLine.maxY {
            let mask = view.layer?.mask as? CAShapeLayer ?? CAShapeLayer()
            let rect = floating
                ? chrome.bounds.offsetBy(dx: chrome.frame.minX - grid.minX, dy: grid.maxY - chrome.frame.maxY)
                : CGRect(x: 0, y: 0, width: content.width, height: max(0, content.maxY - placement.topLine.maxY))
            if !floating || mask.path?.boundingBoxOfPath != rect {
                mask.path = floating
                    ? CGPath(roundedRect: rect, cornerWidth: floatingRadius, cornerHeight: floatingRadius, transform: nil)
                    : CGPath(rect: rect, transform: nil)
            }
            if view.layer?.mask !== mask { view.layer?.mask = mask }
        } else if view.layer?.mask != nil { view.layer?.mask = nil }
        if view.scroller.superview !== chrome { chrome.addSubview(view.scroller, positioned: .below, relativeTo: nil) }
        view.scroller.select = view.onSelect
        let scrollerFrame = CGRect(x: max(0, chrome.bounds.maxX - 12),
                                   y: chrome.content.minY, width: 12, height: chrome.content.height)
        if view.scroller.frame != scrollerFrame { view.scroller.frame = scrollerFrame }
    }

    private func hover(_ chrome: PaneChrome, _ point: NSPoint?) {
        guard !isHidden else { return }
        let show = point.map { chrome.hotZone.contains($0) } ?? false
        let entry = displayed(chrome.pane)
        for view in displayedPanes { view.toolbarShown = show && view === entry?.view }
        if show, let view = entry?.view {
            let toolbar = self.toolbar ?? PaneToolbar(runtime: runtime)
            self.toolbar = toolbar
            if toolbar.superview !== chrome {
                let find = chrome.subviews.first { $0 is PaneFind }
                chrome.addSubview(toolbar, positioned: find == nil ? .above : .below, relativeTo: find)
            }
            toolbar.frame = chrome.toolbarFrame
            toolbar.update(command: { view.onSelect(); view.onCommand($0) }, zoomed: zoomed, drag: { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0) })
        }
        guard let toolbar, toolbar.superview === chrome else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.toolbarFadeDuration
            #if KIDO_VISUAL
            context.completionHandler = { MainActor.assumeIsolated { toolbar.visualAnimationsEnded += 1 } }
            #endif
            toolbar.animator().alphaValue = show ? 1 : 0
        }
        invalidateCursorRects()
    }

    private var pixel: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    private var placement: PaneLayout? {
        guard let shown, let cell = session?.cell else { return nil }
        return PaneLayout(root: shown.visible.root, bounds: bounds, cell: cell, pixel: pixel)
    }

    func cellChanged() {
        guard hot, !isHidden else { return }
        place()
        sizeClient()
    }

    private func makePane(_ id: PaneID) -> PaneView? {
        guard let view = PaneView(runtime: runtime, pane: id, font: session?.font ?? 0, host: session?.host ?? .local) else { return nil }
        view.onURL = { [weak self] in self?.session?.onURL($0) }
        view.canPrompt = { [weak self] in self?.session?.canPrompt() == true }
        view.onPrompt = { [weak self] pane, quote in self?.session?.onPrompt(pane, quote) }
        view.onSelect = { [weak self] in
            guard let self else { return }
            session?.selectPane(id)
            let slot = shownPanes.first { $0.value.shown.position.pane == id }?.key ?? id
            let floats = shown?.visible.root.panes.filter { $0.layer != .tiled } ?? []
            if case .floating(let z) = floats.first(where: { $0.id == slot })?.layer, z < floats.count - 1 {
                session?.edit(.float(KoSchema.EditFloat(pane: slot, z: floats.count)), nil)
            }
        }
        view.onCommand = { [weak self] command in self?.session?.paneCommand(command, id) }
        view.onShowAncestor = { [weak self] in self?.session?.selectPane($0.pane) }
        view.onAlternateChange = { [weak self] in self?.place() }
        view.onFindChange = { [weak self] in self?.place(); self?.invalidateCursorRects() }
        view.onCellChange = { [weak self] in self?.session?.cellChanged() }
        view.onFontChange = { [weak self] in self?.session?.fontChanged($0) }
        return view
    }

    private func box(_ frame: CGRect, border: CGFloat, fill: NSColor) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = border
        box.fillColor = fill
        return box
    }

    private var zoomed: Bool { shown?.visible.root.panes.count == 1 && (shown?.layout.root.panes.count ?? 0) > 1 }

    private enum Edge { case left, right, top, bottom }
    private enum DropZone {
        case centre(PaneID)
        case pane(PaneID, Edge)
        case window(PaneID, Edge)
    }
    private enum PaneDrag {
        case tiled(PaneID, NSPoint)
        case floating(Pane, NSPoint, CGRect, NSCursor.FrameResizePosition?)
    }
    private var paneDrag: PaneDrag?
    private var claimed: Reorder?
    private var dragWindow: NSWindow?
    #if KIDO_STRESS
    var stressEvent: (String, String) -> Void = { _, _ in }
    var stressFloats: [(pane: Pane, frame: CGRect, free: Bool)] {
        guard let placement else { return [] }
        return (shown?.visible.root.panes ?? []).filter { $0.layer != .tiled }.map {
            ($0, floatFrame($0.id, $0.geometry, placement), freeFrames[$0.id] != nil)
        }
    }
    #endif
    private var lastFloatEdit: KoSchema.Edit?

    private func floatFrame(_ id: PaneID, _ geometry: Geometry, _ placement: PaneLayout) -> CGRect {
        if let liveFrame {
            switch liveFrame {
            case .dragging(let pane, let frame), .held(let pane, let frame):
                if pane == id { return placement.clamp(frame) }
            }
        }
        if let frame = freeFrames[id], placement.geometry(frame) == geometry { return frame }
        freeFrames[id] = nil
        return placement.clamp(placement.frame(geometry))
    }

    private func validateFrames(_ placement: PaneLayout) {
        if let placed, placed != placement {
            liveFrame = nil
            endDrag()
        }
        placed = placement
        let floats = Dictionary(uniqueKeysWithValues: (shown?.visible.root.panes ?? [])
            .filter { $0.layer != .tiled }.map { ($0.id, $0.geometry) })
        freeFrames = freeFrames.filter { id, frame in
            let keep = !zoomed && floats[id] == placement.geometry(frame)
            #if KIDO_STRESS
            stressEvent(keep ? "free-frame-kept" : "free-frame-dropped", id.description)
            #endif
            return keep
        }
    }

    // The layout shows every edit that was sent: a held float frame becomes the free frame of the
    // float if the server kept its geometry.
    func editsSettled() {
        defer { if !defersRestore { displayedPanes.forEach { $0.endResizeIntent() } } }
        guard case .held(let id, let frame) = liveFrame else { return }
        liveFrame = nil
        if !zoomed, let placement, let pane = shown?.visible.root.panes.first(where: { $0.id == id && $0.layer != .tiled }),
           placement.geometry(frame) == pane.geometry {
            freeFrames[id] = frame
            #if KIDO_STRESS
            stressEvent("free-frame-kept", id.description)
            #endif
        }
        if let placement { placeFloat(id, placement) }
    }

    private func floatEdge(_ point: NSPoint) -> (Pane, NSCursor.FrameResizePosition)? {
        guard !zoomed, let placement else { return nil }
        for pane in (shown?.visible.root.panes ?? []).filter({ $0.layer != .tiled }).sorted(by: {
            guard case .floating(let a) = $0.layer, case .floating(let b) = $1.layer else { return false }; return a > b
        }) {
            let frame = floatFrame(pane.id, pane.geometry, placement)
            guard frame.contains(point) else { continue }
            return floatEdges(frame).first { $0.1.contains(point) }.map { (pane, $0.0) }
        }
        return nil
    }

    private func floatEdges(_ r: CGRect) -> [(NSCursor.FrameResizePosition, CGRect)] {
        [
            (.topLeft, CGRect(x: r.minX, y: r.minY, width: 5, height: 5)),
            (.bottomLeft, CGRect(x: r.minX, y: r.maxY - 5, width: 5, height: 5)),
            (.topRight, CGRect(x: r.maxX - 5, y: r.minY, width: 5, height: 5)),
            (.bottomRight, CGRect(x: r.maxX - 5, y: r.maxY - 5, width: 5, height: 5)),
            (.left, CGRect(x: r.minX, y: r.minY + 5, width: 5, height: max(0, r.height - 10))),
            (.right, CGRect(x: r.maxX - 5, y: r.minY + 5, width: 5, height: max(0, r.height - 10))),
            (.top, CGRect(x: r.minX + 5, y: r.minY, width: max(0, r.width - 10), height: 5)),
            (.bottom, CGRect(x: r.minX + 5, y: r.maxY - 5, width: max(0, r.width - 10), height: 5)),
        ]
    }

    private func sendFloat(_ edit: KoSchema.Edit, _ pane: PaneID) {
        guard edit != lastFloatEdit else { return }
        lastFloatEdit = edit
        session?.edit(edit, .float(pane))
    }

    private func beginDrag(_ pane: PaneID, _ event: NSEvent) {
        if event.type == .keyDown {
            cancelDrag(); return
        }
        if event.type != .leftMouseDown { updateDrag(event); return }
        guard !zoomed, let pane = shown?.visible.root.panes.first(where: { $0.id == pane }) else { return }
        endDrag()
        guard claimPaneDrag() else { return }
        if pane.layer != .tiled { displayed(pane.id)?.view.onSelect() }
        #if KIDO_STRESS
        stressEvent("drag-started", pane.id.description)
        #endif
        switch pane.layer {
        case .tiled: paneDrag = .tiled(pane.id, event.locationInWindow)
        case .floating:
            guard let placement else { return endDrag() }
            paneDrag = .floating(pane, event.locationInWindow, floatFrame(pane.id, pane.geometry, placement), nil)
        }
    }

    @objc func cancelDrag() {
        guard paneDrag != nil || drag != nil else { return }
        liveFrame = nil
        place(); endDrag(); focusActive(force: true)
    }

    func invalidateCursorRects() {
        if paneDrag == nil { window?.invalidateCursorRects(for: self) }
    }

    private func claimPaneDrag() -> Bool {
        guard let reorder = session?.reorder, reorder.claim(.pane) else { return false }
        claimed = reorder
        return true
    }

    private func endDrag() {
        claimed?.release(.pane)
        claimed = nil
        guard paneDrag != nil || drag != nil else { return }
        let target = dragWindow ?? window
        if let dragWindow {
            if !background { NSCursor.pop() }
            dragWindow.enableCursorRects()
            self.dragWindow = nil
        }
        if case .dragging = liveFrame { liveFrame = nil }
        paneDrag = nil
        finishDividerDrag()
        lastFloatEdit = nil
        preview.rect = nil
        target?.invalidateCursorRects(for: self)
        if !defersRestore { displayedPanes.forEach { $0.endResizeIntent() } }
    }

    private func updateDrag(_ event: NSEvent) {
        guard let paneDrag else { return }
        if case .floating(let pane, let origin, let initial, let cursorEdge) = paneDrag {
            let edge = cursorEdge?.layoutEdge
            guard let cell = session?.cell, let placement else { return }
            let dx = event.locationInWindow.x - origin.x
            let dy = origin.y - event.locationInWindow.y
            if edge == nil, lastFloatEdit == nil, hypot(dx, dy) < 4 {
                if event.type == .leftMouseUp { endDrag(); focusActive(force: true) }
                return
            }
            if dragWindow == nil, let window {
                let cursor = cursorEdge.map { NSCursor.frameResize(position: $0, directions: .all) } ?? .closedHand
                window.disableCursorRects()
                if !background { cursor.push() }
                dragWindow = window
            }
            var frame = initial
            if edge == nil { frame.origin.x += dx; frame.origin.y += dy }
            else {
                let minimum = CGSize(width: 2 * cell.width + placement.before.width + placement.after.width,
                                     height: 2 * cell.height + placement.before.height + placement.after.height)
                if edge?.right == true { frame.size.width = max(minimum.width, initial.width + dx) }
                if edge?.bottom == true { frame.size.height = max(minimum.height, initial.height + dy) }
                if edge?.left == true { frame.size.width = max(minimum.width, initial.width - dx); frame.origin.x = initial.maxX - frame.width }
                if edge?.top == true { frame.size.height = max(minimum.height, initial.height - dy); frame.origin.y = initial.maxY - frame.height }
            }
            frame = placement.clamp(frame, resizing: edge)
            liveFrame = .dragging(pane.id, frame)
            placeFloat(pane.id, placement)
            let geometry = placement.geometry(frame)
            if dx != 0 || dy != 0 || lastFloatEdit != nil {
                let moves = edge == nil || edge?.left == true || edge?.top == true
                sendFloat(.float(KoSchema.EditFloat(
                    cols: edge == nil ? nil : geometry.width, pane: pane.id, rows: edge == nil ? nil : geometry.height,
                    x: moves ? max(0, geometry.x) : nil, y: moves ? max(0, geometry.y) : nil)), pane.id)
            }
            if event.type == .leftMouseUp {
                let sent = lastFloatEdit != nil
                liveFrame = sent ? .held(pane.id, frame) : nil
                endDrag()
                if sent, session?.editing() != true { editsSettled() }
                focusActive(force: true)
            }
            return
        }
        guard case .tiled(let source, let origin) = paneDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let moved = hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4
        var drop: (zone: DropZone, rect: CGRect)?
        if moved {
            let tiled = shown?.visible.root.panes.filter { $0.layer == .tiled } ?? []
            let hit = (shown?.visible.root.panes ?? []).sorted {
                switch ($0.layer, $1.layer) { case (.floating(let a), .floating(let b)): a > b; case (.floating, .tiled): true; default: false }
            }.lazy.compactMap { self.displayed($0.id)?.chrome }.first { !$0.isHidden && $0.frame.contains(point) }
            if tiled.count > 1, let placement,
               hit == nil || tiled.contains(where: { $0.id == hit?.pane }) {
                let area = tiled.reduce(CGRect.null) { area, pane in
                    area.union(placement.tiled(pane.geometry, alternate: displayed(pane.id)?.view.alternate ?? false).chrome)
                }
                let outer = CGRect(x: bounds.minX, y: area.minY, width: bounds.width, height: bounds.maxY - area.minY)
                let edge: Edge? = !outer.contains(point) ? nil
                    : point.x < area.minX + 22 ? .left : point.x > area.maxX - 22 ? .right
                    : point.y < area.minY + 22 ? .top : point.y > area.maxY - 22 ? .bottom : nil
                if let edge, let target = tiled.first(where: { $0.id != source }) {
                    drop = (.window(target.id, edge), area)
                } else if let hit, hit.pane != source {
                    let p = hit.convert(point, from: self), b = hit.bounds
                    let x = p.x / b.width, y = p.y / b.height
                    let edge: Edge? = x < 0.25 ? .left : x > 0.75 ? .right : y < 0.25 ? .top : y > 0.75 ? .bottom : nil
                    drop = (edge.map { .pane(hit.pane, $0) } ?? .centre(hit.pane), hit.frame)
                }
                if let (zone, rect) = drop {
                    let edge: Edge? = switch zone {
                    case .centre: nil
                    case .pane(_, let edge), .window(_, let edge): edge
                    }
                    let width: CGFloat, height: CGFloat
                    switch zone {
                    case .pane: width = 4; height = 4
                    default: width = rect.width / 2; height = rect.height / 2
                    }
                    let result: CGRect = switch edge {
                    case .left: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
                    case .right: CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)
                    case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
                    case .bottom: CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
                    case nil: rect
                    }
                    drop = (zone, result)
                }
            }
        }
        if event.type != .leftMouseUp {
            preview.rect = drop?.rect
            return
        }
        endDrag()
        focusActive(force: true)
        guard let (zone, _) = drop, let windowID else { return }
        func edge(_ edge: Edge) -> KoSchema.Edge {
            switch edge { case .left: .left; case .right: .right; case .top: .top; case .bottom: .bottom }
        }
        let edit: KoSchema.Edit = switch zone {
        case .centre(let target): .swap(KoSchema.EditSwap(other: target, pane: source))
        case .pane(let target, let side): .dock(KoSchema.EditDock(edge: edge(side), pane: source, target: target))
        case .window(_, let side): .dockWindow(KoSchema.EditDockWindow(edge: edge(side), pane: source, window: windowID))
        }
        #if KIDO_STRESS
        stressEvent("drag-completed", "\(edit)")
        #endif
        session?.edit(edit, nil)
    }

    private var drag: (divider: Divider, origin: NSPoint, position: Int)?

    private func hitArea(_ divider: Divider, _ placement: PaneLayout) -> CGRect {
        let line = placement.line(divider, pixel: pixel)
        return divider.direction == .leftRight ? line.insetBy(dx: -(6 - pixel) / 2, dy: 0) : line.insetBy(dx: 0, dy: -(6 - pixel) / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        if floatEdge(local) != nil { return self }
        if let placement, shown?.visible.root.panes.contains(where: { $0.layer != .tiled && floatFrame($0.id, $0.geometry, placement).contains(local) }) == true {
            return super.hitTest(point)
        }
        if let placement, shown?.visible.root.dividers.contains(where: { hitArea($0, placement).contains(local) }) == true { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (pane, edge) = floatEdge(point) {
            endDrag()
            guard let placement, claimPaneDrag() else { return }
            paneDrag = .floating(pane, event.locationInWindow, floatFrame(pane.id, pane.geometry, placement), edge)
            displayed(pane.id)?.view.beginResizeIntent()
            #if KIDO_STRESS
            stressEvent("edge-resize-started", pane.id.description)
            #endif
            displayed(pane.id)?.view.onSelect()
            window?.makeFirstResponder(self)
            return
        }
        guard let placement else { return }
        drag = shown?.visible.root.dividers.first { hitArea($0, placement).contains(point) }
            .map { ($0, point, $0.direction == .leftRight ? $0.geometry.x : $0.geometry.y) }
        if drag != nil { displayedPanes.forEach { $0.beginResizeIntent() } }
    }

    override func mouseDragged(with event: NSEvent) {
        if paneDrag != nil { updateDrag(event); return }
        guard let drag, let cell = session?.cell else { return }
        let point = convert(event.locationInWindow, from: nil)
        let position = drag.divider.direction == .leftRight
            ? drag.divider.geometry.x + Int(((point.x - drag.origin.x) / cell.width).rounded())
            : drag.divider.geometry.y + Int(((point.y - drag.origin.y) / cell.height).rounded())
        guard position != drag.position, let edit = drag.divider.resize(to: position) else { return }
        self.drag = (drag.divider, drag.origin, position)
        session?.edit(edit, .divider(drag.divider.first))
    }

    override func mouseUp(with event: NSEvent) {
        if paneDrag != nil { updateDrag(event) }
        finishDividerDrag()
    }

    private func finishDividerDrag() {
        guard drag != nil else { return }
        drag = nil
        if !defersRestore { displayedPanes.forEach { $0.endResizeIntent() } }
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, paneDrag != nil {
            cancelDrag()
        }
        else { super.keyDown(with: event) }
    }

    override func resetCursorRects() {
        for (rect, cursor) in paneCursorRects { addCursorRect(rect, cursor: cursor) }
    }

    var paneCursorRects: [(CGRect, NSCursor)] {
        guard let placement else { return [] }
        var result: [(CGRect, NSCursor)] = []
        var covered: [CGRect] = [placement.topLine]
        func add(_ rect: CGRect, _ cursor: NSCursor) {
            result += rect.intersection(bounds).subtracting(covered).map { ($0, cursor) }
        }
        func terminal(_ id: PaneID, excluding edges: [CGRect] = []) {
            guard let entry = displayed(id), !entry.view.isHidden else { return }
            let view = entry.view
            let cuts = edges + entry.chrome.overlays.map { convert($0, from: entry.chrome) }
            for rect in view.terminalCursorRects {
                for rect in convert(rect, from: view).subtracting(cuts) { add(rect, view.mouseCursor) }
            }
        }
        if !zoomed {
            for pane in (shown?.visible.root.panes ?? []).filter({ $0.layer != .tiled }).sorted(by: {
                guard case .floating(let a) = $0.layer, case .floating(let b) = $1.layer else { return false }; return a > b
            }) {
                let r = floatFrame(pane.id, pane.geometry, placement)
                defer { covered.append(r) }
                if case .floating(let moving, _, _, nil) = paneDrag, moving.id == pane.id,
                   case .dragging = liveFrame {
                    add(r, .closedHand)
                    continue
                }
                if let chrome = displayed(pane.id)?.chrome {
                    for rect in chrome.padding { add(convert(rect, from: chrome), .openHand) }
                }
                let edges = floatEdges(r)
                for (position, rect) in edges {
                    add(rect, .frameResize(position: position, directions: .all))
                }
                terminal(pane.id, excluding: edges.map { $0.1 })
            }
        }
        let dividers = shown?.visible.root.dividers ?? []
        for d in dividers {
            add(hitArea(d, placement), d.direction == .leftRight ? .resizeLeftRight : .resizeUpDown)
        }
        covered += dividers.map { hitArea($0, placement) }
        for pane in shown?.visible.root.panes ?? [] where zoomed || pane.layer == .tiled {
            terminal(pane.id)
        }
        return result
    }

    func debugResize(_ reason: @autoclosure () -> String, pane: PaneID? = nil) {
        guard debugging else { return }
        let sizes = Dictionary(uniqueKeysWithValues: (shown?.visible.root.panes ?? []).map { ($0.id, $0.geometry) })
        for view in displayedPanes where !view.isHidden && (pane == nil || pane == view.pane) {
            let cells = sizes[view.pane].map { "\($0.width)x\($0.height)" } ?? "none"
            debug("resize t=\(ProcessInfo.processInfo.systemUptime) \(reason()) pane=\(view.pane) cells=\(cells) \(view.resizeDebug)")
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        displayedPanes.forEach { $0.beginResizeIntent() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        debugResize("live-end")
    }

    func sizeClient(immediately: Bool = false) {
        guard !isHidden, let placement else { return }
        session?.requestSize(cols: Int(placement.client.width), rows: Int(placement.client.height), immediately: immediately)
    }

    func sizeReport(viewport: KoSize) -> [KoWindowSize] {
        guard let windowID, let shown else { return [] }
        var result = [KoWindowSize(window: windowID, size: viewport)]
        for pane in shown.visible.root.panes {
            guard let position = shownPanes[pane.id]?.shown.position, position.pane != pane.id, position.window != windowID else { continue }
            result.append(KoWindowSize(window: position.window, size: KoSize(cols: pane.geometry.width, rows: pane.geometry.height, cell: viewport.cell)))
        }
        return result.sorted { $0.window.number < $1.window.number }
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        guard !isHidden else { return }
        if hot { place() }
        sizeClient()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willCloseNotification, NSApplication.didResignActiveNotification] {
            center.removeObserver(self, name: name, object: nil)
        }
        guard let window else { return }
        center.addObserver(self, selector: #selector(didBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(cancelDrag), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(cancelDrag), name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    @objc private func didBecomeKey() {
        guard !isHidden, let window else { return }
        if let pane = PaneView.owner(window.firstResponder), pane.superview === self, !pane.isHiddenOrHasHiddenAncestor {
            if pane.pane != active { session?.selectPane(pane.pane) }
        } else if window.attachedSheet == nil, !(session?.sidebarFocused() ?? false) {
            focusActive(force: true)
        }
    }
}
