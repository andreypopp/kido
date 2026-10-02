import AppKit
import os
import GhosttyKit
import TmuxControl

private final class TerminalView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PaneView: NSView, @preconcurrency NSTextInputClient {
    let pane: PaneID
    let born = DispatchTime.now()
    private let onInput: @MainActor @Sendable (Data) -> Void
    var onSelect: () -> Void = {}
    var onCellChange: () -> Void = {}
    var onFontChange: (Float) -> Void = { _ in }
    var onCommand: (PaneCommand) -> Void = { _ in }
    var onResync: (@escaping @Sendable () -> Void) -> Void = { $0() }
    var onScroll: () -> Void = {}
    var onLoadMore: () -> Void = {}
    var onScrollSettled: () -> Void = {}
    let scroller = PaneScroller()
    var find: PaneFind?
    private(set) var alternate = false
    var onAlternateChange: () -> Void = {}
    var historyStrip: CGFloat = 0 {
        didSet {
            if historyStrip != oldValue {
                ghostty_surface_set_render_insets(surface, UInt32((historyStrip * (window?.backingScaleFactor ?? 2)).rounded()), 0)
            }
        }
    }
    private let terminal = TerminalView()
    private let historyLimit = NSBox()
    @objc private func loadMoreHistory() { onLoadMore() }
    private var shifted: Bool { (terminal.layer?.transform.m42 ?? 0) != 0 }
    private var pressed: Set<Int> = []
    private var scrollGeometry = (history: 0, position: ScrollPosition(history: 0, offset: 0, rows: 1), captured: false, limited: false)
    private var scrollPresentation = (position: ScrollPosition(history: 0, offset: 0, rows: 1), distance: Optional<Double>.none)
    nonisolated private let target = OSAllocatedUnfairLock<Double?>(initialState: nil)
    nonisolated private let scrolling = DispatchQueue(label: "kido.scroll", qos: .userInteractive)
    nonisolated var scrollTarget: Int? { target.withLock { $0.map { Int($0.rounded(.up)) } } }
    nonisolated private var scrollDistance: Double? { target.withLock { $0 } }
    private var suppressMomentum = false
    private var scrollRevision = 0
    private var scrollPending: Int?
    private var trimming: DispatchWorkItem?
    private var resyncing: DispatchWorkItem?
    private var thawing: DispatchWorkItem?
    private var restoreCompleted = false
    nonisolated private let anchor = OSAllocatedUnfairLock<ScrollAnchor?>(initialState: nil)
    nonisolated var resizeAnchor: ScrollAnchor? {
        get { anchor.withLock { $0 } }
        set { anchor.withLock { $0 = newValue } }
    }
    private var wheelRemainder = 0.0
    private var wheelMultiplier = (precision: 1.0, discrete: 3.0)
    private var rowHeight: CGFloat = 1
    var onSearch: (String, UUID) -> Void = { _, _ in }

    @objc func showFind(_ sender: Any? = nil) {
        snapScroll()
        if find == nil {
            let bar = PaneFind(self)
            find = bar
            addSubview(bar)
            needsLayout = true
        }
        window?.makeFirstResponder(find?.field)
    }

    @objc func findNext(_ sender: Any? = nil) { snapScroll(); find?.next() }
    @objc func findPrevious(_ sender: Any? = nil) { snapScroll(); find?.previous() }


    struct ScrollPosition: Sendable {
        let history: Int
        let offset: Int
        let rows: Int
    }

    nonisolated var historyEpoch: Int { gridChanged.withLock { epoch } }
    nonisolated(unsafe) private var epoch = 0

    nonisolated func scrollPosition() -> ScrollPosition { scrollPosition(distance: nil)! }

    nonisolated private func scrollPosition(distance: Double?) -> ScrollPosition? {
        var value = ghostty_surface_scrollbar_s()
        _ = ghostty_surface_scrollbar(surface, &value)
        if let distance {
            for attempt in 0..<3 {
                let top = max(0, Double(value.total - value.len) - distance)
                let row = floor(top)
                let pixels = Float(top - row) * Float(ghostty_surface_size(surface).cell_height_px)
                if ghostty_surface_scroll_to_row_pixel_if_revision(surface, UInt64(row), pixels, value.row_space_revision, &value) {
                    debug("scroll-apply pane=\(pane) time=\(CACurrentMediaTime()) distance=\(distance) row=\(value.offset) pixel=\(pixels) goal=\(scrollDistance ?? distance) history=\(value.total - value.len)")
                    break
                }
                guard attempt < 2, ghostty_surface_scrollbar(surface, &value) else { return nil }
            }
        }
        return ScrollPosition(history: max(0, Int(value.total) - Int(value.len)), offset: Int(value.offset), rows: Int(value.len))
    }

