import AppKit
import GhosttyKit

final class ScrollbackView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    let runtime: GhosttyRuntime
    private let canvas = TerminalView()
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t!
    private var surfaceRef: SurfaceRef!
    private var vsyncContext: Unmanaged<VsyncDriver>?
    private(set) var disposed = false
    private var surfaceFocus: Bool?
    private var presented = (visible: true, realized: true)
    private var mouseShape = GHOSTTY_MOUSE_SHAPE_TEXT
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    var onFinish: (_ screen: String) -> Void = { _ in }
    var onCommand: (PaneCommand) -> Void = { _ in }
    var onSelect: () -> Void = {}

    nonisolated static func onMain(_ userdata: UnsafeMutableRawPointer?, _ body: @escaping @MainActor (ScrollbackView) -> Void) {
        guard case .scrollback(let owner) = SurfaceRef.owner(userdata) else { return }
        owner._withUnsafeGuaranteedRef { view in
            DispatchQueue.main.async { [weak view] in guard let view, !view.disposed else { return }; body(view) }
        }
    }

    init?(runtime: GhosttyRuntime, font: Float, command: String, environment: [String: String], directory: String) {
        self.runtime = runtime
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.masksToBounds = true
        canvas.frame = bounds
        addSubview(canvas)
        var config = ghostty_surface_config_new()
        let ref = SurfaceRef(.scrollback(Unmanaged.passUnretained(self)))
        surfaceRef = ref
        config.userdata = Unmanaged.passUnretained(ref).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(canvas).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = font
        config.io_mode = GHOSTTY_SURFACE_IO_EXEC
        let driver = VsyncDriver(view: canvas)
        let context = Unmanaged.passRetained(driver)
        vsyncContext = context
        config.vsync_request_cb = { VsyncDriver.request($0) }
        config.vsync_userdata = context.toOpaque()
        let pairs = environment.map { (strdup($0.key)!, strdup($0.value)!) }
        let strings = [strdup(directory)!, strdup(command)!]
        defer { (pairs.flatMap { [$0.0, $0.1] } + strings).forEach { free($0) } }
        var variables = pairs.map { ghostty_env_var_s(key: UnsafePointer($0.0), value: UnsafePointer($0.1)) }
        config.working_directory = UnsafePointer(strings[0])
        config.command = UnsafePointer(strings[1])
        let created = variables.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return ghostty_surface_new(runtime.app, &config)
        }
        guard let surface = created else {
            driver.close()
            context.release()
            vsyncContext = nil
            return nil
        }
        self.surface = surface
        if font > 0 { setFontSize(font) }
        driver.attach(surface)
        ghostty_surface_set_color_scheme(surface, runtime.colorScheme)
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        MainActor.assumeIsolated { freeSurface() }
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        freeSurface()
    }

    private func freeSurface() {
        guard let surface else { return }
        vsyncContext?.takeUnretainedValue().close()
        ghostty_surface_free(surface)
        vsyncContext?.release()
        vsyncContext = nil
        self.surface = nil
    }

    func setFontSize(_ points: Float) {
        guard !disposed else { return }
        let action = "set_font_size:\(points)"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    func finish() {
        guard !disposed else { return }
        let screen = screenText()
        dispose()
        onFinish(screen)
    }

    private func screenText() -> String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text), let bytes = text.text else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        guard mouseShape != shape else { return }
        mouseShape = shape
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mouseShape == GHOSTTY_MOUSE_SHAPE_POINTER ? .pointingHand : .iBeam)
    }

    func readClipboard(_ state: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, list: Bool) -> ghostty_clipboard_read_result_e {
        guard !disposed, let state, ghostty_clipboard_request_kind(state) == GHOSTTY_CLIPBOARD_REQUEST_PASTE else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        let text = runtime.pasteboard.string(forType: .string) ?? ""
        GhosttyRuntime.completeClipboard(surface, [("text/plain", Data(text.utf8))], available: list ? ["text/plain"] : [], state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    func confirmPaste(_ text: String?, _ state: UnsafeMutableRawPointer?) {
        guard !disposed else { return }
        GhosttyRuntime.completeClipboard(surface, text.map { [("text/plain", Data($0.utf8))] } ?? [], state, confirmed: text != nil)
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        syncSize()
    }

    private func syncSize() {
        guard !disposed, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(max(1, bounds.width * scale)), UInt32(max(1, bounds.height * scale)))
    }

    private func setSurfaceFocus(_ focused: Bool) {
        guard !disposed, surfaceFocus != focused else { return }
        surfaceFocus = focused
        ghostty_surface_set_focus(surface, focused)
    }

    func syncFocus() {
        setSurfaceFocus(window?.firstResponder === self && (NSApp.keyWindow == nil || NSApp.keyWindow === window)
            && (window as? OwnerWindow)?.allowsPaneInput != false)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { syncFocus() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setSurfaceFocus(false) }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncFocus()
        syncSize()
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let window {
            center.addObserver(self, selector: #selector(present), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            center.addObserver(self, selector: #selector(present), name: NSWindow.didChangeScreenNotification, object: window)
        }
        present()
    }

    override func viewDidHide() { super.viewDidHide(); present() }
    override func viewDidUnhide() { super.viewDidUnhide(); present() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSize()
    }

    @objc private func present() {
        guard !disposed else { return }
        vsyncContext?.takeUnretainedValue().updateAvailability()
        let hidden = isHiddenOrHasHiddenAncestor
        var visible = window?.occlusionState.contains(.visible) == true
        #if KIDO_VISUAL
        visible = visible || PaneView.renderOffscreen
        #endif
        let next = (visible: !hidden && visible, realized: !hidden)
        if next.realized != presented.realized { _ = ghostty_surface_set_renderer_realized(surface, next.realized) }
        if next.visible != presented.visible { ghostty_surface_set_occlusion(surface, next.visible) }
        presented = next
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    private func button(_ event: NSEvent, _ state: ghostty_input_mouse_state_e) {
        if state == GHOSTTY_MOUSE_PRESS, event.buttonNumber == 0 {
            window?.makeFirstResponder(self)
            onSelect()
        }
        position(event)
        let button = switch event.buttonNumber {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        default: GHOSTTY_MOUSE_UNKNOWN
        }
        _ = ghostty_surface_mouse_button(surface, state, button, SurfaceInput.mods(event.modifierFlags))
    }

    private func position(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, max(0, bounds.height - point.y), SurfaceInput.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) { button(event, GHOSTTY_MOUSE_PRESS) }
    override func mouseUp(with event: NSEvent) { button(event, GHOSTTY_MOUSE_RELEASE) }
    override func rightMouseDown(with event: NSEvent) { button(event, GHOSTTY_MOUSE_PRESS) }
    override func rightMouseUp(with event: NSEvent) { button(event, GHOSTTY_MOUSE_RELEASE) }
    override func otherMouseDown(with event: NSEvent) { button(event, GHOSTTY_MOUSE_PRESS) }
    override func otherMouseUp(with event: NSEvent) { button(event, GHOSTTY_MOUSE_RELEASE) }
    override func mouseEntered(with event: NSEvent) { position(event) }
    override func mouseMoved(with event: NSEvent) { position(event) }
    override func mouseDragged(with event: NSEvent) { position(event) }
    override func rightMouseDragged(with event: NSEvent) { position(event) }
    override func otherMouseDragged(with event: NSEvent) { position(event) }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let intent = ghostty_surface_wheel_intent(surface, false)
        guard intent != GHOSTTY_WHEEL_IGNORE else { return }
        let mods = (precise ? 1 : 0) | Int32(SurfaceInput.momentum(event).rawValue) << 1
        _ = ghostty_surface_wheel_input(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods, SurfaceInput.mods(event.modifierFlags), false, intent)
    }

    private var acceptsKeyInput: Bool { !disposed && (window as? OwnerWindow)?.allowsPaneInput != false }

    override func keyDown(with event: NSEvent) {
        guard acceptsKeyInput else { return }
        let translation = SurfaceInput.translation(event, surface)
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        interpretKeyEvents([translation])
        syncPreedit(clearIfNeeded: markedBefore)
        SurfaceInput.deliver(surface, event, translation: translation, accumulated: keyTextAccumulator ?? [],
                             composing: markedText.length > 0 || markedBefore, markedBefore: markedBefore)
    }

    override func keyUp(with event: NSEvent) {
        guard acceptsKeyInput else { return }
        SurfaceInput.key(surface, GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard acceptsKeyInput, !hasMarkedText() else { return }
        SurfaceInput.flagsChanged(surface, event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard acceptsKeyInput, event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.contains(.command) else { return false }
        guard let flags = SurfaceInput.binding(surface, event) else { return false }
        if flags & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue != 0,
           flags & (GHOSTTY_BINDING_FLAGS_ALL.rawValue | GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) == 0,
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        keyDown(with: event)
        return true
    }

    override func doCommand(by selector: Selector) {}

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard acceptsKeyInput, item.action == #selector(runCommand(_:)), let command = item.representedObject as? PaneCommand else { return false }
        if case .close = command { return false }
        return true
    }

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? PaneCommand else { return }
        onCommand(command)
    }

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
        guard acceptsKeyInput else { return }
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard acceptsKeyInput, markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let rect = convert(NSRect(x: x, y: bounds.height - y, width: width, height: height), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard acceptsKeyInput, NSApp.currentEvent != nil else { return }
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
            SurfaceInput.committedText(surface, GHOSTTY_ACTION_PRESS, chars)
        } else {
            ghostty_surface_text_input(surface, chars, UInt(chars.utf8.count))
        }
    }
}
