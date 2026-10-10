import AppKit
import GhosttyKit
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class ClipboardTests: VisualTestCase {
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
        owner.clipboardPermission = .ask
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
        func query(_ pane: PaneView) async throws {
            XCTAssertTrue(pane.feed(Data("\u{1b}]52;c;?\u{7}".utf8)))
            for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
        }
        board.clearContents()
        board.setString("secret", forType: .string)
        try await query(pa)
        XCTAssertNotNil(a.preparedAlert)
        a.respondToAlert(.alertThirdButtonReturn)
        try await query(pb)
        XCTAssertNotNil(b.preparedAlert)
        b.respondToAlert(.alertSecondButtonReturn)
        XCTAssertTrue(WindowOwner.clipboardConsent.allows(host))
        try await query(pa)
        XCTAssertNil(a.preparedAlert)
        XCTAssertEqual(replies.last, Data("\u{1b}]52;c;\u{1b}\\".utf8))
        WindowOwner.resetClipboardPermissions([a, b])
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(host))
        XCTAssertEqual(a.clipboardPermission, .ask)
        XCTAssertEqual(b.clipboardPermission, .ask)
        try await query(pa)
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
        for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(replies, [Data("\u{1b}]52;c;\u{1b}\\".utf8)])
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        XCTAssertTrue(pane.feed(Data("\u{1b}]52;c;?\u{7}".utf8)))
        for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
        let respond = try XCTUnwrap(owner.preparedAlert?.respond)
        try await Task.sleep(for: .seconds(8.1))
        XCTAssertNil(owner.preparedAlert)
        respond(.alertSecondButtonReturn)
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(owner.host))
        for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(replies, Array(repeating: Data("\u{1b}]52;c;\u{1b}\\".utf8), count: 2), "expiry replies empty; late grant adds no reply")
        pane.feed(Data("\u{1b}]52;c;?\u{7}".utf8))
        for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
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
        for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(owner.preparedAlert)
        owner.respondToAlert(.alertThirdButtonReturn)
        for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(replies.count, 3)
        XCTAssertEqual(replies.last, Data("\u{1b}]52;p;\u{1b}\\".utf8))
    }
}
