import AppKit
import GhosttyKit
import KoClient
import PaneGeometry
import XCTest
import KoModel
@testable import Kido

// A real ko server: each pane runs `cat` on a fifo, so the test writes what the program prints, and reads
// what the pane's terminal wrote to the program in a file.
@MainActor final class ClipboardTests: VisualTestCase {
    @MainActor private final class Station {
        let pane: PaneView
        private let replies: String
        private let fifo: FileHandle
        private var consumed = 0

        init(pane: PaneView, replies: String, fifo: FileHandle) {
            self.pane = pane
            self.replies = replies
            self.fifo = fifo
        }

        func send(_ text: String) { try? fifo.write(contentsOf: Data(text.utf8)) }

        private var all: Data { (try? Data(contentsOf: URL(fileURLWithPath: replies))) ?? Data() }

        // What the terminal wrote to the program since the last call, once it holds `marker`.
        func reply(until marker: String, within seconds: Double = 20, _ test: ClipboardTests) async throws -> String {
            try await test.wait("the program's input has \(marker)", within: seconds) { String(decoding: self.all.dropFirst(self.consumed), as: UTF8.self).contains(marker) }
            return take()
        }

        func take() -> String {
            let data = all
            defer { consumed = data.count }
            return String(decoding: data.dropFirst(consumed), as: UTF8.self)
        }
    }

    private struct Rig {
        let owners: [WindowOwner]
        let runtime: GhosttyRuntime
        let board: NSPasteboard
        let stations: [Station]
        var owner: WindowOwner { owners[0] }
    }

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func osc(_ metadata: String, _ payload: String? = nil) -> String {
        "\u{1b}]5522;\(metadata)\(payload.map { ";" + $0 } ?? "")\u{1b}\\"
    }

    private func query(_ selector: String = "c") -> String { "\u{1b}]52;\(selector);?\u{7}" }

    private func answer(_ selector: String, _ text: String) -> String { "\u{1b}]52;\(selector);\(b64(text))\u{7}" }

