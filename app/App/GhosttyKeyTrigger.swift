import AppKit
import GhosttyKit

extension ghostty_input_mods_e {
    var eventFlags: NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }
}

extension ghostty_input_trigger_s {
    func matches(keyCode: UInt16, mods: NSEvent.ModifierFlags, text: String?, unshifted: String?, shifted: String?, shiftFree: Bool) -> Bool {
        let flags = mods.intersection([.shift, .control, .option, .command])
        switch tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            return self.mods.eventFlags == flags && Self.keyCodes[key.physical] == keyCode
        case GHOSTTY_TRIGGER_UNICODE:
            guard shiftFree ? self.mods.eventFlags.subtracting(.shift) == flags.subtracting(.shift) : self.mods.eventFlags == flags else { return false }
            return [text, unshifted, shifted].contains { value in
                guard let scalars = value?.unicodeScalars, scalars.count == 1 else { return false }
                return scalars.first?.value == key.unicode
            }
        default:
            return false
        }
    }

    private static let keyCodes: [ghostty_input_key_e: UInt16] = [
        GHOSTTY_KEY_BACKQUOTE: 50, GHOSTTY_KEY_BACKSLASH: 42, GHOSTTY_KEY_BRACKET_LEFT: 33, GHOSTTY_KEY_BRACKET_RIGHT: 30,
        GHOSTTY_KEY_COMMA: 43, GHOSTTY_KEY_DIGIT_0: 29, GHOSTTY_KEY_DIGIT_1: 18, GHOSTTY_KEY_DIGIT_2: 19,
        GHOSTTY_KEY_DIGIT_3: 20, GHOSTTY_KEY_DIGIT_4: 21, GHOSTTY_KEY_DIGIT_5: 23, GHOSTTY_KEY_DIGIT_6: 22,
        GHOSTTY_KEY_DIGIT_7: 26, GHOSTTY_KEY_DIGIT_8: 28, GHOSTTY_KEY_DIGIT_9: 25, GHOSTTY_KEY_EQUAL: 24,
        GHOSTTY_KEY_INTL_BACKSLASH: 10, GHOSTTY_KEY_INTL_RO: 94, GHOSTTY_KEY_INTL_YEN: 93,
        GHOSTTY_KEY_A: 0, GHOSTTY_KEY_B: 11, GHOSTTY_KEY_C: 8, GHOSTTY_KEY_D: 2, GHOSTTY_KEY_E: 14,
        GHOSTTY_KEY_F: 3, GHOSTTY_KEY_G: 5, GHOSTTY_KEY_H: 4, GHOSTTY_KEY_I: 34, GHOSTTY_KEY_J: 38,
        GHOSTTY_KEY_K: 40, GHOSTTY_KEY_L: 37, GHOSTTY_KEY_M: 46, GHOSTTY_KEY_N: 45, GHOSTTY_KEY_O: 31,
        GHOSTTY_KEY_P: 35, GHOSTTY_KEY_Q: 12, GHOSTTY_KEY_R: 15, GHOSTTY_KEY_S: 1, GHOSTTY_KEY_T: 17,
        GHOSTTY_KEY_U: 32, GHOSTTY_KEY_V: 9, GHOSTTY_KEY_W: 13, GHOSTTY_KEY_X: 7, GHOSTTY_KEY_Y: 16, GHOSTTY_KEY_Z: 6,
        GHOSTTY_KEY_MINUS: 27, GHOSTTY_KEY_PERIOD: 47, GHOSTTY_KEY_QUOTE: 39, GHOSTTY_KEY_SEMICOLON: 41, GHOSTTY_KEY_SLASH: 44,
        GHOSTTY_KEY_ALT_LEFT: 58, GHOSTTY_KEY_ALT_RIGHT: 61, GHOSTTY_KEY_BACKSPACE: 51, GHOSTTY_KEY_CAPS_LOCK: 57,
        GHOSTTY_KEY_CONTEXT_MENU: 110, GHOSTTY_KEY_CONTROL_LEFT: 59, GHOSTTY_KEY_CONTROL_RIGHT: 62, GHOSTTY_KEY_ENTER: 36,
        GHOSTTY_KEY_META_LEFT: 55, GHOSTTY_KEY_META_RIGHT: 54, GHOSTTY_KEY_SHIFT_LEFT: 56, GHOSTTY_KEY_SHIFT_RIGHT: 60,
        GHOSTTY_KEY_SPACE: 49, GHOSTTY_KEY_TAB: 48, GHOSTTY_KEY_DELETE: 117, GHOSTTY_KEY_END: 119,
        GHOSTTY_KEY_HOME: 115, GHOSTTY_KEY_INSERT: 114, GHOSTTY_KEY_PAGE_DOWN: 121, GHOSTTY_KEY_PAGE_UP: 116,
        GHOSTTY_KEY_ARROW_DOWN: 125, GHOSTTY_KEY_ARROW_LEFT: 123, GHOSTTY_KEY_ARROW_RIGHT: 124, GHOSTTY_KEY_ARROW_UP: 126,
        GHOSTTY_KEY_NUM_LOCK: 71, GHOSTTY_KEY_NUMPAD_0: 82, GHOSTTY_KEY_NUMPAD_1: 83, GHOSTTY_KEY_NUMPAD_2: 84,
        GHOSTTY_KEY_NUMPAD_3: 85, GHOSTTY_KEY_NUMPAD_4: 86, GHOSTTY_KEY_NUMPAD_5: 87, GHOSTTY_KEY_NUMPAD_6: 88,
        GHOSTTY_KEY_NUMPAD_7: 89, GHOSTTY_KEY_NUMPAD_8: 91, GHOSTTY_KEY_NUMPAD_9: 92, GHOSTTY_KEY_NUMPAD_ADD: 69,
        GHOSTTY_KEY_NUMPAD_COMMA: 95, GHOSTTY_KEY_NUMPAD_DECIMAL: 65, GHOSTTY_KEY_NUMPAD_DIVIDE: 75,
        GHOSTTY_KEY_NUMPAD_ENTER: 76, GHOSTTY_KEY_NUMPAD_EQUAL: 81, GHOSTTY_KEY_NUMPAD_MULTIPLY: 67, GHOSTTY_KEY_NUMPAD_SUBTRACT: 78,
        GHOSTTY_KEY_ESCAPE: 53, GHOSTTY_KEY_F1: 122, GHOSTTY_KEY_F2: 120, GHOSTTY_KEY_F3: 99, GHOSTTY_KEY_F4: 118,
        GHOSTTY_KEY_F5: 96, GHOSTTY_KEY_F6: 97, GHOSTTY_KEY_F7: 98, GHOSTTY_KEY_F8: 100, GHOSTTY_KEY_F9: 101,
        GHOSTTY_KEY_F10: 109, GHOSTTY_KEY_F11: 103, GHOSTTY_KEY_F12: 111, GHOSTTY_KEY_F13: 105, GHOSTTY_KEY_F14: 107,
        GHOSTTY_KEY_F15: 113, GHOSTTY_KEY_F16: 106, GHOSTTY_KEY_F17: 64, GHOSTTY_KEY_F18: 79, GHOSTTY_KEY_F19: 80, GHOSTTY_KEY_F20: 90,
        GHOSTTY_KEY_AUDIO_VOLUME_DOWN: 73, GHOSTTY_KEY_AUDIO_VOLUME_MUTE: 74, GHOSTTY_KEY_AUDIO_VOLUME_UP: 72,
    ]
}
