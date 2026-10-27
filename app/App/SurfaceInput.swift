import AppKit
import GhosttyKit

enum SurfaceInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
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

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    // Control characters are left to Ghostty's key encoder, and AppKit's
    // private-use function-key characters are not text.
    static func text(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let scalars = text?.unicodeScalars, scalars.count == 1 else { return false }
        return scalars.first!.value < 0x20
    }

    @discardableResult
    static func key(
        _ surface: ghostty_surface_t,
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = mods(event.modifierFlags)
        key.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
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

    static func committedText(_ surface: ghostty_surface_t, _ action: ghostty_input_action_e, _ text: String) {
        var key = ghostty_input_key_s()
        key.action = action
        text.withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    // AppKit IMEs (Korean in particular) need the original event object
    // whenever the modifiers are unchanged.
    static func translation(_ event: NSEvent, _ surface: ghostty_surface_t) -> NSEvent {
        let translated = flags(ghostty_surface_key_translation_mods(surface, mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        return translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
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
    }

    static func deliver(_ surface: ghostty_surface_t, _ event: NSEvent, translation: NSEvent, accumulated: [String], composing: Bool, markedBefore: Bool) {
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if markedBefore, !accumulated.isEmpty {
            for text in accumulated where !isComposingControl(text, composing: composing) {
                committedText(surface, action, text)
            }
            // Arrows after a commit still move the cursor; a plain left arrow
            // is already accounted for by the IME.
            let replay: Bool = switch event.keyCode {
            case 0x7D, 0x7C, 0x7E: true
            case 0x7B: !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
            default: false
            }
            if replay { key(surface, action, event: event, translationMods: translation.modifierFlags) }
        } else if !accumulated.isEmpty {
            for text in accumulated where !isComposingControl(text, composing: composing) {
                key(surface, action, event: event, translationMods: translation.modifierFlags, text: text)
            }
        } else if !isComposingControl(event.characters, composing: composing) {
            key(surface, action, event: event, translationMods: translation.modifierFlags, text: text(translation), composing: composing)
        }
    }

    static func flagsChanged(_ surface: ghostty_surface_t, _ event: NSEvent) {
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
        let held = mods(event.modifierFlags).rawValue & mod.rawValue != 0
        let sidePressed = rightMask.map { event.modifierFlags.rawValue & UInt($0) != 0 } ?? true
        key(surface, held && sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    static func binding(_ surface: ghostty_surface_t, _ event: NSEvent) -> UInt32? {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = UInt32(event.keyCode)
        key.mods = mods(event.modifierFlags)
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            key.text = ptr
            return ghostty_surface_key_is_binding(surface, key, &flags)
        }
        return isBinding ? flags.rawValue : nil
    }

    static func momentum(_ event: NSEvent) -> ghostty_input_mouse_momentum_e {
        switch event.momentumPhase {
        case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }
}