    nonisolated func prepend(_ bytes: Data, epoch expected: Int) -> Int {
        gridChanged.withLock {
            guard epoch == expected, case .confirmed = grid else { return 0 }
            return bytes.withUnsafeBytes {
                guard let base = $0.baseAddress else { return 0 }
                return Int(ghostty_surface_prepend_history(surface, base.assumingMemoryBound(to: CChar.self), UInt($0.count)))
            }
        }
    }

    nonisolated func trimHistory(keeping minimum: Int) -> Int {
        scrolling.sync {
            gridChanged.withLock {
                guard case .confirmed = grid else { return 0 }
                let position = scrollPosition()
                let distance = scrollTarget ?? (position.history - position.offset)
                let rows = max(0, min(position.offset - 5000, position.history - max(minimum, distance + 5000)))
                return Int(ghostty_surface_trim_history(surface, UInt(rows)))
            }
        }
    }

    nonisolated func scroll(to row: Int) {
        var value = ghostty_surface_scrollbar_s()
        clearScrollTarget()
        guard ghostty_surface_scrollbar(surface, &value) else { return }
        _ = ghostty_surface_scroll_to_row_if_revision(surface, UInt64(row), value.row_space_revision, &value)
    }

    func updateScroller(history: Int, position: ScrollPosition, alternate: Bool, limited: Bool = false) {
        let changed = self.alternate != alternate || scrollGeometry.history != history
            || scrollGeometry.position.history != position.history || scrollGeometry.position.rows != position.rows
            || scrollGeometry.limited != limited || (scrollTarget == nil && scrollGeometry.position.offset != position.offset)
        guard changed else { return }
        scrollRevision += 1
        updateAlternate(alternate)
        scrollGeometry = (history, position, scrollGeometry.captured, limited)
        if alternate { clearScrollTarget() }
        else {
            let limit = scrollLimit
            target.withLock { $0 = $0.map { min(Double(limit), $0) } }
        }
        queueScroll()
    }

    private func finishResize() {
        guard restoreCompleted, resizeAnchor == nil, (scrollTarget ?? 0) <= scrollGeometry.position.history else { return }
        thawing?.cancel()
        thawing = nil
        present()
    }

    private var scrollLimit: Int {
        let (history, position, _, limited) = scrollGeometry
        return limited ? min(history, position.history) : history
    }

