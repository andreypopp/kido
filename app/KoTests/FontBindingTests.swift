import AppKit
import GhosttyKit
import XCTest
@testable import Kido

final class FontBindingTests: XCTestCase {
    func testDefaultTriggers() throws {
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)
        for (action, scalar) in [("increase_font_size:1", "+"), ("decrease_font_size:1", "-"), ("reset_font_size", "0")] {
            let trigger = ghostty_config_trigger(config, action, UInt(action.utf8.count))
            XCTAssertEqual(trigger.tag, GHOSTTY_TRIGGER_UNICODE)
            XCTAssertEqual(trigger.key.unicode, scalar.unicodeScalars.first?.value)
            XCTAssertEqual(trigger.mods.eventFlags, .command)
        }
        let trigger = ghostty_config_trigger(config, "increase_font_size:1", 20)
        XCTAssertTrue(trigger.matches(keyCode: 24, mods: .command, text: "=", unshifted: "=", shifted: "+", shiftFree: false))
        XCTAssertTrue(trigger.matches(keyCode: 24, mods: [.command, .shift], text: "+", unshifted: "=", shifted: "+", shiftFree: true))
        XCTAssertFalse(trigger.matches(keyCode: 24, mods: [.command, .shift], text: "+", unshifted: "=", shifted: "+", shiftFree: false))
        let reset = ghostty_config_trigger(config, "reset_font_size", 15)
        XCTAssertFalse(reset.matches(keyCode: 29, mods: [.command, .shift], text: ")", unshifted: "0", shifted: ")", shiftFree: false))
        XCTAssertTrue(reset.matches(keyCode: 29, mods: [.command, .shift], text: ")", unshifted: "0", shifted: ")", shiftFree: true))
        var catchAll = ghostty_input_trigger_s()
        catchAll.tag = GHOSTTY_TRIGGER_CATCH_ALL
        XCTAssertFalse(catchAll.matches(keyCode: 24, mods: [], text: "=", unshifted: "=", shifted: "+", shiftFree: false))
        XCTAssertFalse(trigger.matches(keyCode: 24, mods: [.command, .option], text: "+", unshifted: "=", shifted: "+", shiftFree: false))
    }

    func testConfiguredTriggers() throws {
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }
        let text = "keybind = clear\nkeybind = ctrl+shift+key_q=increase_font_size:1\nkeybind = alt+ø=decrease_font_size:1\nkeybind = super+f5=reset_font_size\n"
        ghostty_config_load_string(config, text, UInt(text.utf8.count), "/font-bindings")
        ghostty_config_finalize(config)
        XCTAssertEqual(ghostty_config_diagnostics_count(config), 0)
        let increase = ghostty_config_trigger(config, "increase_font_size:1", 20)
        XCTAssertTrue(increase.matches(keyCode: 12, mods: [.control, .shift], text: "A", unshifted: "a", shifted: nil, shiftFree: false))
        XCTAssertFalse(increase.matches(keyCode: 0, mods: [.control, .shift], text: "Q", unshifted: "q", shifted: nil, shiftFree: false))
        XCTAssertFalse(increase.matches(keyCode: 12, mods: .control, text: "q", unshifted: "q", shifted: nil, shiftFree: false))
        XCTAssertFalse(increase.matches(keyCode: 12, mods: .control, text: "q", unshifted: "q", shifted: nil, shiftFree: true))
        let decrease = ghostty_config_trigger(config, "decrease_font_size:1", 20)
        XCTAssertTrue(decrease.matches(keyCode: 31, mods: .option, text: "ø", unshifted: "o", shifted: nil, shiftFree: false))
        XCTAssertTrue(decrease.matches(keyCode: 31, mods: [.option, .shift], text: "Ø", unshifted: "o", shifted: "ø", shiftFree: true))
        XCTAssertFalse(decrease.matches(keyCode: 31, mods: [.option, .command], text: "ø", unshifted: "o", shifted: nil, shiftFree: false))
        XCTAssertTrue(decrease.matches(keyCode: 31, mods: [.option, .capsLock], text: "ø", unshifted: "o", shifted: nil, shiftFree: false))
        XCTAssertFalse(decrease.matches(keyCode: 31, mods: .option, text: "øx", unshifted: "o", shifted: nil, shiftFree: false))
        let reset = ghostty_config_trigger(config, "reset_font_size", 15)
        XCTAssertTrue(reset.matches(keyCode: 96, mods: .command, text: nil, unshifted: nil, shifted: nil, shiftFree: false))
        XCTAssertFalse(reset.matches(keyCode: 97, mods: .command, text: nil, unshifted: nil, shifted: nil, shiftFree: false))
        let missing = ghostty_config_trigger(config, "increase_font_size:2", 20)
        XCTAssertFalse(missing.matches(keyCode: 0, mods: [], text: "a", unshifted: "a", shifted: nil, shiftFree: false))
    }
}
