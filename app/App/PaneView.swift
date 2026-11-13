import AppKit
import KoClientKit
import os
import GhosttyKit
import IOSurface
import KoClient
import PaneGeometry
import KoModel
import SidebarFeed

private final class TerminalView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class Overlay: PaneCapsule {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// The surface's size. The grid belongs to the view's decoder thread, which hands it over when it
// applies a resize or a restore. The cell and the pixels belong to main: a font, scale or config change
// refreshes them, and the fork keeps the surface's grid where the server put it.
struct SurfaceGeometry {
    private(set) var columns: UInt16
    private(set) var rows: UInt16
    private(set) var pixels: (width: UInt32, height: UInt32)
    private(set) var cell: (width: UInt32, height: UInt32)

    init(_ size: ghostty_surface_size_s) {
        columns = size.columns
        rows = size.rows
        pixels = (size.width_px, size.height_px)
        cell = (size.cell_width_px, size.cell_height_px)
    }

    mutating func handOver(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }

    mutating func refreshCell(_ size: ghostty_surface_size_s) {
        pixels = (size.width_px, size.height_px)
        cell = (size.cell_width_px, size.cell_height_px)
    }
}

final class PaneView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool { acceptsKeyInput && canPerformMenuItem(item) }

    func canPerformMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(promptSelectionItem(_:)): canPrompt()
        case #selector(copySelectionItem(_:)), #selector(NSText.copy(_:)): hasSelection
        case #selector(NSText.selectAll(_:)), #selector(NSText.paste(_:)): copyMode == nil
        case #selector(reloadPage(_:)): webviewView != nil
        case #selector(toggleCopyMode(_:)): !webviewFocused
        case #selector(runCommand(_:)):
            if case .float? = item.representedObject as? PaneCommand { floatTitle().map { item.title = $0 } != nil } else { true }
        case #selector(showFind(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)): true
        default: false
        }
    }

    #if KIDO_VISUAL
    var visualScale: CGFloat?
    var visualKeyUps = 0
    var visualEventMonitor: ((NSEvent) -> NSEvent?)?
    var visualKeyEvents = 0
    var visualBindingQueries = 0
    var visualBindingActions = 0
    var visualTextInputs = 0
    var visualMenuCommands = 0
    @MainActor static var pasteEventTimeout: TimeInterval = 30
    @MainActor static var clipboardTimeout: TimeInterval = 8
    @MainActor static var copyEntryTimeout: TimeInterval = 2
    #else
    static let pasteEventTimeout: TimeInterval = 30
    static let clipboardTimeout: TimeInterval = 8
    static let copyEntryTimeout: TimeInterval = 2
    #endif

    let pane: PaneID
    let born = DispatchTime.now()
    nonisolated let host: Host
    var onURL: (String) -> Void = { _ in }
    var onSelect: () -> Void = {}
    var onCellChange: () -> Void = {}
    var onFontChange: (Float) -> Void = { _ in }
    var onCommand: (PaneCommand) -> Void = { _ in }
    var floatTitle: () -> String? = { nil }
    var onFindChange: () -> Void = {}
    let scroller = PaneScroller()
    var find: PaneFind? { didSet { needsLayout = true; onFindChange() } }
    var canPrompt: () -> Bool = { false }
    var selectionQuote: String? { hasSelection ? readSelection() : nil }
    var onPrompt: (PaneView, String?) -> Void = { _, _ in }
    private(set) var webviewView: WebviewPaneView?
    var inputResponder: NSResponder { if let webviewView { webviewView } else { self } }
    var webviewFocused: Bool {
        guard let webviewView, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: webviewView)
    }
    var chromeViews: [NSView] { [webviewView].compactMap { $0 } + [copyLabel, breadcrumb, runtimePill] + [find].compactMap { $0 } }

    func updateWebview(_ webview: KoSchema.Webview?) {
        guard runtime.values.webview.enabled, let page = webview?.page, let client else { releaseWebview(); return }
        guard !isHiddenOrHasHiddenAncestor || webviewView != nil else { return }
        if webviewView == nil {
            endCopy()
            unmarkText()
            find?.close()
            webviewView = WebviewPaneView(pane: self, client: client)
            terminal.isHidden = true
            needsLayout = true
            if let chrome = copyLabel.superview { chrome.addSubview(webviewView!, positioned: .below, relativeTo: copyLabel) }
            if window?.firstResponder === self { window?.makeFirstResponder(inputResponder) }
        }
        webviewView?.updateTheme()
        webviewView?.update(path: page.path, serving: webview?.serving == true)
    }

    func releaseWebview() {
        guard let webviewView else { return }
        let focused = webviewFocused || find?.focused == true
        find?.close()
        webviewView.close()
        self.webviewView = nil
        terminal.isHidden = false
        needsLayout = true
        if focused { window?.makeFirstResponder(self) }
    }
    enum CopyMode { case entering(DispatchWorkItem), cursor, selecting, lines(anchor: (x: Int, y: Int), cursor: (x: Int, y: Int)) }
    private(set) var copyMode: CopyMode?
    private enum MouseDrag {
        case cell(anchor: (x: Int, y: Int), last: (x: Int, y: Int))
        case word(start: (x: Int, y: Int), end: (x: Int, y: Int), anchor: (x: Int, y: Int), last: (x: Int, y: Int))
        case line(row: Int, last: (x: Int, y: Int))

        var last: (x: Int, y: Int) {
            switch self {
            case .cell(_, let last), .word(_, _, _, let last), .line(_, let last): last
            }
        }

        func moved(to cell: (x: Int, y: Int)) -> MouseDrag {
            switch self {
            case .cell(let anchor, _): .cell(anchor: anchor, last: cell)
            case .word(let start, let end, let anchor, _): .word(start: start, end: end, anchor: anchor, last: cell)
            case .line(let row, _): .line(row: row, last: cell)
            }
        }
    }
    private struct CopyPress {
        var cell: (x: Int, y: Int)
        var clickCount: Int
        var latest: (x: Int, y: Int)
        var point: NSPoint
        var selection: ((x: Int, y: Int), (x: Int, y: Int))?

        mutating func move(to point: NSPoint, cell: (x: Int, y: Int)) {
            latest = cell
            self.point = point
        }
    }
    private enum LeftGesture {
        case pending(CopyPress), released(CopyPress), swallowed
        case content(NSPoint, ghostty_hit_s)
    }
    private var mouseDrag: MouseDrag?
    private var leftGesture: LeftGesture?
    private var dragPoint: NSPoint?
    private var autoscroll: Timer?
    var copyFind: (query: String?, older: Bool) = (nil, true)
    private(set) var copyingLines = false
    enum Freeze { case off, entering, frozen }
    private(set) var alternate = false
    var onAlternateChange: () -> Void = {}
    var renderInsets = PaneLayout.RenderInsets() {
        didSet {
            if renderInsets != oldValue {
                ghostty_surface_set_render_insets(surface, UInt32((renderInsets.top * contentScale).rounded()), UInt32((renderInsets.bottom * contentScale).rounded()))
            }
        }
    }
    private(set) var mouseShape = GHOSTTY_MOUSE_SHAPE_TEXT
    private var contentHover = false
    var mouseCursor: NSCursor {
        if contentHover { return .pointingHand }
        return switch mouseShape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING, GHOSTTY_MOUSE_SHAPE_MOVE, GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: .closedHand
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NE_RESIZE, GHOSTTY_MOUSE_SHAPE_SW_RESIZE, GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: .frameResize(position: .topRight, directions: .all)
        case GHOSTTY_MOUSE_SHAPE_NW_RESIZE, GHOSTTY_MOUSE_SHAPE_SE_RESIZE, GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: .frameResize(position: .topLeft, directions: .all)
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY: .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: .dragLink
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: .contextualMenu
        default: .arrow
        }
    }

    weak var cursorHost: WindowView?

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        guard mouseShape != shape else { return }
        mouseShape = shape
        cursorHost?.invalidateCursorRects(for: self)
    }

    var terminalCursorRects: [CGRect] {
        CGRect(x: 0, y: renderInsets.bottom, width: bounds.width,
               height: max(0, bounds.height - renderInsets.top - renderInsets.bottom))
            .subtracting(subviews.filter { $0 !== terminal && !$0.isHidden && $0.alphaValue > 0 }.map(\.frame))
    }

    private let terminal = TerminalView()
    private let copyLabel: Overlay
    private let runtimePill: RuntimePill
    private let breadcrumb: PaneBreadcrumb
    var breadcrumbPath: [ShownPane.Entry] = [] { didSet { breadcrumb.show(breadcrumbPath) } }
    var onShowAncestor: (Snapshot.Position) -> Void = { _ in }
    // Where the pane runs, from the model; the pill shows it and the chrome draws its stripe.
    var runtimeMark: RuntimeMark? { didSet { if runtimeMark != oldValue { showRuntime(); webviewView?.updateTheme() } } }
    var runtimeFocused = true { didSet { if runtimeFocused != oldValue { showRuntime() } } }
    // The hover toolbar covers the pill's corner, so the pill gives way to it.
    var toolbarShown = false { didSet { if toolbarShown != oldValue { needsLayout = true } } }
    private var pressed: Set<Int> = []
    private struct ScrollGeometry {
        var position = ScrollPosition(retainedHistoryRows: 0, offset: 0, rows: 1)
        var captured = false
    }
    private var scrollGeometry = ScrollGeometry()
    private struct OutputUpdate: Sendable {
        let position: ScrollPosition
        let alternate: Bool
        let captured: Bool
    }
    private struct OutputState {
        var latest: OutputUpdate?
        var completed = 0
        var capturing = false
        var requested = false
    }
    nonisolated private let outputUpdate = OSAllocatedUnfairLock(initialState: OutputState())
    #if KIDO_VISUAL
    nonisolated private let decodedBytes = OSAllocatedUnfairLock(initialState: 0)
    nonisolated var visualDecodedBytes: Int { decodedBytes.withLock { $0 } }
    nonisolated(unsafe) var visualAfterScrollerCapture: (@Sendable () -> Void)?
    var visualHoldScrollbarAction = false
    var visualScrollerOffset: Int { scrollGeometry.position.offset }
    var visualScrollerIdle: Bool { outputUpdate.withLock { $0.latest == nil && !$0.capturing && !$0.requested } }
    #endif
    private var scrollPresentation = (position: ScrollPosition(retainedHistoryRows: 0, offset: 0, rows: 1), distance: Optional<Double>.none, revision: 0)
    nonisolated private let target = OSAllocatedUnfairLock<Double?>(initialState: nil)
    nonisolated private let scrolling = DispatchQueue(label: "kido.scroll", qos: .userInteractive)
    nonisolated private let viewport = OSAllocatedUnfairLock(initialState: 0)
    nonisolated var scrollTarget: Int? { target.withLock { $0.map { Int($0.rounded(.up)) } } }
    nonisolated private var scrollDistance: Double? { target.withLock { $0 } }
    private var suppressMomentum = false
    nonisolated private let scrollIntent = OSAllocatedUnfairLock(initialState: 0)
    nonisolated var scrollRevision: Int { scrollIntent.withLock { $0 } }
    @discardableResult nonisolated private func invalidateScroll() -> Int {
        scrollIntent.withLock { $0 += 1; return $0 }
    }
    private var scrollPending: Int?
    private var scrollRender = false
    nonisolated var frozen: Bool { content.withLock { $0.freeze != .off } }
    private var resizeIntent = false
    private var renderSequence: UInt64 = 0
    private var wheelRemainder = 0.0
    private var wheelOwner: ghostty_wheel_disposition_e?
    private var rowHeight: CGFloat = 1
    @objc func reloadPage(_ sender: Any? = nil) { webviewView?.browser.reload() }

    @objc func showFind(_ sender: Any? = nil) {
        if case .entering = copyMode { return }
        snapScroll()
        openFind(navigate: false)
        window?.makeFirstResponder(find?.field)
    }

    private func openFind(navigate: Bool) {
        guard find == nil else { return }
        let bar = PaneFind(self, runtime: runtime)
        find = bar
        guard let query = copyFind.query else { return }
        copyFind.query = nil
        bar.field.stringValue = query
        bar.search(navigate: navigate)
    }

    static func owner(_ responder: NSResponder?) -> PaneView? {
        var view = responder as? NSView
        while let current = view {
            if let pane = current as? PaneView { return pane }
            view = (current as? PaneFind)?.pane ?? (current as? WebviewPaneView)?.pane ?? current.superview
        }
        return nil
    }

    @objc func findNext(_ sender: Any? = nil) { snapScroll(); find?.next() }
    @objc func findPrevious(_ sender: Any? = nil) { snapScroll(); find?.previous() }


    struct ScrollPosition: Sendable {
        let retainedHistoryRows: Int
        let offset: Int
        let rows: Int
    }

    nonisolated func scrollPosition() -> ScrollPosition {
        var value = ghostty_surface_scrollbar_s()
        _ = ghostty_surface_scrollbar(surface, &value)
        return ScrollPosition(retainedHistoryRows: max(0, Int(value.total) - Int(value.len)), offset: Int(value.offset), rows: Int(value.len))
    }

    nonisolated private func scrollPosition(distance: Double) -> (position: ScrollPosition, viewportDelta: Int)? {
        var value = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &value) else { return nil }
        for attempt in 0..<3 {
            let top = max(0, Double(value.total - value.len) - distance)
            let row = floor(top)
            let pixels = Float(top - row) * Float(ghostty_surface_size(surface).cell_height_px)
            var delta: Int64 = 0
            if ghostty_surface_scroll_to_row_pixel_if_revision(surface, UInt64(row), pixels, value.row_space_revision, &value, &delta) {
                debug("scroll-apply pane=\(pane) time=\(CACurrentMediaTime()) distance=\(distance) row=\(value.offset) pixel=\(pixels) goal=\(scrollDistance ?? distance) history=\(value.total - value.len)")
                return (ScrollPosition(retainedHistoryRows: max(0, Int(value.total) - Int(value.len)), offset: Int(value.offset), rows: Int(value.len)), Int(delta))
            }
            guard attempt < 2, ghostty_surface_scrollbar(surface, &value) else { return nil }
        }
        return nil
    }

    nonisolated func scroll(to row: Int) {
        var value = ghostty_surface_scrollbar_s()
        clearScrollTarget()
        guard ghostty_surface_scrollbar(surface, &value) else { return }
        var delta: Int64 = 0
        _ = ghostty_surface_scroll_to_row_pixel_if_revision(surface, UInt64(row), 0, value.row_space_revision, &value, &delta)
    }

    func refreshScroller() {
        updateScroller(position: scrollPosition(), alternate: ghostty_surface_is_alternate_screen(surface))
    }

    private func updateScroller(position: ScrollPosition, alternate: Bool) {
        #if KIDO_VISUAL
        visualScrollerRefreshes += 1
        #endif
        let changed = self.alternate != alternate || scrollGeometry.position.retainedHistoryRows != position.retainedHistoryRows
            || scrollGeometry.position.rows != position.rows || (scrollTarget == nil && scrollGeometry.position.offset != position.offset)
        guard changed else { return }
        invalidateScroll()
        updateAlternate(alternate)
        scrollGeometry.position = position
        if alternate { clearScrollTarget() }
        queueScroll()
    }

    private func rendered(_ token: UInt64, status: ghostty_render_presentation_status_e) {
        #if KIDO_VISUAL
        visualFrames.removeValue(forKey: token)?(status)
        #endif
    }

    private func presentScroll() {
        let (position, applied, _) = scrollPresentation
        let distance = applied ?? Double(position.retainedHistoryRows - position.offset)
        scroller.update(history: position.retainedHistoryRows, rows: position.rows,
                        offset: Double(position.retainedHistoryRows) - distance, alternate: alternate)
    }

    func requestScroll(_ distance: Int) {
        suppressMomentum = true
        wheelRemainder = 0
        requestScrollDistance { _ in Double(distance) }
    }

    private func requestScrollDistance(snapshot: ScrollPosition? = nil, _ move: @Sendable (Double) -> Double) {
        let snapshot = snapshot ?? scrollPosition()
        let position = Double(snapshot.retainedHistoryRows - snapshot.offset)
        let limit = Double(snapshot.retainedHistoryRows)
        let previous = scrollDistance ?? position
        let distance = max(0, min(limit, move(previous)))
        guard distance != previous else { return }
        invalidateScroll()
        target.withLock { $0 = distance }
        scrollRender = true
        queueScroll()
    }

    private func queueScroll() {
        guard scrollPending == nil else { return }
        let revision = scrollRevision
        scrollPending = revision
        scrolling.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { _ = self } }
            let (distance, moved) = viewport.withLock { _ in
                let distance = scrollDistance
                let moved = if let distance { scrollPosition(distance: distance)?.position } else { scrollPosition() }
                return (distance, moved)
            }
            DispatchQueue.main.async {
                guard self.scrollPending == revision else { return }
                self.scrollPending = nil
                if self.scrollRevision != revision { self.queueScroll(); return }
                let render = self.scrollRender
                self.scrollRender = false
                if let moved {
                    self.scrollGeometry.position = moved
                    self.scrollPresentation = (moved, distance, revision)
                    self.presentScroll()
                    if render, self.presented.visible, self.window?.firstResponder !== self {
                        _ = ghostty_surface_request_render_with_token(self.surface, 0)
                    }
                }
                if self.scrollDistance != distance { self.queueScroll() }
            }
        }
    }

    nonisolated func clearScrollTarget() { target.withLock { $0 = nil } }

    private func prepareScrollSnap() -> Int {
        suppressMomentum = true
        wheelRemainder = 0
        return invalidateScroll()
    }

    func snapScroll() {
        let revision = prepareScrollSnap()
        let applied = viewport.withLock { adjustment -> (ScrollPosition, Double)? in
            guard let distance = scrollDistance else { return nil }
            let aligned = distance.rounded()
            target.withLock { $0 = aligned }
            guard let moved = scrollPosition(distance: aligned) else { return nil }
            adjustment += moved.viewportDelta
            return (moved.position, aligned)
        }
        if let (moved, aligned) = applied {
            scrollGeometry.position = moved
            scrollPresentation = (moved, aligned, revision)
        }
        presentScroll()
    }

    #if KIDO_STRESS || KIDO_VISUAL
    var visualCopyLabel: String? { copyLabel.isHidden ? nil : (copyLabel.subviews[0] as? NSTextField)?.stringValue }
    var visualPressed: Int { pressed.count }
    var wheelRowHeight: CGFloat { rowHeight }
    var wheelDistance: Double? { scrollDistance }
    #if KIDO_VISUAL
    var renderedImage: CGImage? {
        guard let io = installedSurface, let pixels = renderedPixels,
              let provider = CGDataProvider(data: pixels as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: IOSurfaceGetWidth(io), height: IOSurfaceGetHeight(io), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: IOSurfaceGetWidth(io) * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    #endif
    var renderedPixels: Data? {
        guard let io = installedSurface else { return nil }
        IOSurfaceLock(io, .readOnly, nil)
        defer { IOSurfaceUnlock(io, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(io)
        var data = Data()
        for row in 0..<IOSurfaceGetHeight(io) {
            data.append(base.advanced(by: row * IOSurfaceGetBytesPerRow(io)).assumingMemoryBound(to: UInt8.self), count: IOSurfaceGetWidth(io) * 4)
        }
        return data
    }
    #endif

    #if KIDO_VISUAL
    private(set) var visualSwallowedDrags = 0
    #endif

    func resetScroll() {
        snapScroll()
        let revision = invalidateScroll()
        clearScrollTarget()
        let moved = viewport.withLock { adjustment -> ScrollPosition? in
            guard let moved = scrollPosition(distance: 0) else { return nil }
            adjustment += moved.viewportDelta
            return moved.position
        }
        if let moved {
            scrollGeometry.position = moved
            scrollPresentation = (moved, nil, revision)
        }
        presentScroll()
    }

    private func updateAlternate(_ alternate: Bool) {
        guard self.alternate != alternate else { return }
        if case .entering = copyMode {} else { endCopy() }
        self.alternate = alternate
        note("pane \(pane) alternate screen=\(alternate)")
        onAlternateChange()
        resetScroll()
        find?.search()
    }

    override func layout() {
        super.layout()
        let drawn = convertFromBacking(NSSize(width: Int(geometry.pixels.width), height: Int(geometry.pixels.height)))
        let height = drawn.height + renderInsets.top + renderInsets.bottom
        terminal.frame = NSRect(x: 0, y: bounds.height - height, width: drawn.width, height: height)
        rowHeight = cell.height
        presentScroll()
        guard let parent = copyLabel.superview else { return }
        let chrome = parent.bounds
        if let webviewView, let paneChrome = parent as? PaneChrome {
            var interior = chrome.insetBy(dx: 1, dy: 1)
            if paneChrome.runtimeMark != nil {
                interior.origin.y = max(interior.minY, PaneChrome.stripeBand)
                interior.size.height = max(0, chrome.maxY - 1 - interior.minY)
            }
            webviewView.frame = parent.convert(bounds, from: self).intersection(interior)
        }
        let capsule = min(420, max(200, chrome.width - 16))
        find?.frame = NSRect(x: chrome.width - 8 - capsule, y: 8, width: capsule, height: 32)
        let copy = copyLabel.subviews[0]
        copy.frame = NSRect(origin: NSPoint(x: 7, y: 4), size: copy.fittingSize)
        let copyWidth = copy.frame.width + 14
        let crumbX = copyMode == nil ? 8 : 8 + copyWidth + 6
        let obstacles = parent.subviews.filter { ($0 is PaneFind || ($0 is PaneToolbar && toolbarShown)) && !$0.isHidden }
        let right = obstacles.map { $0.frame.minX - 6 }.min() ?? chrome.width - 8
        let y: CGFloat = !obstacles.isEmpty && right - crumbX < 72 ? 48 : 8
        copyLabel.frame = NSRect(x: 8, y: y, width: copyWidth, height: 22)
        let width = runtimePill.fittingWidth
        runtimePill.frame = NSRect(x: chrome.width - 8 - width, y: 8, width: width, height: RuntimePill.height)
        let available = max(0, (y == 48 ? chrome.width - 8 : right) - crumbX)
        runtimePill.isHidden = runtimeMark == nil || find != nil || toolbarShown
            || (copyMode != nil && runtimePill.frame.minX < copyLabel.frame.maxX + 8)
            || (!breadcrumbPath.isEmpty && available - breadcrumb.minimumWidth < width + 6)
        let crumbWidth = breadcrumb.fit(max(0, available - (runtimePill.isHidden ? 0 : width + 6)))
        breadcrumb.isHidden = crumbWidth == 0
        breadcrumb.frame = NSRect(x: crumbX, y: y, width: crumbWidth, height: 22)
    }

    private func showRuntime() {
        runtimePill.show(runtimeMark, focused: runtimeFocused)
        needsLayout = true
    }

    // Freed in deinit, so the last reference must be dropped on the main
    // thread, after the view that feeds it closed.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t!

    // The surface's size as main knows it: layout never reads the surface while the decoder may write it.
    private(set) var geometry = SurfaceGeometry(ghostty_surface_size_s())

    // The pane's view on the server: its decoder thread is the only writer of the surface's terminal.
    private(set) var koView: KoView?
    private var inputFailure: ko_code?
    private(set) var restoring = false
    // Copy mode freezes the surface: the feed that arrives meanwhile is dropped and asks for a
    // new snapshot when copy mode ends. `parsing` counts the feeds that run.
    nonisolated private let content = OSAllocatedUnfairLock(initialState: (freeze: Freeze.off, parsing: 0, dirty: false))

    private var installedSurface: IOSurfaceRef? {
        for layer in [terminal.layer].compactMap({ $0 }) + (terminal.layer?.sublayers ?? []) {
            guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { continue }
            return (contents as! IOSurfaceRef)
        }
        return nil
    }

    private var installedPixels: CGSize? {
        installedSurface.map { CGSize(width: IOSurfaceGetWidth($0), height: IOSurfaceGetHeight($0)) }
    }

    var resizeDebug: String {
        let size = ghostty_surface_size(surface)
        let io = installedPixels.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"
        return "frame=\(frame) grid=\(size.columns)x\(size.rows) inset=\((renderInsets.top * contentScale).rounded())px visible=\(presented.visible) io=\(io)"
    }

    #if KIDO_VISUAL || KIDO_STRESS
    func wheelEvent(y: Int32, x: Int32 = 0, precise: Bool = true, shift: Bool = false, band: Int = 0, momentum: Int64 = 0) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                               wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0),
              let initial = NSEvent(cgEvent: cg) else { return nil }
        cg.flags = shift ? .maskShift : []
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let local = NSPoint(x: cell.width / 2, y: band > 0 ? bounds.height - renderInsets.top / 2
            : band < 0 ? renderInsets.bottom / 2 : bounds.height - renderInsets.top - cell.height / 2)
        let point = convert(local, to: nil)
        cg.location = CGPoint(x: cg.location.x + point.x - initial.locationInWindow.x,
                              y: cg.location.y - point.y + initial.locationInWindow.y)
        return NSEvent(cgEvent: cg)
    }
    #endif

    #if KIDO_VISUAL
    // What the surface writes, for a pane that no server view feeds.
    var visualInput: ((Data) -> Void)?
    var visualDroppedWhileFrozen: Bool { content.withLock { $0.dirty } }
    // The bytes that frozen copy mode dropped.
    nonisolated let visualDropped = OSAllocatedUnfairLock(initialState: 0)
    // The OSC 2 titles that the surface parsed: fences for what a test wrote to the pane.
    var visualTitles: [String] = []
    // What the surface sent to the server, and the snapshots that it restored.
    var visualSent: [Data] = []
    var visualRestores = 0
    var visualClipboardPending: Bool { clipboard != nil }
    var visualPendingImageFrames: Int { surface.kittyPendingFrames.count }
    var visualText: String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text), let bytes = text.text else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }
    // Holds copy mode in its entry, as a feed that runs would.
    var visualHoldCopyEntry = false
    func visualReleaseCopyEntry() {
        visualHoldCopyEntry = false
        completeEntry()
    }
    var visualBeeps = 0
    var visualScrollerRefreshes = 0
    var visualCaptured: Bool { scrollGeometry.captured }
    var visualPasteEventExpired: Bool { pasteEvent.map { DispatchTime.now() >= $0.deadline } ?? true }
    func visualRefuseInput() { acceptingInput = false }
    static var renderOffscreen = false
    private var visualFrames: [UInt64: (ghostty_render_presentation_status_e) -> Void] = [:]
    var visualInstalledPixels: CGSize? { installedPixels }
    var visualResizeIntent: Bool { resizeIntent }
    var visualTerminalFrame: CGRect { terminal.frame }
    var visualTerminalHidden: Bool { terminal.layer?.isHidden == true }
    var visualScrollerRows: Int { scrollGeometry.position.retainedHistoryRows }
    var visualReady: Bool {
        !restoring && scrollPending == nil
    }
    var visualState: String {
        "insets=\(renderInsets.top),\(renderInsets.bottom) find=\(find != nil) alternate=\(alternate) scroll=\(String(describing: scrollDistance))"
    }
    func visualScroll(_ distance: Double) { requestScrollDistance { _ in distance } }
    func visualFrame(_ completion: @escaping (ghostty_render_presentation_status_e) -> Void) {
        renderSequence += 1
        let token = renderSequence
        visualFrames[token] = completion
        if !ghostty_surface_request_render_with_token(surface, token) {
            visualFrames.removeValue(forKey: token)?(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED)
        }
    }
    #endif

    private var imageLimit: UInt64?
    private var images: PaneImages?
    func retryImages() { images?.retry() }
    private var presented = (visible: true, realized: true)
    private var eventMonitor: Any?
    private var paste: (alert: NSAlert, state: UnsafeMutableRawPointer?)?
    let runtime: GhosttyRuntime
    private var clipboard: (read: KoClipboardRead, timeout: DispatchWorkItem?, deadline: DispatchTime)?
    private weak var client: KoClient?
    private var pasteEvent: (changeCount: Int, deadline: DispatchTime, text: String?)?
    private(set) var acceptingInput = true
    private var acceptsKeyInput: Bool { acceptingInput && (window as? OwnerWindow)?.allowsPaneInput != false }
    private(set) var disposed = false

    func dispose() {
        releaseWebview()
        guard !disposed else { return }
        disposed = true
        _ = (window?.delegate as? WindowOwner)?.cancelUploads(self)
        invalidateClipboard()
        images?.stop()
        detach()
        find?.close()
        stopAutoscroll()
        if let paste {
            self.paste = nil
            complete(paste.state, "")
            paste.alert.window.sheetParent?.endSheet(paste.alert.window)
        }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
    }

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?

    // Ghostty calls back on its renderer and IO threads too, where a strong
    // reference to the view could be its last.
    nonisolated static func onMain(_ userdata: UnsafeMutableRawPointer?, _ body: @escaping @MainActor (PaneView) -> Void) {
        Unmanaged<PaneView>.fromOpaque(userdata!)._withUnsafeGuaranteedRef { view in
            DispatchQueue.main.async { [weak view] in guard let view, !view.disposed else { return }; body(view) }
        }
    }

    init?(runtime: GhosttyRuntime, pane: PaneID, font: Float, host: Host = .local) {
        self.runtime = runtime
        self.pane = pane
        self.host = host
        copyLabel = Overlay(runtime: runtime, radius: 8)
        runtimePill = RuntimePill(runtime: runtime)
        breadcrumb = PaneBreadcrumb(runtime: runtime)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.masksToBounds = true
        terminal.frame = bounds
        addSubview(terminal)
        var config = ghostty_surface_config_new()
        let this = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = this
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(terminal).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = font
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.kitty_clipboard = false
        config.kitty_image_media = GHOSTTY_IMAGE_MEDIA_DIRECT
        config.io_write_userdata = this
        // Called on the reader or Ghostty's IO thread; a strong reference
        // taken there could be the view's last.
        config.io_write_cb = { userdata, bytes, count in
            guard let bytes, count > 0 else { return }
            let data = Data(bytes: bytes, count: Int(count))
            PaneView.onMain(userdata) { pane in
                guard pane.acceptingInput else { return pane.inputFailed(KO_ERR_REFUSED) }
                #if KIDO_VISUAL
                if let input = pane.visualInput { return input(data) }
                pane.visualSent.append(data)
                #endif
                guard let view = pane.koView else { return pane.inputFailed(KO_ERR_CLOSED) }
                do {
                    try view.text(data)
                    pane.inputFailure = nil
                } catch {
                    pane.inputFailed((error as? KoError)?.code ?? KO_ERR_IO)
                }
            }
        }
        guard let surface = ghostty_surface_new(runtime.app, &config) else { return nil }
        self.surface = surface
        geometry = SurfaceGeometry(ghostty_surface_size(surface))
        // Ghostty does not mark config.font_size as adjusted; a reload replaces it.
        if font > 0 { setFontSize(font) }
        syncFocus()
        _ = ghostty_surface_set_render_presented_callback(surface, { @Sendable userdata, token in
            PaneView.onMain(userdata) { $0.rendered(token, status: GHOSTTY_RENDER_PRESENTATION_PRESENTED) }
        }, this)
        _ = ghostty_surface_set_render_failed_callback(surface, { @Sendable userdata, token, status in
            PaneView.onMain(userdata) { $0.rendered(token, status: status) }
        }, this)
        scroller.alphaValue = 0
        scroller.isHidden = true
        scroller.begin = { [weak self] in self?.snapScroll() }
        scroller.jump = { [weak self] in self?.requestScroll($0) }
        copyLabel.addSubview(NSTextField(labelWithString: ""))
        copyLabel.isHidden = true
        breadcrumb.pane = self
        breadcrumb.showAncestor = { [weak self] in self?.onShowAncestor($0) }
        breadcrumb.isHidden = true
        runtimePill.pane = self
        runtimePill.isHidden = true
        ghostty_surface_set_color_scheme(surface, runtime.colorScheme)
        // The callback must not reenter the surface (ghostty.h).
        _ = ghostty_surface_set_font_size_action_callback(surface, { userdata, _, _, points, _, _ in
            PaneView.onMain(userdata) { pane in
                pane.reflow { pane.onFontChange(points) }
            }
        }, this)
        updateTrackingAreas()
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        // AppKit sends no keyUp through the responder chain while Command is
        // held, and delivers no first click to a view without acceptsFirstMouse
        // (SurfaceView_AppKit.swift, localEventLeftMouseDown).
        let monitor: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self, let window, event.window === window else { return event }
            switch event.type {
            case .leftMouseDown:
                if let webviewView, window.attachedSheet == nil,
                   let hit = window.contentView?.superview?.hitTest(event.locationInWindow), hit.isDescendant(of: webviewView) {
                    onSelect()
                    window.makeFirstResponder(inputResponder)
                    syncFocus()
                    return event
                }
                if acceptsKeyInput, window.attachedSheet == nil, !(NSApp.isActive && window.isKeyWindow), window.firstResponder !== self,
                   window.contentView?.superview?.hitTest(event.locationInWindow) === self {
                    window.makeFirstResponder(self)
                    onSelect()
                }
                return event
            default:
                guard acceptsKeyInput, event.modifierFlags.contains(.command), window.firstResponder === self else { return event }
                keyUp(with: event)
                return nil
            }
        }
        #if KIDO_VISUAL
        visualEventMonitor = monitor
        #endif
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown], handler: monitor)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            guard let surface else { return }
            images?.stop()
            if let paste {
                complete(paste.state, "")
                paste.alert.window.sheetParent?.endSheet(paste.alert.window)
            }
            ghostty_surface_free(surface)
        }
    }

    // The view feeds the surface from its decoder thread, which gives the grid the snapshot's size
    // and then the server's resizes.
    func attach(_ client: KoClient) {
        guard koView == nil, !disposed else { return }
        restoring = true
        if let limit = client.kittyImagesMaxBytes, limit != imageLimit {
            imageLimit = limit
            applyConfig()
            if font > 0 { setFontSize(font) }
        }
        self.client = client
        let pane = pane
        let images = PaneImages(surface: surface!, local: host == .local, fetches: client.imageFetches) { image, frame, generation, acceptShm in
            try client.image(pane: pane, image: image, frame: frame, generation: generation, acceptShm: acceptShm)
        }
        self.images?.stop()
        self.images = images
        // The server's resize sets the grid on the decoder thread; copy mode does not outlive it.
        nonisolated(unsafe) let surface = surface!
        let hooks = KoViewHooks(bytes: { [weak self] bytes in self?.feed(bytes) }, afterFeed: { [weak self] item in
            if item.kind == Int32(KO_FEED_BYTES) { images.surfaceChanged() }
            guard item.kind == Int32(KO_FEED_RESIZE) else { return }
            let size = ghostty_surface_size(surface)
            DispatchQueue.main.async {
                self?.geometry.handOver(columns: size.columns, rows: size.rows)
                self?.refreshCell()
                self?.endCopy()
                self?.refreshScroller()
            }
        }, afterRestore: { [weak self] _ in
            images.surfaceChanged()
            let size = ghostty_surface_size(surface)
            DispatchQueue.main.async {
                self?.geometry.handOver(columns: size.columns, rows: size.rows)
                self?.refreshCell()
            }
        })
        do {
            koView = try client.openView(pane: pane, surface: surface, hooks: hooks) { [weak self] event in self?.viewEvent(event) }
        } catch {
            restoring = false
            note("view of \(pane) did not open: \(error)")
        }
    }

    // ko_view_close waits for a restore or a feed that runs, so it runs on a utility queue; the
    // surface stays alive until it returned.
    func detach() {
        guard let view = koView else { return }
        koView = nil
        restoring = false
        DispatchQueue.global(qos: .utility).async {
            view.close()
            DispatchQueue.main.async { _ = self }
        }
    }

    private func inputFailed(_ code: ko_code) {
        guard inputFailure != code else { return }
        inputFailure = code
        let reason = code == KO_ERR_CLOSED ? "view closed" : String(cString: ko_code_message(Int32(code.rawValue)))
        note("input to \(pane) dropped: \(reason)")
    }

    private func viewEvent(_ event: KoViewEvent) {
        switch event {
        case .restored(let generation, let result):
            note("view of \(pane) restored generation=\(generation) result=\(result.rawValue)")
            #if KIDO_VISUAL
            visualRestores += 1
            #endif
            restoring = false
            if result != GHOSTTY_SNAPSHOT_RESTORE_OK { note("restore of \(pane) ended with \(result.rawValue)") }
            refreshScroller()
            queueScroll()
            completeEntry()
            needsLayout = true
        case .closed(_, let message):
            note("view of \(pane) closed: \(message)")
            detach()
        case .link(let code, let message):
            if code == KO_OK {
                inputFailure = nil
                note("view of \(pane) up")
            } else {
                note("view of \(pane) lost: \(message)")
            }
        }
    }

    @discardableResult nonisolated func feed(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let admitted = content.withLock { state in
            guard state.freeze == .off else { state.dirty = true; return false }
            state.parsing += 1
            return true
        }
        guard admitted else {
            #if KIDO_VISUAL
            let count = bytes.count
            visualDropped.withLock { $0 += count }
            #endif
            return false
        }
        return scrolling.sync {
            let pinned = viewport.withLock { adjustment in
                scrollDistance.map { $0 > 0 } == true ? (scrollPosition(), adjustment) : nil
            }
            if let base = bytes.baseAddress {
                ghostty_surface_process_output(surface, base.assumingMemoryBound(to: CChar.self), UInt(bytes.count))
            }
            if let (pinned, before) = pinned {
                viewport.withLock { adjustment in
                    let position = scrollPosition()
                    let delta = (position.retainedHistoryRows - position.offset) - (pinned.retainedHistoryRows - pinned.offset) - (adjustment - before)
                    target.withLock {
                        if let distance = $0, distance > 0 { $0 = max(0, distance + Double(delta)) }
                    }
                }
            }
            #if KIDO_VISUAL
            let count = bytes.count
            decodedBytes.withLock { $0 += count }
            #endif
            publishOutputUpdate(completed: 1)
            return true
        }
    }

    func refreshScrollerAfterRender() {
        guard scrollTarget == nil else { return }
        outputUpdate.withLock { $0.requested = true }
        captureScrollerIfNeeded()
    }

    private func captureScrollerIfNeeded() {
        guard !disposed, scrollTarget == nil, outputUpdate.withLock({ state in
            guard state.latest == nil, !state.capturing, state.requested else { return false }
            state.capturing = true
            return true
        }) else { return }
        scrolling.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { _ = self } }
            publishOutputUpdate(completed: 0)
        }
    }

    nonisolated private func publishOutputUpdate(completed: Int) {
        outputUpdate.withLock { $0.requested = false }
        let update = OutputUpdate(position: scrollPosition(), alternate: ghostty_surface_is_alternate_screen(surface), captured: ghostty_surface_mouse_captured(surface))
        #if KIDO_VISUAL
        visualAfterScrollerCapture?()
        #endif
        let post = outputUpdate.withLock { state in
            let post = state.latest == nil
            state.latest = update
            state.completed += completed
            if completed == 0 { state.capturing = false }
            return post
        }
        if post { DispatchQueue.main.async { [weak self] in self?.applyOutputUpdate() } }
    }

    private func applyOutputUpdate() {
        let (update, completed) = outputUpdate.withLock { state in
            defer { state.latest = nil; state.completed = 0 }
            return (state.latest, state.completed)
        }
        content.withLock { $0.parsing -= completed }
        guard let update else { return }
        updateScroller(position: update.position, alternate: update.alternate)
        if scrollDistance != scrollPresentation.distance { queueScroll() }
        if update.captured != scrollGeometry.captured {
            _ = prepareScrollSnap()
            target.withLock { $0 = $0?.rounded() }
            queueScroll()
        }
        scrollGeometry.captured = update.captured
        completeEntry()
        captureScrollerIfNeeded()
    }

    @discardableResult nonisolated func feed(_ data: Data) -> Bool {
        data.withUnsafeBytes { feed($0) }
    }

    var font: Float { ghostty_surface_font_size(surface) }

    private var contentScale: CGFloat {
        #if KIDO_VISUAL
        if let visualScale { return visualScale }
        #endif
        return window?.backingScaleFactor ?? 2
    }

    var cell: CGSize {
        let size = ghostty_surface_size(surface)
        return NSSize(width: CGFloat(size.cell_width_px) / contentScale, height: CGFloat(size.cell_height_px) / contentScale)
    }

    func beginResizeIntent(gesture: Bool = true) {
        endCopy()
        if gesture { resizeIntent = true }
        snapScroll()
    }

    func endResizeIntent() {
        resizeIntent = false
        presentScroll()
    }

    var shiftedBackground = false { didSet { updatePaper() } }
    var transparentPaper = false {
        didSet { if transparentPaper != oldValue { reloadConfig() } }
    }

    var paperColor: NSColor { shiftedBackground ? runtime.unfocusedPaper : runtime.background }

    func updatePaper() {
        layer?.backgroundColor = paperColor.cgColor
        webviewView?.updateTheme()
    }

    func setFontSize(_ points: Float) {
        let action = "set_font_size:\(points)"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    private func applyConfig() {
        guard let config = ghostty_config_clone(runtime.config) else { return }
        var text = ""
        if transparentPaper { text += "background-opacity = 0\nbackground-opacity-cells = false\n" }
        if let imageLimit { text += "image-storage-limit = \(min(imageLimit, UInt64(UInt32.max)))\n" }
        if !text.isEmpty {
            ghostty_config_load_string(config, text, UInt(text.utf8.count), "/kido-pane")
            ghostty_config_finalize(config)
        }
        ghostty_surface_update_config(surface, config)
        ghostty_config_free(config)
    }

    func reloadConfig(font: Float? = nil) {
        updatePaper()
        reflow { [weak self] in
            guard let self else { return }
            applyConfig()
            if let font { setFontSize(font) }
        }
    }

    // A font change changes the cell, not the grid: the surface keeps the server's grid, and the new
    // pixel size reaches the server as the window's size.
    func reflow(_ change: @escaping @MainActor () -> Void) {
        beginResizeIntent(gesture: false)
        change()
        refreshCell()
    }

    // The surface's cell after a change that main made; the decoder hands over every grid.
    private func refreshCell() {
        geometry.refreshCell(ghostty_surface_size(surface))
        needsLayout = true
    }

    // MARK: - Copy mode

    @objc func toggleCopyMode(_ sender: Any?) {
        guard !webviewFocused else { return }
        guard copyMode == nil else { return endCopy() }
        startCopy()
    }

    private func startCopy() {
        guard !disposed, acceptingInput, superview != nil, !isHiddenOrHasHiddenAncestor, window?.attachedSheet == nil,
              paste == nil, clipboard == nil, pressed.isEmpty, !restoring,
              (window?.delegate as? WindowOwner)?.uploading(self) != true else { return refuseCopy() }
        let deadline = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refuseCopy() } }
        copyMode = .entering(deadline)
        find?.search(navigate: false)
        inputContext?.discardMarkedText()
        unmarkText()
        lastPerformKeyEvent = nil
        presentCopy()
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneView.copyEntryTimeout, execute: deadline)
        content.withLock { $0.freeze = .entering }
        completeEntry()
    }

    private func beep() {
        #if KIDO_VISUAL
        visualBeeps += 1
        #else
        NSSound.beep()
        #endif
    }

    private func refuseCopy() {
        endCopy()
        beep()
    }

    private func completeEntry() {
        #if KIDO_VISUAL
        guard !visualHoldCopyEntry else { return }
        #endif
        guard case .entering(let deadline) = copyMode, !restoring, content.withLock({ state in
            guard state.freeze == .entering, state.parsing == 0 else { return false }
            state.freeze = .frozen
            return true
        }) else { return }
        deadline.cancel()
        refreshScroller()
        scrollGeometry.captured = ghostty_surface_mouse_captured(surface)
        snapScroll()
        var metrics = ghostty_surface_grid_metrics_s(), bar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), ghostty_surface_scrollbar(surface, &bar) else { return refuseCopy() }
        let cursor = metrics.cursor_in_viewport ? (x: Int(metrics.cursor_column), y: Int(bar.offset) + Int(metrics.cursor_row))
            : (x: 0, y: Int(bar.offset + bar.len) - 1)
        copyMode = .cursor
        guard select(cursor, cursor) else { return refuseCopy() }
        presentCopy()
        window?.makeFirstResponder(self)
        find?.search(navigate: false)
        replayCopyPress()
    }

    func endCopy() {
        guard let mode = copyMode else { return }
        if case .entering(let deadline) = mode { deadline.cancel() } else {
            _ = ghostty_surface_set_selection(surface, nil)
            find?.close()
        }
        let dirty = content.withLock { state in
            defer { state.freeze = .off; state.dirty = false }
            return state.dirty
        }
        copyMode = nil
        if case .pending = leftGesture { leftGesture = .swallowed }
        else if case .released = leftGesture { leftGesture = nil }
        copyFind = (nil, true)
        stopAutoscroll()
        presentCopy()
        if case .entering = mode { find?.search(navigate: false) }
        if dirty {
            restoring = true
            try? koView?.resync()
        }
    }

    private func presentCopy() {
        copyLabel.isHidden = copyMode == nil
        let entering = if case .entering = copyMode { true } else { false }
        (copyLabel.subviews[0] as? NSTextField)?.attributedStringValue = NSAttributedString(string: entering ? "COPY…" : "COPY", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .kern: 0.44, .foregroundColor: entering ? Chrome.inkSecondary : Chrome.ink])
        needsLayout = true
        presentScroll()
    }

    private func select(_ anchor: (x: Int, y: Int), _ cursor: (x: Int, y: Int)) -> Bool {
        var selection = ghostty_selection_s(top_left: point(anchor), bottom_right: point(cursor), rectangle: false)
        return ghostty_surface_set_selection(surface, &selection)
    }

    private func selectLines(_ anchor: Int, _ cursor: Int) -> Bool {
        var bar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &bar) else { return false }
        var top = min(anchor, cursor), bottom = max(anchor, cursor)
        while top > 0, ghostty_surface_row_wrapped(surface, UInt32(top - 1)) { top -= 1 }
        while bottom < Int(bar.total) - 1, ghostty_surface_row_wrapped(surface, UInt32(bottom)) { bottom += 1 }
        return select((0, top), (Int(ghostty_surface_size(surface).columns) - 1, bottom))
    }

    private func copyKey(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let name = switch (mods, event.keyCode) {
        case ([], 53): "q"
        case ([], 36), ([], 76): "y"
        case ([], 123): "h"
        case ([], 124): "l"
        case ([], 125): "j"
        case ([], 126): "k"
        case ([.command], _) where key == "c": "y"
        case ([.control], _) where key == "u" || key == "d": "^" + key
        case ([], _), ([.shift], _): event.characters ?? ""
        default: ""
        }
        if case .entering = copyMode { if name == "q" { endCopy() }; return }
        if name == "q", event.keyCode == 53, let find { return find.close() }
        switch name {
        case "q": endCopy()
        case "/", "?":
            copyFind.older = name == "?"
            showFind()
        case "n", "N":
            guard let find else { return copyFind.query == nil ? () : openFind(navigate: true) }
            if copyFind.older == (name == "n") { find.next() } else { find.previous() }
        case "y", "v", "V", "h", "l", "w", "b", "e", "^", "j", "k", "0", "$", "^u", "^d", "g", "G": copyMove(name)
        case "p":
            guard hasSelection else { beep(); return }
            openPrompt()
        default: break
        }
    }

    func copyMove(_ name: String, to point: (x: Int, y: Int)? = nil) {
        if case .entering = copyMode { return }
        guard let bounds = selectionBounds() else { return endCopy() }
        var anchor = bounds.0
        var cursor = bounds.1
        var lines = false, selecting = false
        switch copyMode {
        case .lines(let a, let c): (anchor, cursor, lines) = (a, c, true)
        case .selecting: selecting = true
        default: anchor = cursor
        }
        switch name {
        case "y":
            if selecting || lines {
                copyingLines = lines
                _ = ghostty_surface_binding_action(surface, "copy_to_clipboard", 17)
                copyingLines = false
            }
            return endCopy()
        case "v" where selecting, "V" where lines:
            copyMode = .cursor
            if !select(cursor, cursor) { endCopy() }
            return
        case "v":
            copyMode = .selecting
            if !select(anchor, cursor) { endCopy() }
            return
        case "V":
            copyMode = .lines(anchor: anchor, cursor: cursor)
            if !selectLines(anchor.y, cursor.y) { endCopy() }
            return
        default: break
        }
        var bar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &bar) else { return endCopy() }
        let columns = Int(ghostty_surface_size(surface).columns), rows = Int(bar.len), history = Int(bar.total) - rows, row = cursor.y
        switch name {
        case "h", "l", "w", "b", "e", "^":
            let motion = switch name {
            case "h": GHOSTTY_POINT_MOTION_LEFT
            case "l": GHOSTTY_POINT_MOTION_RIGHT
            case "w": GHOSTTY_POINT_MOTION_WORD_NEXT
            case "b": GHOSTTY_POINT_MOTION_WORD_PREVIOUS
            case "e": GHOSTTY_POINT_MOTION_WORD_END
            default: GHOSTTY_POINT_MOTION_FIRST_NONBLANK
            }
            guard let moved = movePoint(motion, cursor) else { return endCopy() }
            cursor = moved
        case "j": cursor.y += 1
        case "k": cursor.y -= 1
        case "0": cursor.x = 0
        case "$": cursor.x = columns - 1
        case "^u": cursor.y -= max(1, rows / 2)
        case "^d": cursor.y += max(1, rows / 2)
        case "g": cursor.y = 0
        case "G": cursor.y = history + rows - 1
        default: if let point { cursor = point }
        }
        cursor = (min(max(0, cursor.x), columns - 1), min(max(0, cursor.y), history + rows - 1))
        if lines { copyMode = .lines(anchor: anchor, cursor: cursor) }
        guard lines ? cursor.y == row || selectLines(anchor.y, cursor.y) : select(selecting ? anchor : cursor, cursor) else { return endCopy() }
        let top = history - (scrollTarget ?? (history - Int(bar.offset)))
        if !alternate, cursor.y < top || cursor.y >= top + rows {
            requestScroll(history - (cursor.y < top ? max(0, cursor.y - 2) : min(history, cursor.y + 3 - rows)))
        }
    }

    // MARK: - Clipboard

    // A request is completed exactly once; an empty completion refuses it.
    private func complete(_ state: UnsafeMutableRawPointer?, _ text: String) {
        complete(state, [KoClipboardContent(mime: "text/plain", data: Data(text.utf8))])
    }

    private func complete(_ state: UnsafeMutableRawPointer?, _ contents: [KoClipboardContent], available: [String] = []) {
        snapScroll()
        GhosttyRuntime.completeClipboard(surface, contents, available: available, state, confirmed: true)
    }

    func listClipboard(_ state: UnsafeMutableRawPointer) {
        pasteEvent = (runtime.pasteboard.changeCount, .now() + PaneView.pasteEventTimeout, pasting)
        complete(state, [], available: pasting == nil ? PasteboardMIME.available(runtime.pasteboard) : ["text/plain"])
    }

    func receiveClipboardRead(_ read: KoClipboardRead) {
        guard acceptingInput, clipboard == nil, runtime.clipboard.read != .deny else { return refuse(read) }
        let board = runtime.pasteboard
        if read.mimes.isEmpty {
            client?.answerClipboard(id: read.id, contents: [], available: PasteboardMIME.available(board))
            return
        }
        if let event = pasteEvent {
            pasteEvent = nil
            if DispatchTime.now() < event.deadline {
                guard event.changeCount == board.changeCount else {
                    client?.answerClipboard(id: read.id, contents: [])
                    return
                }
                return serve(read, text: event.text)
            }
        }
        if runtime.clipboard.read == .allow { return serve(read) }
        clipboard = (read, nil, .now() + PaneView.clipboardTimeout)
        guard let owner = window?.delegate as? WindowOwner else { return finishClipboard(false) }
        owner.requestClipboard(self, read.mimes.allSatisfy { $0 == "text/plain" } ? .clipboard : .rich)
    }

    private func refuse(_ read: KoClipboardRead) {
        client?.answerClipboard(id: read.id, contents: nil)
    }

    private func serve(_ read: KoClipboardRead, text: String? = nil) {
        let board = runtime.pasteboard
        let available = read.list ? PasteboardMIME.available(board) : []
        let contents = text.map { read.mimes.contains("text/plain") ? [KoClipboardContent(mime: "text/plain", data: Data($0.utf8))] : [] } ?? PasteboardMIME.read(board, read.mimes)
        guard text == nil, clipboard == nil, read.mimes.contains("image/png"), !contents.contains(where: { $0.mime == "image/png" }),
              let tiff = board.data(forType: .tiff) else {
            client?.answerClipboard(id: read.id, contents: contents, available: available)
            return
        }
        clipboard = (read, nil, .distantFuture)
        Task { [weak self] in
            let converted = try? await Upload(image: tiff)
            guard let self, clipboard?.read.id == read.id else { return }
            clipboard = nil
            if copyMode != nil { return refuse(read) }
            let png: [KoClipboardContent] = if case .data(let data)? = converted?.sources.first?.bytes { [KoClipboardContent(mime: "image/png", data: data)] } else { [] }
            client?.answerClipboard(id: read.id, contents: contents + png, available: available)
        }
    }

    var clipboardOnTime: Bool { clipboard.map { DispatchTime.now() < $0.deadline } ?? false }

    func expireClipboard() {
        guard let clipboard else { return }
        let timeout = DispatchWorkItem { [weak self] in self?.finishClipboard(false) }
        self.clipboard?.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: clipboard.deadline, execute: timeout)
    }

    private func takeClipboard() -> KoClipboardRead? {
        guard let pending = clipboard else { return nil }
        clipboard = nil
        pending.timeout?.cancel()
        (window?.delegate as? WindowOwner)?.releaseClipboard(self)
        return pending.read
    }

    func finishClipboard(_ granted: Bool) {
        guard let read = takeClipboard() else { return }
        if granted { serve(read) } else { refuse(read) }
    }

    func invalidateClipboard() {
        endCopy()
        acceptingInput = false
        pasteEvent = nil
        finishClipboard(false)
    }

    private(set) var pasting: String?

    func paste(_ text: String) {
        guard webviewView == nil else { return }
        pasting = text
        defer { pasting = nil }
        _ = ghostty_surface_binding_action(surface, "paste_from_clipboard", 20)
    }

    func pasteImage() -> Bool {
        guard webviewView == nil else { return false }
        guard pasting == nil, let types = runtime.pasteboard.types, !types.contains(.fileURL), !types.contains(.string),
              let type = [NSPasteboard.PasteboardType.png, .tiff].first(where: types.contains) else { return false }
        (window?.delegate as? WindowOwner)?.uploadImage(runtime.pasteboard.data(forType: type), to: self)
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptingInput, copyMode == nil else { return [] }
        if webviewView != nil { return (window?.delegate as? WindowOwner)?.isLocalProgram(self) == true && sender.draggingPasteboard.types?.contains(.fileURL) == true ? .copy : [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptingInput, copyMode == nil, let owner = window?.delegate as? WindowOwner else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if webviewView != nil {
            guard owner.isLocalProgram(self), !urls.isEmpty else { return false }
            owner.dropFiles(urls, into: self); return true
        }
        if urls.isEmpty, let promises = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            owner.uploadPromises(promises, to: self)
        } else {
            owner.upload(Result { () throws(Failure) in try Upload(files: urls, copying: host != .local || owner.sshDestination(self) != nil) }, to: self)
        }
        return true
    }

    func confirmPaste(_ text: String, _ state: UnsafeMutableRawPointer?) {
        guard !disposed, paste == nil, copyMode == nil, let window else { return complete(state, "") }
        let alert = NSAlert()
        alert.messageText = "Paste this text?"
        alert.informativeText = "It may run commands when pasted into the terminal."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        scroll.hasHorizontalScroller = true
        let view = scroll.documentView as! NSTextView
        view.string = text
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        alert.accessoryView = scroll
        paste = (alert, state)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let paste, paste.alert === alert else { return }
            self.paste = nil
            complete(paste.state, response == .alertFirstButtonReturn ? text : "")
        }
    }

    // MARK: - NSView

    override var acceptsFirstResponder: Bool { true }

    private var surfaceFocus: Bool?

    private func setSurfaceFocus(_ focused: Bool) {
        guard !disposed, let surface, surfaceFocus != focused else { return }
        surfaceFocus = focused
        ghostty_surface_set_focus(surface, focused)
    }

    func syncFocus() {
        setSurfaceFocus((window?.firstResponder === self || webviewFocused) && (window as? OwnerWindow)?.isInputWindow != false)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            note("pane \(pane) became first responder")
            syncFocus()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        snapScroll()
        let result = super.resignFirstResponder()
        if result {
            note("pane \(pane) resigned first responder")
            setSurfaceFocus(false)
        }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncFocus()
        viewDidChangeBackingProperties()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            center.addObserver(
                self, selector: #selector(present), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            center.addObserver(self, selector: #selector(present), name: NSWindow.didChangeScreenNotification, object: window)
        }
        present()
    }

    override func viewDidHide() {
        super.viewDidHide()
        present()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        present()
    }

    @objc private func present() {
        if isHiddenOrHasHiddenAncestor || window == nil { endCopy() }
        if let id = window?.screen?.displayID {
            ghostty_surface_set_display_id(surface, id)
        }
        let hidden = isHiddenOrHasHiddenAncestor
        var visible = window?.occlusionState.contains(.visible) == true
        #if KIDO_VISUAL
        visible = visible || Self.renderOffscreen
        #endif
        let next = (visible: !hidden && visible, realized: !hidden)
        if next.realized != presented.realized { _ = ghostty_surface_set_renderer_realized(surface, next.realized) }
        if next.visible != presented.visible { ghostty_surface_set_occlusion(surface, next.visible) }
        presented = next
        queueScroll()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        snapScroll()
        let scale = contentScale
        reflow { [weak self] in
            guard let self else { return }
            ghostty_surface_set_content_scale(surface, scale, scale)
            onCellChange()
        }
        ghostty_surface_set_render_insets(surface, UInt32((renderInsets.top * scale).rounded()), UInt32((renderInsets.bottom * scale).rounded()))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self))
        super.updateTrackingAreas()
    }

    @objc func runCommand(_ sender: NSMenuItem) {
        #if KIDO_VISUAL
        visualMenuCommands += 1
        #endif
        guard let command = sender.representedObject as? PaneCommand else { return }
        onCommand(command)
    }

    // MARK: - Mouse

    func inRenderBand(_ point: NSPoint) -> Bool {
        let y = point.y
        return (renderInsets.bottom > 0 && y < renderInsets.bottom)
            || (renderInsets.top > 0 && bounds.height - y < renderInsets.top)
    }

    private func button(_ event: NSEvent, _ state: ghostty_input_mouse_state_e) -> Bool {
        if copyMode != nil {
            if state == GHOSTTY_MOUSE_PRESS { endCopy() }
            return true
        }
        if state == GHOSTTY_MOUSE_PRESS {
                let strip = inRenderBand(convert(event.locationInWindow, from: nil))
            if event.buttonNumber == 0 || strip {
                window?.makeFirstResponder(self)
                onSelect()
            }
            if strip { position(event); return true }
            snapScroll()
        } else if !pressed.contains(event.buttonNumber) { return true }
        if state == GHOSTTY_MOUSE_PRESS { position(event); pressed.insert(event.buttonNumber) }
        else { pressed.remove(event.buttonNumber) }
        let button = switch event.buttonNumber {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        default: GHOSTTY_MOUSE_UNKNOWN
        }
        return ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    private func position(_ event: NSEvent) {
        updateContentHover(event.modifierFlags, point: convert(event.locationInWindow, from: nil))
        guard copyMode == nil else { return }
        if inRenderBand(convert(event.locationInWindow, from: nil)) && pressed.isEmpty {
            ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
            return
        }
        guard scrollDistance.map({ $0 == $0.rounded() }) != false else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let point = surfacePoint(pos)
        ghostty_surface_mouse_pos(surface, point.x, point.y, Self.mods(event.modifierFlags))
    }

    private func point(_ cell: (x: Int, y: Int)) -> ghostty_point_s {
        ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(cell.x), y: UInt32(cell.y))
    }

    private func gridCell(_ point: NSPoint) -> (x: Int, y: Int) {
        var bar = ghostty_surface_scrollbar_s()
        _ = ghostty_surface_scrollbar(surface, &bar)
        let size = ghostty_surface_size(surface)
        let columns = max(1, Int(size.columns)), rows = max(1, Int(bar.len))
        let x = min(max(0, Int(floor(point.x / max(1, cell.width)))), columns - 1)
        let viewportRow = min(max(0, Int(floor((bounds.height - point.y - renderInsets.top) / max(1, cell.height)))), rows - 1)
        let y = min(max(0, Int(bar.offset) + viewportRow), max(0, Int(bar.total) - 1))
        return (x, y)
    }

    private func gridCell(_ event: NSEvent) -> (x: Int, y: Int) {
        gridCell(convert(event.locationInWindow, from: nil))
    }

    private func movePoint(_ motion: ghostty_point_motion_e, _ from: (x: Int, y: Int)) -> (x: Int, y: Int)? {
        var moved = ghostty_point_s()
        guard ghostty_surface_move_point(surface, point(from), motion, &moved) else { return nil }
        return (Int(moved.x), Int(moved.y))
    }

    private func decodedText(_ text: inout ghostty_text_s) -> String? {
        guard let bytes = text.text else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    private func cellText(_ cell: (x: Int, y: Int)) -> String? {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(top_left: point(cell), bottom_right: point(cell), rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text), let value = decodedText(&text) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private func wordRange(at cell: (x: Int, y: Int)) -> (start: (x: Int, y: Int), end: (x: Int, y: Int))? {
        guard cellText(cell) != nil else { return nil }
        var start = cell
        if let previous = movePoint(GHOSTTY_POINT_MOTION_WORD_PREVIOUS, cell),
           let previousEnd = movePoint(GHOSTTY_POINT_MOTION_WORD_END, previous),
           previousEnd.y > cell.y || (previousEnd.y == cell.y && previousEnd.x >= cell.x),
           let right = movePoint(GHOSTTY_POINT_MOTION_RIGHT, previous), cellText(right) != nil {
            start = previous
        }
        guard var end = movePoint(GHOSTTY_POINT_MOTION_WORD_END, start) else { return nil }
        if start == cell, let right = movePoint(GHOSTTY_POINT_MOTION_RIGHT, cell), cellText(right) == nil { end = cell }
        return (start, end)
    }

    private func selectWord(_ word: (start: (x: Int, y: Int), end: (x: Int, y: Int))) {
        copyMode = .selecting
        if !select(word.start, word.end) { endCopy() }
    }

    func readSelection() -> String {
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return "" }
        return decodedText(&text) ?? ""
    }

    private func selectionBounds() -> ((x: Int, y: Int), (x: Int, y: Int))? {
        var value = ghostty_selection_s()
        guard ghostty_surface_selection(surface, &value) else { return nil }
        return ((Int(value.top_left.x), Int(value.top_left.y)), (Int(value.bottom_right.x), Int(value.bottom_right.y)))
    }

    var hasSelection: Bool {
        guard ghostty_surface_has_selection(surface) else { return false }
        if case .cursor = copyMode { return false }
        if case .entering = copyMode { return false }
        return true
    }

    private func selectionContains(_ cell: (x: Int, y: Int)) -> Bool {
        guard let (top, bottom) = selectionBounds() else { return false }
        return (cell.y > top.y || (cell.y == top.y && cell.x >= top.x))
            && (cell.y < bottom.y || (cell.y == bottom.y && cell.x <= bottom.x))
    }

    private func edgeOverflow(_ point: NSPoint) -> (above: CGFloat, below: CGFloat) {
        (point.y - (bounds.height - renderInsets.top), renderInsets.bottom - point.y)
    }

    private func applyDrag(_ cell: (x: Int, y: Int)) {
        guard let drag = mouseDrag else { return }
        switch drag {
        case .cell(let anchor, _):
            if case .selecting = copyMode {} else {
                copyMode = .selecting
                if !select(anchor, cell) { return endCopy() }
            }
            copyMove("", to: cell)
        case .word(let start, let end, let anchor, _):
            guard let word = wordRange(at: cell) else { return }
            let (top, bottom) = cell.y < anchor.y || (cell.y == anchor.y && cell.x < anchor.x) ? (word.start, end) : (start, word.end)
            copyMode = .selecting
            if !select(top, bottom) { endCopy() }
        case .line(let row, _):
            let columns = Int(ghostty_surface_size(surface).columns)
            copyMode = .lines(anchor: (0, row), cursor: (columns - 1, cell.y))
            if !selectLines(row, cell.y) { endCopy() }
        }
    }

    private func stopAutoscroll() {
        autoscroll?.invalidate()
        autoscroll = nil
    }

    private func updateAutoscroll() {
        guard let point = dragPoint else { return stopAutoscroll() }
        let overflow = edgeOverflow(point)
        guard overflow.above > 0 || overflow.below > 0 else { return stopAutoscroll() }
        guard autoscroll == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscroll = timer
    }

    private func autoscrollTick() {
        guard let point = dragPoint, copyMode != nil else { return stopAutoscroll() }
        let overflow = edgeOverflow(point)
        guard overflow.above > 0 || overflow.below > 0 else { return stopAutoscroll() }
        let position = scrollPosition()
        let distance = position.retainedHistoryRows - position.offset
        let step = max(1, Int((max(overflow.above, overflow.below) / 40).rounded(.down)) + 1)
        let next = overflow.above > 0 ? min(position.retainedHistoryRows, distance + step) : max(0, distance - step)
        guard next != distance else { return stopAutoscroll() }
        requestScroll(next)
        let cell = gridCell(point)
        let row = position.retainedHistoryRows - next + (overflow.above > 0 ? 0 : position.rows - 1)
        applyDrag((cell.x, max(0, row)))
    }

    private static func contentModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .command, .control, .option]) == [.shift, .command]
    }

    private func updateContentHover(_ flags: NSEvent.ModifierFlags, point: NSPoint) {
        let hover = Self.contentModifiers(flags) && contentHit(point).kind != GHOSTTY_HIT_NONE
        setContentHover(hover)
    }

    private func setContentHover(_ hover: Bool) {
        guard hover != contentHover else { return }
        contentHover = hover
        cursorHost?.invalidateCursorRects(for: self)
        mouseCursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        if Self.contentModifiers(event.modifierFlags), !disposed {
            let point = convert(event.locationInWindow, from: nil)
            let hit = contentHit(point)
            if hit.kind != GHOSTTY_HIT_NONE {
                leftGesture = .content(point, hit)
                window?.makeFirstResponder(self)
                onSelect()
                return
            }
        }
        if copyMode == nil, Self.copyPress(event) {
            beginCopyPress(event)
            return
        }
        if copyMode == nil {
            if leftGesture != nil { return }
            return _ = button(event, GHOSTTY_MOUSE_PRESS)
        }
        guard !disposed else { return }
        if entering {
            if Self.copyPress(event) {
                let point = convert(event.locationInWindow, from: nil)
                let cell = gridCell(point)
                if case .pending(var press) = leftGesture {
                    press.cell = cell
                    press.clickCount = max(press.clickCount, event.clickCount)
                    press.move(to: point, cell: cell)
                    leftGesture = .pending(press)
                } else {
                    leftGesture = .pending(CopyPress(cell: cell, clickCount: event.clickCount, latest: cell,
                                                     point: point, selection: nil))
                }
            }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        copyMouseDown(cell: gridCell(point), clickCount: event.clickCount,
                      shift: event.modifierFlags.contains(.shift), point: point)
    }

    private static func copyPress(_ event: NSEvent) -> Bool {
        event.buttonNumber == 0
            && event.modifierFlags.intersection([.shift, .control, .option, .command]) == [.shift]
    }

    private var entering: Bool {
        if case .entering = copyMode { return true }
        return false
    }

    private func beginCopyPress(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cell = gridCell(point)
        let press = CopyPress(cell: cell, clickCount: event.clickCount, latest: cell,
                              point: point, selection: selectionBounds())
        window?.makeFirstResponder(self)
        onSelect()
        startCopy()
        if copyMode == nil {
            leftGesture = .swallowed
        } else {
            leftGesture = .pending(press)
            if !entering { replayCopyPress() }
        }
    }

    private func replayCopyPress() {
        let press: CopyPress
        let released: Bool
        switch leftGesture {
        case .pending(let value):
            press = value
            released = false
        case .released(let value):
            press = value
            released = true
        default: return
        }
        leftGesture = nil
        if let selection = press.selection {
            copyMode = .selecting
            guard select(selection.0, selection.1) else { return endCopy() }
        }
        copyMouseDown(cell: press.cell, clickCount: press.clickCount, shift: press.selection != nil, point: press.point)
        if press.latest != press.cell { advanceDrag(to: press.latest, point: press.point) }
        if released { endMouseDrag() } else { updateAutoscroll() }
    }

    private func copyMouseDown(cell: (x: Int, y: Int), clickCount: Int, shift: Bool, point: NSPoint) {
        window?.makeFirstResponder(self)
        snapScroll()
        stopAutoscroll()
        dragPoint = point
        if shift, let selection = selectionBounds() {
            switch copyMode {
            case .lines(let anchor, _):
                mouseDrag = .line(row: anchor.y, last: cell)
            case .selecting:
                mouseDrag = .cell(anchor: selection.0, last: cell)
            default:
                copyMode = .selecting
                mouseDrag = .cell(anchor: cell, last: cell)
            }
            copyMove("", to: cell)
            return
        }
        if clickCount >= 3 {
            let columns = Int(ghostty_surface_size(surface).columns)
            copyMode = .lines(anchor: (0, cell.y), cursor: (columns - 1, cell.y))
            mouseDrag = .line(row: cell.y, last: cell)
            if !selectLines(cell.y, cell.y) { endCopy() }
        } else if clickCount == 2, let word = wordRange(at: cell) {
            mouseDrag = .word(start: word.start, end: word.end, anchor: cell, last: cell)
            selectWord(word)
        } else {
            copyMode = .cursor
            mouseDrag = .cell(anchor: cell, last: cell)
            if !select(cell, cell) { endCopy() }
        }
    }

    private func advanceDrag(to cell: (x: Int, y: Int), point: NSPoint) {
        mouseDrag = mouseDrag?.moved(to: cell)
        dragPoint = point
        updateAutoscroll()
        applyDrag(cell)
    }

    private func endMouseDrag() {
        stopAutoscroll()
        mouseDrag = nil
        dragPoint = nil
    }

    override func mouseUp(with event: NSEvent) {
        if case .content(let point, let hit) = leftGesture {
            leftGesture = nil
            guard !disposed else { return }
            let release = convert(event.locationInWindow, from: nil)
            guard hypot(release.x - point.x, release.y - point.y) < 3 else { return }
            activateContent(hit, at: point)
            return
        }
        guard copyMode != nil else {
            if leftGesture != nil, event.buttonNumber == 0 {
                leftGesture = nil
                return
            }
            _ = button(event, GHOSTTY_MOUSE_RELEASE)
            ghostty_surface_mouse_pressure(surface, 0, 0)
            return
        }
        if entering {
            switch leftGesture {
            case .pending(var press):
                let point = convert(event.locationInWindow, from: nil)
                press.move(to: point, cell: gridCell(point))
                leftGesture = .released(press)
            case .swallowed, .none:
                leftGesture = nil
            case .released, .content:
                break
            }
            return
        }
        if event.buttonNumber == 0 { leftGesture = nil }
        endMouseDrag()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard copyMode != nil else {
            let captured = ghostty_surface_mouse_captured(surface)
            let consumed = button(event, GHOSTTY_MOUSE_PRESS)
            if !captured {
                let removed = pressed.remove(event.buttonNumber) ?? pressed.remove(1)
                if removed != nil {
                    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
                }
                if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            } else if !consumed {
                super.rightMouseDown(with: event)
            }
            return
        }
        if case .entering = copyMode { return }
        window?.makeFirstResponder(self)
        selectForMenu(event)
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    func selectForMenu(_ event: NSEvent) {
        guard copyMode != nil else { return }
        let cell = gridCell(event)
        if case .cursor = copyMode {
            if let word = wordRange(at: cell) { selectWord(word) }
        } else if !selectionContains(cell), let word = wordRange(at: cell) {
            selectWord(word)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if copyMode == nil { _ = button(event, GHOSTTY_MOUSE_RELEASE) }
    }

    override func otherMouseDown(with event: NSEvent) { if copyMode == nil { _ = button(event, GHOSTTY_MOUSE_PRESS) } }
    override func otherMouseUp(with event: NSEvent) { if copyMode == nil { _ = button(event, GHOSTTY_MOUSE_RELEASE) } }
    override func mouseEntered(with event: NSEvent) { position(event) }
    override func mouseMoved(with event: NSEvent) { position(event) }
    override func mouseDragged(with event: NSEvent) {
        if case .content = leftGesture {
            leftGesture = .swallowed
            return
        }
        if entering {
            if case .pending(var press) = leftGesture {
                let point = convert(event.locationInWindow, from: nil)
                press.move(to: point, cell: gridCell(point))
                leftGesture = .pending(press)
            }
            return
        }
        if copyMode == nil {
            if leftGesture != nil {
                #if KIDO_VISUAL
                visualSwallowedDrags += 1
                #endif
                return
            }
            return position(event)
        }
        guard let drag = mouseDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let cell = gridCell(point)
        guard cell != drag.last else { return }
        advanceDrag(to: cell, point: point)
    }
    override func rightMouseDragged(with event: NSEvent) { position(event) }
    override func otherMouseDragged(with event: NSEvent) { position(event) }

    override func mouseExited(with event: NSEvent) {
        setContentHover(false)
        guard NSEvent.pressedMouseButtons == 0, copyMode == nil else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard hasSelection else { return nil }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(copySelectionItem(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = .command
        copy.target = self
        menu.addItem(copy)
        let prompt = NSMenuItem(title: "Prompt with Selection…", action: #selector(promptSelectionItem(_:)), keyEquivalent: "o")
        prompt.keyEquivalentModifierMask = .command
        prompt.target = self
        menu.addItem(prompt)
        return menu
    }

    private func bindingAction(_ action: String) {
        #if KIDO_VISUAL
        visualBindingActions += 1
        #endif
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    override func selectAll(_ sender: Any?) { bindingAction("select_all") }
    @objc func copy(_ sender: Any?) { copySelectionItem(sender) }
    @objc func paste(_ sender: Any?) { if webviewView == nil { bindingAction("paste_from_clipboard") } }

    @objc func copySelectionItem(_ sender: Any?) {
        if copyMode != nil { copyMove("y") }
        else { bindingAction("copy_to_clipboard") }
    }

    @objc func promptSelectionItem(_ sender: Any?) { openPrompt() }

    func openPrompt() {
        if case .entering = copyMode { return }
        guard canPrompt() else { beep(); return }
        onPrompt(self, selectionQuote)
    }

    func promptDelivered() {
        if copyMode != nil { endCopy() } else { _ = ghostty_surface_set_selection(surface, nil) }
    }


    #if KIDO_VISUAL
    var visualAcceptsFirstMouse = true
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { visualAcceptsFirstMouse }
    #endif

    override func pressureChange(with event: NSEvent) {
        guard !pressed.isEmpty else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    override func scrollWheel(with event: NSEvent) {
        let time = CACurrentMediaTime()
        debug("wheel pane=\(pane) time=\(time) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) precise=\(event.hasPreciseScrollingDeltas) delta=\(event.scrollingDeltaY) eventTime=\(event.timestamp)")
        let strip = inRenderBand(convert(event.locationInWindow, from: nil))
        if strip { position(event) }
        let precise = event.hasPreciseScrollingDeltas
        if event.momentumPhase.isEmpty && event.scrollingDeltaY != 0 { suppressMomentum = false }
        if suppressMomentum && !event.momentumPhase.isEmpty { return }
        for _ in 0..<3 {
            let intent = copyMode == nil ? ghostty_surface_wheel_intent(surface, strip) : alternate ? GHOSTTY_WHEEL_IGNORE : GHOSTTY_WHEEL_VIEWPORT
            let accepted = copyMode != nil || intent == GHOSTTY_WHEEL_PROGRAM || ghostty_surface_wheel_input(surface, 0, 0, 0, Self.mods(event.modifierFlags), strip, intent)
            if !accepted { continue }
            if wheelOwner != intent { wheelRemainder = 0; wheelOwner = intent }
            debug("wheel-route pane=\(pane) disposition=\(intent.rawValue)")
            if intent == GHOSTTY_WHEEL_IGNORE { return }
            if intent == GHOSTTY_WHEEL_VIEWPORT {
                guard event.scrollingDeltaY != 0 else { return }
                let delta = event.scrollingDeltaY
                let wheelMultiplier = runtime.values.mouse.scrollMultiplier
                let current = scrollPosition()
                if current.retainedHistoryRows == 0 {
                    wheelRemainder = 0
                    requestScrollDistance(snapshot: current) { _ in 0 }
                    return
                }
                let distance = scrollDistance ?? Double(current.retainedHistoryRows - current.offset)
                if precise && pressed.isEmpty {
                    let rows = delta * wheelMultiplier.precision / Double(max(1, rowHeight))
                    requestScrollDistance(snapshot: current) { $0 + rows }
                    return
                }
                if distance != distance.rounded() { snapScroll() }
                wheelRemainder += precise ? delta * wheelMultiplier.precision / Double(max(1, rowHeight))
                    : (delta > 0 ? max(1, delta) : min(-1, delta)) * wheelMultiplier.discrete
                let rows = Int(wheelRemainder)
                wheelRemainder -= Double(rows)
                if rows != 0 {
                    requestScrollDistance(snapshot: current) { $0.rounded() + Double(rows) }
                }
                return
            }
            scroller.reveal()
            if scrollDistance.map({ $0 != $0.rounded() }) == true { snapScroll() }
            let momentum: ghostty_input_mouse_momentum_e = switch event.momentumPhase {
            case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
            case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
            case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
            case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
            case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
            case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
            default: GHOSTTY_MOUSE_MOMENTUM_NONE
            }
            let mods = (precise ? 1 : 0) | Int32(momentum.rawValue) << 1
            if ghostty_surface_wheel_input(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods,
                                           Self.mods(event.modifierFlags), strip, intent) { return }
        }
    }

    // MARK: - Keyboard

    private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    #if KIDO_VISUAL
    static var visualKeyTranslation: ((NSEvent, NSEvent.ModifierFlags) -> String?)?
    #endif

    private static func characters(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        #if KIDO_VISUAL
        if let visualKeyTranslation { return visualKeyTranslation(event, modifiers) }
        #endif
        return event.characters(byApplyingModifiers: modifiers)
    }

    // Control characters are left to Ghostty's key encoder, and AppKit's
    // private-use function-key characters are not text.
    private static func text(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return Self.characters(event, modifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let scalars = text?.unicodeScalars, scalars.count == 1 else { return false }
        return scalars.first!.value < 0x20
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        key.consumed_mods = Self.mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.composing = composing
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = Self.characters(event, modifiers: [])?.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        guard let text, let first = text.utf8.first, first >= 0x20, first != 0x7F else {
            return ghostty_surface_key(surface, key)
        }
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
    }

    private func committedText(_ action: ghostty_input_action_e, _ text: String) {
        var key = ghostty_input_key_s()
        key.action = action
        text.withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard webviewView == nil else { return }
        debug("key route code=\(event.keyCode) pane=\(pane) firstResponder=\(PaneView.owner(window?.firstResponder)?.pane.description ?? (window?.firstResponder).map { String(describing: type(of: $0)) } ?? "none")")
        #if KIDO_VISUAL
        visualKeyEvents += 1
        #endif
        if copyMode != nil { return copyKey(event) }
        if scrollTarget != nil { resetScroll() }
        if let find, event.keyCode == 53 { find.close(); return }
        if event.keyCode == 53, (window?.delegate as? WindowOwner)?.cancelUploads(self) == true { return }
        if let find, event.keyCode == 36, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            if event.modifierFlags.contains(.shift) { find.previous() } else { find.next() }
            return
        }
        let translated = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // AppKit IMEs (Korean in particular) need the original event object
        // whenever the modifiers are unchanged.
        let translationEvent = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationMods,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: Self.characters(event, modifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode) ?? event

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore
        let accumulated = keyTextAccumulator ?? []

        if markedBefore, !accumulated.isEmpty {
            for text in accumulated where !Self.isComposingControl(text, composing: composing) {
                committedText(action, text)
            }
            // Arrows after a commit still move the cursor; a plain left arrow
            // is already accounted for by the IME.
            let replay: Bool = switch event.keyCode {
            case 0x7D, 0x7C, 0x7E: true
            case 0x7B: !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
            default: false
            }
            if replay { keyAction(action, event: event, translationMods: translationEvent.modifierFlags) }
        } else if !accumulated.isEmpty {
            for text in accumulated where !Self.isComposingControl(text, composing: composing) {
                keyAction(action, event: event, translationMods: translationEvent.modifierFlags, text: text)
            }
        } else if !Self.isComposingControl(event.characters, composing: composing) {
            keyAction(
                action,
                event: event,
                translationMods: translationEvent.modifierFlags,
                text: Self.text(translationEvent),
                composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard webviewView == nil else { return }
        #if KIDO_VISUAL
        visualKeyUps += 1
        #endif
        guard copyMode == nil else { return }
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard webviewView == nil else { return }
        updateContentHover(event.modifierFlags, point: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        let mod: ghostty_input_mods_e
        let rightMask: Int32?
        switch event.keyCode {
        case 0x39: (mod, rightMask) = (GHOSTTY_MODS_CAPS, nil)
        case 0x38: (mod, rightMask) = (GHOSTTY_MODS_SHIFT, nil)
        case 0x3C: (mod, rightMask) = (GHOSTTY_MODS_SHIFT, NX_DEVICERSHIFTKEYMASK)
        case 0x3B: (mod, rightMask) = (GHOSTTY_MODS_CTRL, nil)
        case 0x3E: (mod, rightMask) = (GHOSTTY_MODS_CTRL, NX_DEVICERCTLKEYMASK)
        case 0x3A: (mod, rightMask) = (GHOSTTY_MODS_ALT, nil)
        case 0x3D: (mod, rightMask) = (GHOSTTY_MODS_ALT, NX_DEVICERALTKEYMASK)
        case 0x37: (mod, rightMask) = (GHOSTTY_MODS_SUPER, nil)
        case 0x36: (mod, rightMask) = (GHOSTTY_MODS_SUPER, NX_DEVICERCMDKEYMASK)
        default: return
        }
        guard !hasMarkedText(), copyMode == nil else { return }
        let held = Self.mods(event.modifierFlags).rawValue & mod.rawValue != 0
        let sidePressed = rightMask.map { event.modifierFlags.rawValue & UInt($0) != 0 } ?? true
        keyAction(held && sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    // AppKit offers command and control chords here before keyDown and may
    // turn them into doCommand selectors; an unbound chord is re-sent through
    // the event system and recognised in doCommand by its timestamp. A plain
    // consumed Ghostty binding goes to a menu item with that shortcut first,
    // as in Ghostty's own app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard webviewView == nil, acceptsKeyInput, event.type == .keyDown, window?.firstResponder === self else { return false }
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let chord = event.charactersIgnoringModifiers?.lowercased()
        if mods == [.command, .shift] && chord == "c" { toggleCopyMode(nil); return true }
        if copyMode != nil {
            if mods == .command, chord == "o" {
                if case .entering = copyMode { return true }
                if !canPrompt() { beep(); return true }
            }
            // AppKit's Edit menu adds Emoji & Symbols (fn-E), which a plain e also matches.
            if mods.contains(.command), mods != [.command] || chord != "c", NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
            copyKey(event)
            return true
        }

        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        key.unshifted_codepoint = Self.characters(event, modifiers: [])?.unicodeScalars.first?.value ?? 0
        #if KIDO_VISUAL
        visualBindingQueries += 1
        #endif
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            key.text = ptr
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        if isBinding {
            let flags = flags.rawValue
            if flags & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue != 0,
               flags & (GHOSTTY_BINDING_FLAGS_ALL.rawValue | GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) == 0,
               NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            guard event.timestamp != 0 else { return false }
            guard !event.modifierFlags.isDisjoint(with: [.command, .control]) else {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
            } else {
                lastPerformKeyEvent = event.timestamp
                return false
            }
        }
        guard let final = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    override func doCommand(by selector: Selector) {
        guard webviewView == nil, acceptsKeyInput else { return }
        if copyMode == nil, let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    // MARK: - NSTextInputClient

    private func syncPreedit(clearIfNeeded: Bool = true) {
        if markedText.length > 0 {
            let text = markedText.string
            ghostty_surface_preedit(surface, text, UInt(text.utf8.count))
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange { NSRange() }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard webviewView == nil, acceptsKeyInput, copyMode == nil else { return }
        snapScroll()
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard webviewView == nil, acceptsKeyInput, markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        snapScroll()
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return screenRect(NSRect(x: x, y: y - max(height, cell.height), width: width, height: max(height, cell.height)))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard webviewView == nil, acceptsKeyInput else { return }
        #if KIDO_VISUAL
        visualTextInputs += 1
        #endif
        guard copyMode == nil else { return }
        snapScroll()
        guard NSApp.currentEvent != nil else { return }
        let chars = switch string {
        case let v as NSAttributedString: v.string
        case let v as String: v
        default: ""
        }
        let hadMarkedText = hasMarkedText()
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
        } else if hadMarkedText, !chars.isEmpty {
            committedText(GHOSTTY_ACTION_PRESS, chars)
        } else {
            ghostty_surface_text_input(surface, chars, UInt(chars.utf8.count))
        }
    }
}