    // A server with a window for each pane, and a window of each owner that shows its pane.
    private func rig(configFile: String? = nil, panes: Int = 1, owners count: Int = 1, visible: Bool = true) async throws -> Rig {
        let dir = try koServerDir()
        _ = try await KoServer.launch(dir: dir)
        var fifos: [FileHandle] = []
        for n in 1...panes {
            let fifo = dir + "/fifo.\(n)"
            XCTAssertEqual(mkfifo(fifo, 0o600), 0)
            fifos.append(try XCTUnwrap(FileHandle(forUpdatingAtPath: fifo)))
        }
        let windows = (1...panes).map { n in
            let script = "stty raw -echo; : > '\(dir)/ready.\(n)'; cat '\(dir)/fifo.\(n)' & exec cat > '\(dir)/replies.\(n)'"
            return #"{"name":"w\#(n)","tree":\#(koPane(script))}"#
        }.joined(separator: ",")
        try await koPut(dir, #"[{"name":"main","windows":[\#(windows)]}]"#)
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        let runtime = try XCTUnwrap(configFile.map { GhosttyRuntime(configFile: $0, pasteboard: board) } ?? GhosttyRuntime(pasteboard: board))
        var owners: [WindowOwner] = []
        var stations: [Station] = []
        for index in 0..<count {
            let owner = WindowOwner(host: .local, runtime: runtime, start: false)
            owner.testServerDir = dir
            owners.append(owner)
            if visible {
                owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                owner.window.orderFront(nil)
            }
            owner.start()
            try await wait("owner \(index) connected") { owner.testClient != nil && owner.testSession?.windows.values.contains { !$0.panes.isEmpty } == true }
            if index > 0 { try owner.testClient?.select(KO_SELECT_WINDOW, WindowID(number: UInt32(index + 1))) }
        }
        for (index, fifo) in fifos.enumerated() {
            let owner = owners[min(index, owners.count - 1)]
            let id = PaneID(number: UInt32(index + 1))
            try await wait("pane \(index + 1) shown") { owner.testSession?.pane(id) != nil }
            let pane = try XCTUnwrap(owner.testSession?.pane(id))
            try await wait("pane \(index + 1) raw") { FileManager.default.fileExists(atPath: dir + "/ready.\(index + 1)") }
            stations.append(Station(pane: pane, replies: dir + "/replies.\(index + 1)", fifo: fifo))
        }
        addTeardownBlock { @MainActor in
            owners.forEach { $0.close() }
            board.releaseGlobally()
        }
        return Rig(owners: owners, runtime: runtime, board: board, stations: stations)
    }

    private func text(_ text: String) -> [KoClipboardContent] { [KoClipboardContent(mime: "text/plain", data: Data(text.utf8))] }

    func testModeFiveFiveTwoTwoCmdVEmitsPasteEventForOneRead() async throws {
        let rig = try await rig()
        let (board, owner, station) = (rig.board, rig.owner, rig.stations[0])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2])
        func set(_ text: String) {
            board.clearContents()
            board.declareTypes([.string, .png], owner: nil)
            board.setString(text, forType: .string)
            board.setData(png, forType: .png)
        }
        func paste() async throws -> String {
            XCTAssertTrue(ghostty_surface_binding_action(station.pane.surface, "paste_from_clipboard", 20))
            let event = try await station.reply(until: "status=DONE", self)
            XCTAssertTrue(event.contains("status=DATA:mime=Lg=="), "Cmd-V under mode 5522 sends the event, not text: \(event)")
            XCTAssertTrue(event.contains(b64("text/plain image/png\n")), event)
            XCTAssertNil(owner.preparedAlert)
            return String(try XCTUnwrap(event.components(separatedBy: "pw=").dropFirst().first?.prefix { !"\u{1b}:;".contains($0) }))
        }
        func read(_ pw: String, _ mime: String) async throws -> String {
            station.send(osc("type=read:name=\(b64("test")):pw=\(pw)", b64(mime)))
            return try await station.reply(until: "status=", self)
        }
        set("hello")
        station.send("\u{1b}[?2004h\u{1b}[?5522hmode-set")
        try await wait("the mirror took the mode") { station.pane.visualText.contains("mode-set") }
        let pw = try await paste()
        let served = try await read(pw, "image/png")
        XCTAssertTrue(served.contains("status=DATA:mime=\(b64("image/png"));\(png.base64EncodedString())"), "the read that follows a paste event is the user's own: \(served)")
        XCTAssertNil(owner.preparedAlert)
        station.send(osc("type=read:name=\(b64("test")):pw=\(pw)", b64("image/png")))
        try await wait("an application read asks first") { owner.preparedAlert != nil }
        owner.respondToAlert(.alertThirdButtonReturn)
        let denied = try await station.reply(until: "status=EPERM", self)
        XCTAssertFalse(denied.contains("status=DATA"))
        owner.clipboardPermission = [:]
        let stale = try await paste()
        set("changed")
        let changed = try await read(stale, "text/plain")
        XCTAssertTrue(changed.contains("status=OK") && !changed.contains("status=DATA"), "a clipboard that changed after the event serves nothing: \(changed)")
        XCTAssertNil(owner.preparedAlert)
        let old = PaneView.pasteEventTimeout
        PaneView.pasteEventTimeout = 0.1
        defer { PaneView.pasteEventTimeout = old }
        let expired = try await paste()
        try await wait("paste event expired") { station.pane.visualPasteEventExpired }
        station.send(osc("type=read:name=\(b64("test")):pw=\(expired)", b64("text/plain")))
        try await wait("a read after the event expired asks") { owner.preparedAlert != nil }
        owner.respondToAlert(.alertThirdButtonReturn)
        _ = try await station.reply(until: "status=EPERM", self)
    }

    func testRichReadAsksSeparatelyAndResetDeniesIt() async throws {
        let rig = try await rig()
        let (board, owner, station) = (rig.board, rig.owner, rig.stations[0])
        board.clearContents()
        board.declareTypes([.string, .png], owner: nil)
        board.setString("text", forType: .string)
        board.setData(Data([1, 2, 3]), forType: .png)
        station.send(osc("type=read", b64(".")))
        let listed = try await station.reply(until: "status=DONE", self)
        XCTAssertTrue(listed.contains(b64("text/plain image/png\n")), listed)
        XCTAssertNil(owner.preparedAlert)
        owner.clipboardPermission[.clipboard] = .allow
        station.send(osc("type=read", b64("text/plain")))
        let plain = try await station.reply(until: "status=DONE", self)
        XCTAssertTrue(plain.contains("status=DATA:mime=\(b64("text/plain"));\(b64("text"))"), plain)
        XCTAssertNil(owner.preparedAlert)
        station.send(osc("type=read", b64("image/png")))
        try await wait("the rich read asks") { owner.preparedAlert != nil }
        XCTAssertEqual(owner.preparedAlert?.alert.messageText, "Allow applications on “Local” to read images, HTML and file lists from your Mac clipboard?")
        WindowOwner.resetClipboardPermissions([owner])
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(owner.clipboardPermission, [:])
        let refused = try await station.reply(until: "status=EPERM", self)
        XCTAssertFalse(refused.contains("status=DATA"), "a text grant does not serve a rich read: \(refused)")
        station.send(osc("type=read", b64("image/png")))
        try await wait("the rich read asks again") { owner.preparedAlert != nil }
        station.pane.invalidateClipboard()
        XCTAssertNil(owner.preparedAlert)
        _ = try await station.reply(until: "status=EPERM", self)
    }

    func testServerWritesValidateEveryRepresentation() async throws {
        let rig = try await rig()
        let (board, owner) = (rig.board, rig.owner)
        board.clearContents()
        board.setString("before", forType: .string)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 9])
        let changes = board.changeCount
        owner.writeClipboard([KoClipboardContent(mime: "image/png", data: png), KoClipboardContent(mime: "application/x-unknown", data: Data("x".utf8))])
        XCTAssertEqual(board.changeCount, changes, "one representation that the app refuses refuses the write")
        owner.writeClipboard([KoClipboardContent(mime: "image/png", data: png)] + text("caption"))
        XCTAssertEqual(board.data(forType: .png), png)
        XCTAssertEqual(board.string(forType: .string), "caption")
        let written = board.changeCount
        owner.writeClipboard([KoClipboardContent(mime: "image/png", data: Data(count: PasteboardMIME.limit + 1))])
        owner.writeClipboard([KoClipboardContent(mime: "text/plain", data: Data(count: PasteboardMIME.textLimit + 1))])
        owner.writeClipboard([KoClipboardContent(mime: "text/plain", data: Data([0x61, 0, 0x62]))])
        owner.writeClipboard([])
        XCTAssertEqual(board.changeCount, written)
        XCTAssertEqual(board.data(forType: .png), png)
    }

    func testAProgramsOSC52WriteReachesTheClipboardThroughTheServer() async throws {
        let rig = try await rig()
        let (board, station) = (rig.board, rig.stations[0])
        board.clearContents()
        board.setString("before", forType: .string)
        try rig.owner.testClient?.focus(true)
        station.send("\u{1b}]52;c;\(b64("a\0b"))\u{7}")
        station.send("\u{1b}]52;c;\(b64("live ✓\ntext"))\u{7}")
        try await wait("the clipboard holds the second write") { board.string(forType: .string) == "live ✓\ntext" }
    }

    func testAMirrorNeitherAnswersNorAppliesOSC52OrOSC5522() async throws {
        let config = URL(fileURLWithPath: "/tmp/kido-clipboard-\(UUID().uuidString).conf")
        try "clipboard-read = allow\nclipboard-write = allow\n".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        var replies: [Data] = []
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { replies.append($0) })
        owner.window.contentView = pane
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        pane.resize(cols: 80, rows: 24)
        defer { pane.dispose(); owner.close() }
        board.clearContents()
        board.setString("secret", forType: .string)
        let changes = board.changeCount
        for bytes in [query("c"), "\u{1b}]52;p;?\u{1b}\\", "\u{1b}]52;c;\(b64("pwned"))\u{7}", "\u{1b}]52;s;\(b64("pwned"))\u{1b}\\"] {
            XCTAssertTrue(pane.feed(Data(bytes.utf8)))
            try await drain(runtime)
        }
        XCTAssertTrue(pane.feed(Data(osc("type=read", b64("text/plain")).utf8)))
        XCTAssertTrue(pane.feed(Data((osc("type=write") + osc("type=wdata:mime=\(b64("text/plain"))", b64("pwned")) + osc("type=wdata")).utf8)))
        try await drain(runtime)
        XCTAssertEqual(replies, [], "no byte of a reply goes toward the pane's program")
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(board.changeCount, changes)
        XCTAssertEqual(board.string(forType: .string), "secret")
        XCTAssertEqual(runtime.clipboard, .init(read: .ask, write: .allow), "the user's allow is the server path's policy: reads still ask")
    }

    func testConsentCancellationRegistersAndLimits() async throws {
        let config = URL(fileURLWithPath: "/tmp/kido-clipboard-\(UUID().uuidString).conf")
        try "clipboard-read = allow\n".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        let rig = try await rig(configFile: config.path)
        let (board, runtime, owner, station) = (rig.board, rig.runtime, rig.owner, rig.stations[0])
        XCTAssertEqual(runtime.clipboard.read, .ask)
        board.clearContents()
        board.setString("secret", forType: .string)
        station.send(query())
        try await wait("the read asks") { owner.preparedAlert != nil }
        station.send(query("p"))
        let second = try await station.reply(until: "\u{1b}]52;p;", self)
        XCTAssertEqual(second, "\u{1b}]52;p;\u{7}", "one pending read for each pane")
        owner.respondToAlert(.alertThirdButtonReturn)
        let first = try await station.reply(until: "\u{1b}]52;c;", self)
        XCTAssertEqual(first, "\u{1b}]52;c;\u{7}")
        station.send(query())
        let denied = try await station.reply(until: "\u{1b}]52;c;", self)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertEqual(denied, "\u{1b}]52;c;\u{7}")
        XCTAssertTrue(ghostty_surface_binding_action(station.pane.surface, "reload_config", 13))
        try await wait("the reload kept the user's policy") { runtime.clipboard.read == .ask }
        owner.clipboardPermission = [:]
        station.send(query())
        try await wait("the read asks again") { owner.preparedAlert != nil }
        let respond = try XCTUnwrap(owner.preparedAlert?.respond)
        station.pane.finishClipboard(false)
        _ = try await station.reply(until: "\u{1b}]52;c;", self)
        respond(.alertFirstButtonReturn)
        XCTAssertNil(owner.preparedAlert)
        station.send(query())
        try await wait("the read asks a third time") { owner.preparedAlert != nil }
        board.clearContents()
        board.setString("fresh ✓\ntext", forType: .string)
        owner.respondToAlert(.alertSecondButtonReturn)
        let allowed = try await station.reply(until: "\u{1b}]52;c;", self)
        XCTAssertEqual(allowed, answer("c", "fresh ✓\ntext"))
        XCTAssertTrue(WindowOwner.clipboardConsent.allows(.local))
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(.remote("Local")))
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(.remote("other")))
        owner.window.orderOut(nil)
        station.send(query("s"))
        let hidden = try await station.reply(until: "\u{1b}]52;s;", self)
        XCTAssertEqual(hidden, answer("s", "fresh ✓\ntext"), "a hidden window with a grant answers")
        board.clearContents()
        station.send(query("s"))
        let empty = try await station.reply(until: "\u{1b}]52;s;", self)
        XCTAssertEqual(empty, "\u{1b}]52;s;\u{7}")
        board.setString(String(repeating: "x", count: 1_048_577), forType: .string)
        station.send(query())
        let big = try await station.reply(until: "\u{1b}]52;c;", self)
        XCTAssertEqual(big, "\u{1b}]52;c;\u{7}")
        board.clearContents()
        board.setString("Cmd-V ✓\ntext", forType: .string)
        station.send("\u{1b}[?2004hbracketed")
        try await wait("the mirror took the mode") { station.pane.visualText.contains("bracketed") }
        owner.window.orderFront(nil)
        owner.window.makeFirstResponder(station.pane)
        let paste = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: owner.window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(station.pane.performKeyEquivalent(with: paste))
        let pasted = try await station.reply(until: "\u{1b}[201~", self)
        XCTAssertEqual(pasted, "\u{1b}[200~Cmd-V ✓\ntext\u{1b}[201~")
        station.pane.invalidateClipboard()
        station.send(query())
        let retired = try await station.reply(until: "\u{1b}]52;c;", self)
        XCTAssertEqual(retired, "\u{1b}]52;c;\u{7}", "a retired pane refuses a read")
    }

    func testDenySurvivesAnotherConnectionsAlwaysAllowAndReset() async throws {
        let rig = try await rig(panes: 2, owners: 2)
        let (a, b) = (rig.owners[0], rig.owners[1])
        let (first, second) = (rig.stations[0], rig.stations[1])
        rig.board.clearContents()
        rig.board.setString("secret", forType: .string)
        first.send(query())
        try await wait("the first window asks") { a.preparedAlert != nil }
        a.respondToAlert(.alertThirdButtonReturn)
        _ = try await first.reply(until: "\u{1b}]52;c;", self)
        second.send(query())
        try await wait("the second window asks") { b.preparedAlert != nil }
        b.respondToAlert(.alertSecondButtonReturn)
        let granted = try await second.reply(until: "\u{1b}]52;c;", self)
        XCTAssertEqual(granted, answer("c", "secret"))
        XCTAssertTrue(WindowOwner.clipboardConsent.allows(.local))
        first.send(query())
        let denied = try await first.reply(until: "\u{1b}]52;c;", self)
        XCTAssertNil(a.preparedAlert)
        XCTAssertEqual(denied, "\u{1b}]52;c;\u{7}", "a denial for this connection survives the other's always allow")
        WindowOwner.resetClipboardPermissions([a, b])
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(.local))
        XCTAssertEqual(a.clipboardPermission, [:])
        XCTAssertEqual(b.clipboardPermission, [:])
        first.send(query())
        try await wait("the first window asks again") { a.preparedAlert != nil }
        a.respondToAlert(.alertThirdButtonReturn)
    }

    func testTwoWindowsOfOneHostShareOneSheet() async throws {
        let rig = try await rig(panes: 2, owners: 2)
        let (a, b) = (rig.owners[0], rig.owners[1])
        let (first, second) = (rig.stations[0], rig.stations[1])
        rig.board.clearContents()
        rig.board.declareTypes([.string, .png], owner: nil)
        rig.board.setString("text", forType: .string)
        rig.board.setData(Data([1, 2, 3]), forType: .png)
        first.send(query())
        try await wait("the first window asks") { a.preparedAlert != nil }
        second.send(osc("type=read", b64("image/png")))
        let refused = try await second.reply(until: "status=EPERM", self)
        XCTAssertFalse(refused.contains("status=DATA"))
        XCTAssertNil(b.preparedAlert, "a rich read of another window of the host opens no second sheet")
        second.send(query())
        _ = try await second.reply(until: "\u{1b}]52;c;", self)
        XCTAssertNil(b.preparedAlert)
        a.respondToAlert(.alertThirdButtonReturn)
        _ = try await first.reply(until: "\u{1b}]52;c;", self)
    }

    func testPersistedExactHostGrantsAndExplicitDeny() async throws {
        let suite = "kido-clipboard-test-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
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
        try "clipboard-read = deny\nclipboard-write = deny\n".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        let rig = try await rig(configFile: config.path)
        XCTAssertEqual(rig.runtime.clipboard, .init(read: .deny, write: .deny))
        let (board, owner, station) = (rig.board, rig.owner, rig.stations[0])
        board.clearContents()
        board.setString("kept", forType: .string)
        let changes = board.changeCount
        owner.writeClipboard(text("ignored"))
        XCTAssertEqual(board.changeCount, changes, "the user's clipboard-write = deny ignores the server's write")
        station.send(query())
        let refused = try await station.reply(until: "\u{1b}]52;c;", self)
        XCTAssertEqual(refused, "\u{1b}]52;c;\u{7}", "clipboard-read = deny refuses at once")
        XCTAssertNil(owner.preparedAlert)
    }

    func testHiddenUnapprovedReadAndEightSecondDeadline() async throws {
        let old = PaneView.clipboardTimeout
        defer { PaneView.clipboardTimeout = old }
        let rig = try await rig(visible: false)
        let (board, owner, station) = (rig.board, rig.owner, rig.stations[0])
        board.clearContents()
        board.setString("secret", forType: .string)
        station.send(query())
        let hidden = try await station.reply(until: "\u{1b}]52;c;", self)
        XCTAssertEqual(hidden, "\u{1b}]52;c;\u{7}", "a hidden window refuses at once")
        XCTAssertNil(owner.preparedAlert)
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        PaneView.clipboardTimeout = 0.5
        station.send(query())
        try await wait("the read asks") { owner.preparedAlert != nil }
        let respond = try XCTUnwrap(owner.preparedAlert?.respond)
        let expired = try await station.reply(until: "\u{1b}]52;c;", self)
        PaneView.clipboardTimeout = old
        XCTAssertEqual(expired, "\u{1b}]52;c;\u{7}")
        XCTAssertNil(owner.preparedAlert)
        respond(.alertSecondButtonReturn)
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(owner.host))
        station.send(query())
        try await wait("the read asks again") { owner.preparedAlert != nil }
        let retiredResponse = try XCTUnwrap(owner.preparedAlert?.respond)
        station.pane.dispose()
        let disposed = try await station.reply(until: "\u{1b}]52;c;", self)
        XCTAssertEqual(disposed, "\u{1b}]52;c;\u{7}", "disposing the pane refuses its pending read")
        retiredResponse(.alertSecondButtonReturn)
        XCTAssertNil(owner.preparedAlert)
        XCTAssertFalse(WindowOwner.clipboardConsent.allows(owner.host))
    }
}
