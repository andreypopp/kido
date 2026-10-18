import AppKit
import GhosttyKit
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class ClipboardTests: VisualTestCase {
    @MainActor private final class Replies {
        var data: [Data] = []
        var text: String { String(decoding: data.joined(), as: UTF8.self) }
    }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func osc(_ metadata: String, _ payload: String? = nil) -> Data {
        Data("\u{1b}]5522;\(metadata)\(payload.map { ";" + $0 } ?? "")\u{1b}\\".utf8)
    }

    private func kittyPane() throws -> (board: NSPasteboard, runtime: GhosttyRuntime, owner: WindowOwner, pane: PaneView, replies: Replies) {
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .remote("rich-host"), runtime: runtime, start: false)
        let replies = Replies()
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13, host: owner.host) { replies.data.append($0) })
        owner.window.contentView = pane
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        addTeardownBlock { @MainActor in pane.dispose(); owner.close(); board.releaseGlobally() }
        return (board, runtime, owner, pane, replies)
    }

    func testModeFiveFiveTwoTwoCmdVEmitsPasteEventForOneRead() async throws {
        let (board, runtime, owner, pane, replies) = try kittyPane()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2])
        func set(_ text: String) {
            board.clearContents()
            board.declareTypes([.string, .png], owner: nil)
            board.setString(text, forType: .string)
            board.setData(png, forType: .png)
        }
        func paste() async throws -> String {
            replies.data = []
            XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "paste_from_clipboard", 20))
            try await drain(runtime)
            let pw = try XCTUnwrap(replies.text.components(separatedBy: "pw=").dropFirst().first?.prefix { $0 != "\u{1b}" })
            XCTAssertEqual(replies.text, "\u{1b}]5522;type=read:status=OK:pw=\(pw)\u{1b}\\\u{1b}]5522;type=read:status=DATA:mime=Lg==:pw=\(pw);"
                + b64("text/plain image/png\n") + "\u{1b}\\\u{1b}]5522;type=read:status=DONE:pw=\(pw)\u{1b}\\", "Cmd-V under mode 5522 sends the event, not text")
            XCTAssertNil(owner.preparedAlert)
            return String(pw)
        }
        func read(_ pw: String) async throws -> String {
            replies.data = []
            XCTAssertTrue(pane.feed(osc("type=read:name=\(b64("test")):pw=\(pw)", b64("image/png"))))
            try await drain(runtime)
            return replies.text
        }
        set("hello")
        XCTAssertTrue(pane.feed(Data("\u{1b}[?2004h\u{1b}[?5522h".utf8)))
        try await drain(runtime)
        let pw = try await paste()
        let served = try await read(pw)
        XCTAssertEqual(served, "\u{1b}]5522;type=read:status=OK\u{1b}\\\u{1b}]5522;type=read:status=DATA:mime=\(b64("image/png"));\(png.base64EncodedString())\u{1b}\\\u{1b}]5522;type=read:status=DONE\u{1b}\\")
        XCTAssertNil(owner.preparedAlert)
        let replayed = try await read(pw)
        XCTAssertEqual(replayed, "", "a used password is an application read, which asks first")
        XCTAssertNotNil(owner.preparedAlert)
        owner.respondToAlert(.alertThirdButtonReturn)
        try await drain(runtime)
        XCTAssertEqual(replies.text, "\u{1b}]5522;type=read:status=EPERM\u{1b}\\")
        owner.clipboardPermission = [:]
        let stale = try await paste()
        set("changed")
        let changed = try await read(stale)
        XCTAssertEqual(changed, "\u{1b}]5522;type=read:status=OK\u{1b}\\\u{1b}]5522;type=read:status=DONE\u{1b}\\")
        XCTAssertNil(owner.preparedAlert)
        func superseded(_ old: String) async throws {
            try await wait("previous sheet closed") { owner.window.attachedSheet == nil }
            set("next")
            _ = try await paste()
            let late = try await read(old)
            XCTAssertEqual(late, "", "a newer paste event revokes an unused older password")
            XCTAssertNotNil(owner.preparedAlert)
            owner.respondToAlert(.alertThirdButtonReturn)
            try await drain(runtime)
            XCTAssertEqual(replies.text, "\u{1b}]5522;type=read:status=EPERM\u{1b}\\")
            owner.clipboardPermission = [:]
        }
        try await superseded(try await paste())
        let old = PaneView.pasteEventTimeout
        PaneView.pasteEventTimeout = 0.1
        defer { PaneView.pasteEventTimeout = old }
        let expired = try await paste()
        try await wait("paste event expired") { pane.visualPasteEventExpired }
        PaneView.pasteEventTimeout = old
        try await superseded(expired)
    }

    func testRichReadAsksSeparatelyAndResetDeniesIt() async throws {
        let (board, runtime, owner, pane, replies) = try kittyPane()
        board.clearContents()
        board.declareTypes([.string, .png], owner: nil)
        board.setString("text", forType: .string)
        board.setData(Data([1, 2, 3]), forType: .png)
        XCTAssertTrue(pane.feed(osc("type=read", b64("."))))
        try await drain(runtime)
        XCTAssertEqual(replies.text, "\u{1b}]5522;type=read:status=OK\u{1b}\\\u{1b}]5522;type=read:status=DATA:mime=Lg==;\(b64("text/plain image/png\n"))\u{1b}\\\u{1b}]5522;type=read:status=DONE\u{1b}\\")
        XCTAssertNil(owner.preparedAlert)
        replies.data = []
        owner.clipboardPermission[.clipboard] = .allow
        XCTAssertTrue(pane.feed(osc("type=read", b64("text/plain"))))
        try await drain(runtime)
        XCTAssertTrue(replies.text.contains("status=DATA:mime=\(b64("text/plain"));\(b64("text"))"), replies.text)
        XCTAssertNil(owner.preparedAlert)
        replies.data = []
        XCTAssertTrue(pane.feed(osc("type=read", b64("image/png"))))
        try await drain(runtime)
        XCTAssertEqual(owner.preparedAlert?.alert.messageText, "Allow applications on “rich-host” to read images, HTML and file lists from your Mac clipboard?")
        XCTAssertEqual(replies.text, "", "a text grant does not serve a rich read")
        WindowOwner.resetClipboardPermissions([owner])
        try await drain(runtime)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(owner.clipboardPermission, [:])
        XCTAssertEqual(replies.text, "\u{1b}]5522;type=read:status=EPERM\u{1b}\\")
        replies.data = []
        XCTAssertTrue(pane.feed(osc("type=read", b64("image/png"))))
        try await drain(runtime)
        XCTAssertNotNil(owner.preparedAlert)
        pane.invalidateClipboard()
        try await drain(runtime)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(replies.text, "", "a reconnect drops a pending read without a reply")
    }

    func testKittyWritesValidateEveryRepresentation() async throws {
        let (board, runtime, _, pane, replies) = try kittyPane()
        board.clearContents()
        board.setString("before", forType: .string)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 9])
        func write(_ parts: [(String, Data)]) -> Data {
            parts.reduce(osc("type=write")) { $0 + osc("type=wdata:mime=\(b64($1.0))", $1.1.base64EncodedString()) } + osc("type=wdata")
        }
        let changes = board.changeCount
        XCTAssertTrue(pane.feed(write([("image/png", png), ("application/x-unknown", Data("x".utf8))])))
        try await drain(runtime)
        XCTAssertEqual(replies.text, "\u{1b}]5522;type=write:status=EINVAL\u{1b}\\")
        XCTAssertEqual(board.changeCount, changes)
        replies.data = []
        XCTAssertTrue(pane.feed(write([("image/png", png)]), kind: .snapshot))
        try await drain(runtime)
        XCTAssertEqual(replies.text, "", "a replayed transaction writes nothing")
        XCTAssertEqual(board.changeCount, changes)
        let split = write([("image/png", png), ("text/plain", Data("caption".utf8))])
        let cut = split.count - 40
        XCTAssertTrue(pane.feed(split.prefix(cut)))
        XCTAssertTrue(pane.feed(split.dropFirst(cut)))
        try await drain(runtime)
        XCTAssertEqual(replies.text, "\u{1b}]5522;type=write:status=DONE\u{1b}\\")
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertEqual(board.string(forType: .string), "caption")
        replies.data = []
        let chunk = osc("type=wdata:mime=\(b64("image/png"))", Data(count: 3 << 20).base64EncodedString())
        XCTAssertTrue(pane.feed(osc("type=write")))
        for _ in 0..<21 { XCTAssertTrue(pane.feed(chunk)) }
        XCTAssertTrue(pane.feed(osc("type=wdata:mime=\(b64("image/png"))", Data(count: (64 << 20) + 1 - 21 * (3 << 20)).base64EncodedString()) + osc("type=wdata")))
        try await drain(runtime)
        XCTAssertEqual(replies.text, "\u{1b}]5522;type=write:status=EFBIG\u{1b}\\")
        XCTAssertEqual(board.data(forType: .png), png)
    }

    func testConsentCancellationRegistersAndLimits() async throws {
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        XCTAssertNotEqual(board.name.rawValue, "NSGeneralPboard")
        let config = URL(fileURLWithPath: "/tmp/kido-clipboard-\(UUID().uuidString).conf")
        try "clipboard-read = allow\n".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        var access: UnsafePointer<CChar>?
        XCTAssertTrue(ghostty_config_get(runtime.config, &access, "clipboard-read", 14))
        XCTAssertEqual(access.map { String(cString: $0) }, "ask")
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        var replies: [Data] = []
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { replies.append($0) })
        owner.window.contentView = pane
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        defer { pane.dispose(); owner.close(); board.releaseGlobally() }
        func query(_ selector: String = "c") { XCTAssertTrue(pane.feed(Data("\u{1b}]52;\(selector);?\u{7}".utf8))) }
        func expected(_ selector: String, _ text: String) -> Data { Data("\u{1b}]52;\(selector);\(Data(text.utf8).base64EncodedString())\u{1b}\\".utf8) }
        board.clearContents()
        board.setString("secret", forType: .string)
        query()
        try await drain(runtime)
        XCTAssertNotNil(owner.preparedAlert)
        XCTAssertEqual(replies, [])
        query("p")
        try await drain(runtime)
        XCTAssertEqual(replies, [expected("p", "")])
        owner.respondToAlert(.alertThirdButtonReturn)
        try await drain(runtime)
        XCTAssertEqual(replies, [expected("p", ""), expected("c", "")])
        query()
        try await drain(runtime)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(replies.last, expected("c", ""))
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "reload_config", 13))
        try await drain(runtime)
        XCTAssertTrue(ghostty_config_get(runtime.config, &access, "clipboard-read", 14))
        XCTAssertEqual(access.map { String(cString: $0) }, "ask")
        owner.clipboardPermission = [:]
        query()
        try await drain(runtime)
        let respond = try XCTUnwrap(owner.preparedAlert?.respond)
        pane.cancelClipboard()
        respond(.alertFirstButtonReturn)
        try await drain(runtime)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(replies.count, 3)
        query()
        try await drain(runtime)
        board.clearContents()
        board.setString("fresh ✓\ntext", forType: .string)
        owner.respondToAlert(.alertSecondButtonReturn)
        try await drain(runtime)
        XCTAssertEqual(replies.last, expected("c", "fresh ✓\ntext"))
        XCTAssertTrue(WindowOwner.clipboardConsent.allows(.local))
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(.remote("Local")))
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(.remote("other")))
        owner.window.orderOut(nil)
        for selector in ["c", "p", "s"] {
            query(selector)
            try await drain(runtime)
            XCTAssertEqual(replies.last, expected(selector, "fresh ✓\ntext"))
        }
        board.clearContents()
        query("s")
        try await drain(runtime)
        XCTAssertEqual(replies.last, expected("s", ""))
        board.setString(String(repeating: "x", count: 1_048_577), forType: .string)
        query()
        try await drain(runtime)
        XCTAssertEqual(replies.last, expected("c", ""))
        for selector in ["c", "p", "s"] {
            let text = "live \(selector) ✓\ntext"
            let encoded = Data(text.utf8).base64EncodedString()
            XCTAssertTrue(pane.feed(Data("\u{1b}]52;\(selector);\(encoded)\u{1b}\\".utf8)))
            try await drain(runtime)
            XCTAssertEqual(board.string(forType: .string), text)
        }
        let changes = board.changeCount
        for payload in ["!invalid!", Data([0]).base64EncodedString(), Data(repeating: 120, count: 1_048_577).base64EncodedString()] {
            XCTAssertTrue(pane.feed(Data("\u{1b}]52;c;\(payload)\u{7}".utf8)))
            try await drain(runtime)
            XCTAssertEqual(board.changeCount, changes)
        }
        let count = replies.count
        pane.feed(Data("\u{1b}[c\u{1b}[6n".utf8))
        try await drain(runtime)
        XCTAssertEqual(replies.count, count, "MANUAL_MIRROR still suppresses non-clipboard replies")
        board.clearContents()
        board.setString("Cmd-V ✓\ntext", forType: .string)
        XCTAssertTrue(pane.feed(Data("\u{1b}[?2004h".utf8)))
        owner.window.makeFirstResponder(pane)
        let paste = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: owner.window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        let pasteStart = replies.count
        XCTAssertTrue(pane.performKeyEquivalent(with: paste))
        try await drain(runtime)
        XCTAssertEqual(Data(replies.dropFirst(pasteStart).joined()), Data("\u{1b}[200~Cmd-V ✓\ntext\u{1b}[201~".utf8))
        let finalCount = replies.count
        pane.invalidateClipboard()
        query()
        try await drain(runtime)
        XCTAssertEqual(replies.count, finalCount, "retired surface requests cannot inject late replies")
    }

    func testDenySurvivesAnotherConnectionsAlwaysAllowAndReset() async throws {
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let host = Host.remote("precedence-host")
        let a = WindowOwner(host: host, runtime: runtime, start: false)
        let b = WindowOwner(host: host, runtime: runtime, start: false)
        var replies: [Data] = []
        let pa = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13, host: host) { replies.append($0) })
        let pb = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 1), font: 13, host: host) { _ in })
        a.window.contentView = pa
        b.window.contentView = pb
        for owner in [a, b] {
            owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            owner.window.orderFront(nil)
        }
        for pane in [pa, pb] {
            pane.resize(cols: 80, rows: 24)
            XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        }
        defer { pa.dispose(); pb.dispose(); a.close(); b.close(); board.releaseGlobally() }
        func query(_ pane: PaneView, _ owner: WindowOwner) async throws {
            let count = replies.count
            XCTAssertTrue(pane.feed(Data("\u{1b}]52;c;?\u{7}".utf8)))
            try await wait("clipboard read handled") { owner.preparedAlert != nil || replies.count > count }
        }
        board.clearContents()
        board.setString("secret", forType: .string)
        try await query(pa, a)
        XCTAssertNotNil(a.preparedAlert)
        a.respondToAlert(.alertThirdButtonReturn)
        try await query(pb, b)
        XCTAssertNotNil(b.preparedAlert)
        b.respondToAlert(.alertSecondButtonReturn)
        XCTAssertTrue(WindowOwner.clipboardConsent.allows(host))
        try await query(pa, a)
        XCTAssertNil(a.preparedAlert)
        XCTAssertEqual(replies.last, Data("\u{1b}]52;c;\u{1b}\\".utf8))
        WindowOwner.resetClipboardPermissions([a, b])
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(host))
        XCTAssertEqual(a.clipboardPermission, [:])
        XCTAssertEqual(b.clipboardPermission, [:])
        try await query(pa, a)
        XCTAssertNotNil(a.preparedAlert)
        a.respondToAlert(.alertThirdButtonReturn)
    }

    func testPersistedExactHostGrantsAndExplicitDeny() throws {
        let suite = "kido-clipboard-test-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let board = NSPasteboard(name: .init(suite))
        defer { board.releaseGlobally() }
        let consent = ClipboardConsent(grants: store)
        consent.allowAlways(.remote("user@alias"))
        let next = ClipboardConsent(grants: store)
        XCTAssertTrue(next.allows(.remote("user@alias")))
        XCTAssertFalse(next.allows(.remote("user@Alias")))
        XCTAssertFalse(next.allows(.remote("alias")))
        XCTAssertFalse(next.allows(.local))
        consent.reset()
        XCTAssertFalse(next.allows(.remote("user@alias")))
        let config = URL(fileURLWithPath: "/tmp/\(suite).conf")
        try "clipboard-read = deny\n".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        let denied = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        var access: UnsafePointer<CChar>?
        XCTAssertTrue(ghostty_config_get(denied.config, &access, "clipboard-read", 14))
        XCTAssertEqual(access.map { String(cString: $0) }, "deny")
    }

    func testHiddenUnapprovedReadAndEightSecondDeadline() async throws {
        let old = PaneView.clipboardTimeout
        defer { PaneView.clipboardTimeout = old }
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .remote("deadline-host"), runtime: runtime, start: false)
        var replies: [Data] = []
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13, host: owner.host) { replies.append($0) })
        owner.window.contentView = pane
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        defer { pane.dispose(); owner.close(); board.releaseGlobally() }
        pane.feed(Data("\u{1b}]52;c;?\u{7}".utf8))
        try await wait("refused read replies empty") { replies == [Data("\u{1b}]52;c;\u{1b}\\".utf8)] }
        try await drain(runtime)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(replies, [Data("\u{1b}]52;c;\u{1b}\\".utf8)])
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        PaneView.clipboardTimeout = 0.5
        XCTAssertTrue(pane.feed(Data("\u{1b}]52;c;?\u{7}".utf8)))
        try await drain(runtime)
        let respond = try XCTUnwrap(owner.preparedAlert?.respond)
        try await wait("clipboard deadline replies empty") {
            replies == Array(repeating: Data("\u{1b}]52;c;\u{1b}\\".utf8), count: 2)
        }
        PaneView.clipboardTimeout = old
        XCTAssertNil(owner.preparedAlert)
        respond(.alertSecondButtonReturn)
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(owner.host))
        try await drain(runtime)
        XCTAssertEqual(replies, Array(repeating: Data("\u{1b}]52;c;\u{1b}\\".utf8), count: 2), "expiry replies empty; late grant adds no reply")
        pane.feed(Data("\u{1b}]52;c;?\u{7}".utf8))
        try await drain(runtime)
        let retiredResponse = try XCTUnwrap(owner.preparedAlert?.respond)
        pane.dispose()
        retiredResponse(.alertSecondButtonReturn)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(owner.host))
        let reused = try XCTUnwrap(PaneView(runtime: runtime, pane: pane.pane, font: 13, host: owner.host) { replies.append($0) })
        owner.window.contentView = reused
        reused.resize(cols: 80, rows: 24)
        XCTAssertTrue(reused.commitSnapshot(epoch: reused.historyEpoch))
        defer { reused.dispose() }
        reused.feed(Data("\u{1b}]52;p;?\u{7}".utf8))
        try await drain(runtime)
        XCTAssertNotNil(owner.preparedAlert)
        owner.respondToAlert(.alertThirdButtonReturn)
        try await drain(runtime)
        XCTAssertEqual(replies.count, 3)
        XCTAssertEqual(replies.last, Data("\u{1b}]52;p;\u{1b}\\".utf8))
    }
}
