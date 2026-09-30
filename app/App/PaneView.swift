import AppKit
import GhosttyKit

struct Grid: Equatable {
    var cols: Int
    var rows: Int
    var cell: CGSize
}

final class PaneView: NSView, @preconcurrency NSTextInputClient {
    var onInput: (Data) -> Void = { _ in }
    var onGridChange: (Grid) -> Void = { _ in }

    // The tmux reader thread feeds it while deinit may free it; unsound once views close.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t!
    private(set) var grid = Grid(cols: 0, rows: 0, cell: .zero)

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?

    nonisolated static func from(_ userdata: UnsafeMutableRawPointer?) -> PaneView {
        Unmanaged<PaneView>.fromOpaque(userdata!).takeUnretainedValue()
    }

    init?(runtime: GhosttyRuntime) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var config = ghostty_surface_config_new()
        let this = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = this
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: this))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.io_write_userdata = this
        config.io_write_cb = { userdata, bytes, count in
            guard let bytes, count > 0 else { return }
            let pane = PaneView.from(userdata)
            let data = Data(bytes: bytes, count: Int(count))
            DispatchQueue.main.async { pane.onInput(data) }
        }
        guard let surface = ghostty_surface_new(runtime.app, &config) else { return nil }
        self.surface = surface
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        ghostty_surface_free(surface)
    }

    nonisolated func feed(_ bytes: Data) {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            ghostty_surface_process_output(surface, base.assumingMemoryBound(to: CChar.self), UInt(buffer.count))
        }
    }

    func updateGrid() {
        let size = ghostty_surface_size(surface)
        let next = Grid(
            cols: Int(size.columns),
            rows: Int(size.rows),
            cell: convertFromBacking(NSSize(width: Int(size.cell_width_px), height: Int(size.cell_height_px))))
        guard next != grid else { return }
        grid = next
        onGridChange(next)
    }

    private func resize() {
        let px = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
        updateGrid()
    }

    // MARK: - NSView

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { ghostty_surface_set_focus(surface, true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { ghostty_surface_set_focus(surface, false) }
        return result
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
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
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        resize()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self))
        super.updateTrackingAreas()
    }

    // MARK: - Mouse

    private func button(_ event: NSEvent, _ state: ghostty_input_mouse_state_e) -> Bool {
        let button = switch event.buttonNumber {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        default: GHOSTTY_MOUSE_UNKNOWN
        }
        return ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    private func position(_ event: NSEvent) {
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
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
        guard NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func pressureChange(with event: NSEvent) {
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
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
        let factor = precise ? 2.0 : 1.0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor, mods)
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
    // the event system and recognised in doCommand by its timestamp.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }

        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            key.text = ptr
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        if isBinding {
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
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let rect = convert(NSRect(x: x, y: bounds.height - y, width: width, height: max(height, grid.cell.height)), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
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
