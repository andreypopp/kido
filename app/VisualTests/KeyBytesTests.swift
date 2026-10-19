import AppKit
import GhosttyKit
import TmuxControl
import XCTest
@testable import Kido

extension VisualTests {
    struct KeyCase {
        let name: String
        let characters: String
        var ignoring: String? = nil
        var mods: NSEvent.ModifierFlags = []
        var code: UInt16 = 0
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    private func startRecorder(_ pane: PaneView, request: String) async throws -> URL {
        let file = directory.appendingPathComponent("recv-\(UUID().uuidString)")
        try Data().write(to: file)
        let ready = directory.appendingPathComponent("ready-\(UUID().uuidString)")
        let script = directory.appendingPathComponent("rec-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        printf '\u{1b}[<u\u{1b}[=0;1u\u{1b}[>4;0m\u{1b}[?2004h\(request)'
        stty raw -echo
        : > '\(ready.path)'
        exec cat >> '\(file.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try await command(["respawn-pane", "-k", "-t", pane.pane.description, script.path])
        try await wait("recorder ready", within: 5) { FileManager.default.fileExists(atPath: ready.path) }
        try await settle()
        window.makeFirstResponder(pane)
        return file
    }

    private func bytes(_ file: URL) -> Data { (try? Data(contentsOf: file)) ?? Data() }

    private func event(_ key: KeyCase, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: key.mods,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.ignoring ?? key.characters,
            isARepeat: false, keyCode: key.code)!
    }

    private func drive(_ keys: [KeyCase]) {
        for key in keys { window.sendEvent(event(key)) }
    }

