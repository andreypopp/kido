import AppKit
import GhosttyKit
import KoClientKit
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
    private enum PaneHost {
        case tiled
        case popping(frame: CGRect, sent: CellPoint)
        case floating(FloatWindow)
        case zoomedFloat(FloatWindow)
        var window: FloatWindow? {
            switch self {
            case .floating(let window), .zoomedFloat(let window): window
            case .tiled, .popping: nil
            }
        }
    }
    private struct RetainedPane {
        let view: PaneView
        let chrome: PaneChrome
        var host = PaneHost.tiled
    }
    private var displayedPaneIDs: [PaneID: PaneID] = [:]
    private var retainedPaneViews: [PaneID: RetainedPane] = [:]
    private var shownPanes: [PaneID: ShownPane] = [:]
    private var displayedSlots: [PaneID: RetainedPane] { displayedPaneIDs.compactMapValues { retainedPaneViews[$0] } }
    private func displayed(_ id: PaneID) -> RetainedPane? { displayedPaneIDs[id].flatMap { retainedPaneViews[$0] } }
    var retainedCount: Int { retainedPaneViews.count }
    var retainedPanes: [PaneView] { retainedPaneViews.values.map(\.view) }
    func contains(_ pane: PaneView) -> Bool { retainedPaneViews[pane.pane]?.view === pane }
    var hostWindows: [FloatWindow] { retainedPaneViews.values.compactMap(\.host.window) }
    private var floatWindows: [PaneID: FloatWindow] { displayedPaneIDs.compactMapValues { retainedPaneViews[$0]?.host.window } }
    var floatsInteractive: Bool { !zoomed }
    var cancelsDrag: Bool { paneDrag != nil }
    var inputWindow: NSWindow? { hostWindows.first { $0.isInputWindow } ?? window }

    func releaseUnusedPanes() {
        let shown = Set(displayedPaneIDs.values)
        for (id, slot) in retainedPaneViews where !shown.contains(id) && slot.view.webviewView == nil {
            slot.host.window?.detach()
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
    private let floatingRadius: CGFloat = 10
    private var toolbar: PaneToolbar?
    private let preview = PaneDropPreview()
    private let ghostView = PaneDropPreview()
    override var isHidden: Bool {
        didSet {
            if isHidden { endDrag(); toolbar?.removeFromSuperview(); toolbar = nil; raisedFor = nil } else { raiseActiveFloat() }
            syncHosts()
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
        var lines = ["bounds=\(rect(bounds)) separator=\(placement.map { rect($0.topLine) } ?? "-") banner=\(window?.contentView.map(bannerVisible) ?? false)"]
        for pane in displayedPanes.filter({ !$0.isHidden }).sorted(by: { $0.pane.number < $1.pane.number }) {
            let chrome = retainedPaneViews[pane.pane]?.chrome
            let geometry = shown?.visible.root.panes.first { $0.id == chrome?.pane }
            let grid = CGRect(x: pane.frame.minX, y: pane.frame.minY + pane.renderInsets.top,
                              width: pane.frame.width, height: pane.frame.height - pane.renderInsets.top - pane.renderInsets.bottom)
            let shift = floatWindows[pane.pane].map { CGPoint(x: $0.rect.minX - (chrome?.frame.minX ?? 0), y: $0.rect.minY - (chrome?.frame.minY ?? 0)) } ?? .zero
            func main(_ r: CGRect) -> CGRect { r.offsetBy(dx: shift.x, dy: shift.y) }
            lines.append("\(pane.pane) cells=\(geometry.map { String(describing: $0.geometry) } ?? "-") layer=\(geometry.map { String(describing: $0.layer) } ?? "-") grid=\(rect(main(grid))) content=\(rect(main(pane.frame))) chrome=\(chrome.map { rect(main($0.frame)) } ?? "-") \(pane.visualState)")
        }
        lines += dividers.map { "divider=\(rect($0.frame))" }.sorted()
        lines += floatWindows.filter { pair in !pair.value.content.isHidden && shown?.visible.root.panes.contains { $0.id == pair.key && $0.layer != .tiled } == true }
            .sorted { $0.key.number < $1.key.number }.map { "float \($0.key)=\(rect($0.value.rect))" }
        return lines.joined(separator: "\n")
    }
    var visualPaneDragging: Bool { paneDrag != nil }
    var visualPreview: PaneDropPreview { preview }
    func visualFloatRect(_ id: PaneID) -> CGRect? { floatWindows[id]?.rect }
    var visualGhostView: PaneDropPreview { ghostView }
    var visualFloatHosts: [FloatWindow] {
        (shown?.visible.root.panes ?? []).compactMap { pane -> (Int, FloatWindow)? in
            guard case .floating(let z, _) = pane.layer, let host = floatWindows[pane.id], !host.content.isHidden else { return nil }
            return (z, host)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
    var visualChromes: [PaneChrome] { retainedPaneViews.values.map(\.chrome) }
    var visualGhost: CGRect? { ghostRect }
    var visualGhostWindow: NSWindow? { ghostWindow }
    func visualBeginDrag(_ pane: PaneID, _ event: NSEvent, from handle: DragHandle) { beginDrag(pane, event, from: handle) }
    #endif

    var hot: Bool { !retainedPaneViews.isEmpty }

    var defersRestore: Bool {
        paneDrag != nil || drag != nil || floatWindows.values.contains { if case .awaitingMove = $0.position { true } else if case .awaitingDock = $0.position { true } else { false } } || session?.editing() == true || window?.inLiveResize == true
    }

    func updateBackground() {
        layer?.backgroundColor = runtime.background.cgColor
        hostWindows.forEach { $0.content.handles.foreground = runtime.foreground }
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
            case .tiled(let id, _, _): visible.root.panes.contains { $0.id == id && $0.layer == .tiled }
            case .floating(let pane, _, _, _, _): visible.root.panes.contains { $0.id == pane.id && $0.layer != .tiled }
            }
            if zoomed || !valid {
                #if KIDO_STRESS
                stressEvent("drag-layout-cancelled", zoomed ? "zoomed" : "source removed or changed layer")
                #endif
                cancelDrag()
            }
        }
        releaseMovedFloats()
        // Hiding the focused pane gives the focus to the next key view, so read it before the relayout.
        let paneFocused = PaneView.owner(inputWindow?.firstResponder).map { focused in displayedPanes.contains { $0 === focused } } == true
        let previous = active
        active = visible.root.panes.first { $0.active }.map { shownPanes[$0.id]?.shown.position.pane ?? $0.id } ?? active
        guard hot else { return }
        let known = displayedPanes.contains { $0.pane == active }
        if changed, !isHidden { relayout() } else { updateBreadcrumbs() }
        raiseActiveFloat()
        if paneFocused && active != previous { focusActive(force: true) }
        else if !known { focusActive(force: false) }
    }

    private var raisedFor: PaneID?

    private func raiseActiveFloat() {
        guard active != raisedFor else { return }
        raisedFor = active
        let floats = shown?.visible.root.panes.filter { $0.layer != .tiled } ?? []
        guard let slot = activeSlot, let float = floats.first(where: { $0.id == slot }) else { return }
        let top: Int
        switch float.layer {
        case .floating(_, .child(_, let z, let count)): top = z < count - 1 ? count : 0
        case .floating(let z, .window):
            let count = floats.filter { if case .floating(_, .window) = $0.layer { true } else { false } }.count
            top = z < count - 1 ? count : 0
        default: top = 0
        }
        if top > 0 { session?.edit(.float(KoSchema.EditFloat(pane: slot, z: top)), nil) }
    }

    func present() -> Int {
        let created = !hot
        relayout()
        sizeClient(immediately: true)
        return created ? retainedPanes.count : 0
    }

    func evict() {
        endDrag()
        ghostRect = nil
        hostWindows.forEach { $0.detach() }
        retainedPaneViews.values.forEach { $0.view.dispose() }
        retainedPaneViews = [:]
        toolbar?.removeFromSuperview()
        toolbar = nil
        dividers = []
        backings = [:]
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
        guard !isHidden, let view = activePane, let window, let input = inputWindow else { return }
        let focused = input.firstResponder
        guard force || focused === input || focused == nil || PaneView.owner(focused).map({ session?.contains($0) ?? contains($0) }) == true
        else { return }
        let target = view.window ?? window
        if target !== input, input.isKeyWindow { target.makeKey() }
        target.makeFirstResponder(view.inputResponder)
    }

    func close() {
        evict()
        removeFromSuperview()
    }

    private func relayout() {
        guard let shown, window != nil else { return }
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
            retainedPaneViews[gone.pane]?.host.window?.detach()
            retainedPaneViews[gone.pane]?.host = .tiled
        }
        let cell = session?.cell ?? views.values.lazy.map(\.cell).first { $0.width > 0 && $0.height > 0 } ?? .zero
        guard cell.width > 0, cell.height > 0 else { return }
        let placement = PaneLayout(root: shown.visible.root, bounds: bounds, cell: cell, pixel: pixel)
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        if let client = session?.client {
            for view in views.values where existing[view.pane] == nil { view.attach(client) }
        }
        var tiled: [NSView] = [], floating: [PaneID: [NSView]] = [:]
        backings = [:]
        var nextDisplayedPaneIDs: [PaneID: PaneID] = [:]
        for pane in layoutPanes {
            guard let view = views[pane.id] else { continue }
            let g = (seen[pane.id] ?? pane).geometry
            view.isHidden = seen[pane.id] == nil
            let chrome = retainedPaneViews[view.pane].flatMap { $0.chrome.pane == pane.id ? $0.chrome : nil }
                ?? PaneChrome(pane: pane.id, runtime: runtime)
            var host = retainedPaneViews[view.pane]?.host ?? .tiled
            let isFloating = (seen[pane.id] ?? pane).layer != .tiled
            if pane.layer != .tiled {
                let native = host.window ?? makeHost(pane.id, from: host)
                host = isFloating ? .floating(native) : .zoomedFloat(native)
            } else if let native = host.window {
                native.detach()
                host = .tiled
            }
            retainedPaneViews[view.pane] = RetainedPane(view: view, chrome: chrome, host: host)
            nextDisplayedPaneIDs[pane.id] = view.pane
            chrome.select = view.onSelect
            chrome.hover = { [weak self] chrome, point in self?.hover(chrome, point) }
            chrome.wantsLayer = true
            chrome.layer?.cornerRadius = isFloating ? floatingRadius : 0
            chrome.layer?.masksToBounds = isFloating
            place(chrome, view, g, placement, host: isFloating ? host.window : nil)
            chrome.isHidden = view.isHidden
            view.transparentPaper = !isFloating
            switch (seen[pane.id] ?? pane).layer {
            case .tiled:
                let backing = box(chrome.frame, border: 0, fill: view.paperColor)
                backing.isHidden = view.isHidden
                backings[pane.id] = backing
                tiled += [backing, view, chrome]
            case .floating:
                if view.isHidden { floating[pane.id] = [view, chrome] }
                else {
                    let backing = box(chrome.frame, border: pixel, fill: runtime.background)
                    backing.wantsLayer = true
                    backing.cornerRadius = floatingRadius
                    backing.borderColor = Chrome.hairline
                    let shadow = NSShadow()
                    shadow.shadowColor = Chrome.floatShadow.color
                    shadow.shadowBlurRadius = Chrome.floatShadow.blur
                    shadow.shadowOffset = NSSize(width: 0, height: Chrome.floatShadow.offset)
                    backing.shadow = shadow
                    backings[pane.id] = backing
                    floating[pane.id] = [backing, view, chrome]
                }
            }
        }
        dividers = (shown.visible.root.dividers.map { drawnLine($0, placement, root: shown.visible.root) } + [placement.topLine]).map {
            box($0, border: 0, fill: runtime.separator)
        }
        preview.frame = bounds
        preview.ghostRadius = floatingRadius
        preview.autoresizingMask = [.width, .height]
        let hidden = retainedPaneViews.values.filter { !actual.contains($0.view.pane) }.flatMap { [$0.view, $0.chrome] as [NSView] }
        subviews = hidden + dividers + tiled + [preview]
        displayedPaneIDs = nextDisplayedPaneIDs
        for (id, host) in floatWindows { host.content.subviews = floating[id] ?? [] }
        syncHosts()
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
        #if KIDO_STRESS
        stressEvent("place-window", "")
        #endif
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        var changed = false
        for (id, entry) in displayedSlots where !entry.chrome.isHidden {
            guard let pane = seen[id] else { continue }
            let view = entry.view, chrome = entry.chrome
            let host = pane.layer != .tiled ? entry.host.window : nil
            let previous = (chrome.frame, host?.rect)
            place(chrome, view, pane.geometry, placement, host: host)
            changed = changed || previous != (chrome.frame, host?.rect)
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
              let entry = displayed(id), let host = floatWindows[id],
              host.rect != floatFrame(id, pane.geometry, placement, host) else { return }
        place(entry.chrome, entry.view, pane.geometry, placement, host: host)
        host.invalidateCursorRects(for: host.content)
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
        let mainKey = (window as? OwnerWindow)?.isInputWindow != false
        let floatKey = floatWindows.values.contains { ($0.isInputWindow || !mainKey && $0.hostedSheet != nil) && !$0.content.isHidden }
        let unfocused = !mainKey || (session?.sidebarFocused() ?? false)
        for entry in entries {
            let pane = entry.view, chrome = entry.chrome
            pane.syncFocus()
            let tiled = pane.transparentPaper
            let hostKey = (pane.window as? OwnerWindow)?.isInputWindow != false
            let shifted = tiled && !floatKey && (!mainKey || multiple && (unfocused || chrome.pane != active))
            chrome.treatment = tiled
                ? (multiple && !unfocused && chrome.pane == active ? .edge : .plain)
                : (chrome.pane == active && hostKey ? .focus : .overlay)
            let focused = tiled ? !shifted && !floatKey : chrome.pane == active && hostKey
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

    private func place(_ chrome: PaneChrome, _ view: PaneView, _ g: Geometry, _ placement: PaneLayout, host: FloatWindow?) {
        let floating = host != nil
        let mark = session?.marks[view.pane]
        view.runtimeMark = mark
        chrome.runtimeMark = mark
        chrome.stripeTop = host != nil ? PaneLayout.floatTop : 0
        let frame: CGRect, grid: CGRect, content: CGRect, insets: PaneLayout.RenderInsets
        if floating {
            let rect = floatFrame(chrome.pane, g, placement, host)
            if let host { positionHost(host, rect) }
            frame = CGRect(x: FloatWindow.margin, y: FloatWindow.margin, width: rect.width, height: rect.height)
            grid = CGRect(origin: CGPoint(x: frame.minX + placement.before.width, y: frame.minY + PaneLayout.floatTop),
                          size: placement.grid(g).size)
            content = grid
            insets = .init()
        } else {
            let tiled = placement.tiled(g, alternate: view.alternate, band: mark == nil ? 0 : PaneChrome.stripeBand)
            (frame, grid, content, insets) = (tiled.chrome, tiled.grid, tiled.content, tiled.insets)
        }
        if chrome.frame != frame { chrome.frame = frame; view.needsLayout = true }
        if chrome.treatment == .edge { chrome.needsDisplay = true }
        if backings[chrome.pane]?.frame != frame { backings[chrome.pane]?.frame = frame }
        for overlay in view.chromeViews where overlay.superview !== chrome { chrome.addSubview(overlay); view.needsLayout = true }
        if toolbar?.superview === chrome, toolbar?.frame != chrome.toolbarFrame { toolbar?.frame = chrome.toolbarFrame }
        view.renderInsets = insets
        if view.frame != content { view.frame = content }
        chrome.content = content.offsetBy(dx: -frame.minX, dy: -frame.minY)
        if floating { host?.content.grid = grid }
        chrome.drag = floating && !zoomed ? { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0, from: .frame) } : nil
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
            toolbar.update(command: { view.onSelect(); view.onCommand($0) }, zoomed: zoomed, drag: { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0, from: .grip) })
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
            if id == active { raisedFor = nil; raiseActiveFloat() }
            session?.hostsOrdered()
        }
        view.cursorHost = self
        view.onCommand = { [weak self] command in self?.session?.paneCommand(command, id) }
        view.floatTitle = { [weak self] in self?.session?.floatTitle(id) }
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
    enum DragHandle { case grip, frame }
    private enum FloatGesture {
        case move, dock
        case resize(NSCursor.FrameResizePosition)
    }
    private enum PaneDrag {
        case tiled(PaneID, NSPoint, grip: CGFloat)
        case floating(Pane, NSPoint, CGRect, FloatGesture, resting: FloatWindow.Position)
    }
    private struct DragInput {
        var point: NSPoint
        var up: Bool
        var flags: NSEvent.ModifierFlags
    }
    private var paneDrag: PaneDrag?
    private var lastInput: DragInput?
    private var dragStarted = false
    private var flagsMonitor: Any?
    private var claimed: Reorder?
    private var dragWindow: NSWindow?
    private var dragSource: NSWindow?
    private var ghostWindow: NSWindow?
    private var ghostRect: CGRect? { didSet { if ghostRect != oldValue { updateGhostWindow() } } }
    #if KIDO_STRESS
    var stressEvent: (String, String) -> Void = { _, _ in }
    var stressFloats: [(pane: Pane, frame: CGRect, free: Bool)] {
        guard let placement else { return [] }
        return (shown?.visible.root.panes ?? []).filter { $0.layer != .tiled }.map {
            ($0, floatFrame($0.id, $0.geometry, placement, floatWindows[$0.id]), floatWindows[$0.id]?.position != .layout)
        }
    }
    #endif
    private var lastFloatEdit: KoSchema.Edit?
    private var stacked: [PaneID] = []

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    private func viewPoint(_ screen: NSPoint) -> NSPoint {
        window.map { convert($0.convertPoint(fromScreen: screen), from: nil) } ?? screen
    }

    private func screenRect(_ rect: CGRect) -> CGRect {
        window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    private func input(_ event: NSEvent) -> DragInput {
        DragInput(point: screenPoint(event), up: event.type == .leftMouseUp, flags: event.modifierFlags)
    }

    private func makeHost(_ id: PaneID, from state: PaneHost) -> FloatWindow {
        let host = FloatWindow(owner: window?.delegate)
        host.content.logical = self
        host.content.pane = id
        host.content.handles.foreground = runtime.foreground
        host.appearance = window?.appearance
        host.focusChanged = { [weak self] old, next in self?.session?.hostFocusChanged(old, next) }
        host.becameKey = { [weak self] in self?.floatBecameKey(id) }
        if case .popping(let frame, let sent) = state { host.position = .awaitingMove(frame: frame, sent: sent) }
        return host
    }

    private func floatBecameKey(_ id: PaneID) {
        guard let entry = displayed(id), let host = floatWindows[id] else { return }
        if PaneView.owner(host.firstResponder) == nil { host.makeFirstResponder(entry.view.inputResponder) }
        if entry.view.pane != active { session?.selectPane(entry.view.pane) }
        updateFocusTreatment()
    }

    func syncHosts() {
        let floats = (shown?.visible.root.panes ?? []).compactMap { pane -> (z: Int, id: PaneID)? in
            if case .floating(let z, _) = pane.layer { (z, pane.id) } else { nil }
        }.sorted { $0.z < $1.z }
        let wanted = Set(floats.map(\.id))
        let open = !isHidden && window?.isMiniaturized == false && session?.floatsAllowed() != false
        var changed = false
        for (id, host) in floatWindows {
            changed = host.present(open && wanted.contains(id) && displayed(id)?.view.isHidden == false, over: window) || changed
        }
        let order = floats.map(\.id)
        guard changed || order != stacked else { return }
        stacked = order
        for id in order { if let host = floatWindows[id], !host.content.isHidden { host.raise() } }
        session?.hostsOrdered()
    }

    private func positionHost(_ host: FloatWindow, _ rect: CGRect) {
        host.rect = rect
        host.content.chrome = CGRect(x: FloatWindow.margin, y: FloatWindow.margin, width: rect.width, height: rect.height)
        guard window != nil else { return }
        let frame = screenRect(rect).insetBy(dx: -FloatWindow.margin, dy: -FloatWindow.margin)
        if host.frame != frame { host.setFrame(frame, display: false) }
    }

    private func floatFrame(_ id: PaneID, _ geometry: Geometry, _ placement: PaneLayout, _ host: FloatWindow?) -> CGRect {
        let canonical = placement.clamp(placement.floatFrame(geometry), clip: clip(id))
        switch host?.position ?? .layout {
        case .layout: return canonical
        case .dragging(let frame, _), .awaitingMove(let frame, _), .awaitingDock(let frame): return frame
        case .local(let frame, _): return CGRect(origin: frame.origin, size: canonical.size)
        }
    }

    private func clip(_ id: PaneID) -> Geometry? {
        shown?.visible.root.panes.first { $0.id == id }?.layer.clip
    }

    private func layoutPane(_ id: PaneID) -> Pane? { shown?.layout.root.panes.first { $0.id == id } }

    private func wire(_ frame: CGRect, _ id: PaneID, _ placement: PaneLayout) -> (width: Int, height: Int, point: CellPoint) {
        let g = placement.floatGeometry(frame)
        let pane = layoutPane(id)
        guard let extent = pane?.layer.clip ?? shown?.layout.root.geometry else { return (g.width, g.height, CellPoint(x: max(0, g.x), y: max(0, g.y))) }
        let pad = pane?.border == true ? 1 : 0
        let width = min(g.width, max(1, extent.width - 2 * pad)), height = min(g.height, max(1, extent.height - 2 * pad))
        return (width, height, CellPoint(x: min(max(g.x - extent.x, pad), max(pad, extent.width - width - pad)),
                                         y: min(max(g.y - extent.y, pad), max(pad, extent.height - height - pad))))
    }

    private func layoutPoint(_ id: PaneID) -> CellPoint? {
        layoutPane(id).flatMap { $0.layer == .tiled ? nil : CellPoint(x: $0.geometry.x - ($0.layer.clip?.x ?? 0), y: $0.geometry.y - ($0.layer.clip?.y ?? 0)) }
    }

    private func releaseMovedFloats() {
        for (id, host) in floatWindows {
            if case .local(_, let sent) = host.position, layoutPoint(id) != sent { host.position = .layout }
        }
    }

    private func limit(_ frame: CGRect, _ edge: PaneLayout.ResizeEdge?, _ pane: Pane, _ placement: PaneLayout) -> CGRect {
        if let window, window.styleMask.contains(.fullScreen), let screen = window.screen {
            let area = convert(window.convertFromScreen(screen.frame), from: nil)
            var r = frame
            if let edge {
                if edge.left { let x = max(area.minX, r.minX); r.size.width = r.maxX - x; r.origin.x = x }
                if edge.right { r.size.width = min(r.maxX, area.maxX) - r.minX }
                if edge.top { let y = max(area.minY, r.minY); r.size.height = r.maxY - y; r.origin.y = y }
                if edge.bottom { r.size.height = min(r.maxY, area.maxY) - r.minY }
            } else {
                r.size.width = min(r.width, area.width)
                r.size.height = min(r.height, area.height)
                r.origin.x = min(max(area.minX, r.minX), area.maxX - r.width)
                r.origin.y = min(max(area.minY, r.minY), area.maxY - r.height)
            }
            return r
        }
        let area = pane.layer.clip.map { placement.frame($0) } ?? placement.floatingBounds
        var r = frame
        if r.width > area.width { if edge?.left == true { r.origin.x = r.maxX - area.width }; r.size.width = area.width }
        if r.height > area.height { if edge?.top == true { r.origin.y = r.maxY - area.height }; r.size.height = area.height }
        return r
    }

    func editsSettled() {
        defer { if !defersRestore { displayedPanes.forEach { $0.endResizeIntent() } } }
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        for (id, record) in retainedPaneViews { if case .popping = record.host { retainedPaneViews[id]?.host = .tiled } }
        for (id, host) in floatWindows {
            switch host.position {
            case .awaitingMove(let frame, let sent):
                host.position = layoutPoint(id) == sent && !fullScreen ? .local(frame: frame, sent: sent) : .layout
                #if KIDO_STRESS
                stressEvent(host.position == .layout ? "free-frame-dropped" : "free-frame-kept", id.description)
                #endif
            case .awaitingDock: host.position = .layout
            case .layout, .dragging, .local: break
            }
            if let placement { placeFloat(id, placement) }
        }
    }

    private func sendFloat(_ edit: KoSchema.Edit, _ pane: PaneID) {
        guard edit != lastFloatEdit else { return }
        lastFloatEdit = edit
        session?.edit(edit, .float(pane))
    }

    func beginDrag(_ pane: PaneID, _ event: NSEvent, from handle: DragHandle) {
        if event.type == .keyDown {
            cancelDrag(); return
        }
        if event.type != .leftMouseDown { updateDrag(input(event)); return }
        guard !zoomed, let pane = shown?.visible.root.panes.first(where: { $0.id == pane }) else { return }
        endDrag()
        guard claimPaneDrag() else { return }
        dragSource = event.window ?? window
        if pane.layer != .tiled { displayed(pane.id)?.view.onSelect() }
        #if KIDO_STRESS
        stressEvent("drag-started", pane.id.description)
        #endif
        switch pane.layer {
        case .tiled:
            let chrome = displayed(pane.id)?.chrome
            paneDrag = .tiled(pane.id, screenPoint(event), grip: (chrome?.toolbarFrame.minX ?? 0) + 16)
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                if let self, let last = lastInput { updateDrag(DragInput(point: last.point, up: false, flags: event.modifierFlags)) }
                return event
            }
        case .floating:
            guard let placement, let host = floatWindows[pane.id] else { return endDrag() }
            let frame = floatFrame(pane.id, pane.geometry, placement, host)
            paneDrag = .floating(pane, screenPoint(event), frame, handle == .grip ? .dock : .move, resting: host.position)
            host.position = .dragging(frame: frame, sent: nil)
        }
    }

    func beginEdgeResize(_ id: PaneID, _ edge: NSCursor.FrameResizePosition, _ event: NSEvent) {
        endDrag()
        guard let placement, let host = floatWindows[id], let pane = shown?.visible.root.panes.first(where: { $0.id == id }),
              claimPaneDrag() else { return }
        dragSource = event.window ?? window
        let frame = floatFrame(id, pane.geometry, placement, host)
        paneDrag = .floating(pane, screenPoint(event), frame, .resize(edge), resting: host.position)
        host.position = .dragging(frame: frame, sent: nil)
        displayed(id)?.view.beginResizeIntent()
        #if KIDO_STRESS
        stressEvent("edge-resize-started", id.description)
        #endif
        displayed(id)?.view.onSelect()
        dragSource?.makeFirstResponder(host.content)
    }

    func continueDrag(_ event: NSEvent) {
        if paneDrag != nil { updateDrag(input(event)) }
    }

    @objc func cancelDrag() {
        guard paneDrag != nil || drag != nil else { return }
        endDrag(); place(); focusActive(force: true)
    }

    func invalidateCursorRects() {
        if paneDrag == nil {
            window?.invalidateCursorRects(for: self)
            hostWindows.forEach { $0.invalidateCursorRects(for: $0.content) }
        }
    }

    func invalidateCursorRects(for pane: PaneView) {
        guard paneDrag == nil, let physical = pane.window else { return }
        if let host = physical as? FloatWindow { host.invalidateCursorRects(for: host.content) } else { physical.invalidateCursorRects(for: self) }
    }

    private func claimPaneDrag() -> Bool {
        guard let reorder = session?.reorder, reorder.claim(.pane) else { return false }
        claimed = reorder
        return true
    }

    private func updateGhostWindow() {
        guard let rect = ghostRect, let window else {
            ghostWindow.map { $0.parent?.removeChildWindow($0); $0.orderOut(nil); $0.contentView = nil; $0.close() }
            ghostWindow = nil
            return
        }
        let ghost = ghostWindow ?? GhostWindow(contentView: ghostView)
        ghostWindow = ghost
        ghost.setFrame(screenRect(rect), display: false)
        ghostView.ghostRadius = floatingRadius
        ghostView.ghost = CGRect(origin: .zero, size: rect.size)
        if window.isVisible {
            if ghost.parent !== window {
                window.addChildWindow(ghost, ordered: .above)
                ghost.orderFront(nil)
                session?.hostsOrdered()
            }
        }
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
        if case .floating(let pane, _, _, _, let resting)? = paneDrag, let host = floatWindows[pane.id], case .dragging(let frame, let sent) = host.position {
            var held = frame, point = sent
            if window?.styleMask.contains(.fullScreen) == true, let placement, sent != nil, let origin = layoutPane(pane.id)?.layer.clip ?? shown?.layout.root.geometry {
                let canonical = wire(frame, pane.id, placement)
                point = canonical.point
                held = placement.floatFrame(Geometry(x: canonical.point.x + origin.x, y: canonical.point.y + origin.y, width: canonical.width, height: canonical.height))
            }
            host.position = point.map { .awaitingMove(frame: held, sent: $0) } ?? resting
            if point != nil, let placement { placeFloat(pane.id, placement) }
        }
        let sentMove = floatWindows.values.contains { if case .awaitingMove = $0.position { true } else { false } }
        paneDrag = nil
        lastInput = nil
        dragSource = nil
        dragStarted = false
        flagsMonitor.map(NSEvent.removeMonitor)
        flagsMonitor = nil
        finishDividerDrag()
        lastFloatEdit = nil
        preview.rect = nil
        ghostRect = nil
        target?.invalidateCursorRects(for: self)
        invalidateCursorRects()
        if sentMove, session?.editing() != true { editsSettled() }
        if !defersRestore { displayedPanes.forEach { $0.endResizeIntent() } }
    }

    private func updateDrag(_ input: DragInput) {
        guard let paneDrag else { return }
        if case .floating(let pane, let origin, let initial, let gesture, _) = paneDrag {
            let cursorEdge: NSCursor.FrameResizePosition? = if case .resize(let position) = gesture { position } else { nil }
            let edge = cursorEdge?.layoutEdge
            guard let cell = session?.cell, let placement, let host = floatWindows[pane.id] else { return }
            let dx = input.point.x - origin.x
            let dy = origin.y - input.point.y
            if edge == nil, !dragStarted, hypot(dx, dy) < 4 {
                if input.up { endDrag(); focusActive(force: true) }
                return
            }
            dragStarted = true
            if dragWindow == nil, let source = dragSource ?? window {
                let cursor = cursorEdge.map { NSCursor.frameResize(position: $0, directions: .all) } ?? .closedHand
                source.disableCursorRects()
                if !background { cursor.push() }
                dragWindow = source
            }
            var frame = initial
            if edge == nil { frame.origin.x += dx; frame.origin.y += dy }
            else {
                let minimum = CGSize(width: 2 * cell.width + placement.before.width + placement.after.width,
                                     height: 2 * cell.height + PaneLayout.floatTop + placement.after.height)
                if edge?.right == true { frame.size.width = max(minimum.width, initial.width + dx) }
                if edge?.bottom == true { frame.size.height = max(minimum.height, initial.height + dy) }
                if edge?.left == true { frame.size.width = max(minimum.width, initial.width - dx); frame.origin.x = initial.maxX - frame.width }
                if edge?.top == true { frame.size.height = max(minimum.height, initial.height - dy); frame.origin.y = initial.maxY - frame.height }
            }
            frame = limit(frame, edge, pane, placement)
            var sent: CellPoint?
            if case .dragging(_, let before) = host.position { sent = before }
            let geometry = wire(frame, pane.id, placement)
            host.position = .dragging(frame: frame, sent: sent)
            placeFloat(pane.id, placement)
            var target: (zone: DropZone, rect: CGRect)? = if case .dock = gesture, windowID != nil, session?.floatTitle(pane.id) != nil { dropTarget(at: viewPoint(input.point), source: pane.id) } else { nil }
            if case .centre? = target?.zone { target = nil }
            preview.rect = target?.rect
            if let target, let windowID, input.up {
                host.position = .awaitingDock(frame: frame)
                let edit = dropEdit(target.zone, pane.id, windowID)
                #if KIDO_STRESS
                stressEvent("drag-completed", "\(edit)")
                #endif
                session?.edit(edit, nil)
                endDrag()
                focusActive(force: true)
                return
            }
            if target == nil, dx != 0 || dy != 0 || lastFloatEdit != nil {
                let moves = edge == nil || edge?.left == true || edge?.top == true
                sendFloat(.float(KoSchema.EditFloat(
                    cols: edge == nil ? nil : geometry.width, pane: pane.id, rows: edge == nil ? nil : geometry.height,
                    x: moves ? geometry.point.x : nil, y: moves ? geometry.point.y : nil)), pane.id)
                host.position = .dragging(frame: frame, sent: geometry.point)
            }
            if input.up {
                endDrag()
                focusActive(force: true)
            }
            return
        }
        guard case .tiled(let source, let origin, let grip) = paneDrag else { return }
        let point = viewPoint(input.point)
        let moved = hypot(input.point.x - origin.x, input.point.y - origin.y) >= 4
        var drop = moved ? dropTarget(at: point, source: source) : nil
        var ghost: CGRect?
        let tiled = shown?.visible.root.panes.filter { $0.layer == .tiled } ?? []
        if moved, tiled.count > 1, let placement, let cell = session?.cell, (drop == nil && displayed(source)?.chrome.frame.contains(point) != true) || input.flags.contains(.option) {
            drop = nil
            let area = paneArea(tiled, placement)
            let chrome = displayed(source)?.chrome.frame ?? .zero
            let padding = CGSize(width: placement.before.width + placement.after.width, height: PaneLayout.floatTop + placement.after.height)
            let size = CGSize(width: max(20 * cell.width + padding.width, min(chrome.width, area.width * 0.6)),
                              height: max(6 * cell.height + padding.height, min(chrome.height, area.height * 0.6)))
            let free = CGRect(origin: CGPoint(x: point.x - min(grip, size.width - 16), y: point.y - 14), size: size)
            ghost = window?.styleMask.contains(.fullScreen) == true ? placement.clamp(free) : free
        }
        if !input.up {
            lastInput = input
            preview.rect = drop?.rect
            ghostRect = ghost
            return
        }
        endDrag()
        focusActive(force: true)
        guard let windowID else { return }
        if let ghost, let placement {
            let geometry = wire(ghost, source, placement)
            if let key = displayedPaneIDs[source] { retainedPaneViews[key]?.host = .popping(frame: ghost, sent: geometry.point) }
            let edit = KoSchema.Edit.float(KoSchema.EditFloat(cols: geometry.width, pane: source, rows: geometry.height, x: geometry.point.x, y: geometry.point.y))
            #if KIDO_STRESS
            stressEvent("drag-completed", "\(edit)")
            #endif
            session?.editSelecting(edit)
        } else if let (zone, _) = drop {
            let edit = dropEdit(zone, source, windowID)
            #if KIDO_STRESS
            stressEvent("drag-completed", "\(edit)")
            #endif
            session?.edit(edit, nil)
        }
    }

    private func paneArea(_ tiled: [Pane], _ placement: PaneLayout) -> CGRect {
        tiled.reduce(CGRect.null) { area, pane in
            area.union(placement.tiled(pane.geometry, alternate: displayed(pane.id)?.view.alternate ?? false).chrome)
        }
    }

    private func dropEdit(_ zone: DropZone, _ source: PaneID, _ windowID: WindowID) -> KoSchema.Edit {
        func edge(_ edge: Edge) -> KoSchema.Edge {
            switch edge { case .left: .left; case .right: .right; case .top: .top; case .bottom: .bottom }
        }
        return switch zone {
        case .centre(let target): .swap(KoSchema.EditSwap(other: target, pane: source))
        case .pane(let target, let side): .dock(KoSchema.EditDock(edge: edge(side), pane: source, target: target))
        case .window(_, let side): .dockWindow(KoSchema.EditDockWindow(edge: edge(side), pane: source, window: windowID))
        }
    }

    // The drop target under `point` and its insertion bar, for a tiled pane or a float that `source` drags.
    private func dropTarget(at point: NSPoint, source: PaneID) -> (zone: DropZone, rect: CGRect)? {
        let tiled = shown?.visible.root.panes.filter { $0.layer == .tiled } ?? []
        func blocker(_ pane: Pane) -> CGRect? {
            if pane.layer == .tiled { return displayed(pane.id).flatMap { $0.chrome.isHidden ? nil : $0.chrome.frame } }
            return floatWindows[pane.id].flatMap { $0.content.isHidden ? nil : $0.rect }
        }
        let hit = (shown?.visible.root.panes ?? []).filter { $0.id != source }.sorted {
            switch ($0.layer, $1.layer) { case (.floating(let a, _), .floating(let b, _)): a > b; case (.floating, .tiled): true; default: false }
        }.lazy.compactMap { pane in blocker(pane).map { (pane, $0) } }.first { $0.1.contains(point) }
        guard tiled.contains(where: { $0.id != source }), let placement,
              hit == nil || hit?.0.layer == .tiled else { return nil }
        let area = paneArea(tiled, placement)
        let outer = CGRect(x: bounds.minX, y: area.minY, width: bounds.width, height: bounds.maxY - area.minY)
        let edge: Edge? = !outer.contains(point) ? nil
            : point.x < area.minX + 22 ? .left : point.x > area.maxX - 22 ? .right
            : point.y < area.minY + 22 ? .top : point.y > area.maxY - 22 ? .bottom : nil
        var drop: (zone: DropZone, rect: CGRect)?
        if let edge, let target = tiled.first(where: { $0.id != source }) {
            drop = (.window(target.id, edge), area)
        } else if let (pane, frame) = hit {
            let x = (point.x - frame.minX) / frame.width, y = (point.y - frame.minY) / frame.height
            let edge: Edge? = x < 0.25 ? .left : x > 0.75 ? .right : y < 0.25 ? .top : y > 0.75 ? .bottom : nil
            drop = (edge.map { .pane(pane.id, $0) } ?? .centre(pane.id), frame)
        }
        guard let (zone, rect) = drop else { return nil }
        let side: Edge?, width: CGFloat, height: CGFloat
        switch zone {
        case .centre: (side, width, height) = (nil, rect.width / 2, rect.height / 2)
        case .pane(_, let edge): (side, width, height) = (edge, 4, 4)
        case .window(_, let edge): (side, width, height) = (edge, rect.width / 2, rect.height / 2)
        }
        let bar: CGRect = switch side {
        case .left: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        case .right: CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)
        case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        case .bottom: CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        case nil: rect
        }
        return (zone, bar)
    }

    private var drag: (divider: Divider, origin: NSPoint, position: Int)?

    private func hitArea(_ divider: Divider, _ placement: PaneLayout) -> CGRect {
        let line = placement.line(divider, pixel: pixel)
        return divider.direction == .leftRight ? line.insetBy(dx: -(6 - pixel) / 2, dy: 0) : line.insetBy(dx: 0, dy: -(6 - pixel) / 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        if let placement, shown?.visible.root.dividers.contains(where: { hitArea($0, placement).contains(local) }) == true { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let placement else { return }
        drag = shown?.visible.root.dividers.first { hitArea($0, placement).contains(point) }
            .map { ($0, point, $0.direction == .leftRight ? $0.geometry.x : $0.geometry.y) }
        if drag != nil { displayedPanes.forEach { $0.beginResizeIntent() } }
    }

    override func mouseDragged(with event: NSEvent) {
        if paneDrag != nil { updateDrag(input(event)); return }
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
        if paneDrag != nil { updateDrag(input(event)) }
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

    func floatCursorRects(_ id: PaneID) -> [(CGRect, NSCursor)] {
        guard !zoomed, let entry = displayed(id), let host = floatWindows[id] else { return [] }
        let chrome = entry.chrome, content = host.content
        let moved: PaneID? = if case .floating(let pane, _, _, let gesture, _)? = paneDrag { if case .resize = gesture { nil } else { pane.id } } else { nil }
        if case .dragging(_, _) = host.position, moved == id { return [(chrome.frame, .closedHand)] }
        var result: [(CGRect, NSCursor)] = []
        let zones = FloatContent.zones(chrome.frame)
        let toolbar = floatToolbar(id)
        var cuts: [CGRect] = []
        let grid = host.content.grid
        for (zone, rect) in zones {
            switch zone {
            case .resize(let position): result += rect.subtracting([grid]).map { ($0, .frameResize(position: position, directions: .all)) }
            case .move: result += rect.subtracting(cuts + [grid] + (toolbar.map { [$0] } ?? [])).map { ($0, .openHand) }
            }
            if zone != .move { cuts.append(rect) }
        }
        for rect in chrome.padding { result += content.convert(rect, from: chrome).subtracting(cuts).map { ($0, .openHand) } }
        cuts += chrome.overlays.map { content.convert($0, from: chrome) }
        if !entry.view.isHidden {
            for rect in entry.view.terminalCursorRects { for piece in content.convert(rect, from: entry.view).subtracting(cuts) { result.append((piece, entry.view.mouseCursor)) } }
        }
        return result
    }

    func floatToolbar(_ id: PaneID) -> CGRect? {
        guard let toolbar, let chrome = displayed(id)?.chrome, toolbar.superview === chrome, !toolbar.isHidden, toolbar.alphaValue > 0,
              let content = floatWindows[id]?.content else { return nil }
        return content.convert(toolbar.frame, from: chrome)
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
        let dividers = shown?.visible.root.dividers ?? []
        for d in dividers {
            add(hitArea(d, placement), d.direction == .leftRight ? .resizeLeftRight : .resizeUpDown)
        }
        covered += dividers.map { hitArea($0, placement) }
        for pane in shown?.visible.root.panes ?? [] where pane.layer == .tiled {
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
        if hot {
            endDrag()
            floatWindows.values.forEach { $0.position = .layout }
            place()
        }
        sizeClient()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            for host in hostWindows {
                host.delegate = window.delegate
                host.appearance = window.appearance
            }
            if hot, !isHidden {
                needsReconcile = true
                relayout()
            }
        }
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
        if let pane = PaneView.owner(window.firstResponder), contains(pane), !pane.isHiddenOrHasHiddenAncestor {
            if pane.pane != active { session?.selectPane(pane.pane) }
        } else if window.attachedSheet == nil, !(session?.sidebarFocused() ?? false), activePane?.window === window {
            focusActive(force: true)
        }
    }
}

final class GhostWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(contentView view: NSView) {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = view
    }
}