    private func presentScroll() {
        let (position, applied) = scrollPresentation
        let history = scrollGeometry.history, limited = scrollGeometry.limited
        let distance = applied ?? Double(position.history - position.offset)
        historyLimit.isHidden = !limited || distance < Double(position.history - position.rows)
        let shifted = distance > Double(position.history)
        if shifted && !self.shifted {
            for button in pressed {
                let value = button == 0 ? GHOSTTY_MOUSE_LEFT : button == 1 ? GHOSTTY_MOUSE_RIGHT : GHOSTTY_MOUSE_MIDDLE
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, value, GHOSTTY_MODS_NONE)
            }
            pressed.removeAll()
            ghostty_surface_mouse_pressure(surface, 0, 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = CATransform3DMakeTranslation(0, -min(bounds.height, CGFloat(max(0, distance - Double(position.history))) * rowHeight), 0)
        if let layer = terminal.layer, !CATransform3DEqualToTransform(layer.transform, transform) {
            layer.transform = transform
            layer.setNeedsDisplay()
        }
        CATransaction.commit()
        scroller.update(history: history, rows: position.rows, offset: Double(history) - distance, alternate: alternate,
                        unavailable: limited ? max(0, history - position.history) : 0)
    }

    func requestScroll(_ distance: Int) {
        suppressMomentum = true
        wheelRemainder = 0
        requestScrollDistance { _ in Double(distance) }
    }

    private func requestScrollDistance(_ move: @Sendable (Double) -> Double) {
        let position = Double(scrollGeometry.position.history - scrollGeometry.position.offset), limit = Double(scrollLimit)
        target.withLock {
            let previous = $0 ?? position
            $0 = max(0, min(limit, move(previous)))
        }
        queueScroll()
    }

    private func queueScroll() {
        guard scrollPending == nil else { return }
        let revision = scrollRevision
        scrollPending = revision
        scrolling.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { _ = self } }
            let distance = scrollDistance
            let moved = scrollPosition(distance: distance)
            DispatchQueue.main.async {
                guard self.scrollPending == revision else { return }
                self.scrollPending = nil
                if self.scrollRevision != revision { self.queueScroll(); return }
                if let moved {
                    self.scrollGeometry.position = moved
                    self.scrollPresentation = (moved, distance)
                    self.presentScroll()
                    self.finishResize()
                }
                self.onScroll()
                self.scheduleTrim()
                if self.scrollDistance != distance { self.queueScroll() }
            }
        }
    }

    private func scheduleTrim() {
        trimming?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.alternate, self.find == nil, self.pressed.isEmpty else { return }
            self.onScrollSettled()
        }
        trimming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    nonisolated func clearScrollTarget() { target.withLock { $0 = nil } }

    func snapScroll() {
        suppressMomentum = true
        wheelRemainder = 0
        scrollRevision += 1
        scrolling.sync {
            if let distance = scrollDistance {
                let aligned = distance.rounded()
                target.withLock { $0 = aligned }
                if let moved = scrollPosition(distance: aligned) {
                    scrollGeometry.position = moved
                    scrollPresentation = (moved, aligned)
                }
            }
        }
        scrollPending = nil
        presentScroll()
    }

    func resetScroll() {
        snapScroll()
        scrollRevision += 1
        clearScrollTarget()
        scrollPresentation.distance = nil
        presentScroll()
        scheduleTrim()
    }

    private func updateAlternate(_ alternate: Bool) {
        guard self.alternate != alternate else { return }
        self.alternate = alternate
        onAlternateChange()
        resetScroll()
        find?.search()
    }

    override func layout() {
        super.layout()
        terminal.frame = bounds
        rowHeight = cell.height
        presentScroll()
        find?.frame = NSRect(x: 0, y: max(0, bounds.height - 36), width: bounds.width, height: 36)
        historyLimit.frame.size = historyLimit.contentView!.fittingSize
        historyLimit.frame.size.width += 16
        historyLimit.frame.size.height += 4
        historyLimit.frame.origin = NSPoint(x: (bounds.width - historyLimit.frame.width) / 2, y: max(0, bounds.height - historyLimit.frame.height - (find == nil ? 8 : 44)))
    }

    // Freed in deinit, so the last reference must be dropped on the main
    // thread, and never while the reader may feed it (Connection).
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t!

    // Ghostty resizes the terminal on its IO thread at least 25ms after
    // set_grid_size (termio/Thread.zig), so output fed before that lands in
    // the old grid. grid_metrics reads the terminal's grid under the renderer
    // lock, making the IO thread yield to it (renderer/State.zig lockDemand),
    // so main polls it from 25ms on to confirm a new grid, and feed waits for
    // that. Output a grid never confirmed is dropped, and the pane is captured
    // again once it is, or once the confirmation is given up.
    private enum Grid {
        case confirmed
        case pending(until: Date)
        case lost
    }

    private let gridChanged = NSCondition()
    nonisolated(unsafe) private var grid = Grid.confirmed

    private var presented = (visible: true, realized: true)
    private var keyUpMonitor: Any?
    private var paste: (alert: NSAlert, state: UnsafeMutableRawPointer?)?

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?

    // Ghostty calls back on its renderer and IO threads too, where a strong
    // reference to the view could be its last.
    nonisolated static func surface(_ userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        Unmanaged<PaneView>.fromOpaque(userdata!)._withUnsafeGuaranteedRef(\.surface)
    }

    nonisolated static func onMain(_ userdata: UnsafeMutableRawPointer?, _ body: @escaping @MainActor (PaneView) -> Void) {
        Unmanaged<PaneView>.fromOpaque(userdata!)._withUnsafeGuaranteedRef { view in
            DispatchQueue.main.async { [weak view] in view.map(body) }
        }
    }

    init?(runtime: GhosttyRuntime, pane: PaneID, font: Float, onInput: @escaping @MainActor @Sendable (Data) -> Void) {
        self.pane = pane
        self.onInput = onInput
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
        config.io_write_userdata = this
        // Called on the reader or Ghostty's IO thread; a strong reference
        // taken there could be the view's last.
        config.io_write_cb = { userdata, bytes, count in
            guard let bytes, count > 0 else { return }
            let input = Unmanaged<PaneView>.fromOpaque(userdata!)._withUnsafeGuaranteedRef(\.onInput)
            let data = Data(bytes: bytes, count: Int(count))
            DispatchQueue.main.async { input(data) }
        }
        guard let surface = ghostty_surface_new(runtime.app, &config) else { return nil }
        self.surface = surface
        let serialized = ghostty_config_serialize(runtime.config)
        if let bytes = serialized.ptr {
            let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(serialized.len)), as: UTF8.self)
            if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("mouse-scroll-multiplier = ") }) {
                for value in line.dropFirst("mouse-scroll-multiplier = ".count).split(separator: ",") {
                    let pair = value.split(separator: ":")
                    if pair.count == 2, let number = Double(pair[1]) {
                        if pair[0] == "precision" { wheelMultiplier.precision = number }
                        if pair[0] == "discrete" { wheelMultiplier.discrete = number }
                    }
                }
            }
        }
        ghostty_string_free(serialized)
        scroller.alphaValue = 0
        scroller.isHidden = true
        scroller.begin = { [weak self] in self?.snapScroll() }
        scroller.jump = { [weak self] in self?.requestScroll($0) }
        let label = NSTextField(labelWithString: "Older history not loaded (memory limit)")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let loadMore = NSButton(title: "Load more", target: self, action: #selector(loadMoreHistory))
        loadMore.bezelStyle = .rounded
        loadMore.controlSize = .small
        let content = NSStackView(views: [label, loadMore])
        historyLimit.boxType = .custom
        historyLimit.borderWidth = 0
        historyLimit.fillColor = .windowBackgroundColor
        historyLimit.cornerRadius = 5
        historyLimit.contentViewMargins = NSSize(width: 8, height: 2)
        historyLimit.contentView = content
        historyLimit.isHidden = true
        addSubview(historyLimit)
        ghostty_surface_set_color_scheme(surface, runtime.colorScheme)
        // The callback must not reenter the surface (ghostty.h).
        _ = ghostty_surface_set_font_size_action_callback(surface, { userdata, _, _, points, _, _ in
            PaneView.onMain(userdata) { $0.snapScroll(); $0.onFontChange(points) }
        }, this)
        updateTrackingAreas()
        // AppKit sends no keyUp through the responder chain while Command is
        // held (SurfaceView_AppKit.swift).
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), let window, event.window === window,
                window.firstResponder === self
            else { return event }
            keyUp(with: event)
            return nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated {
            if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
            guard let surface else { return }
            if let paste {
                complete(paste.state, "")
                paste.alert.window.sheetParent?.endSheet(paste.alert.window)
            }
            ghostty_surface_free(surface)
        }
    }

    nonisolated func feed(_ bytes: Data) {
        let confirmed = gridChanged.withLock {
            while case .pending(let until) = grid, gridChanged.wait(until: until) {}
            switch grid {
            case .confirmed: return true
            case .pending: grid = .lost
            case .lost: break
            }
            return false
        }
        guard confirmed else { return }
        scrolling.sync {
            let pinned = scrollDistance.map { $0 > 0 } == true ? scrollPosition() : nil
            bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                ghostty_surface_process_output(surface, base.assumingMemoryBound(to: CChar.self), UInt(buffer.count))
            }
            if let pinned {
                let position = scrollPosition()
                let delta = (position.history - position.offset) - (pinned.history - pinned.offset)
                target.withLock {
                    if let distance = $0, distance > 0 { $0 = max(0, distance + Double(delta)) }
                }
            }
            let captured = ghostty_surface_mouse_captured(surface), alternate = ghostty_surface_is_alternate_screen(surface)
            DispatchQueue.main.async { [weak self] in
                if let self, captured != scrollGeometry.captured { snapScroll() }
                self?.scrollGeometry.captured = captured
                self?.updateAlternate(alternate)
            }
        }
    }

    var font: Float { ghostty_surface_font_size(surface) }

    var cell: CGSize {
        let size = ghostty_surface_size(surface)
        return convertFromBacking(NSSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px)))
    }

    func resize(cols: Int, rows: Int) {
        let size = ghostty_surface_size(surface)
        guard (Int(size.columns), Int(size.rows)) != (cols, rows) else { return }
        snapScroll()
        resyncing?.cancel()
        restoreCompleted = false
        thawing?.cancel()
        let thaw = DispatchWorkItem { [weak self] in
            self?.thawing = nil
            self?.present()
        }
        thawing = thaw
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: thaw)
        if resizeAnchor == nil, !ghostty_surface_is_alternate_screen(surface) {
            let position = scrollPosition()
            if (scrollTarget ?? (position.history - position.offset)) > 0 {
                var text = ghostty_text_s()
                let lines = ghostty_surface_viewport_anchor(surface, &text)
                let body = text.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self) }
                resizeAnchor = ScrollAnchor(lines: Int(lines), text: body)
                if text.text != nil { ghostty_surface_free_text(surface, &text) }
            }
        }
        gridChanged.withLock { epoch += 1 }
        guard ghostty_surface_set_grid_size(surface, UInt16(cols), UInt16(rows), nil) else { return settle() }
        let now = Date.now, resize = historyEpoch
        gridChanged.withLock { if case .confirmed = grid { grid = .pending(until: now + 1) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.confirm(cols, rows, resize, until: now + 10)
        }
    }

    private func confirm(_ cols: Int, _ rows: Int, _ resize: Int, until: Date) {
        guard resize == historyEpoch else { return }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), (Int(metrics.columns), Int(metrics.rows)) == (cols, rows)
        else {
            guard Date.now < until else { return settle() }
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                self?.confirm(cols, rows, resize, until: until)
            }
        }
        settle()
    }

    private func settle() {
        gridChanged.withLock {
            grid = .confirmed
            gridChanged.broadcast()
        }
        scheduleResync()
    }

    private func scheduleResync() {
        resyncing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window?.inLiveResize != true else { return }
            self.resyncing = nil
            let epoch = self.historyEpoch
            self.onResync { [weak self] in
                DispatchQueue.main.async {
                    guard let self, epoch == self.historyEpoch else { return }
                    self.restoreCompleted = true
                    self.finishResize()
                }
            }
        }
        resyncing = work
        if window?.inLiveResize != true { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work) }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if resyncing != nil, gridChanged.withLock({ if case .confirmed = grid { true } else { false } }) { scheduleResync() }
    }

    // MARK: - Clipboard

    // A request is completed exactly once; an empty completion refuses it.
    private func complete(_ state: UnsafeMutableRawPointer?, _ text: String) {
        snapScroll()
        ghostty_surface_complete_clipboard_request(surface, text, state, true)
    }

    func deny(_ state: UnsafeMutableRawPointer?) {
        complete(state, "")
    }

    func confirmPaste(_ text: String, _ state: UnsafeMutableRawPointer?) {
        guard paste == nil, let window else { return deny(state) }
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

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { ghostty_surface_set_focus(surface, true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        snapScroll()
        let result = super.resignFirstResponder()
        if result { ghostty_surface_set_focus(surface, false) }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            center.addObserver(
                self, selector: #selector(present), name: NSWindow.didChangeOcclusionStateNotification, object: window)
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
        let hidden = isHiddenOrHasHiddenAncestor
        let next = (visible: !hidden && thawing == nil && window?.occlusionState.contains(.visible) == true, realized: !hidden)
        if next.realized != presented.realized { _ = ghostty_surface_set_renderer_realized(surface, next.realized) }
        if next.visible != presented.visible { ghostty_surface_set_occlusion(surface, next.visible) }
        presented = next
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        if let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
        snapScroll()
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_render_insets(surface, UInt32((historyStrip * scale).rounded()), 0)
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
        if let command = sender.representedObject as? PaneCommand { onCommand(command) }
    }

    // MARK: - Mouse

    private func inHistoryStrip(_ event: NSEvent) -> Bool {
        historyStrip > 0 && bounds.height - convert(event.locationInWindow, from: nil).y < historyStrip
    }

    private func button(_ event: NSEvent, _ state: ghostty_input_mouse_state_e) -> Bool {
        if state == GHOSTTY_MOUSE_PRESS {
            let strip = inHistoryStrip(event)
            if event.buttonNumber == 0 || strip {
                window?.makeFirstResponder(self)
                onSelect()
            }
            if strip { position(event); return true }
            snapScroll()
        } else if !pressed.contains(event.buttonNumber) { return true }
        guard !shifted else { return true }
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
        if inHistoryStrip(event) && pressed.isEmpty {
            ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
            return
        }
        guard !shifted, scrollDistance.map({ $0 == $0.rounded() }) != false else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let y = bounds.height - pos.y - historyStrip
        ghostty_surface_mouse_pos(surface, pos.x, y, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        _ = button(event, GHOSTTY_MOUSE_PRESS)
    }

    override func mouseUp(with event: NSEvent) {
        _ = button(event, GHOSTTY_MOUSE_RELEASE)
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !button(event, GHOSTTY_MOUSE_PRESS) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !button(event, GHOSTTY_MOUSE_RELEASE) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) { _ = button(event, GHOSTTY_MOUSE_PRESS) }
    override func otherMouseUp(with event: NSEvent) { _ = button(event, GHOSTTY_MOUSE_RELEASE) }
    override func mouseEntered(with event: NSEvent) { position(event) }
    override func mouseMoved(with event: NSEvent) { position(event) }
    override func mouseDragged(with event: NSEvent) { position(event) }
    override func rightMouseDragged(with event: NSEvent) { position(event) }
    override func otherMouseDragged(with event: NSEvent) { position(event) }

    override func mouseExited(with event: NSEvent) {
        guard !shifted, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func pressureChange(with event: NSEvent) {
        guard !shifted, !pressed.isEmpty else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    override func scrollWheel(with event: NSEvent) {
        let time = CACurrentMediaTime()
        debug("wheel pane=\(pane) time=\(time) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) precise=\(event.hasPreciseScrollingDeltas) delta=\(event.scrollingDeltaY) eventTime=\(event.timestamp)")
        let strip = inHistoryStrip(event)
        if strip { position(event) }
        let precise = event.hasPreciseScrollingDeltas
        if event.momentumPhase.isEmpty && event.scrollingDeltaY != 0 { suppressMomentum = false }
        if suppressMomentum && !event.momentumPhase.isEmpty { return }
        if !alternate && (!scrollGeometry.captured || strip) && scrollGeometry.history > 0 {
            guard event.scrollingDeltaY != 0 else { return }
            let delta = event.scrollingDeltaY
            let distance = scrollDistance ?? Double(scrollGeometry.position.history - scrollGeometry.position.offset)
            if precise && pressed.isEmpty {
                let rows = delta * wheelMultiplier.precision / Double(max(1, rowHeight))
                requestScrollDistance { $0 + rows }
                return
            }
            if distance != distance.rounded() { snapScroll() }
            wheelRemainder += precise ? delta * wheelMultiplier.precision / Double(max(1, rowHeight))
                : (delta > 0 ? max(1, delta) : min(-1, delta)) * wheelMultiplier.discrete
            let rows = Int(wheelRemainder)
            wheelRemainder -= Double(rows)
            if rows != 0 {
                requestScrollDistance { $0.rounded() + Double(rows) }
            }
            return
        }
        if strip { return }
        scheduleTrim()
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
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
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

    // Control characters are left to Ghostty's key encoder, and AppKit's
    // private-use function-key characters are not text.
    private static func text(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
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
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
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
        if scrollTarget != nil { resetScroll() }
        if let find, event.keyCode == 53 { find.close(); return }
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
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
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
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
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
        guard !hasMarkedText() else { return }
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
        guard event.type == .keyDown, window?.firstResponder === self else { return false }

        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
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
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
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
        snapScroll()
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
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
        let rect = convert(NSRect(x: x, y: bounds.height - historyStrip - y, width: width, height: max(height, cell.height)), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
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