    private func keyCases() -> [KeyCase] {
        [
            KeyCase(name: "a", characters: "a"),
            KeyCase(name: "S-a", characters: "A", ignoring: "a", mods: [.shift]),
            KeyCase(name: "Return", characters: "\r", code: 36),
            KeyCase(name: "S-Return", characters: "\r", mods: [.shift], code: 36),
            KeyCase(name: "C-Return", characters: "\r", mods: [.control], code: 36),
            KeyCase(name: "M-Return", characters: "\r", mods: [.option], code: 36),
            KeyCase(name: "C-c", characters: "\u{03}", ignoring: "c", mods: [.control], code: 8),
            KeyCase(name: "C-a", characters: "\u{01}", ignoring: "a", mods: [.control]),
            KeyCase(name: "C-u", characters: "\u{15}", ignoring: "u", mods: [.control], code: 32),
            KeyCase(name: "C-w", characters: "\u{17}", ignoring: "w", mods: [.control], code: 13),
            KeyCase(name: "M-a", characters: "å", ignoring: "a", mods: [.option]),
            KeyCase(name: "M-z", characters: "Ω", ignoring: "z", mods: [.option], code: 6),
            KeyCase(name: "Tab", characters: "\t", code: 48),
            KeyCase(name: "S-Tab", characters: "\u{19}", ignoring: "\t", mods: [.shift], code: 48),
            KeyCase(name: "Up", characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126),
            KeyCase(name: "S-Up", characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), mods: [.shift], code: 126),
            KeyCase(name: "C-Up", characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), mods: [.control], code: 126),
            KeyCase(name: "M-Up", characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), mods: [.option], code: 126),
            KeyCase(name: "Down", characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125),
            KeyCase(name: "Right", characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124),
            KeyCase(name: "Left", characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123),
            KeyCase(name: "F1", characters: String(UnicodeScalar(NSF1FunctionKey)!), code: 122),
            KeyCase(name: "F5", characters: String(UnicodeScalar(NSF5FunctionKey)!), code: 96),
            KeyCase(name: "F12", characters: String(UnicodeScalar(NSF12FunctionKey)!), code: 111),
            KeyCase(name: "Escape", characters: "\u{1b}", code: 53),
            KeyCase(name: "BSpace", characters: "\u{7f}", code: 51),
            KeyCase(name: "Delete", characters: String(UnicodeScalar(NSDeleteFunctionKey)!), code: 117),
            KeyCase(name: "C-S-a", characters: "\u{01}", ignoring: "a", mods: [.control, .shift]),
        ]
    }

    private static let plainBytes: [String: String] = [
        "a": "61", "S-a": "41", "Return": "0d",
        "S-Return": "1b 5b 32 37 3b 32 3b 31 33 7e",
        "C-Return": "1b 5b 32 37 3b 35 3b 31 33 7e",
        "M-Return": "1b 0d", "C-c": "03", "C-a": "01", "C-u": "15", "C-w": "17",
        "M-a": "c3 a5", "M-z": "ce a9", "Tab": "09", "S-Tab": "1b 5b 5a",
        "Up": "1b 5b 41", "S-Up": "1b 5b 31 3b 32 41", "C-Up": "1b 5b 31 3b 35 41",
        "M-Up": "1b 5b 31 3b 33 41", "Down": "1b 5b 42", "Right": "1b 5b 43", "Left": "1b 5b 44",
        "F1": "1b 4f 50", "F5": "1b 5b 31 35 7e", "F12": "1b 5b 32 34 7e",
        "Escape": "1b", "BSpace": "7f", "Delete": "1b 5b 33 7e", "C-S-a": "1b 5b 39 37 3b 36 75",
    ]

    private static let kittyBytes: [String: String] = [
        "a": "61", "S-a": "41", "Return": "0d",
        "S-Return": "1b 5b 31 33 3b 32 75",
        "C-Return": "1b 5b 31 33 3b 35 75",
        "M-Return": "1b 5b 31 33 3b 33 75",
        "C-c": "1b 5b 39 39 3b 35 75", "C-a": "1b 5b 39 37 3b 35 75",
        "C-u": "1b 5b 31 31 37 3b 35 75", "C-w": "1b 5b 31 31 39 3b 35 75",
        "M-a": "c3 a5", "M-z": "ce a9", "Tab": "09", "S-Tab": "1b 5b 39 3b 32 75",
        "Up": "1b 5b 31 3b 31 3a 31 41", "S-Up": "1b 5b 31 3b 32 3a 31 41",
        "C-Up": "1b 5b 31 3b 35 3a 31 41", "M-Up": "1b 5b 31 3b 33 3a 31 41",
        "Down": "1b 5b 31 3b 31 3a 31 42", "Right": "1b 5b 31 3b 31 3a 31 43", "Left": "1b 5b 31 3b 31 3a 31 44",
        "F1": "1b 5b 31 3b 31 3a 31 50", "F5": "1b 5b 31 35 7e", "F12": "1b 5b 32 34 7e",
        "Escape": "1b 5b 32 37 75", "BSpace": "7f", "Delete": "1b 5b 33 7e",
        "C-S-a": "1b 5b 39 37 3a 36 35 3b 36 75",
    ]

    private func expect(_ table: [String: String], _ label: String, _ file: URL) async throws {
        let keys = keyCases()
        try Data().write(to: file)
        for key in keys {
            if let pane = terminal?.panes.first { window.makeFirstResponder(pane) }
            let start = bytes(file).count
            window.sendEvent(event(key))
            let wanted = data(table[key.name]!)
            try await wait("\(label) \(key.name)", within: 2) { self.bytes(file).count >= start + wanted.count }
            let got = bytes(file).dropFirst(start)
            XCTAssertEqual(Data(got), wanted, "\(label) \(key.name): \(hex(Data(got)))")
        }
    }

    private func toggleExtendedKeys(_ on: Bool) async throws {
        _ = try await command(["set", "-s", "extended-keys", on ? "on" : "off"])
        _ = try await command(["set", "-s", "extended-keys-format", "csi-u"])
    }

    private func paste(_ label: String, _ file: URL) async throws -> Data {
        try Data().write(to: file)
        runtime.pasteboard.clearContents()
        runtime.pasteboard.setString("Cmd-V ✓\ntext", forType: .string)
        window.makeFirstResponder(try XCTUnwrap(terminal?.panes.first))
        let event = event(KeyCase(name: "paste", characters: "v", mods: [.command], code: 9))
        if !window.performKeyEquivalent(with: event), !(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false) {
            window.sendEvent(event)
        }
        let expected = data("1b 5b 32 30 30 7e") + Data("Cmd-V ✓\ntext".utf8) + data("1b 5b 32 30 31 7e")
        try await wait("\(label) paste", within: 5) { self.bytes(file).count >= expected.count }
        let got = bytes(file)
        XCTAssertEqual(got, expected, "\(label) paste: \(hex(got))")
        try Data().write(to: file)
        return got
    }

    func testKeyBytes() async throws {
        try await start()
        let pane = try XCTUnwrap(terminal?.panes.first)
        let conf = try String(contentsOf: directory.appendingPathComponent("server.conf"), encoding: .utf8)
        XCTAssertTrue(conf.contains("set -s extended-keys on"))
        XCTAssertTrue(conf.contains("set -s extended-keys-format csi-u"))
        let extendedKeys = try await command(["show", "-s", "extended-keys"])
        XCTAssertEqual(extendedKeys, "extended-keys on")
        let extendedKeysFormat = try await command(["show", "-s", "extended-keys-format"])
        XCTAssertEqual(extendedKeysFormat, "extended-keys-format csi-u")

        let plain = try await startRecorder(pane, request: "")
        try await toggleExtendedKeys(true)
        try await expect(Self.plainBytes, "plain on", plain)
        try await toggleExtendedKeys(false)
        try await expect(Self.plainBytes, "plain off", plain)
        try await toggleExtendedKeys(true)
        _ = try await paste("plain on", plain)
        try await toggleExtendedKeys(false)
        _ = try await paste("plain off", plain)
        try await toggleExtendedKeys(true)

        let kitty = try await startRecorder(pane, request: "\u{1b}[>7u\u{1b}[?u")
        try await expect(Self.kittyBytes, "kitty on", kitty)
        try await toggleExtendedKeys(false)
        try await expect(Self.kittyBytes, "kitty off", kitty)
        try await toggleExtendedKeys(true)

        let commands = try await startRecorder(pane, request: "")
        runtime.pasteboard.clearContents()
        let chords: [(String, UInt16)] = [("c", 8), ("v", 9), ("f", 3), ("o", 31), ("k", 40), ("t", 17), ("h", 4), ("j", 38), ("l", 37), ("w", 13)]
        for (ch, code) in chords {
            window.makeFirstResponder(pane)
            let key = event(KeyCase(name: ch, characters: ch, mods: [.command], code: code))
            if !window.performKeyEquivalent(with: key), !(NSApp.mainMenu?.performKeyEquivalent(with: key) ?? false) {
                window.sendEvent(key)
            }
        }
        window.makeFirstResponder(pane)
        drive([KeyCase(name: "a", characters: "a")])
        try await wait("command chords", within: 5) { self.bytes(commands).count >= 1 }
        XCTAssertEqual(bytes(commands), Data("a".utf8), "command chords: \(hex(bytes(commands)))")
    }
}
