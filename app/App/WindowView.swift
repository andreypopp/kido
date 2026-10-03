import AppKit
import TmuxControl

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
    private weak var connection: Connection?
    private let runtime: GhosttyRuntime
    private var shown: (layout: Layout, visible: Layout)?
    private var active: PaneID?
    var stale = false
    private var needsReconcile = true
    private var dividers: [NSBox] = []
    private var floatingBoxes: [PaneID: NSBox] = [:]
    private var freeFrames: [PaneID: CGRect] = [:]
    private var placed: PaneLayout?
    private enum FloatFrame { case dragging(PaneID, CGRect), settling(PaneID, CGRect) }
    private var liveFrame: FloatFrame?
    private let floatingRadius: CGFloat = 10
    private var toolbar: PaneToolbar?
    private let preview = PaneDropPreview()
    override var isHidden: Bool {
        didSet {
            if isHidden { endDrag(); toolbar?.removeFromSuperview(); toolbar = nil }
        }
    }

    init(runtime: GhosttyRuntime, connection: Connection?) {
        self.runtime = runtime
        self.connection = connection
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = runtime.background.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    var panes: [PaneView] { subviews.compactMap { $0 as? PaneView } }

    var hot: Bool { !panes.isEmpty }

    private var dividerDrain = false
    var defersRestore: Bool {
        if dividerDrain { return true }
        if paneDrag != nil || drag != nil || liveFrame != nil { return true }
        if case .sending = delivery { return true }
        return window?.inLiveResize == true
    }

    func updateBackground() {
        layer?.backgroundColor = runtime.background.cgColor
        subviews.compactMap { $0 as? PaneChrome }.forEach { $0.needsDisplay = true }
        floatingBoxes.values.forEach { $0.fillColor = runtime.background }
    }

    private var session: SessionView? { superview as? SessionView }

    func update(_ layout: Layout, _ visible: Layout) {
        let changed = shown.map { $0.layout != layout || $0.visible != visible } ?? true
        func sameTopology(_ a: Node, _ b: Node) -> Bool {
            switch (a, b) {
            case (.pane(let a), .pane(let b)): a.id == b.id && a.layer == b.layer
            case (.split(let a, _, let ac), .split(let b, _, let bc)):
                a == b && ac.count == bc.count && zip(ac, bc).allSatisfy { sameTopology($0, $1) }
            default: false
            }
        }
        needsReconcile = needsReconcile || (shown.map { !sameTopology($0.layout.root, layout.root) || !sameTopology($0.visible.root, visible.root) } ?? true)
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
        active = visible.root.panes.first { $0.focus == .active }?.id ?? active
        guard hot else { return }
        let known = panes.contains { $0.pane == active }
        if changed {
            if isHidden {
                for pane in layout.root.panes {
                    panes.first(where: { $0.pane == pane.id })?.resize(cols: pane.geometry.width, rows: pane.geometry.height)
                }
            } else { relayout() }
        }
        if !known { focusActive(force: false) }
    }

    func present(_ synced: DispatchGroup) -> (created: Int, resynced: Int) {
        let created = !hot
        relayout(created ? synced : nil)
        sizeClient()
        let resync = !created ? panes.filter { stale || $0.resizeDirty } : []
        stale = false
        for pane in resync {
            synced.enter()
            connection?.sync(pane.pane) { synced.leave() }
        }
        return (created ? panes.count : 0, resync.count)
    }

    func evict() {
        endDrag()
        panes.forEach { connection?.detach($0) }
        toolbar?.removeFromSuperview()
        toolbar = nil
        dividers = []
        floatingBoxes = [:]
        freeFrames = [:]
        liveFrame = nil
        placed = nil
        needsReconcile = true
        subviews = []
    }

    func focus(_ pane: PaneID) {
        active = pane
        for chrome in subviews.compactMap({ $0 as? PaneChrome }) { chrome.dimmed = chrome.pane != active }
        focusActive(force: false)
    }

    func focusActive(force: Bool) {
        guard !isHidden, let view = panes.first(where: { $0.pane == active }), let window else { return }
        let focused = window.firstResponder
        guard force || focused === window || focused == nil || (focused as? PaneView)?.isDescendant(of: session ?? self) == true
        else { return }
        window.makeFirstResponder(view)
    }

    func close() {
        evict()
        removeFromSuperview()
    }

    private func relayout(_ synced: DispatchGroup? = nil) {
        guard let shown else { return }
        guard !isHidden else { return }
        if !needsReconcile { place(resizeGrids: true); return }
        let layoutPanes = shown.layout.root.panes
        let existing = Dictionary(uniqueKeysWithValues: panes.map { ($0.pane, $0) })
        var views: [PaneID: PaneView] = [:]
        for pane in layoutPanes {
            views[pane.id] = existing[pane.id] ?? makePane(pane.id)
        }
        for (id, gone) in existing where views[id] == nil { connection?.detach(gone) }
        let cell = session?.cell ?? views.values.lazy.map(\.cell).first { $0.width > 0 && $0.height > 0 } ?? .zero
        guard cell.width > 0, cell.height > 0 else { return }
        let placement = PaneLayout(root: shown.visible.root, bounds: bounds, cell: cell, pixel: pixel)
        validateFrames(placement)
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        let overlays = Dictionary(uniqueKeysWithValues: subviews.compactMap { $0 as? PaneChrome }.map { ($0.pane, $0) })
        var tiled: [NSView] = [], floating: [(z: Int, views: [NSView])] = []
        floatingBoxes = [:]
        for pane in layoutPanes {
            guard let view = views[pane.id] else { continue }
            let g = (seen[pane.id] ?? pane).geometry
            view.isHidden = seen[pane.id] == nil
            view.resize(cols: g.width, rows: g.height)
            let chrome = overlays[pane.id] ?? PaneChrome(pane: pane.id, runtime: runtime)
            chrome.select = view.onSelect
            chrome.hover = { [weak self] chrome, point in self?.hover(chrome, point) }
            place(chrome, view, g, placement, floating: (seen[pane.id] ?? pane).layer != .tiled)
            chrome.isHidden = view.isHidden
            chrome.dimmed = pane.id != active
            switch (seen[pane.id] ?? pane).layer {
            case .tiled:
                tiled += [view, chrome]
            case .floating(let z):
                if view.isHidden { floating.append((z, [view, chrome])) }
                else {
                    let backing = box(chrome.frame, border: pixel, fill: runtime.background)
                    backing.wantsLayer = true
                    backing.cornerRadius = floatingRadius
                    backing.borderColor = .separatorColor
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
                    shadow.shadowBlurRadius = 12
                    shadow.shadowOffset = NSSize(width: 0, height: -3)
                    backing.shadow = shadow
                    floatingBoxes[pane.id] = backing
                    floating.append((z, [backing, view, chrome]))
                }
            }
        }
        dividers = (shown.visible.root.dividers.map { placement.line($0, pixel: pixel) } + [placement.topLine]).map {
            box($0, border: 0, fill: .separatorColor)
        }
        preview.frame = bounds
        preview.autoresizingMask = [.width, .height]
        subviews = dividers + tiled + floating.sorted { $0.z > $1.z }.flatMap(\.views) + [preview]
        for view in views.values where existing[view.pane] == nil {
            synced?.enter()
            connection?.attach(view) { synced?.leave() }
        }
        invalidateCursorRects()
        needsReconcile = false
    }

    private func place(resizeGrids: Bool = false) {
        guard !isHidden, let shown, let placement else { return }
        validateFrames(placement)
        #if KIDO_STRESS
        stressEvent("place-window", "")
        #endif
        let seen = Dictionary(uniqueKeysWithValues: shown.visible.root.panes.map { ($0.id, $0) })
        let layout = Dictionary(uniqueKeysWithValues: shown.layout.root.panes.map { ($0.id, $0) })
        let views = Dictionary(uniqueKeysWithValues: panes.map { ($0.pane, $0) })
        if resizeGrids {
            for view in views.values {
                guard let pane = seen[view.pane] ?? layout[view.pane] else { continue }
                view.resize(cols: pane.geometry.width, rows: pane.geometry.height)
            }
        }
        var changed = false
        for chrome in subviews.compactMap({ $0 as? PaneChrome }) where !chrome.isHidden {
            guard let pane = seen[chrome.pane], let view = views[chrome.pane] else { continue }
            chrome.dimmed = chrome.pane != active
            let previous = chrome.frame
            place(chrome, view, pane.geometry, placement, floating: pane.layer != .tiled)
            changed = changed || previous != chrome.frame
            if floatingBoxes[chrome.pane]?.frame != chrome.frame { floatingBoxes[chrome.pane]?.frame = chrome.frame }
            if toolbar?.superview === chrome { toolbar?.frame = chrome.toolbarFrame }
        }
        for (box, frame) in zip(dividers, shown.visible.root.dividers.map { placement.line($0, pixel: pixel) } + [placement.topLine]) {
            if box.frame != frame { box.frame = frame; changed = true }
        }
        if changed { invalidateCursorRects() }
    }

    private func placeFloat(_ id: PaneID, _ placement: PaneLayout) {
        guard let pane = shown?.visible.root.panes.first(where: { $0.id == id && $0.layer != .tiled }),
              let chrome = subviews.lazy.compactMap({ $0 as? PaneChrome }).first(where: { $0.pane == id }),
              let view = panes.first(where: { $0.pane == id }),
              chrome.frame != floatFrame(id, pane.geometry, placement) else { return }
        place(chrome, view, pane.geometry, placement, floating: true)
        if floatingBoxes[id]?.frame != chrome.frame { floatingBoxes[id]?.frame = chrome.frame }
        if toolbar?.superview === chrome, toolbar?.frame != chrome.toolbarFrame { toolbar?.frame = chrome.toolbarFrame }
        invalidateCursorRects()
        #if KIDO_STRESS
        stressEvent("place-float", id.description)
        #endif
    }

    private func place(_ chrome: PaneChrome, _ view: PaneView, _ g: Geometry, _ placement: PaneLayout, floating: Bool) {
        let frame: CGRect, grid: CGRect, content: CGRect, insets: PaneLayout.RenderInsets
        if floating {
            frame = floatFrame(chrome.pane, g, placement)
            grid = CGRect(origin: CGPoint(x: frame.minX + placement.before.width, y: frame.minY + placement.before.height),
                          size: placement.grid(g).size)
            content = grid
            insets = .init()
        } else {
            let tiled = placement.tiled(g, alternate: view.alternate)
            (frame, grid, content, insets) = (tiled.chrome, tiled.grid, tiled.content, tiled.insets)
        }
        if chrome.frame != frame { chrome.frame = frame }
        view.renderInsets = insets
        if view.frame != content { view.frame = content }
        chrome.content = content.offsetBy(dx: -frame.minX, dy: -frame.minY)
        chrome.drag = floating && !zoomed ? { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0) } : nil
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = floating ? floatingRadius : 0
        chrome.layer?.masksToBounds = floating
        if floating {
            let mask = view.layer?.mask as? CAShapeLayer ?? CAShapeLayer()
            let rect = chrome.bounds.offsetBy(dx: chrome.frame.minX - grid.minX, dy: grid.maxY - chrome.frame.maxY)
            if mask.path?.boundingBoxOfPath != rect {
                mask.path = CGPath(roundedRect: rect, cornerWidth: floatingRadius, cornerHeight: floatingRadius, transform: nil)
            }
            if view.layer?.mask !== mask { view.layer?.mask = mask }
        } else if content.minY < placement.topLine.maxY {
            let mask = view.layer?.mask as? CAShapeLayer ?? CAShapeLayer()
            let rect = CGRect(x: 0, y: 0, width: content.width, height: max(0, content.maxY - placement.topLine.maxY))
            mask.path = CGPath(rect: rect, transform: nil)
            view.layer?.mask = mask
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
        if show, let view = panes.first(where: { $0.pane == chrome.pane }) {
            let toolbar = self.toolbar ?? PaneToolbar()
            self.toolbar = toolbar
            if toolbar.superview !== chrome { toolbar.removeFromSuperview(); chrome.addSubview(toolbar) }
            toolbar.frame = chrome.toolbarFrame
            toolbar.update(command: { view.onSelect(); view.onCommand($0) }, zoomed: zoomed, drag: { [weak self, pane = chrome.pane] in self?.beginDrag(pane, $0) })
        }
        guard let toolbar, toolbar.superview === chrome else { return }
        invalidateCursorRects()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            toolbar.animator().alphaValue = show ? 1 : 0
        }
    }

    private var pixel: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    private var placement: PaneLayout? {
        guard let shown, let cell = session?.cell else { return nil }
        return PaneLayout(root: shown.visible.root, bounds: bounds, cell: cell, pixel: pixel)
    }

    func cellChanged() {
        guard hot, !isHidden else { return }
        place(resizeGrids: true)
        sizeClient()
    }

    private func makePane(_ id: PaneID) -> PaneView? {
        guard let view = PaneView(
            runtime: runtime, pane: id, font: session?.font ?? 0,
            onInput: { [weak connection] in connection?.sendKeys(id, $0) })
        else { return nil }
        view.onSelect = { [weak self] in
            guard let self else { return }
            var commands = [Command("select-pane", "-t", id)]
            if case .floating(let z) = self.shown?.visible.root.panes.first(where: { $0.id == id })?.layer, z > 0 {
                commands.append(Command("move-pane", "-t", id, "-z", 0))
            }
            self.sendPane(commands)
        }
        view.onCommand = { [weak self] command in
            guard let connection = self?.connection,
                let tmux = command.command(id, cell: self?.session?.cell ?? .zero, model: connection.model)
            else { return }
            if case .clear = command {
                connection.sync(id, first: [tmux, Command("clear-history", "-t", id)])
            } else { self?.sendPane([tmux]) }
        }
        view.onAlternateChange = { [weak self] in self?.place() }
        view.onCellChange = { [weak self] in self?.session?.cellChanged() }
        view.onFontChange = { [weak self] in self?.session?.fontChanged($0) }
        view.onResync = { [weak connection] in connection?.syncResize(id) ?? false }
        view.onGridFailure = { [weak connection] in connection?.gridFailed() }
        return view
    }

    private func box(_ frame: CGRect, border: CGFloat, fill: NSColor) -> NSBox {
        let box = NSBox(frame: frame)
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = border
        box.borderColor = .gray
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
    private enum Delivery { case idle, sending(pending: [Command]?) }
    private var delivery = Delivery.idle
    private var lastFloatCommand: [Command]?

    private func floatFrame(_ id: PaneID, _ geometry: Geometry, _ placement: PaneLayout) -> CGRect {
        if let liveFrame {
            switch liveFrame {
            case .dragging(let pane, let frame), .settling(let pane, let frame):
                if pane == id { return placement.clamp(frame) }
            }
        }
        if let frame = freeFrames[id], placement.geometry(frame) == geometry { return frame }
        freeFrames[id] = nil
        return placement.frame(geometry)
    }

    private func validateFrames(_ placement: PaneLayout) {
        let mask = layer?.mask as? CAShapeLayer ?? CAShapeLayer()
        mask.path = CGPath(rect: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                                       height: max(0, bounds.height - placement.topLine.maxY)), transform: nil)
        layer?.mask = mask
        if let placed, placed != placement {
            if case .sending = delivery { delivery = .sending(pending: nil) }
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

    private func settleFloat() {
        guard case .settling(let id, let frame) = liveFrame else { return }
        connection?.send([Command("display-message", "-p", "")]) { [weak self] _ in
            guard let self, case .settling(let current, let rect) = self.liveFrame, current == id, rect == frame else { return }
            self.liveFrame = nil
            if !self.zoomed, let placement = self.placement,
               let pane = self.shown?.visible.root.panes.first(where: { $0.id == id && $0.layer != .tiled }),
               placement.geometry(frame) == pane.geometry {
                self.freeFrames[id] = frame
                #if KIDO_STRESS
                self.stressEvent("free-frame-kept", id.description)
                #endif
            }
            if let placement = self.placement { self.placeFloat(id, placement) }
            self.panes.forEach { $0.endResizeIntent() }
        }
    }

    private func floatEdge(_ point: NSPoint) -> (Pane, NSCursor.FrameResizePosition)? {
        guard !zoomed, let placement else { return nil }
        for pane in (shown?.visible.root.panes ?? []).filter({ $0.layer != .tiled }).sorted(by: {
            guard case .floating(let a) = $0.layer, case .floating(let b) = $1.layer else { return false }; return a < b
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

    private func sendPane(_ commands: [Command], done: (@MainActor @Sendable () -> Void)? = nil) {
        connection?.send(commands) { [weak self] replies in
            if let failure = replies?.compactMap({ reply -> String? in
                if case .failure(let lines) = reply { return lines.joined(separator: "\n") }; return nil
            }).first, let window = self?.window {
                #if KIDO_STRESS
                self?.stressEvent("pane-command-failed-command", commands.map(\.line).joined(separator: "; "))
                self?.stressEvent("pane-command-failed", failure)
                #else
                let alert = NSAlert()
                alert.messageText = "Pane command failed"
                alert.informativeText = failure
                alert.beginSheetModal(for: window)
                #endif
            }
            done?()
        }
    }

    private func sendFloat(_ commands: [Command]) {
        guard commands != lastFloatCommand else { return }
        lastFloatCommand = commands
        if case .sending = delivery { delivery = .sending(pending: commands); return }
        delivery = .sending(pending: nil)
        sendPane(commands) { [weak self] in
            guard let self, case .sending(let pending) = self.delivery else { return }
            self.delivery = .idle
            if let pending { self.lastFloatCommand = nil; self.sendFloat(pending) }
            else {
                self.settleFloat()
                if self.liveFrame == nil { self.panes.forEach { $0.endResizeIntent() } }
            }
        }
    }

    private func beginDrag(_ pane: PaneID, _ event: NSEvent) {
        if event.type == .keyDown {
            cancelDrag(); return
        }
        if event.type != .leftMouseDown { updateDrag(event); return }
        guard !zoomed, let pane = shown?.visible.root.panes.first(where: { $0.id == pane }) else { return }
        endDrag()
        if pane.layer != .tiled { panes.first(where: { $0.pane == pane.id })?.onSelect() }
        #if KIDO_STRESS
        stressEvent("drag-started", pane.id.description)
        #endif
        switch pane.layer {
        case .tiled: paneDrag = .tiled(pane.id, event.locationInWindow)
        case .floating:
            guard let placement else { return }
            paneDrag = .floating(pane, event.locationInWindow, floatFrame(pane.id, pane.geometry, placement), nil)
        }
    }

    @objc func cancelDrag() {
        guard paneDrag != nil || drag != nil else { return }
        if case .sending = delivery { delivery = .sending(pending: nil) }
        liveFrame = nil
        place(); endDrag(); focusActive(force: true)
    }

    private func invalidateCursorRects() {
        if paneDrag == nil { window?.invalidateCursorRects(for: self) }
    }

    private func endDrag() {
        guard paneDrag != nil || drag != nil else { return }
        let target = dragWindow ?? window
        if let dragWindow {
            if !background { NSCursor.pop() }
            dragWindow.enableCursorRects()
            self.dragWindow = nil
        }
        if case .dragging = liveFrame { liveFrame = nil }
        paneDrag = nil
        drag = nil
        lastFloatCommand = nil
        preview.rect = nil
        target?.invalidateCursorRects(for: self)
        if !defersRestore { panes.forEach { $0.endResizeIntent() } }
    }

    private func updateDrag(_ event: NSEvent) {
        guard let paneDrag else { return }
        if case .floating(let pane, let origin, let initial, let cursorEdge) = paneDrag {
            let edge = cursorEdge?.layoutEdge
            guard let cell = session?.cell, let placement else { return }
            let dx = event.locationInWindow.x - origin.x
            let dy = origin.y - event.locationInWindow.y
            if edge == nil, lastFloatCommand == nil, hypot(dx, dy) < 4 {
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
            let x = geometry.x, y = geometry.y, width = geometry.width, height = geometry.height
            if dx != 0 || dy != 0 || lastFloatCommand != nil {
                var commands: [Command] = []
                if edge != nil {
                    commands.append(Command("if-shell", "-F", "-t", pane.id, "#{==:#{pane-border-lines},none}",
                        Command("resize-pane", "-t", pane.id, "-x", width, "-y", height).line,
                        Command("resize-pane", "-t", pane.id, "-x", width + 2, "-y", height + 2).line))
                }
                if edge == nil || edge?.left == true || edge?.top == true {
                    commands.append(Command("move-pane", "-t", pane.id,
                        "-X", "#{?#{==:#{pane-border-lines},none},\(x),\(x - 1)}",
                        "-Y", "#{?#{==:#{pane-border-lines},none},\(y),\(y - 1)}"))
                }
                sendFloat(commands)
            }
            if event.type == .leftMouseUp {
                liveFrame = .settling(pane.id, frame)
                endDrag()
                if case .idle = delivery { settleFloat() }
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
            let hit = subviews.reversed().lazy.compactMap { $0 as? PaneChrome }.first { !$0.isHidden && $0.frame.contains(point) }
            if tiled.count > 1, let placement,
               hit == nil || tiled.contains(where: { $0.id == hit?.pane }) {
                let area = tiled.reduce(CGRect.null) { area, pane in
                    area.union(placement.tiled(pane.geometry, alternate: panes.first { $0.pane == pane.id }?.alternate ?? false).chrome)
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
        guard let (zone, _) = drop else { return }
        let command: Command
        switch zone {
        case .centre(let target): command = Command("swap-pane", "-s", source, "-t", target)
        case .pane(let target, let edge), .window(let target, let edge):
            let axis = edge == .left || edge == .right ? "-h" : "-v"
            switch zone {
            case .window where edge == .left || edge == .top:
                command = Command("move-pane", "-s", source, "-t", target, "-f", axis, "-b")
            case .window:
                command = Command("move-pane", "-s", source, "-t", target, "-f", axis)
            default:
                command = edge == .left || edge == .top
                    ? Command("move-pane", "-s", source, "-t", target, axis, "-b")
                    : Command("move-pane", "-s", source, "-t", target, axis)
            }
        }
        #if KIDO_STRESS
        stressEvent("drag-completed", command.line)
        #endif
        sendPane([command])
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
            guard let placement else { return }
            paneDrag = .floating(pane, event.locationInWindow, floatFrame(pane.id, pane.geometry, placement), edge)
            panes.first(where: { $0.pane == pane.id })?.beginResizeIntent()
            #if KIDO_STRESS
            stressEvent("edge-resize-started", pane.id.description)
            #endif
            panes.first(where: { $0.pane == pane.id })?.onSelect()
            window?.makeFirstResponder(self)
            return
        }
        guard let placement else { return }
        drag = shown?.visible.root.dividers.first { hitArea($0, placement).contains(point) }
            .map { ($0, point, $0.direction == .leftRight ? $0.geometry.x : $0.geometry.y) }
        if drag != nil { panes.forEach { $0.beginResizeIntent() } }
    }

    override func mouseDragged(with event: NSEvent) {
        if paneDrag != nil { updateDrag(event); return }
        guard let drag, let cell = session?.cell else { return }
        let point = convert(event.locationInWindow, from: nil)
        let position = drag.divider.direction == .leftRight
            ? drag.divider.geometry.x + Int(((point.x - drag.origin.x) / cell.width).rounded())
            : drag.divider.geometry.y + Int(((point.y - drag.origin.y) / cell.height).rounded())
        guard position != drag.position, let command = drag.divider.resize(to: position) else { return }
        self.drag = (drag.divider, drag.origin, position)
        connection?.send([command])
    }

    override func mouseUp(with event: NSEvent) {
        if paneDrag != nil { updateDrag(event) }
        if drag != nil {
            dividerDrain = true
            drag = nil
            connection?.send([Command("display-message", "-p", "")]) { [weak self] _ in
                self?.dividerDrain = false
                self?.panes.forEach { $0.endResizeIntent() }
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, paneDrag != nil {
            cancelDrag()
        }
        else { super.keyDown(with: event) }
    }

    override func resetCursorRects() {
        guard let placement else { return }
        var covered: [CGRect] = []
        func add(_ rect: CGRect, _ cursor: NSCursor) {
            for rect in rect.intersection(bounds).subtracting(covered) { addCursorRect(rect, cursor: cursor) }
        }
        if !zoomed {
            for pane in (shown?.visible.root.panes ?? []).filter({ $0.layer != .tiled }).sorted(by: {
                guard case .floating(let a) = $0.layer, case .floating(let b) = $1.layer else { return false }; return a < b
            }) {
                let r = floatFrame(pane.id, pane.geometry, placement)
                defer { covered.append(r) }
                if case .floating(let moving, _, _, nil) = paneDrag, moving.id == pane.id,
                   case .dragging = liveFrame {
                    add(r, .closedHand)
                    continue
                }
                if let chrome = subviews.compactMap({ $0 as? PaneChrome }).first(where: { $0.pane == pane.id }) {
                    for rect in chrome.padding { add(convert(rect, from: chrome), .openHand) }
                }
                for (position, rect) in floatEdges(r) {
                    add(rect, .frameResize(position: position, directions: .all))
                }
            }
        }
        for d in shown?.visible.root.dividers ?? [] {
            add(hitArea(d, placement), d.direction == .leftRight ? .resizeLeftRight : .resizeUpDown)
        }
    }

    func debugResize(_ reason: @autoclosure () -> String, pane: PaneID? = nil) {
        guard debugging else { return }
        let sizes = Dictionary(uniqueKeysWithValues: (shown?.visible.root.panes ?? []).map { ($0.id, $0.geometry) })
        for view in panes where !view.isHidden && (pane == nil || pane == view.pane) {
            let tmux = sizes[view.pane].map { "\($0.width)x\($0.height)" } ?? "none"
            debug("resize t=\(ProcessInfo.processInfo.systemUptime) \(reason()) pane=\(view.pane) tmux=\(tmux) \(view.resizeDebug)")
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        panes.forEach { $0.beginResizeIntent() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        debugResize("live-end")
        connection?.flushSize()
    }

    private func sizeClient() {
        guard !isHidden, let placement else { return }
        connection?.resize(cols: Int(placement.client.width), rows: Int(placement.client.height))
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
        guard !isHidden, let pane = window?.firstResponder as? PaneView, pane.pane != active else { return }
        connection?.send([Command("select-pane", "-t", pane.pane)])
    }
}
