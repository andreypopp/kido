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
    private var windowRoom: CGSize? { shown.map { CGSize(width: $0.layout.root.geometry.width, height: $0.layout.root.geometry.height) } }
    enum PaneHost {
        case tiled
        case docked(frame: CGRect, cols: Int, rows: Int)
        case popping(frame: CGRect, sent: CellPoint)
        case refloating(frame: CGRect, cols: Int, rows: Int, sent: CellPoint)
        case floating(FloatWindow)
        var window: FloatWindow? {
            switch self {
            case .floating(let window): window
            case .tiled, .docked, .popping, .refloating: nil
            }
        }
    }
    private struct RetainedPane {
        let view: PaneView
        let chrome: PaneChrome
        var host = PaneHost.tiled
    }
    private var displayedPaneIDs: Set<PaneID> = []
    private var retainedPaneViews: [PaneID: RetainedPane] = [:]
    private var displayedEntries: [RetainedPane] { displayedPaneIDs.compactMap { retainedPaneViews[$0] } }
    private func displayed(_ id: PaneID) -> RetainedPane? { displayedPaneIDs.contains(id) ? retainedPaneViews[id] : nil }
    var retainedCount: Int { retainedPaneViews.count }
    var retainedPanes: [PaneView] { retainedPaneViews.values.map(\.view) }
    func contains(_ pane: PaneView) -> Bool { retainedPaneViews[pane.pane]?.view === pane }
    var hostWindows: [FloatWindow] { retainedPaneViews.values.compactMap(\.host.window) }
    private var floatWindows: [PaneID: FloatWindow] { Dictionary(uniqueKeysWithValues: displayedPaneIDs.compactMap { id in retainedPaneViews[id]?.host.window.map { (id, $0) } }) }
    var hasFloats: Bool { shown?.layout.root.panes.contains { $0.layer != .tiled } == true }
    var hasFloatState: Bool {
        hasFloats || retainedPaneViews.values.contains { if case .tiled = $0.host { false } else { true } }
    }
    var cancelsDrag: Bool { paneDrag != nil }
    var inputWindow: NSWindow? { session?.inputWindow ?? window }

    func releaseUnusedPanes() {
        for (id, slot) in retainedPaneViews where !displayedPaneIDs.contains(id) && slot.view.webviewView == nil {
            guard case .tiled = slot.host else { continue }
            slot.view.chromeViews.forEach { $0.removeFromSuperview() }
            slot.chrome.removeFromSuperview()
            slot.view.scroller.removeFromSuperview()
            slot.view.dispose()
            slot.view.removeFromSuperview()
            retainedPaneViews.removeValue(forKey: id)
        }
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
            guard isHidden != oldValue else { return }
            needsReconcile = true
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

    var displayedPanes: [PaneView] { displayedEntries.map(\.view) }

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
            guard case .floating(let z) = pane.layer, let host = floatWindows[pane.id], !host.content.isHidden else { return nil }
            return (z, host)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
    var visualChromes: [PaneChrome] { retainedPaneViews.values.map(\.chrome) }
    var visualGhost: CGRect? { ghostRect }
    var visualGhostWindow: NSWindow? { ghostWindow }
    func visualBeginDrag(_ pane: PaneID, _ event: NSEvent) { beginDrag(pane, event) }
    #endif

    var hot: Bool { !retainedPaneViews.isEmpty }

    var defersRestore: Bool {
        paneDrag != nil || drag != nil || floatWindows.values.contains { if case .awaitingMove = $0.position { true } else if case .awaitingDock = $0.position { true } else { false } } || session?.editing() == true || window?.inLiveResize == true
    }

    func updateBackground() {
        layer?.backgroundColor = runtime.background.cgColor
        hostWindows.forEach { $0.content.handles.foreground = runtime.foreground }
        updateFocusTreatment(forcePaper: true)
        for chrome in displayedEntries.map(\.chrome) {
            chrome.needsDisplay = true
            for overlay in chrome.subviews { overlay.needsDisplay = true }
        }
        dividers.forEach { $0.fillColor = runtime.separator }
    }

    private var session: SessionView? { superview as? SessionView }

    func update(_ layout: Layout, _ visible: Layout) {
        let changed = shown.map { $0.layout != layout || $0.visible != visible } ?? true
        func sameTopology(_ a: PaneGeometry.Node, _ b: PaneGeometry.Node) -> Bool {
            switch (a, b) {
            case (.pane(let a), .pane(let b)): a.id == b.id && a.layer == b.layer
            case (.split(let a, _, let ac), .split(let b, _, let bc)):
                a == b && ac.count == bc.count && zip(ac, bc).allSatisfy { sameTopology($0, $1) }
            default: false
            }
        }
        needsReconcile = needsReconcile || (shown.map { !sameTopology($0.layout.root, layout.root) || !sameTopology($0.visible.root, visible.root) } ?? true)
        let windowResized = shown.map { $0.layout.root.geometry.width != layout.root.geometry.width || $0.layout.root.geometry.height != layout.root.geometry.height } ?? false
        let focusedPane = PaneView.owner(inputWindow?.firstResponder)
        let focusedWindow = focusedPane?.window
        let wasKey = focusedWindow?.isKeyWindow == true
        let paneFocused = focusedPane.map { focused in displayedPanes.contains { $0 === focused } } == true
        for pane in shown?.layout.root.panes ?? [] where pane.layer != .tiled {
            guard layout.root.panes.contains(where: { $0.id == pane.id && $0.layer == .tiled }),
                  let host = retainedPaneViews[pane.id]?.host.window else { continue }
            let frame = host.frame.insetBy(dx: FloatWindow.margin, dy: FloatWindow.margin)
            host.detach()
            retainedPaneViews[pane.id]?.host = .docked(frame: frame, cols: pane.geometry.width, rows: pane.geometry.height)
        }
        for id in retainedPaneViews.keys where !layout.root.panes.contains(where: { $0.id == id }) {
            retainedPaneViews[id]?.host.window?.detach()
            retainedPaneViews[id]?.host = .tiled
        }
        shown = (layout, visible)
        if let paneDrag {
            let valid: Bool = switch paneDrag {
            case .tiled(let id, _, _): !zoomed && visible.root.panes.contains { $0.id == id && $0.layer == .tiled }
            case .floating(let pane, _, _, _, _): layout.root.panes.contains { $0.id == pane.id && $0.layer != .tiled }
            }
            if !valid {
                #if KIDO_STRESS
                stressEvent("drag-layout-cancelled", zoomed ? "zoomed" : "source removed or changed layer")
                #endif
                cancelDrag()
            }
        }
        releaseMovedFloats(windowResized: windowResized)
        let previous = active
        if let pane = layout.root.panes.first(where: { $0.active }), pane.layer != .tiled { active = pane.id }
        else { active = visible.root.panes.first { $0.active }?.id ?? active }
        guard hot else { return }
        let known = displayedPanes.contains { $0.pane == active }
        if changed { relayout() }
        raiseActiveFloat()
        let reparented = focusedPane === activePane && focusedWindow !== activePane?.window
        if paneFocused && (active != previous || reparented) {
            if reparented && wasKey { activePane?.window?.makeKeyAndOrderFront(nil) }
            focusActive(force: true)
        } else if !known { focusActive(force: false) }
        refreshFloatIdentity()
    }

    private var raisedFor: PaneID?

    private func raiseActiveFloat() {
        guard active != raisedFor else { return }
        raisedFor = active
        let floats = shown?.layout.root.panes.filter { $0.layer != .tiled } ?? []
        guard let active, let float = floats.first(where: { $0.id == active }) else { return }
        if case .awaitingDock? = floatWindows[active]?.position { return }
        floatWindows[active]?.raise()
        guard case .floating(let z) = float.layer, z < floats.count - 1 else { return }
        session?.edit(.float(KoSchema.EditFloat(pane: active, z: floats.count)), nil)
    }

    func present() -> Int {
        let created = !hot
        relayout()
        sizeClient(immediately: true)
        return created ? retainedPanes.count : 0
    }

    func evict(keepingFloats: Bool = true) {
        endDrag()
        ghostRect = nil
        retainedPaneViews = retainedPaneViews.filter { _, record in
            let keep: Bool = switch record.host { case .tiled: false; default: keepingFloats }
            if keep { return true }
            record.host.window?.detach()
            record.view.dispose()
            return false
        }
        toolbar?.removeFromSuperview()
        toolbar = nil
        dividers = []
        backings = [:]
        needsReconcile = true
        subviews = []
        displayedPaneIDs = []
    }

    func focus(_ pane: PaneID) {
        active = pane
        updateFocusTreatment()
        focusActive(force: false)
    }

    var activePane: PaneView? { displayedPanes.first { $0.pane == active } }

    func focusActive(force: Bool) {
        guard let view = activePane, !view.isHiddenOrHasHiddenAncestor, let window, let input = inputWindow else { return }
        let focused = input.firstResponder
        guard force || focused === input || focused == nil || PaneView.owner(focused).map({ session?.contains($0) ?? contains($0) }) == true
        else { return }
        let target = view.window ?? window
        if target !== input, input.isKeyWindow { target.makeKeyAndOrderFront(nil) }
        target.makeFirstResponder(view.inputResponder)
    }

    func close() {
        evict(keepingFloats: false)
        removeFromSuperview()
    }

    private func relayout() {
        guard !isHidden || hasFloats || !hostWindows.isEmpty || !displayedPaneIDs.isEmpty, let shown, window != nil else { return }
        if !needsReconcile { place(); return }
        let layoutPanes = shown.layout.root.panes.filter { pane in
            pane.layer == .tiled ? !isHidden : session?.ownsFloats() != false
        }
        let existing = retainedPaneViews.mapValues(\.view)
        var views: [PaneID: PaneView] = [:]
        for pane in layoutPanes { views[pane.id] = existing[pane.id] ?? makePane(pane.id) }
        let actual = Set(views.values.lazy.map(\.pane))
        let removed = existing.values.filter { !actual.contains($0.pane) }
        if !removed.isEmpty { toolbar?.removeFromSuperview(); toolbar = nil }
        for gone in removed {
            gone.isHidden = true
            gone.scroller.removeFromSuperview()
            retainedPaneViews[gone.pane]?.chrome.isHidden = true
            retainedPaneViews[gone.pane]?.host.window?.detach()
            if !shown.layout.root.panes.contains(where: { $0.id == gone.pane }) { retainedPaneViews[gone.pane]?.host = .tiled }
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
        var nextDisplayedPaneIDs: Set<PaneID> = []
        for pane in layoutPanes {
            guard let view = views[pane.id] else { continue }
            let presented = pane.layer == .tiled ? (seen[pane.id] ?? pane) : pane
            let g = presented.geometry
            view.isHidden = pane.layer == .tiled && (isHidden || seen[pane.id] == nil)
            let chrome = retainedPaneViews[view.pane].flatMap { $0.chrome.pane == pane.id ? $0.chrome : nil }
                ?? PaneChrome(pane: pane.id, runtime: runtime)
            var host = retainedPaneViews[view.pane]?.host ?? .tiled
            let isFloating = pane.layer != .tiled
            if pane.layer != .tiled {
                let native = host.window ?? makeHost(pane.id, from: host)
                host = .floating(native)
            } else if let native = host.window {
                native.detach()
                host = .tiled
            }
            retainedPaneViews[view.pane] = RetainedPane(view: view, chrome: chrome, host: host)
            nextDisplayedPaneIDs.insert(pane.id)
            chrome.select = view.onSelect
            chrome.hover = { [weak self] chrome, point in self?.hover(chrome, point) }
            chrome.wantsLayer = true
            chrome.layer?.cornerRadius = isFloating ? floatingRadius : 0
            chrome.layer?.masksToBounds = isFloating
            place(chrome, view, g, placement, host: isFloating ? host.window : nil)
            chrome.isHidden = view.isHidden
            view.transparentPaper = !isFloating
            switch presented.layer {
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
        for view in views.values where !view.isHiddenOrHasHiddenAncestor {
            view.updateWebview(session?.webview(view.pane))
        }
        updateFocusTreatment()
        session?.updateWebview()
        invalidateCursorRects()
        needsReconcile = false
        if let chrome = toolbar?.superview as? PaneChrome {
            hover(chrome, chrome.isHidden ? nil : chrome.window.map { chrome.convert($0.mouseLocationOutsideOfEventStream, from: nil) })
        }
        sizeClient()
        #if KIDO_VISUAL
        session?.visualReconciled(self)
        #endif
    }

    func place() {
        guard !isHidden || hasFloats, let shown, let placement else { return }
        #if KIDO_STRESS
        stressEvent("place-window", "")
        #endif
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        var changed = false
        for entry in displayedEntries where !entry.chrome.isHidden {
            let id = entry.view.pane
            guard let pane = shown.layout.root.panes.first(where: { $0.id == id && $0.layer != .tiled }) ?? seen[id] else { continue }
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
        guard let pane = shown?.layout.root.panes.first(where: { $0.id == id && $0.layer != .tiled }),
              let entry = displayed(id), let host = floatWindows[id],
              host.rect != floatFrame(pane.geometry, placement, host) else { return }
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
        let entries = displayedEntries
        let multiple = entries.filter { !$0.chrome.isHidden && $0.view.transparentPaper }.count > 1
        let mainKey = (window as? OwnerWindow)?.isInputWindow != false
        let focusedPane = OwnerWindow.focusedPane
        for entry in entries {
            let pane = entry.view, chrome = entry.chrome
            pane.syncFocus()
            let tiled = pane.transparentPaper
            let focused = pane === focusedPane
            let shifted = tiled && (!mainKey || multiple && !focused)
            chrome.treatment = focused
                ? (tiled && multiple ? .edge : .plain)
                : (tiled ? .plain : .overlay)
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
    func freezeFloatOrigins() {
        for (id, host) in floatWindows {
            if case .layout = host.position, let point = layoutPoint(id) {
                host.position = .local(frame: host.frame.insetBy(dx: FloatWindow.margin, dy: FloatWindow.margin), sent: point)
            }
        }
    }

    private func updateFloatIdentity(_ view: PaneView, host: FloatWindow?) {
        if let host, let windowID { host.title = session?.floatTitle(view.pane, windowID) ?? "" }
    }

    func refreshFloatIdentity() {
        for entry in displayedEntries { updateFloatIdentity(entry.view, host: entry.host.window) }
    }

    func refreshFloats() {
        guard hasFloats || !hostWindows.isEmpty else { return }
        needsReconcile = true
        if hot || hasFloats && session?.ownsFloats() != false { relayout() }
    }

    func marksChanged(_ changed: Set<PaneID>, banded: Bool) {
        if banded { return place() }
        for slot in displayedEntries where changed.contains(slot.view.pane) {
            let mark = session?.marks[slot.view.pane]
            slot.chrome.runtimeMark = mark
            slot.view.runtimeMark = mark
        }
    }

    private func place(_ chrome: PaneChrome, _ view: PaneView, _ g: Geometry, _ placement: PaneLayout, host: FloatWindow?) {
        let floating = host != nil
        chrome.kind = floating ? .floating : .tiled
        updateFloatIdentity(view, host: host)
        let mark = session?.marks[view.pane]
        view.runtimeMark = mark
        chrome.runtimeMark = mark
        chrome.stripeTop = host != nil ? PaneLayout.floatTop - PaneChrome.stripeBand : 0
        let frame: CGRect, grid: CGRect, content: CGRect, insets: PaneLayout.RenderInsets
        if floating {
            let rect = floatFrame(g, placement, host)
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
        if let toolbar, toolbar.superview === chrome {
            if toolbar.frame != chrome.toolbarFrame { toolbar.frame = chrome.toolbarFrame }
            toolbar.update(command: { view.onSelect(); view.onCommand($0) }, zoomed: zoomed, floatState: view.floatState(),
                           drag: { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0) })
        }
        view.renderInsets = insets
        if view.frame != content { view.frame = content }
        chrome.content = content.offsetBy(dx: -frame.minX, dy: -frame.minY)
        if floating { host?.content.grid = grid }
        chrome.drag = floating ? { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0) } : nil
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
        guard !isHidden || floatWindows[chrome.pane]?.content.isHidden == false else { return }
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
            toolbar.update(command: { view.onSelect(); view.onCommand($0) }, zoomed: zoomed, floatState: view.floatState(), drag: { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0) })
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
        view.onPrompt = { [weak self] pane, quote, preselect in self?.session?.onPrompt(pane, quote, preselect) }
        view.onSelect = { [weak self] in
            guard let self else { return }
            session?.selectPane(id)
            if id == active { raisedFor = nil; raiseActiveFloat() }
        }
        view.cursorHost = self
        view.onCommand = { [weak self] command in self?.session?.paneCommand(command, id) }
        view.floatState = { [weak self] in self?.session?.floatState(id) }
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
    private enum FloatGesture {
        case move
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
            ($0, floatFrame($0.geometry, placement, floatWindows[$0.id]), floatWindows[$0.id]?.position != .layout)
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

    private func viewRect(_ rect: CGRect) -> CGRect {
        window.map { convert($0.convertFromScreen(rect), from: nil) } ?? rect
    }

    private func input(_ event: NSEvent) -> DragInput {
        DragInput(point: screenPoint(event), up: event.type == .leftMouseUp, flags: event.modifierFlags)
    }

    func takeFloatHosts(for panes: Set<PaneID>? = nil) -> [PaneID: PaneHost] {
        let hosts = retainedPaneViews.reduce(into: [PaneID: PaneHost]()) { hosts, entry in
            let (id, record) = entry
            guard panes?.contains(id) != false else { return }
            if case .tiled = record.host { return }
            if panes != nil, let host = record.host.window, let pane = layoutPane(id) {
                let frame = host.frame.insetBy(dx: FloatWindow.margin, dy: FloatWindow.margin)
                host.detach()
                hosts[id] = .docked(frame: frame, cols: pane.geometry.width, rows: pane.geometry.height)
            } else { hosts[id] = record.host }
        }
        guard !hosts.isEmpty else { return [:] }
        cancelDrag()
        for (id, state) in hosts {
            retainedPaneViews[id]?.host = .tiled
            guard let host = state.window else { continue }
            (host.delegate as? WindowOwner)?.floatClosing(host)
            if let point = layoutPoint(id) {
                host.position = .local(frame: host.frame.insetBy(dx: FloatWindow.margin, dy: FloatWindow.margin), sent: point)
            }
            host.content.subviews = [host.content.handles]
            host.content.logical = nil
            host.becameKey = {}
            host.focusChanged = { _, _ in }
        }
        needsReconcile = true
        return hosts
    }

    func adoptFloatHosts(_ hosts: [PaneID: PaneHost]) {
        for (id, state) in hosts {
            if retainedPaneViews[id] == nil {
                guard let view = makePane(id) else { state.window?.detach(); continue }
                if let client = session?.client { view.attach(client) }
                retainedPaneViews[id] = RetainedPane(view: view, chrome: PaneChrome(pane: id, runtime: runtime))
            }
            retainedPaneViews[id]?.host.window?.detach()
            retainedPaneViews[id]?.host = state
            if let host = state.window { bindHost(host, pane: id) }
        }
        needsReconcile = true
        relayout()
        constrainFloats()
    }

    func constrainFloats() {
        for (id, host) in floatWindows {
            let actual = host.frame.insetBy(dx: FloatWindow.margin, dy: FloatWindow.margin)
            let frame: CGRect = switch host.position {
            case .layout: actual
            case .local(let stored, _):
                CGRect(origin: stored.origin, size: layoutPane(id).flatMap { pane in placement.map { floatFrame(pane.geometry, $0, nil).size } } ?? actual.size)
            case .dragging(let stored, _, _), .awaitingMove(let stored, _, _), .awaitingDock(let stored): stored
            }
            let next = reachable(frame)
            guard next != actual else { continue }
            switch host.position {
            case .layout:
                guard let point = layoutPoint(id) else { continue }
                host.position = .local(frame: next, sent: point)
            case .local(_, let sent): host.position = .local(frame: next, sent: sent)
            case .dragging(_, let sent, let room): host.position = .dragging(frame: next, sent: sent, room: room)
            case .awaitingMove(_, let sent, let room): host.position = .awaitingMove(frame: next, sent: sent, room: room)
            case .awaitingDock: host.position = .awaitingDock(frame: next)
            }
            host.rect = viewRect(next)
            host.setFrame(next.insetBy(dx: -FloatWindow.margin, dy: -FloatWindow.margin), display: false)
        }
    }

    private func reachable(_ frame: CGRect) -> CGRect {
        let screen = NSScreen.screens.filter { $0.frame.intersects(frame) }.max {
            let a = frame.intersection($0.frame), b = frame.intersection($1.frame)
            return a.width * a.height < b.width * b.height
        } ?? window?.screen
        return screen.map { FloatWindow.reachable(frame, in: $0.visibleFrame) } ?? frame
    }

    private func bindHost(_ host: FloatWindow, pane id: PaneID) {
        host.delegate = window?.delegate
        host.content.logical = self
        host.content.pane = id
        host.content.handles.foreground = runtime.foreground
        host.appearance = window?.appearance
        host.focusChanged = { [weak self] old, next in self?.session?.hostFocusChanged(old, next) }
        host.becameKey = { [weak self] in self?.floatBecameKey(id) }
    }

    private func makeHost(_ id: PaneID, from state: PaneHost) -> FloatWindow {
        let host = FloatWindow(owner: window?.delegate)
        bindHost(host, pane: id)
        switch state {
        case .popping(let frame, let sent):
            host.position = .awaitingMove(frame: frame, sent: sent, room: windowRoom)
        case .refloating(let frame, _, _, let sent):
            let size = layoutPane(id).flatMap { pane in placement.map { floatFrame(pane.geometry, $0, nil).size } } ?? frame.size
            let restored = CGRect(origin: frame.origin, size: size)
            host.position = .local(frame: reachable(restored), sent: layoutPoint(id) ?? sent)
        case .tiled, .docked, .floating: break
        }
        return host
    }

    func floatAgainEdit(_ id: PaneID) -> KoSchema.Edit? {
        guard case .docked(let frame, let cols, let rows)? = retainedPaneViews[id]?.host, let placement else { return nil }
        let size = placement.floatFrame(Geometry(x: 0, y: 0, width: cols, height: rows)).size
        let geometry = wire(viewRect(CGRect(origin: frame.origin, size: size)), id, placement)
        retainedPaneViews[id]?.host = .refloating(frame: frame, cols: cols, rows: rows, sent: geometry.point)
        return .float(KoSchema.EditFloat(cols: cols, pane: id, rows: rows, x: geometry.point.x, y: geometry.point.y))
    }

    private func floatBecameKey(_ id: PaneID) {
        guard let entry = displayed(id), let host = floatWindows[id] else { return }
        if PaneView.owner(host.firstResponder) == nil { host.makeFirstResponder(entry.view.inputResponder) }
        session?.selectPane(entry.view.pane)
        updateFocusTreatment()
    }

    func syncHosts() {
        let hosts = floatWindows
        let floats = (shown?.layout.root.panes ?? []).compactMap { pane -> (z: Int, id: PaneID)? in
            if case .floating(let z) = pane.layer { (z, pane.id) } else { nil }
        }.sorted { $0.z < $1.z }
        let wanted = Set(floats.map(\.id))
        let open = session?.ownsFloats() != false && session?.floatsAllowed() != false
        var changed = false
        for (id, host) in hosts where !wanted.contains(id) { changed = host.present(false) || changed }
        for pane in floats {
            if let host = hosts[pane.id] { changed = host.present(open && displayed(pane.id)?.view.isHidden == false) || changed }
        }
        let order = floats.map(\.id)
        guard changed || order != stacked else { return }
        stacked = order
        if let active, let host = hosts[active], !host.content.isHidden { host.raise() }
    }

    private func positionHost(_ host: FloatWindow, _ rect: CGRect) {
        host.rect = rect
        host.content.chrome = CGRect(x: FloatWindow.margin, y: FloatWindow.margin, width: rect.width, height: rect.height)
        guard window != nil else { return }
        let frame = screenRect(rect).insetBy(dx: -FloatWindow.margin, dy: -FloatWindow.margin)
        if host.frame != frame { host.setFrame(frame, display: false) }
    }

    private func floatFrame(_ geometry: Geometry, _ placement: PaneLayout, _ host: FloatWindow?) -> CGRect {
        let canonical = placement.clamp(limit(placement.floatFrame(geometry), nil, placement))
        switch host?.position ?? .layout {
        case .layout: return canonical
        case .dragging(let frame, _, _), .awaitingMove(let frame, _, _), .awaitingDock(let frame): return viewRect(frame)
        case .local(let frame, _): return viewRect(CGRect(origin: frame.origin, size: canonical.size))
        }
    }

    private func layoutPane(_ id: PaneID) -> Pane? { shown?.layout.root.panes.first { $0.id == id } }

    private func wire(_ frame: CGRect, _ id: PaneID, _ placement: PaneLayout) -> (width: Int, height: Int, point: CellPoint) {
        let g = placement.floatGeometry(frame)
        let pane = layoutPane(id)
        guard let extent = shown?.layout.root.geometry else { return (g.width, g.height, CellPoint(x: max(0, g.x), y: max(0, g.y))) }
        let pad = pane?.border == true ? 1 : 0
        let width = min(g.width, max(1, extent.width - 2 * pad)), height = min(g.height, max(1, extent.height - 2 * pad))
        return (width, height, CellPoint(x: min(max(g.x - extent.x, pad), max(pad, extent.width - width - pad)),
                                         y: min(max(g.y - extent.y, pad), max(pad, extent.height - height - pad))))
    }

    private func layoutPoint(_ id: PaneID) -> CellPoint? {
        layoutPane(id).flatMap { $0.layer == .tiled ? nil : CellPoint(x: $0.geometry.x, y: $0.geometry.y) }
    }

    private func releaseMovedFloats(windowResized: Bool) {
        for (id, host) in floatWindows {
            guard case .local(let frame, let sent) = host.position, let point = layoutPoint(id) else { continue }
            if windowResized { host.position = .local(frame: frame, sent: point) }
            else if point != sent { host.position = .layout }
        }
    }

    private func limit(_ frame: CGRect, _ edge: PaneLayout.ResizeEdge?, _ placement: PaneLayout) -> CGRect {
        let area = placement.floatingBounds
        var r = frame
        if r.width > area.width { if edge?.left == true { r.origin.x = r.maxX - area.width }; r.size.width = area.width }
        if r.height > area.height { if edge?.top == true { r.origin.y = r.maxY - area.height }; r.size.height = area.height }
        return r
    }

    func editsSettled() {
        defer { if !defersRestore { displayedPanes.forEach { $0.endResizeIntent() } } }
        for (id, record) in retainedPaneViews {
            switch record.host {
            case .popping: retainedPaneViews[id]?.host = .tiled
            case .refloating(let frame, let cols, let rows, _): retainedPaneViews[id]?.host = .docked(frame: frame, cols: cols, rows: rows)
            case .tiled, .docked, .floating: break
            }
        }
        for (id, host) in floatWindows {
            switch host.position {
            case .awaitingMove(let frame, let sent, let room):
                let resized = room != nil && room != windowRoom
                host.position = (layoutPoint(id) == sent || resized) ? .local(frame: frame, sent: layoutPoint(id) ?? sent) : .layout
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

    func beginDrag(_ pane: PaneID, _ event: NSEvent) {
        if event.type == .keyDown {
            cancelDrag(); return
        }
        if event.type != .leftMouseDown { updateDrag(input(event)); return }
        if paneDrag != nil { cancelDrag(); return }
        guard let pane = shown?.layout.root.panes.first(where: { $0.id == pane && $0.layer != .tiled }) ?? shown?.visible.root.panes.first(where: { $0.id == pane }),
              pane.layer != .tiled || !zoomed else { return }
        endDrag()
        guard claimPaneDrag() else { return }
        dragSource = event.window ?? window
        if pane.layer != .tiled { displayed(pane.id)?.view.onSelect() }
        #if KIDO_STRESS
        stressEvent("drag-started", pane.id.description)
        #endif
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, let last = lastInput { updateDrag(DragInput(point: last.point, up: false, flags: event.modifierFlags)) }
            return event
        }
        switch pane.layer {
        case .tiled:
            let chrome = displayed(pane.id)?.chrome
            paneDrag = .tiled(pane.id, screenPoint(event), grip: (chrome?.toolbarFrame.minX ?? 0) + 16)
        case .floating:
            guard let placement, let host = floatWindows[pane.id] else { return endDrag() }
            let frame = floatFrame(pane.geometry, placement, host)
            paneDrag = .floating(pane, screenPoint(event), frame, .move, resting: host.position)
            host.position = .dragging(frame: screenRect(frame), sent: nil, room: windowRoom)
            dragSource?.makeFirstResponder(host.content)
        }
    }

    func beginEdgeResize(_ id: PaneID, _ edge: NSCursor.FrameResizePosition, _ event: NSEvent) {
        endDrag()
        guard let placement, let host = floatWindows[id], let pane = shown?.layout.root.panes.first(where: { $0.id == id && $0.layer != .tiled }),
              claimPaneDrag() else { return }
        dragSource = event.window ?? window
        let frame = floatFrame(pane.geometry, placement, host)
        paneDrag = .floating(pane, screenPoint(event), frame, .resize(edge), resting: host.position)
        host.position = .dragging(frame: screenRect(frame), sent: nil, room: windowRoom)
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
        endDrag(); place()
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
            }
        }
    }

    private weak var floatDropView: WindowView?

    private func endDrag() {
        floatDropView?.preview.rect = nil
        floatDropView = nil
        claimed?.release(.pane)
        claimed = nil
        guard paneDrag != nil || drag != nil else { return }
        let target = dragWindow ?? window
        let responder: PaneView? = if case .floating(let pane, _, _, _, _)? = paneDrag { displayed(pane.id)?.view } else { nil }
        if let dragWindow {
            if !background { NSCursor.pop() }
            dragWindow.enableCursorRects()
            self.dragWindow = nil
        }
        if case .floating(let pane, _, _, _, let resting)? = paneDrag, let host = floatWindows[pane.id], case .dragging(let frame, let sent, let room) = host.position {
            host.position = sent.map { .awaitingMove(frame: frame, sent: $0, room: room) } ?? resting
            if sent != nil, let placement { placeFloat(pane.id, placement) }
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
        if let responder, let host = responder.window { host.makeFirstResponder(responder.inputResponder) }
        else { focusActive(force: true) }
    }

    private func updateDrag(_ input: DragInput) {
        guard let paneDrag else { return }
        lastInput = input
        if case .floating(let pane, let origin, let initial, let gesture, _) = paneDrag {
            let cursorEdge: NSCursor.FrameResizePosition? = if case .resize(let position) = gesture { position } else { nil }
            let edge = cursorEdge?.layoutEdge
            guard let cell = session?.cell, let placement, let host = floatWindows[pane.id] else { return }
            let dx = input.point.x - origin.x
            let dy = origin.y - input.point.y
            if edge == nil, !dragStarted, hypot(dx, dy) < 4 {
                if input.up { endDrag() }
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
            frame = limit(frame, edge, placement)
            var sent: CellPoint?, room: CGSize?
            if case .dragging(_, let before, let extent) = host.position { sent = before; room = extent }
            let geometry = wire(frame, pane.id, placement)
            host.position = .dragging(frame: screenRect(frame), sent: sent, room: room)
            placeFloat(pane.id, placement)
            let destination: WindowView? = if case .move = gesture, input.flags.contains(.option), session?.floatState(pane.id)?.isEnabled == true {
                session?.floatDropView(input.point, pane.id)
            } else { nil }
            if floatDropView !== destination { floatDropView?.preview.rect = nil }
            floatDropView = destination
            let target = destination?.dropTarget(at: destination?.viewPoint(input.point) ?? .zero, source: pane.id)
            destination?.preview.rect = target?.rect
            if let target, let destination, let windowID = destination.windowID, input.up {
                host.position = .awaitingDock(frame: screenRect(frame))
                let edit = dropEdit(target.zone, pane.id, windowID)
                #if KIDO_STRESS
                stressEvent("drag-completed", "\(edit)")
                #endif
                session?.dockFloat(edit, destination)
                endDrag()
                return
            }
            if target == nil, edge != nil || input.up, dx != 0 || dy != 0 || lastFloatEdit != nil {
                let moves = edge == nil || edge?.left == true || edge?.top == true
                sendFloat(.float(KoSchema.EditFloat(
                    cols: edge == nil ? nil : geometry.width, pane: pane.id, rows: edge == nil ? nil : geometry.height,
                    x: moves ? geometry.point.x : nil, y: moves ? geometry.point.y : nil)), pane.id)
                host.position = .dragging(frame: screenRect(frame), sent: geometry.point, room: windowRoom)
            }
            if input.up { endDrag() }
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
            ghost = free
        }
        if !input.up {
            preview.rect = drop?.rect
            ghostRect = ghost
            return
        }
        endDrag()
        guard let windowID else { return }
        if let ghost, let placement {
            let geometry = wire(ghost, source, placement)
            if displayedPaneIDs.contains(source) { retainedPaneViews[source]?.host = .popping(frame: screenRect(ghost), sent: geometry.point) }
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
        let floating = shown?.layout.root.panes.first(where: { $0.id == source })?.layer != .tiled
        let hit = (shown?.visible.root.panes ?? []).filter { $0.id != source && (!floating || $0.layer == .tiled) }.sorted {
            switch ($0.layer, $1.layer) { case (.floating(let a), .floating(let b)): a > b; case (.floating, .tiled): true; default: false }
        }.lazy.compactMap { pane in blocker(pane).map { (pane, $0) } }.first { $0.1.contains(point) }
        guard tiled.contains(where: { $0.id != source }), let placement,
              hit == nil || hit?.0.layer == .tiled else { return nil }
        let area = paneArea(tiled, placement)
        let outer = CGRect(x: bounds.minX, y: area.minY, width: bounds.width, height: bounds.maxY - area.minY)
        let edge: Edge? = !outer.contains(point) ? nil
            : point.x < area.minX + 22 ? .left : point.x > area.maxX - 22 ? .right
            : point.y < area.minY + 22 ? .top : point.y > area.maxY - 22 ? .bottom : nil
        var drop: (zone: DropZone, rect: CGRect)?
        if let edge, !floating, let target = tiled.first(where: { $0.id != source }) {
            drop = (.window(target.id, edge), area)
        } else if let (pane, frame) = hit {
            let x = (point.x - frame.minX) / frame.width, y = (point.y - frame.minY) / frame.height
            let edge: Edge? = x < 0.25 ? .left : x > 0.75 ? .right : y < 0.25 ? .top : y > 0.75 ? .bottom : nil
            if floating && edge == nil { return nil }
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
        guard let entry = displayed(id), let host = floatWindows[id] else { return [] }
        let chrome = entry.chrome, content = host.content
        let moved: PaneID? = if case .floating(let pane, _, _, let gesture, _)? = paneDrag { if case .resize = gesture { nil } else { pane.id } } else { nil }
        if case .dragging = host.position, moved == id { return [(chrome.frame, .closedHand)] }
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
        guard let windowID else { return [] }
        return [KoWindowSize(window: windowID, size: viewport)]
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        if hot {
            endDrag()
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
            if hot {
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
        guard !isHidden, session?.updating != true, let window else { return }
        if let pane = PaneView.owner(window.firstResponder), contains(pane), !pane.isHiddenOrHasHiddenAncestor {
            session?.selectPane(pane.pane)
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
