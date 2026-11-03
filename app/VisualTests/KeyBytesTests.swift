import AppKit
import Carbon
import GhosttyKit
import KoClient
import KoModel
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

    // A new window whose pane records the bytes that reach it, shown.
    private func startRecorder(request: String, later: String = "") async throws -> URL {
        let file = directory.appendingPathComponent("recv-\(UUID().uuidString)")
        try Data().write(to: file)
        let ready = directory.appendingPathComponent("ready-\(UUID().uuidString)")
        let script = directory.appendingPathComponent("rec-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        printf '\u{1b}[<u\u{1b}[=0;1u\u{1b}[>4;0m\u{1b}[?2004h\(request)'
        stty raw -echo
        : > '\(ready.path)'
        \(later.isEmpty ? "" : "head -c 1 > /dev/null; printf '\(later)'")
        exec cat >> '\(file.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let window = try XCTUnwrap(koModel.map(\.layout.layout.windows)?.last?.id)
        let added = try await edit(.addWindow(KoSchema.EditAddWindow(after: window, new: KoSchema.CreatePane(command: .shell(.init(command: script.path))), session: SessionID(number: 1))))
        let recorder = try XCTUnwrap(added.createdWindow)
        try XCTUnwrap(client).select(KO_SELECT_WINDOW, recorder)
        try await wait("recorder ready", within: 5) { FileManager.default.fileExists(atPath: ready.path) }
        try await wait("the recorder is shown") { self.currentModel.window == recorder }
        try await settle()
        // The surface answers a flags query through the server: its reply is not a key.
        if request.contains("\u{1b}[?u") {
            try await wait("the flags reply", within: 5) { self.bytes(file).starts(with: Data("\u{1b}[?".utf8)) }
            try Data().write(to: file)
        }
        self.window.makeFirstResponder(try XCTUnwrap(terminal?.panes.first))
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
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let id = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(source, kTISPropertyInputSourceID)).takeUnretainedValue() as String
        guard id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" else {
            throw XCTSkip("keyboard layout is \(id); the test needs ABC or US")
        }
        try await start()
        // The bytes that Ghostty encodes reach the pane unchanged (ko_view_input).
        let plain = try await startRecorder(request: "")
        try await expect(Self.plainBytes, "plain", plain)
        _ = try await paste("plain", plain)

        let kitty = try await startRecorder(request: "\u{1b}[>7u\u{1b}[?u")
        try await expect(Self.kittyBytes, "kitty", kitty)

        let commands = try await startRecorder(request: "")
        runtime.pasteboard.clearContents()
        let chords: [(String, UInt16)] = [("c", 8), ("v", 9), ("f", 3), ("o", 31), ("k", 40), ("t", 17), ("h", 4), ("j", 38), ("l", 37), ("w", 13)]
        let pane = try XCTUnwrap(terminal?.panes.first)
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

    // The bytes a pane receives after `send`, up to a fence that follows them through the surface's own input
    // path (main, then the view's connection), so the two stay in order. A send through the server's HTTP API
    // has been handled when its call returns, so the fence follows it too. A paste answers on a later turn
    // of the main loop, so its test waits for the bytes first (`atLeast`).
    private func received(_ file: URL, atLeast: Int = 0, send: () async throws -> Void) async throws -> Data {
        try Data().write(to: file)
        try await send()
        try await wait("the bytes", within: 5) { self.bytes(file).count >= atLeast }
        let fence = Data("\u{2}FENCE\u{3}".utf8)
        let view = try XCTUnwrap(terminal?.panes.first?.koView)
        await withCheckedContinuation { done in
            DispatchQueue.main.async {
                try? view.text(fence)
                done.resume()
            }
        }
        try await wait("the fence after the bytes", within: 5) { self.bytes(file).range(of: fence) != nil }
        let all = bytes(file)
        return all.subdata(in: 0..<all.range(of: fence)!.lowerBound)
    }

    private func keyBody(_ action: String, key: Int, mods: Int, unshifted: Int, text: String) -> String {
        #"{"type":"key","action":"\#(action)","key":\#(key),"mods":\#(mods),"unshifted_codepoint":\#(unshifted),"text":"\#(text)","composing":false}"#
    }

    private func post(_ body: String) async throws {
        let file = directory.appendingPathComponent("body-\(UUID().uuidString).json")
        try Data(body.utf8).write(to: file)
        let pane = try XCTUnwrap(terminal?.panes.first).pane.description
        _ = try await ko(["api", "-X", "POST", "--input", file.path, "/panes/\(pane)/input"], dir: directory.path)
    }

    // What the surface encodes (sent to the pane as bytes) against what the server encodes for the same key,
    // under kitty flags 0, 1 and 3. Shift+Space is the one difference: the surface sends the text that the
    // key makes, the server's heuristic does not consume Shift.
    func testSurfaceBytesAndServerKeyReachThePaneAsTheSameBytes() async throws {
        try await start()
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), f1 = String(UnicodeScalar(NSF1FunctionKey)!)
        // name, the surface's event, the server's key, the expected bytes for flags 0, 1 and 3 (surface; server if it differs)
        let cases: [(KeyCase, String, Bool, [(String, String?)])] = [
            (KeyCase(name: "a", characters: "a"), keyBody("press", key: 20, mods: 0, unshifted: 97, text: "a"), false,
             [("61", nil), ("61", nil), ("61", nil)]),
            (KeyCase(name: "S-a", characters: "A", ignoring: "a", mods: [.shift]), keyBody("press", key: 20, mods: 1, unshifted: 97, text: "A"), false,
             [("41", nil), ("41", nil), ("41", nil)]),
            (KeyCase(name: "C-a", characters: "\u{01}", ignoring: "a", mods: [.control]), keyBody("press", key: 20, mods: 2, unshifted: 97, text: ""), false,
             [("01", nil), ("1b 5b 39 37 3b 35 75", nil), ("1b 5b 39 37 3b 35 75", nil)]),
            (KeyCase(name: "S-Space", characters: " ", mods: [.shift], code: 49), keyBody("press", key: 63, mods: 1, unshifted: 32, text: " "), false,
             [("20", nil), ("20", "1b 5b 33 32 3b 32 75"), ("20", "1b 5b 33 32 3b 32 75")]),
            (KeyCase(name: "Return", characters: "\r", code: 36), keyBody("press", key: 58, mods: 0, unshifted: 13, text: ""), false,
             [("0d", nil), ("0d", nil), ("0d", nil)]),
            (KeyCase(name: "Up", characters: up, code: 126), keyBody("press", key: 78, mods: 0, unshifted: 0, text: ""), false,
             [("1b 5b 41", nil), ("1b 5b 41", nil), ("1b 5b 31 3b 31 3a 31 41", nil)]),
            (KeyCase(name: "F1", characters: f1, code: 122), keyBody("press", key: 121, mods: 0, unshifted: 0, text: ""), false,
             [("1b 4f 50", nil), ("1b 5b 50", nil), ("1b 5b 31 3b 31 3a 31 50", nil)]),
            (KeyCase(name: "Escape", characters: "\u{1b}", code: 53), keyBody("press", key: 120, mods: 0, unshifted: 27, text: ""), false,
             [("1b", nil), ("1b 5b 32 37 75", nil), ("1b 5b 32 37 75", nil)]),
            (KeyCase(name: "a-release", characters: "a"), keyBody("release", key: 20, mods: 0, unshifted: 97, text: ""), true,
             [("", nil), ("", nil), ("1b 5b 39 37 3b 31 3a 33 75", nil)]),
        ]
        for (index, request) in ["", "\u{1b}[>1u\u{1b}[?u", "\u{1b}[>3u\u{1b}[?u"].enumerated() {
            let file = try await startRecorder(request: request)
            for (key, body, release, expected) in cases {
                if let pane = terminal?.panes.first { window.makeFirstResponder(pane) }
                let surface = try await received(file) { window.sendEvent(self.event(key, type: release ? .keyUp : .keyDown)) }
                let server = try await received(file) { try await post(body) }
                XCTAssertEqual(hex(surface), expected[index].0, "surface, flags set \(index), \(key.name)")
                XCTAssertEqual(hex(server), expected[index].1 ?? expected[index].0, "server, flags set \(index), \(key.name)")
            }
        }
    }

    private func click(_ pane: PaneView, type: NSEvent.EventType) -> NSEvent {
        let cell = pane.cell
        let point = pane.convert(NSPoint(x: cell.width * 2.5, y: pane.bounds.height - pane.renderInsets.top - cell.height * 1.5), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // A click under mode 1006 is the same bytes from the surface and from the server; under 1016 only the
    // surface has the pixel position. The events go to the pane directly: a click through the window is
    // not delivered to an off-screen window that is not key.
    func testSurfaceAndServerEncodeAMouseClickAlikeAndOnlyTheSurfaceHasPixels() async throws {
        try await start()
        let click1006 = "1b 5b 3c 30 3b 33 3b 32 4d 1b 5b 3c 30 3b 33 3b 32 6d"
        let file = try await startRecorder(request: "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?u")
        let pane = try XCTUnwrap(terminal?.panes.first)
        window.makeFirstResponder(pane)
        let surface = try await received(file) {
            pane.mouseDown(with: click(pane, type: .leftMouseDown))
            pane.mouseUp(with: click(pane, type: .leftMouseUp))
        }
        let server = try await received(file) {
            try await post(#"{"type":"mouse","action":"press","button":"left","col":2,"row":1,"mods":0}"#)
            try await post(#"{"type":"mouse","action":"release","button":"left","col":2,"row":1,"mods":0}"#)
        }
        XCTAssertEqual(hex(surface), click1006)
        XCTAssertEqual(hex(server), click1006)
        let pixels = try await startRecorder(request: "\u{1b}[?1000h\u{1b}[?1016h\u{1b}[?u")
        let precisePane = try XCTUnwrap(terminal?.panes.first)
        window.makeFirstResponder(precisePane)
        let precise = try await received(pixels) {
            precisePane.mouseDown(with: click(precisePane, type: .leftMouseDown))
            precisePane.mouseUp(with: click(precisePane, type: .leftMouseUp))
        }
        let numbers = String(decoding: precise, as: UTF8.self).dropFirst(3).prefix { $0 != "M" }.split(separator: ";").compactMap { Int($0) }
        XCTAssertEqual(numbers.count, 3)
        XCTAssertGreaterThan(numbers.dropFirst().first ?? 0, 3, "pixel x is past the cell column")
    }

    func testBracketedPasteOnAndOffAndADeadKeyAndTheFlagStackAcrossACopyModeResync() async throws {
        try await start()
        let board = runtime.pasteboard
        func paste(_ file: URL, _ text: String, bytes: Int) async throws -> Data {
            try await received(file, atLeast: bytes) {
                board.clearContents()
                board.setString(text, forType: .string)
                window.makeFirstResponder(try XCTUnwrap(terminal?.panes.first))
                let key = event(KeyCase(name: "paste", characters: "v", mods: [.command], code: 9))
                if !window.performKeyEquivalent(with: key), !(NSApp.mainMenu?.performKeyEquivalent(with: key) ?? false) { window.sendEvent(key) }
            }
        }
        let on = try await startRecorder(request: "\u{1b}[?2004h\u{1b}[?u")
        let bracketed = try await paste(on, "Cmd-V ✓\ntext", bytes: 26)
        let off = try await startRecorder(request: "\u{1b}[?2004l\u{1b}[?u")
        let raw = try await paste(off, "Cmd-V ✓", bytes: 9)
        XCTAssertEqual(bracketed, data("1b 5b 32 30 30 7e") + Data("Cmd-V ✓\ntext".utf8) + data("1b 5b 32 30 31 7e"))
        XCTAssertEqual(raw, Data("Cmd-V ✓".utf8), "a multi-line paste without brackets asks for consent first")

        let dead = try await startRecorder(request: "")
        window.makeFirstResponder(try XCTUnwrap(terminal?.panes.first))
        // insertText needs a current event, as a key event has.
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        _ = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
        let composed = try await received(dead) {
            let pane = try XCTUnwrap(terminal?.panes.first)
            pane.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            pane.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertEqual(hex(composed), "c3 a9", "a dead key and a letter commit é")

        let pushed = try await startRecorder(request: "", later: "\\033[>1u")
        let pane = try XCTUnwrap(terminal?.panes.first)
        window.makeFirstResponder(pane)
        try await wait("the first restore") { !pane.restoring }
        pane.toggleCopyMode(nil)
        try await wait("copy mode") { if case .cursor = pane.copyMode { true } else { false } }
        try await post(#"{"type":"text","data":"eA=="}"#)
        try await wait("the push reaches the frozen pane") { pane.visualDroppedWhileFrozen }
        pane.endCopy()
        try await wait("the new snapshot") { !pane.restoring }
        let afterResync = try await received(pushed) { window.sendEvent(self.event(KeyCase(name: "C-a", characters: "\u{01}", ignoring: "a", mods: [.control]))) }
        XCTAssertEqual(hex(afterResync), "1b 5b 39 37 3b 35 75", "the flags that were pushed while copy mode froze the pane apply")
    }
}
