import AppKit
import GhosttyKit
import PromptMarkdown
import XCTest
import SnapshotTesting
import SidebarFeed
import TmuxControl
@testable import Kido

@MainActor final class PaletteTests: VisualTestCase {
    private func image(_ palette: PaletteView, _ name: String) {
        palette.layoutSubtreeIfNeeded()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: palette, as: .image, named: name, record: record, testName: "palette"),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    @MainActor private final class PromptProbe {
        var recorded: [RPCRequest] = []
        var candidates: [PromptCandidate] = []
        var reply: Result<RPCEvent.Reply.Value, Failure>?
        var sends: [RPCRequest] { recorded.filter { if case .prompt(_, .some, _) = $0 { true } else { false } } }
        func install(_ owner: WindowOwner) {
            owner.request = { [self] request, done in
                recorded.append(request)
                switch request {
                case .prompt(_, nil, _): done(.success(.prompt(.candidates(candidates))))
                case .prompt(_, .some, _): if let reply { done(reply) }
                default: break
                }
            }
        }
    }

    @MainActor private final class PromptFixture {
        let runtime: GhosttyRuntime
        let app: AppDelegate
        let owner: WindowOwner
        let probe = PromptProbe()
        let realRequest: RPCRequestHandler
        private let previousMenu: NSMenu?
        let snapshot: Snapshot
        var source: PromptSource
        init(_ test: VisualTestCase) throws {
            previousMenu = NSApp.mainMenu
            runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("prompt-" + UUID().uuidString))))
            app = AppDelegate(runtime: runtime)
            owner = try XCTUnwrap(app.open(.local, start: false))
            realRequest = owner.request
            snapshot = try test.sidebarFixture()
            owner.testReceive(snapshot)
            let session = try XCTUnwrap(snapshot.sessions.first)
            source = PromptSource(owner: owner, instance: snapshot.serverInstance, session: session.id, window: WindowID(number: 0), pane: PaneID(number: 0), windowName: "app")
            probe.candidates = [
                PromptCandidate(pane: PaneID(number: 0), session: session.id, window: source.window, title: "near"),
                PromptCandidate(pane: PaneID(number: 502), session: session.id, window: WindowID(number: 2), title: "far"),
            ]
            probe.install(owner)
            NSApp.mainMenu = app.mainMenu()
        }
        func startServer(_ test: VisualTestCase) async throws -> Server {
            let dir = "/tmp/kpp-" + UUID().uuidString.prefix(8)
            let started = try await Child.run(tools.kido, ["server", "--server", dir], env: tools.environment)
            XCTAssertEqual(started.status, 0, started.err)
            let server = try JSONDecoder().decode(Server.self, from: Data(started.out.utf8))
            owner.testEndpoint = Endpoint(server: server, kido: tools.kido)
            test.addTeardownBlock { @MainActor [owner] in
                owner.close()
                _ = try? await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-session", "-t", "$0"], env: tools.environment)
                try? FileManager.default.removeItem(atPath: dir)
            }
            return server
        }
        func open(_ selection: String? = nil) throws -> PalettePrompt {
            var source = source
            source.quote = selection
            app.togglePalette()
            app.palettePanel?.palette.enter(.prompt(source))
            return try XCTUnwrap(app.palettePanel?.palette.prompt)
        }
        func close() { app.closePalette(); owner.close(); runtime.pasteboard.releaseGlobally(); NSApp.mainMenu = previousMenu }
    }

    func testPaletteSnapshots() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("palette-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: config) }
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        for (theme, background, foreground) in [("light", "fff9ec", "424242"), ("dark", "171717", "c9c9c9")] {
            try "background = #\(background)\nforeground = #\(foreground)\n".write(to: config, atomically: true, encoding: .utf8)
            let board = NSPasteboard(name: .init("palette-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
            let suite = "palette-" + UUID().uuidString
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            var recent = RecentHosts()
            let now = Date()
            recent.add("devbox-old", at: now.addingTimeInterval(-21 * 86400))
            recent.add("dev@buildbox", at: now.addingTimeInterval(-86400))
            recent.add("devbox", at: now.addingTimeInterval(-7200))
            preferences.set(try JSONEncoder().encode(recent), forKey: "recentHosts")
            let app = AppDelegate(runtime: runtime, routes: WindowRoutes(preferences: preferences))
            let owner = try XCTUnwrap(app.open(.local, start: false))
            owner.window.setFrame(NSRect(origin: owner.window.frame.origin, size: NSSize(width: 1100, height: 740)), display: false)
            let remote = try XCTUnwrap(app.open(.remote("devbox"), start: false))
            defer { app.closePalette(); owner.close(); remote.close() }
            let initialSnapshot = try sidebarFixture { object in
                let sessions = object["sessions"] as! [[String: Any]]
                var main = sessions[0]
                func nodes(_ source: [[String: Any]]) -> [[String: Any]] {
                    source.map { source in
                        var node = source
                        if node["title"] as? String == "pi-ui" {
                            node["lifecycle"] = ["Live", ["Pi_agent", ["status": ["since": 1791131000, "msg": NSNull(), "state": ["Waiting", ["kind": NSNull(), "progress": NSNull()]]], "session": "session-905"]]]
                        }
                        if let children = node["children"] as? [[String: Any]] { node["children"] = nodes(children) }
                        return node
                    }
                }
                main["nodes"] = nodes(main["nodes"] as! [[String: Any]])
                object["sessions"] = [main]
            }
            owner.testReceive(initialSnapshot)
            owner.sidebar.list.focus()
            NSApp.mainMenu = app.mainMenu()
            // AppKit does not add its automatic full-screen item to an unordered test window's menu.
            let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
            view.autoenablesItems = false
            let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            fullScreen.keyEquivalentModifierMask = [.command, .control]
            fullScreen.target = owner.window
            app.togglePalette()
            let panel = try XCTUnwrap(app.palettePanel)
            let palette = panel.palette
            func query(_ text: String) {
                palette.field.stringValue = text
                palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                (palette.field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            }
            image(palette, "\(theme)-root")
            query("mwatch"); image(palette, "\(theme)-filtered")
            query("watch"); image(palette, "\(theme)-match-run")
            query("ren"); image(palette, "\(theme)-filtered2")
            query("zzqq"); image(palette, "\(theme)-nomatch")
            palette.enter(.connect); image(palette, "\(theme)-connect")
            query("dev"); image(palette, "\(theme)-connect-typing")
            query("me@dev box")
            palette.choose(0)
            XCTAssertNotNil(palette.error)
            image(palette, "\(theme)-connect-invalid")
            app.routes.clearRecent()
            palette.enter(.root); palette.enter(.connect)
            image(palette, "\(theme)-connect-none")
            let session = try XCTUnwrap(owner.snapshot?.sessions.first)
            palette.enter(.rename(owner, try XCTUnwrap(owner.snapshot).serverInstance, session.id, original: session.name)); image(palette, "\(theme)-rename")
            owner.testReceive(try sidebarFixture())
            query("visa"); palette.rename("visa"); image(palette, "\(theme)-rename-error")
            query("main.2"); palette.rename("main.2"); image(palette, "\(theme)-rename-error2")
            app.routes.connect(.remote("devbox-old"))
            app.routes.connect(.remote("dev@buildbox"))
            app.routes.connect(.remote("devbox"))
            owner.testReceive(initialSnapshot)
            palette.enter(.root)
            query("")
            let selectedAgent = try XCTUnwrap(palette.shown.firstIndex { $0.entry.title == "@kido-app" })
            for _ in 0..<selectedAgent { _ = palette.control(palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))) }
            image(palette, "\(theme)-root-agent")
            let probe = PromptProbe()
            let near = PromptCandidate(pane: PaneID(number: 0), session: session.id, window: WindowID(number: 0), title: "kido-app")
            probe.candidates = [near,
                PromptCandidate(pane: PaneID(number: 3), session: session.id, window: WindowID(number: 2), title: "sidebar-mockup"),
                PromptCandidate(pane: PaneID(number: 4), session: session.id, window: WindowID(number: 3), title: "pi-ui")]
            probe.install(owner)
            let source = PromptSource(owner: owner, instance: try XCTUnwrap(owner.snapshot).serverInstance, session: session.id, window: near.window, pane: PaneID(number: 0), windowName: "app")
            let typed = "Look at the failing e2e test in the build log.\nIt reports failed where completed is expected.\nFind the cause and propose a fix."
            let q1 = "--- FAIL: TestRunChildOutcome (2.03s)\n    run_test.go:88: outcome = \"failed\", want \"completed\""
            let q2 = "M lib/run.ml\nM lib/reap.ml"
            for state in ["prompt", "prompt-typing", "prompt-quote", "prompt-markdown", "prompt-twoquotes", "prompt-picker", "prompt-draft", "prompt-sending", "prompt-refused", "prompt-unknown", "prompt-invalid", "prompt-paneclosed"] {
                palette.enter(.root)
                app.promptDrafts = [:]
                var source = source
                if state == "prompt-quote" { source.quote = q1 }
                if state == "prompt-draft" { app.promptDrafts[PromptDraft.Key(host: owner.host, instance: source.instance, pane: near.pane)] = PromptDraft(text: typed) }
                palette.enter(.prompt(source))
                let prompt = try XCTUnwrap(palette.prompt)
                XCTAssertNotNil(prompt.target, "the first visible prompt already has its resolved target")
                if state == "prompt-markdown" {
                    prompt.type("# Failing e2e\nThe run outcome is **failed** where `completed` is expected, see `run_test.go:88`.\nIs `Run.effective_outcome` reading a *stale* pane?\n\n" + q1.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n"))
                } else if state == "prompt-twoquotes" {
                    let beforeCaret = "Both of these look related.\n\n" + q1.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
                    prompt.type(beforeCaret + "\n" + q2.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n"))
                    prompt.textView.setSelectedRange(NSRange(location: beforeCaret.utf16.count, length: 0))
                    prompt.scroll.contentView.scroll(to: .zero)
                    prompt.scroll.reflectScrolledClipView(prompt.scroll.contentView)
                } else if !["prompt", "prompt-quote", "prompt-draft", "prompt-paneclosed"].contains(state) { prompt.type(typed) }
                switch state {
                case "prompt-picker": panel.makeFirstResponder(prompt.targetButton)
                case "prompt-sending": probe.reply = nil; prompt.sendComposed()
                case "prompt-refused": probe.reply = .success(.promptError("Inbox refused the prompt: agent is busy with an external editor.", .refused)); prompt.sendComposed()
                case "prompt-unknown": probe.reply = .success(.promptError("Socket closed while sending.", .unknown)); prompt.sendComposed()
                case "prompt-invalid": probe.reply = .success(.promptError("@kido-app is no longer an agent. Choose another target.", .invalid)); prompt.sendComposed()
                case "prompt-paneclosed": prompt.sourceChanged(gone: true)
                default: break
                }
                image(palette, "\(theme)-\(state)")
            }
            app.closePalette()
            owner.close()
            remote.close()
            app.routes.connect(.remote("devbox-old"))
            app.routes.connect(.remote("dev@buildbox"))
            app.routes.connect(.remote("devbox"))
            app.togglePalette()
            let noWindow = try XCTUnwrap(app.palettePanel)
            XCTAssertEqual(noWindow.palette.shown.compactMap { row -> String? in
                if case .command = row.entry.id { row.entry.title } else { nil }
            }, ["New Session", "Connect to Remote Host…"])
            image(noWindow.palette, "\(theme)-nowindow")
        }
    }

    func testPromptDraftsPickerQuotesAndKeys() throws {
        let fixture = try PromptFixture(self)
        let (app, owner, probe, snapshot) = (fixture.app, fixture.owner, fixture.probe, fixture.snapshot)
        let a = probe.candidates[0], b = probe.candidates[1]
        probe.candidates = [b, a]
        defer { fixture.close() }
        var prompt = try fixture.open()
        XCTAssertEqual(prompt.target, a, "the closest agent is chosen before the first session candidate")
        XCTAssertEqual(probe.recorded.first, .prompt(pane: fixture.source.pane, text: nil, target: nil))
        XCTAssertEqual(prompt.targetButton.menu?.items.map(\.title), ["This window", "@near  this window", "Session main", "@far  window @2"])
        XCTAssertEqual(prompt.targetButton.menu?.items[1].state, .on)
        prompt.type("Explain")
        let initialHeight = try XCTUnwrap(app.palettePanel).frame.height
        let top = try XCTUnwrap(app.palettePanel).frame.maxY
        let panel = try XCTUnwrap(app.palettePanel)
        try sendKey(panel, "\r", code: 36, modifiers: .shift)
        XCTAssertEqual(prompt.textView.string, "Explain\n")
        prompt.type("two\nthree\nfour\nfive\nsix")
        XCTAssertEqual(panel.frame.height - initialHeight, 5 * 18, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, top, accuracy: 0.5)
        prompt.type("\nseven")
        XCTAssertEqual(panel.frame.height - initialHeight, 5 * 18, accuracy: 0.5)
        XCTAssertTrue(prompt.scroll.hasVerticalScroller)
        try sendKey(panel, "\t", code: 48)
        XCTAssertTrue(panel.firstResponder === prompt.targetButton)
        try sendKey(panel, String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
        XCTAssertEqual(prompt.target, b)
        XCTAssertTrue(app.promptDrafts.isEmpty, "without B's draft the text transfers, not duplicates")
        try sendKey(panel, String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
        XCTAssertEqual(prompt.target, a)
        try sendKey(panel, "\u{19}", code: 48, modifiers: .shift)
        XCTAssertTrue(panel.firstResponder === prompt.textView)
        try sendKey(panel, String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        XCTAssertEqual(prompt.target, a, "Up moves the caret, not the target")
        XCTAssertLessThan(prompt.textView.selectedRange().location, prompt.textView.string.utf16.count)
        try sendKey(panel, "\u{19}", code: 48, modifiers: .shift)
        XCTAssertTrue(panel.firstResponder === prompt.send)
        try sendKey(panel, "\t", code: 48)
        XCTAssertTrue(panel.firstResponder === prompt.textView)
        try sendKey(panel, "\t", code: 48)
        XCTAssertTrue(panel.firstResponder === prompt.targetButton)
        try sendKey(panel, "\t", code: 48)
        XCTAssertTrue(panel.firstResponder === prompt.send)
        try sendKey(panel, "\u{19}", code: 48, modifiers: .shift)
        XCTAssertTrue(panel.firstResponder === prompt.targetButton, "Shift-Tab from Send must focus the picker")
        let text = prompt.textView.string
        try sendKey(panel, "\u{1b}", code: 53)
        XCTAssertNil(app.palettePanel)
        prompt = try fixture.open("second")
        let once = appendQuote(to: text, selection: "second").text
        XCTAssertEqual(prompt.textView.string, once)
        app.closePalette(.moved)
        prompt = try fixture.open("second")
        let twice = appendQuote(to: once, selection: "second").text
        XCTAssertEqual(prompt.textView.string, twice, "each new selection appends, including duplicates")
        app.closePalette()
        prompt = try fixture.open()
        XCTAssertEqual(prompt.textView.string, twice)
        let keyB = PromptDraft.Key(host: owner.host, instance: snapshot.serverInstance, pane: b.pane)
        app.promptDrafts[keyB] = PromptDraft(text: "B's saved text\n\n> B quote")
        prompt.chooseTarget(0)
        XCTAssertEqual(prompt.textView.string, "B's saved text\n\n> B quote")
        XCTAssertEqual(app.promptDrafts.count, 2)
        prompt.chooseTarget(1)
        XCTAssertEqual(prompt.textView.string, twice)
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: a.pane, via: .inbox))))
        let sending = try XCTUnwrap(app.palettePanel)
        try sendKey(sending, "\r", code: 36)
        XCTAssertEqual(probe.sends.last, .prompt(pane: fixture.source.pane, text: twice, target: a.pane))
        XCTAssertNil(app.palettePanel)
        XCTAssertNil(app.promptDrafts[PromptDraft.Key(host: owner.host, instance: snapshot.serverInstance, pane: a.pane)])
    }

    func testPromptFailuresNoCandidateAndSourceClosed() throws {
        let fixture = try PromptFixture(self)
        let (app, owner, probe) = (fixture.app, fixture.owner, fixture.probe)
        let board = fixture.runtime.pasteboard
        let a = probe.candidates[0]
        defer { fixture.close() }
        var prompt = try fixture.open()
        prompt.type("Explain")
        probe.reply = .success(.promptError("Busy", .refused))
        prompt.sendComposed()
        XCTAssertEqual(prompt.status.stringValue, "Busy")
        XCTAssertFalse(prompt.retry.isHidden)
        prompt.retry.performClick(nil)
        XCTAssertEqual(probe.sends.count, 2, "Retry sends again after a refusal")
        probe.reply = .success(.promptError("Gone", .invalid))
        prompt.sendComposed()
        XCTAssertEqual(prompt.status.stringValue, "Gone")
        XCTAssertTrue(prompt.targetButton.isEnabled)
        prompt.chooseTarget(1)
        XCTAssertEqual(prompt.status.stringValue, "")
        XCTAssertTrue(prompt.send.isEnabled)
        probe.reply = .success(.promptError("Socket closed.", .unknown))
        prompt.sendComposed()
        XCTAssertFalse(prompt.textView.isEditable)
        XCTAssertTrue(prompt.send.isHidden)
        XCTAssertEqual(prompt.status.stringValue, "Socket closed. It may have arrived; not resent.")
        let sent = probe.sends.count
        prompt.newline(shift: false)
        XCTAssertEqual(probe.sends.count, sent)
        prompt.copyPrompt.performClick(nil)
        XCTAssertEqual(board.string(forType: .string), "Explain")
        app.closePalette()
        prompt = try fixture.open()
        prompt.chooseTarget(1)
        XCTAssertEqual(prompt.textView.string, "Explain", "unknown delivery keeps the target's draft")
        prompt.sourceChanged(gone: true)
        XCTAssertEqual(prompt.status.stringValue, "Source pane closed; agents resolved earlier stay available.")
        prompt.chooseTarget(0)
        XCTAssertTrue(prompt.targetButton.label.string.contains("in window app (pane closed)"))
        probe.reply = .success(.promptError("Gone", .invalid))
        prompt.sendComposed()
        XCTAssertEqual(probe.sends.last, .prompt(pane: a.pane, text: "Explain", target: a.pane))
        app.closePalette()
        app.promptDrafts = [:]
        probe.candidates = []
        prompt = try fixture.open()
        XCTAssertEqual(prompt.targetButton.label.string, "No agent in this window or session")
        XCTAssertFalse(prompt.targetButton.isEnabled)
        XCTAssertFalse(prompt.textView.isEditable)
        XCTAssertFalse(prompt.send.isEnabled)
        let panel = try XCTUnwrap(app.palettePanel)
        try sendKey(panel, "\u{1b}", code: 53)
        XCTAssertNil(app.palettePanel)
        XCTAssertTrue(app.promptDrafts.isEmpty)
        probe.candidates = [a]
        prompt = try fixture.open()
        prompt.type("late")
        var late: (@MainActor @Sendable (Result<RPCEvent.Reply.Value, Failure>) -> Void)?
        owner.request = { _, done in late = done }
        prompt.sendComposed()
        let savedPanel = try XCTUnwrap(app.palettePanel)
        savedPanel.palette.enter(.connect)
        late?(.success(.prompt(.delivered(PromptDelivered(pane: a.pane, via: .inbox)))))
        XCTAssertTrue(app.palettePanel === savedPanel, "a late delivery cannot close another mode")
        XCTAssertEqual(savedPanel.palette.mode, .connect)
        XCTAssertEqual(app.promptDrafts[prompt.key!]?.text, "late", "a late reply cannot clear the kept draft")
    }

    func testPromptQuoteReachesFieldWithCaret() throws {
        let fixture = try PromptFixture(self)
        defer { fixture.close() }
        let prompt = try fixture.open("alpha\nbeta")
        XCTAssertEqual(prompt.textView.string, "\n> alpha\n> beta")
        XCTAssertEqual(prompt.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(prompt.send.isEnabled, "a quote alone can be sent")
    }

    func testPromptFieldClickAfterPickerFocus() throws {
        let fixture = try PromptFixture(self)
        defer { fixture.close() }
        let prompt = try fixture.open()
        let panel = try XCTUnwrap(fixture.app.palettePanel)
        panel.palette.layoutSubtreeIfNeeded()
        try sendKey(panel, "\t", code: 48)
        XCTAssertTrue(panel.firstResponder === prompt.targetButton)
        let point = prompt.textView.convert(NSPoint(x: 24, y: 9), to: nil)
        XCTAssertTrue(panel.contentView?.hitTest(point) === prompt.textView, "a click in the prompt field must reach the text view")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        if panel.isKeyWindow {
            XCTAssertTrue(panel.firstResponder === prompt.textView, "clicking the empty prompt field must move focus from the picker to the text view")
        }
    }

    func testPromptStandardTextEditingKeys() throws {
        let fixture = try PromptFixture(self)
        defer { fixture.close() }
        let prompt = try fixture.open()
        let panel = try XCTUnwrap(fixture.app.palettePanel)
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        for (title, action, key, modifiers) in [
            ("Undo", Selector(("undo:")), "z", NSEvent.ModifierFlags.command),
            ("Redo", Selector(("redo:")), "Z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ] {
            let matches = edit.items.filter { $0.title == title }
            XCTAssertEqual(matches.count, 1, title)
            let item = try XCTUnwrap(matches.first)
            XCTAssertNil(item.target, title)
            XCTAssertEqual(item.action, action, title)
            XCTAssertEqual(item.keyEquivalent, key, title)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, title)
        }
        prompt.type("one two")
        prompt.textView.undoManager?.removeAllActions()
        try sendKey(panel, "a", code: 0, modifiers: .command)
        XCTAssertEqual(prompt.textView.selectedRange(), NSRange(location: 0, length: 7), "Cmd-A must select all through the standard Edit menu")
        prompt.textView.setSelectedRange(NSRange(location: 7, length: 0))
        try sendKey(panel, "!", code: 18, modifiers: .shift)
        XCTAssertEqual(prompt.textView.string, "one two!")
        try sendKey(panel, "z", code: 6, modifiers: .command)
        XCTAssertEqual(prompt.textView.string, "one two", "Cmd-Z must undo typing")
        try sendKey(panel, "Z", code: 6, modifiers: [.command, .shift])
        XCTAssertEqual(prompt.textView.string, "one two!", "Shift-Cmd-Z must redo typing")
        try sendKey(panel, String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123, modifiers: [.option, .function, .numericPad])
        XCTAssertEqual(prompt.textView.selectedRange(), NSRange(location: 4, length: 0), "Option-Left must reach NSTextView's word navigation")
        try sendKey(panel, "\u{7f}", code: 51, modifiers: .command)
        XCTAssertEqual(prompt.textView.string, "two!", "Cmd-Backspace must delete to the start of the line")
        prompt.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = prompt.textView.markedRange(), selection = prompt.textView.selectedRange()
        let attributes = try XCTUnwrap(prompt.textView.textStorage?.attributes(at: marked.location, effectiveRange: nil))
        prompt.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertTrue(prompt.textView.hasMarkedText())
        XCTAssertEqual(prompt.textView.selectedRange(), selection)
        XCTAssertEqual(prompt.textView.textStorage?.attributes(at: marked.location, effectiveRange: nil) as NSDictionary?, attributes as NSDictionary)
        prompt.textView.unmarkText()
        XCTAssertTrue(prompt.textView.string.hasPrefix("か"))
    }

    func testStandardEditMenuPreservesPaneSelectAll() async throws {
        let fixture = try PromptFixture(self)
        defer { fixture.close() }
        let owner = fixture.owner
        let server = try await fixture.startServer(self)
        _ = try await Child.run(server.tmux, ["-u", "-S", server.socket, "respawn-pane", "-k", "-t", "%0", "printf 'pane selection fixture\\r\\n'; exec /bin/cat"], env: tools.environment)
        owner.start()
        try await wait("pane ready") { owner.testSession?.pane(PaneID(number: 0)) != nil }
        let pane = try XCTUnwrap(owner.testSession?.pane(PaneID(number: 0)))
        try await wait("pane text") { self.surfaceText(pane).contains("pane selection fixture") }
        owner.window.makeFirstResponder(pane)
        XCTAssertFalse(pane.hasSelection)
        try sendKey(owner.window, "a", code: 0, modifiers: .command)
        XCTAssertTrue(pane.hasSelection, "Ghostty select_all must win before the standard Edit menu")
        XCTAssertTrue(pane.readSelection().contains("pane selection fixture"))
        try sendKey(owner.window, "c", code: 8, modifiers: .command)
        try await wait("Cmd-C uses Ghostty's clipboard binding") { fixture.runtime.pasteboard.string(forType: .string)?.contains("pane selection fixture") == true }
        fixture.runtime.pasteboard.clearContents()
        fixture.runtime.pasteboard.setString("pane paste probe", forType: .string)
        try sendKey(owner.window, "v", code: 9, modifiers: .command)
        try await wait("Cmd-V uses Ghostty's paste binding") { self.surfaceText(pane).contains("pane paste probe") }
        try sendKey(owner.window, "a", code: 0, modifiers: .command)
        let previousDelegate = NSApp.delegate
        NSApp.delegate = fixture.app
        defer { NSApp.delegate = previousDelegate }
        let shell = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Shell" }?.submenu)
        let explicit = NSMenuItem(title: "Pane leak probe", action: #selector(PaneView.runCommand(_:)), keyEquivalent: "b")
        explicit.target = pane
        explicit.representedObject = PaneCommand.split(.right)
        shell.addItem(explicit)
        let onCommand = pane.onCommand
        var commands = 0
        pane.onCommand = { _ in commands += 1 }
        defer { pane.onCommand = onCommand }
        try await wait("current session ready") { owner.currentSession != nil }
        let session = try XCTUnwrap(owner.currentSession)
        let source = try XCTUnwrap(owner.promptSource(session: session.id, window: try XCTUnwrap(pane.windowID), pane: pane.pane, quote: nil))
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(keyUp.window === owner.window)
        let beforeMonitor = pane.visualKeyUps
        _ = pane.visualKeyUpMonitor?(keyUp)
        XCTAssertEqual(pane.visualKeyUps, beforeMonitor + 1, "the registered monitor works while the palette is closed")
        for mode in [PaletteMode.root, .connect, .rename(owner, source.instance, session.id, original: session.name), .prompt(source)] {
            fixture.app.togglePalette()
            let panel = try XCTUnwrap(fixture.app.palettePanel)
            panel.palette.enter(mode)
            let selection = pane.readSelection()
            let keys = pane.visualKeyEvents, bindings = pane.visualBindingQueries, bindingActions = pane.visualBindingActions, text = pane.visualTextInputs, ups = pane.visualKeyUps, actions = pane.visualMenuCommands
            try sendKey(panel, "x", code: 7)
            try sendKey(panel, "a", code: 0, modifiers: .command)
            try sendKey(panel, "b", code: 11, modifiers: .command)
            _ = owner.window.performKeyEquivalent(with: try key(owner.window, "a", code: 0, modifiers: .command))
            owner.window.sendEvent(try key(owner.window, "x", code: 7))
            XCTAssertTrue(pane.visualKeyUpMonitor?(keyUp) === keyUp, "palette blocks the pane key-up monitor")
            XCTAssertEqual(pane.visualKeyEvents, keys, "palette mode leaked a pane key")
            XCTAssertEqual(pane.visualBindingQueries, bindings, "palette mode leaked a Ghostty binding query")
            XCTAssertEqual(pane.visualBindingActions, bindingActions, "palette mode leaked a Ghostty binding action")
            XCTAssertEqual(pane.visualTextInputs, text, "palette mode leaked text input")
            XCTAssertEqual(pane.visualKeyUps, ups, "palette mode leaked a key-up")
            XCTAssertEqual(pane.visualMenuCommands, actions, "palette mode leaked an explicitly targeted menu action")
            XCTAssertEqual(commands, 0)
            XCTAssertEqual(pane.readSelection(), selection, "palette keys must not change the pane selection")
            fixture.app.closePalette()
        }
        fixture.app.togglePalette()
        let payload = Data("palette OSC52".utf8).base64EncodedString()
        _ = try await Child.run(server.tmux, ["-u", "-S", server.socket, "set-option", "-s", "set-clipboard", "on", ";", "respawn-pane", "-k", "-t", "%0", "printf '\\033]52;c;\(payload)\\007'; exec /bin/cat"], env: tools.environment)
        try await wait("OSC52 writes the private pasteboard while the palette is open") { fixture.runtime.pasteboard.string(forType: .string) == "palette OSC52" }
    }

    func testStandardEditMenuSupportsSearchAndSidebarRename() throws {
        let fixture = try PromptFixture(self)
        defer { fixture.close() }
        let list = fixture.owner.sidebar.list
        list.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        cell.beginRename()
        let renameEditor = try XCTUnwrap(cell.nameField.currentEditor() as? NSTextView)
        let original = renameEditor.string
        try sendKey(fixture.owner.window, "a", code: 0, modifiers: .command)
        XCTAssertEqual(renameEditor.selectedRange(), NSRange(location: 0, length: original.utf16.count))
        try sendKey(fixture.owner.window, "x", code: 7)
        XCTAssertEqual(renameEditor.string, "x")
        try sendKey(fixture.owner.window, "z", code: 6, modifiers: .command)
        XCTAssertEqual(renameEditor.string, original, "sidebar rename supports standard Undo")
        try sendKey(fixture.owner.window, "\u{1b}", code: 53)
        fixture.app.togglePalette()
        let panel = try XCTUnwrap(fixture.app.palettePanel)
        let searchEditor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        for character in "abc" { try sendKey(panel, String(character)) }
        searchEditor.undoManager?.removeAllActions()
        try sendKey(panel, "a", code: 0, modifiers: .command)
        XCTAssertEqual(searchEditor.selectedRange(), NSRange(location: 0, length: 3))
        try sendKey(panel, "x", code: 7)
        XCTAssertEqual(searchEditor.string, "x")
        try sendKey(panel, "z", code: 6, modifiers: .command)
        XCTAssertEqual(searchEditor.string, "abc", "palette search supports standard Undo")
    }

    func testPromptResolveIsAtomicAndBounded() async throws {
        let fixture = try PromptFixture(self)
        let (app, owner) = (fixture.app, fixture.owner)
        defer { fixture.close() }
        var replies: [(@MainActor @Sendable (Result<RPCEvent.Reply.Value, Failure>) -> Void)] = []
        owner.request = { _, done in replies.append(done) }
        let candidates = fixture.probe.candidates
        let result: Result<RPCEvent.Reply.Value, Failure> = .success(.prompt(.candidates(candidates)))
        var source = fixture.source
        source.quote = "selected text"
        let draftKey = PromptDraft.Key(host: owner.host, instance: source.instance, pane: candidates[0].pane)
        app.promptDrafts[draftKey] = PromptDraft(text: "one\ntwo\nthree")
        app.togglePalette()
        var panel = try XCTUnwrap(app.palettePanel)
        let height = panel.frame.height
        panel.palette.enter(.prompt(source))
        panel.palette.enter(.prompt(source))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(panel.palette.mode, .root)
        XCTAssertEqual(panel.frame.height, height)
        XCTAssertNil(panel.palette.prompt)
        replies[0](result)
        let prepared = try XCTUnwrap(panel.palette.prompt)
        XCTAssertEqual(prepared.textView.string, appendQuote(to: "one\ntwo\nthree", selection: "selected text").text)
        XCTAssertEqual(prepared.preferredHeight, 170, accuracy: 0.5)
        app.closePalette()
        for cancellation in ["mode", "closed", "instance"] {
            owner.testReceive(fixture.snapshot)
            app.togglePalette()
            panel = try XCTUnwrap(app.palettePanel)
            panel.palette.enter(.prompt(source))
            let reply = try XCTUnwrap(replies.last)
            switch cancellation {
            case "mode": panel.palette.enter(.connect)
            case "closed": app.closePalette()
            default: owner.testReceive(try sidebarFixture { $0["server_instance"] = ["started_at": 1, "pid": 77777] })
            }
            reply(result)
            XCTAssertNil(app.palettePanel?.palette.prompt, cancellation)
            if cancellation == "mode" { XCTAssertEqual(panel.palette.mode, .connect) }
            if cancellation == "closed" { XCTAssertNil(app.palettePanel) }
            app.closePalette()
        }
        owner.testReceive(fixture.snapshot)
        app.promptDrafts[draftKey] = PromptDraft(text: "one\ntwo\nthree")
        let timeout = PalettePrompt.resolveTimeout
        PalettePrompt.resolveTimeout = 0.05
        defer { PalettePrompt.resolveTimeout = timeout }
        app.togglePalette()
        panel = try XCTUnwrap(app.palettePanel)
        panel.palette.enter(.prompt(source))
        let late = try XCTUnwrap(replies.last)
        try await wait("resolve timeout") { panel.palette.prompt?.status.stringValue == "kido did not reply" }
        let failed = try XCTUnwrap(panel.palette.prompt)
        late(result)
        XCTAssertEqual(failed.status.stringValue, "kido did not reply")
        let count = replies.count
        var retried = 0
        failed.resolved = { retried += 1 }
        failed.retry.performClick(nil)
        failed.retry.performClick(nil)
        XCTAssertEqual(replies.count, count + 1)
        late(result)
        XCTAssertEqual(failed.status.stringValue, "kido did not reply")
        let retryLate = try XCTUnwrap(replies.last)
        try await wait("retry timeout") { retried == 1 }
        retryLate(result)
        XCTAssertNil(failed.target, "a late retry reply cannot restore a timed-out attempt")
        failed.retry.performClick(nil)
        try XCTUnwrap(replies.last)(result)
        XCTAssertEqual(failed.target, candidates[0])
        XCTAssertEqual(failed.textView.string, appendQuote(to: "one\ntwo\nthree", selection: "selected text").text)
        app.closePalette()
        app.togglePalette()
        panel = try XCTUnwrap(app.palettePanel)
        panel.palette.enter(.prompt(source))
        let afterClose = try XCTUnwrap(replies.last)
        owner.close()
        afterClose(result)
        XCTAssertNil(app.palettePanel?.palette.prompt)
    }

    func testPromptDraftRoundTripWithDelayedResolve() async throws {
        let fixture = try PromptFixture(self)
        let (app, owner) = (fixture.app, fixture.owner)
        defer { fixture.close() }
        let server = try await fixture.startServer(self)
        _ = try await Child.run(server.tmux, ["-u", "-S", server.socket, "respawn-pane", "-k", "-t", "$0:", "printf '\\033]7501;state=working:app=claude-code\\007'; exec /bin/cat"], env: tools.environment)
        owner.start()
        try await wait("live agent") { owner.canPrompt && PaneView.owner(owner.window.firstResponder) != nil }
        let pane = try XCTUnwrap(PaneView.owner(owner.window.firstResponder))
        let delegate = NSApp.delegate
        NSApp.delegate = app
        defer { NSApp.delegate = delegate }
        let request = fixture.realRequest
        var release: (() -> Void)?
        owner.request = { value, done in
            request(value) { result in release = { done(result) } }
        }
        app.updateMenu(owner, responder: pane)
        try sendKey(owner.window, "o", code: 31, modifiers: .command)
        let typedEarly = app.palettePanel?.palette.prompt != nil
        XCTAssertNil(app.palettePanel, "a closed palette stays closed until the real resolve reply")
        try sendKey(owner.window, "o", code: 31, modifiers: .command)
        if typedEarly { app.palettePanel?.palette.prompt?.type("one draft for this agent") }
        try await wait("real resolve reply") { release != nil }
        release?()
        try await wait("ready prompt") { app.palettePanel?.palette.prompt?.target != nil }
        let first = try XCTUnwrap(app.palettePanel?.palette.prompt)
        if !typedEarly { first.type("one draft for this agent") }
        let key = try XCTUnwrap(first.key)
        try sendKey(app.palettePanel, "\u{1b}", code: 53)
        owner.request = request
        app.togglePalette()
        let panel = try XCTUnwrap(app.palettePanel)
        let index = try XCTUnwrap(panel.palette.shown.firstIndex { if case .pane(_, let position) = $0.entry.id { return position.pane == key.pane }; return false })
        for _ in 0..<index { _ = panel.palette.control(panel.palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))) }
        try sendKey(panel, "o", code: 31, modifiers: .command)
        try await wait("same target ready") { panel.palette.prompt?.target != nil }
        XCTAssertEqual(panel.palette.prompt?.key, key)
        XCTAssertEqual(panel.palette.prompt?.textView.string, "one draft for this agent", "pane Cmd-O and agent-row Cmd-O must share the draft")
        let raw = "# Heading\nAsk about `value`.\n\n> quote\n> more\n\noutside"
        let ready = try XCTUnwrap(panel.palette.prompt)
        ready.textView.setSelectedRange(NSRange(location: 0, length: ready.textView.string.utf16.count))
        ready.type(raw)
        var sent: String?
        owner.request = { value, done in
            if case .prompt(_, let text?, _) = value { sent = text }
            request(value, done)
        }
        try sendKey(panel, "\r", code: 36)
        try await wait("real server accepts raw markdown") { app.palettePanel == nil }
        XCTAssertEqual(sent, raw, "the real prompt RPC receives the field's exact raw markdown")
    }

    func testPromptShortcutMenuAndQuote() async throws {
        let fixture = try PromptFixture(self)
        let (app, owner, probe) = (fixture.app, fixture.owner, fixture.probe)
        defer { fixture.close() }
        let server = try await fixture.startServer(self)
        let setup = try await Child.run(server.tmux, ["-u", "-S", server.socket, "respawn-pane", "-k", "-t", "$0:", "printf 'alpha beta\\r\\n'; exec /bin/cat", ";", "split-window", "-d", "-t", "$0:", "printf '\\033]7501;state=working:app=claude-code\\007'; exec /bin/cat", ";", "split-window", "-d", "-t", "$0:", "printf '\\033]7501;state=working:app=claude-code\\007\\033]0;second\\007'; exec /bin/cat"], env: tools.environment)
        XCTAssertEqual(setup.status, 0, setup.err)
        owner.start()
        try await wait("source pane and agent are ready") { owner.currentSession != nil && (owner.snapshot?.promptPanes.filter(\.agent).count ?? 0) == 2 && PaneView.owner(owner.window.firstResponder) != nil }
        let pane = try XCTUnwrap(PaneView.owner(owner.window.firstResponder))
        let delegate = NSApp.delegate
        NSApp.delegate = app
        defer { app.closePalette(); NSApp.delegate = delegate }
        let session = try XCTUnwrap(owner.currentSession)
        let near = PromptCandidate(pane: PaneID(number: 1), session: session.id, window: WindowID(number: 0), title: "near")
        let second = PromptCandidate(pane: PaneID(number: 2), session: session.id, window: near.window, title: "second")
        probe.candidates = [near, second]; probe.install(owner)
        owner.window.makeFirstResponder(pane)
        app.updateMenu(owner, responder: pane)
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let promptItem = try XCTUnwrap(edit.items.first { $0.action == #selector(PaneView.promptSelectionItem(_:)) })
        XCTAssertEqual(promptItem.title, "Prompt…")
        XCTAssertTrue(promptItem.isEnabled)
        func commandO() throws {
            app.updateMenu(owner, responder: owner.window.firstResponder)
            try sendKey(owner.window, "o", code: 31, modifiers: .command)
        }
        try commandO()
        var prompt = try XCTUnwrap(app.palettePanel?.palette.prompt)
        XCTAssertEqual(prompt.source.pane, pane.pane)
        XCTAssertTrue(prompt.textView.string.isEmpty)
        XCTAssertEqual(prompt.target, near)
        app.closePalette()
        var selection = ghostty_selection_s(top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0), bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 9, y: 0), rectangle: false)
        XCTAssertTrue(ghostty_surface_set_selection(pane.surface, &selection))
        XCTAssertEqual(pane.readSelection(), "alpha beta")
        try commandO()
        prompt = try XCTUnwrap(app.palettePanel?.palette.prompt)
        XCTAssertTrue(prompt.textView.string.contains("> alpha beta"))
        XCTAssertEqual(promptItem.title, "Prompt with Selection…")
        prompt.type("draft")
        app.closePalette()
        app.promptDrafts[PromptDraft.Key(host: owner.host, instance: try XCTUnwrap(owner.snapshot).serverInstance, pane: second.pane)] = PromptDraft(text: "second draft")
        let agentPane = try XCTUnwrap(owner.testSession?.pane(second.pane))
        owner.window.makeFirstResponder(agentPane)
        try commandO()
        XCTAssertEqual(app.palettePanel?.palette.prompt?.target, second, "an agent's own pane wins over an earlier agent in the same window")
        XCTAssertEqual(app.palettePanel?.palette.prompt?.textView.string, "second draft")
        app.closePalette()
        owner.window.makeFirstResponder(pane)
        app.togglePalette()
        let panel = try XCTUnwrap(app.palettePanel)
        let palette = panel.palette
        palette.field.stringValue = try XCTUnwrap(palette.shown.first { if case .pane(_, let position) = $0.entry.id { position.pane == second.pane } else { false } }?.entry.title)
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try sendKey(panel, "o", code: 31, modifiers: .command)
        prompt = try XCTUnwrap(palette.prompt)
        XCTAssertEqual(prompt.source.pane, second.pane)
        XCTAssertEqual(prompt.target, second)
        XCTAssertEqual(prompt.textView.string, "second draft", "root ⌘O uses the same target draft")
        try sendKey(panel, "o", code: 31, modifiers: .command)
        XCTAssertTrue(palette.prompt === prompt, "⌘O in Prompt mode is ignored")
        app.closePalette()
        owner.window.makeFirstResponder(pane)
        app.togglePalette()
        let root = try XCTUnwrap(app.palettePanel?.palette)
        let row = try XCTUnwrap(root.shown.first { $0.entry.id == .command(15) }?.entry)
        XCTAssertFalse(root.selectedEntry?.agent == true)
        try sendKey(app.palettePanel, "o", code: 31, modifiers: .command)
        XCTAssertEqual(app.palettePanel?.palette.prompt?.source.pane, pane.pane, "root ⌘O on a non-agent uses the anchor pane")
        root.enter(.root)
        root.chooseEntry(row)
        XCTAssertEqual(app.palettePanel?.palette.prompt?.source.pane, pane.pane)
        app.closePalette()
        owner.window.makeFirstResponder(pane)
        pane.toggleCopyMode(nil)
        try await wait("copy mode entered") { if case .cursor = pane.copyMode { true } else { false } }
        try sendKey(owner.window, "p", code: 35)
        XCTAssertNil(app.palettePanel, "p without a copy selection opens nothing")
        try sendKey(owner.window, "v", code: 9)
        XCTAssertTrue(ghostty_surface_set_selection(pane.surface, &selection))
        try sendKey(owner.window, "p", code: 35)
        XCTAssertTrue(app.palettePanel?.palette.prompt?.textView.string.contains("> alpha beta") == true)
        app.closePalette()
        try commandO()
        XCTAssertTrue(app.palettePanel?.palette.prompt?.textView.string.contains("> alpha beta") == true)
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: near.pane, via: .inbox))))
        try XCTUnwrap(app.palettePanel?.palette.prompt).sendComposed()
        XCTAssertNil(app.palettePanel)
        XCTAssertNil(pane.copyMode)
        XCTAssertFalse(pane.hasSelection)
        XCTAssertTrue(owner.window.firstResponder === pane)
        app.promptDrafts = [:]
        probe.recorded = []
        let liveSnapshot = try XCTUnwrap(owner.snapshot)
        owner.testReceive(try sidebarFixture { $0["sessions"] = [] })
        owner.window.makeFirstResponder(pane)
        try commandO()
        XCTAssertNil(app.palettePanel)
        XCTAssertFalse(promptItem.isEnabled)
        pane.toggleCopyMode(nil)
        try await wait("copy mode for no-agent entries") { if case .cursor = pane.copyMode { true } else { false } }
        try sendKey(owner.window, "v", code: 9)
        XCTAssertTrue(ghostty_surface_set_selection(pane.surface, &selection))
        try sendKey(owner.window, "p", code: 35)
        XCTAssertNil(app.palettePanel)
        try commandO()
        XCTAssertNil(app.palettePanel)
        let contextEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let context = try XCTUnwrap(pane.menu(for: contextEvent))
        let contextPrompt = try XCTUnwrap(context.items.first { $0.action == #selector(PaneView.promptSelectionItem(_:)) })
        XCTAssertFalse(pane.validateMenuItem(contextPrompt))
        context.update()
        XCTAssertFalse(contextPrompt.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(contextPrompt.action), to: contextPrompt.target, from: contextPrompt))
        XCTAssertNil(app.palettePanel)
        XCTAssertTrue(probe.recorded.isEmpty)
        app.togglePalette()
        XCTAssertFalse(app.palettePanel?.palette.shown.contains { $0.entry.id == .command(15) } == true)
        let noAgentPanel = try XCTUnwrap(app.palettePanel)
        try sendKey(noAgentPanel, "o", code: 31, modifiers: .command)
        XCTAssertEqual(noAgentPanel.palette.mode, .root)
        XCTAssertTrue(probe.recorded.isEmpty)
        app.closePalette()
        let runSnapshot = try sidebarFixture { object in
            var main = (object["sessions"] as! [[String: Any]])[0]
            var marked = (main["nodes"] as! [[String: Any]])[0]
            marked["children"] = []; marked["run"] = "run-window"
            var agent = marked
            agent["id"] = "%1"; agent["pane"] = "%1"; agent["run"] = NSNull(); agent["title"] = "run-agent"
            main["nodes"] = [marked, agent]; object["sessions"] = [main]
        }
        owner.testReceive(runSnapshot)
        XCTAssertFalse(owner.canPrompt, "every agent in a run window is outside prompt scope")
        try commandO()
        XCTAssertNil(app.palettePanel)
        app.togglePalette()
        let runPanel = try XCTUnwrap(app.palettePanel)
        runPanel.palette.field.stringValue = "run-agent"
        runPanel.palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(runPanel.palette.selectedEntry?.agent == true)
        XCTAssertFalse(runPanel.palette.selectedEntry?.promptable == true, "the run-agent row has no Prompt hint")
        try sendKey(runPanel, "o", code: 31, modifiers: .command)
        XCTAssertEqual(runPanel.palette.mode, .root)
        XCTAssertTrue(probe.recorded.isEmpty)
        owner.testReceive(liveSnapshot)
        runPanel.palette.field.stringValue = ""
        runPanel.palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(app.palettePanel?.palette.shown.contains { $0.entry.id == .command(15) } == true)
        app.closePalette()
        pane.endCopy()
        owner.window.makeFirstResponder(pane)
        try commandO()
        let closingSource = try XCTUnwrap(app.palettePanel?.palette.prompt)
        closingSource.type("closed source")
        let killed = try await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-pane", "-t", pane.pane.description], env: tools.environment)
        XCTAssertEqual(killed.status, 0, killed.err)
        try await wait("source close reaches Prompt mode") { closingSource.sourceGone }
        XCTAssertEqual(closingSource.status.stringValue, "Source pane closed; agents resolved earlier stay available.")
        XCTAssertTrue(closingSource.targetButton.label.string.contains("(pane closed)"))
        closingSource.sendComposed()
        XCTAssertEqual(probe.sends.last, .prompt(pane: near.pane, text: "closed source", target: near.pane))

        XCTAssertNil(app.palettePanel)
    }

    func testPromptDraftPruningAndEmptyDeletion() throws {
        let fixture = try PromptFixture(self)
        let (app, owner, probe, snapshot) = (fixture.app, fixture.owner, fixture.probe, fixture.snapshot)
        let candidate = probe.candidates[0]
        probe.candidates = [candidate]
        defer { fixture.close() }
        var prompt = try fixture.open()
        prompt.type("saved")
        app.palettePanel?.palette.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        XCTAssertEqual(app.promptDrafts.count, 1, "click outside keeps the draft")
        prompt = try fixture.open()
        XCTAssertEqual(prompt.textView.string, "saved")
        prompt.textView.selectAll(nil)
        prompt.textView.insertText("", replacementRange: prompt.textView.selectedRange())
        app.closePalette()
        XCTAssertTrue(app.promptDrafts.isEmpty, "deleting the text removes the draft")
        prompt = try fixture.open()
        prompt.type("server")
        owner.testReceive(try sidebarFixture { $0["server_instance"] = ["started_at": 1791000001, "pid": 4243] })
        XCTAssertNil(app.palettePanel)
        XCTAssertTrue(app.promptDrafts.isEmpty, "an instance change removes even the open draft")
        owner.testReceive(snapshot)
        prompt = try fixture.open()
        prompt.type("agent")
        app.closePalette(.moved)
        XCTAssertEqual(app.promptDrafts.count, 1)
        let editor = try sidebarFixture { object in
            var sessions = object["sessions"] as! [[String: Any]]
            var main = sessions[0], nodes = main["nodes"] as! [[String: Any]]
            let children = nodes[1]["children"] as! [[String: Any]]
            nodes[0]["lifecycle"] = children[1]["lifecycle"]
            main["nodes"] = nodes; sessions[0] = main; object["sessions"] = sessions
        }
        owner.testReceive(editor)
        XCTAssertFalse(editor.promptPanes.first { $0.pane == candidate.pane }!.agent)
        XCTAssertEqual(app.promptDrafts.count, 1, "an external editor keeps the draft while its pane exists")
        owner.testReceive(snapshot)
        prompt = try fixture.open()
        XCTAssertEqual(prompt.textView.string, "agent", "the draft returns when the same pane reports an agent again")
        app.closePalette()
        var removed = snapshot
        removed.sessions[0].nodes.removeAll { if case .item(let item) = $0 { item.pane == candidate.pane } else { false } }
        owner.testReceive(removed)
        XCTAssertTrue(app.promptDrafts.isEmpty, "a killed agent pane drops its draft")
        owner.testReceive(snapshot)
        prompt = try fixture.open()
        prompt.type("owner")
        owner.close()
        XCTAssertTrue(app.promptDrafts.isEmpty, "owner close drops its host's drafts")
    }

    func testPromptMenuTitles() throws {
        let fixture = try PromptFixture(self)
        let app = fixture.app
        defer { fixture.close() }
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let item = try XCTUnwrap(edit.items.first { $0.action == #selector(PaneView.promptSelectionItem(_:)) })
        app.updatePromptMenu(edit, responder: nil)
        XCTAssertEqual(item.title, "Prompt…")
        XCTAssertFalse(item.isEnabled)
    }

    func testPaletteListsEveryWindowAndUnopenedRecentHosts() throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        let local = try XCTUnwrap(app.open(.local, start: false)), remote = try XCTUnwrap(app.open(.remote("devbox"), start: false))
        let previous = NSApp.mainMenu
        defer { app.closePalette(); local.close(); remote.close(); NSApp.mainMenu = previous }
        let snapshot = try sidebarFixture()
        local.testReceive(snapshot); remote.testReceive(snapshot)
        NSApp.mainMenu = app.mainMenu()
        app.routes.connect(.remote("devbox")); app.routes.connect(.remote("devbox-old"))
        var requests: [RPCRequest] = []
        remote.request = { request, _ in requests.append(request) }
        app.togglePalette()
        let palette = try XCTUnwrap(app.palettePanel?.palette)
        let entries = palette.shown.map(\.entry)
        let rows = sidebarRows(snapshot).filter { $0.kind == .header || $0.target != nil }
        XCTAssertEqual(entries.prefix(rows.count).map(\.title), rows.map(\.title))
        XCTAssertEqual(entries.dropFirst(rows.count).prefix(rows.count).map(\.title), rows.map(\.title))
        XCTAssertEqual(entries.filter { $0.symbol == "globe" }.map(\.title), ["devbox-old"])
        XCTAssertEqual(entries[rows.count * 2].id, .host("devbox-old"))
        XCTAssertEqual(entries[rows.count * 2 + 1].title, "New Session")
        let visa = try XCTUnwrap(entries.first { $0.title == "visa" && $0.detail == "devbox" })
        palette.chooseEntry(visa)
        XCTAssertEqual(requests, [.selectSession(try XCTUnwrap(snapshot.sessions.first { $0.name == "visa" }?.id))])
        XCTAssertNil(app.palettePanel)
    }

    func testPaletteKeyTogglesAndRestoresFocus() async throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13, onInput: { _ in }))
        owner.sidebar.content.addSubview(pane)
        let previous = NSApp.mainMenu, delegate = NSApp.delegate
        NSApp.mainMenu = app.mainMenu()
        NSApp.delegate = app
        defer {
            app.closePalette(); pane.dispose(); pane.removeFromSuperview(); owner.close()
            NSApp.mainMenu = previous; NSApp.delegate = delegate
        }
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
            owner.window.makeFirstResponder(pane)
            let opening = try key(owner.window, "p", code: 35, modifiers: modifiers)
            if modifiers == .command { XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: opening) == true) }
            else { XCTAssertTrue(pane.performKeyEquivalent(with: opening)) }
            try await wait("palette opened from a pane", within: 1) { app.palettePanel != nil }
            let panel = try XCTUnwrap(app.palettePanel)
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertNotNil(panel.firstResponder as? NSTextView)
            owner.window.makeFirstResponder(owner.window)
            let event = try key(panel, "p", code: 35, modifiers: modifiers)
            // NSApplication calls this before the field editor; the background app cannot make a window key.
            XCTAssertTrue(panel.performKeyEquivalent(with: event))
            XCTAssertNil(app.palettePanel)
            XCTAssertTrue(owner.window.firstResponder === pane)
        }
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
            owner.sidebar.list.focus()
            let prior = try XCTUnwrap(owner.window.firstResponder)
            let event = try key(owner.window, modifiers.contains(.shift) ? "P" : "p", code: 35, modifiers: modifiers)
            XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
            let panel = try XCTUnwrap(app.palettePanel)
            owner.window.makeFirstResponder(owner.window)
            XCTAssertTrue(panel.performKeyEquivalent(with: event))
            XCTAssertTrue(owner.window.firstResponder === prior)
        }
        owner.close()
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
            let event = try key(nil, modifiers.contains(.shift) ? "P" : "p", code: 35, modifiers: modifiers)
            XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
            let panel = try XCTUnwrap(app.palettePanel)
            XCTAssertTrue(panel.performKeyEquivalent(with: event))
            XCTAssertNil(app.palettePanel)
        }
    }

    func testPaletteClosesOnKeyWindowChangeWithoutStealingFocus() throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        let a = try XCTUnwrap(app.open(.local, start: false)), b = try XCTUnwrap(app.open(.remote("devbox"), start: false))
        defer { app.closePalette(); a.close(); b.close() }
        a.window.makeFirstResponder(a.sidebar.list)
        b.window.makeFirstResponder(b.sidebar.list)
        app.togglePalette()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: b.window)
        XCTAssertNil(app.palettePanel)
        XCTAssertTrue(b.window.firstResponder === b.sidebar.list)
        XCTAssertTrue(a.window.firstResponder === a.sidebar.list)
    }

    func testPaletteRefreshesWhileOpen() throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        defer { app.closePalette(); owner.close() }
        owner.testReceive(try sidebarFixture())
        var requests: [RPCRequest] = []
        owner.request = { request, _ in requests.append(request) }
        app.togglePalette()
        let palette = try XCTUnwrap(app.palettePanel?.palette)
        let stale = try XCTUnwrap(palette.shown.first { $0.entry.title == "main-watch" }?.entry)
        owner.testReceive(try sidebarFixture { $0["server_instance"] = ["started_at": 1791000001, "pid": 4243] })
        XCTAssertEqual(stale.check(), "That pane is gone")
        let rebuilt = try XCTUnwrap(palette.shown.first { $0.entry.title == "main-watch" }?.entry)
        XCTAssertNil(rebuilt.check())
        owner.testReceive(try sidebarFixture { $0["sessions"] = [] })
        XCTAssertFalse(palette.shown.contains { $0.entry.title == "main-watch" })
        XCTAssertEqual(stale.check(), "That pane is gone")
        palette.chooseEntry(stale)
        XCTAssertEqual(palette.error, "That pane is gone")
        XCTAssertTrue(requests.isEmpty)
    }

    func testPaletteModesAndKeys() throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = app.mainMenu()
        defer { NSApp.mainMenu = previousMenu }
        var opened: [Kido.Host] = []
        app.routes.ready(isDefaultLaunch: true) { host, _ in opened.append(host) }
        defer { app.closePalette() }
        app.togglePalette()
        let panel = try XCTUnwrap(app.palettePanel)
        XCTAssertTrue(panel.performKeyEquivalent(with: try key(panel, "K", code: 40, modifiers: [.command, .shift])))
        let palette = panel.palette
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertEqual(palette.mode, .connect)
        panel.sendEvent(try key(panel, "dev"))
        panel.sendEvent(try key(panel, "\u{7f}", code: 51))
        XCTAssertEqual(palette.field.stringValue, "de")
        XCTAssertEqual(palette.mode, .connect)
        editor.selectAll(nil)
        panel.sendEvent(try key(panel, "me@dev box"))
        panel.sendEvent(try key(panel, "\r", code: 36))
        XCTAssertNotNil(palette.error)
        XCTAssertEqual(palette.field.stringValue, "me@dev box")
        XCTAssertTrue(opened.isEmpty)
        editor.selectAll(nil); panel.sendEvent(try key(panel, "devbox"))
        XCTAssertNil(palette.error)
        panel.sendEvent(try key(panel, "\r", code: 36))
        XCTAssertEqual(opened, [.remote("devbox")])
        XCTAssertNil(app.palettePanel)
        app.connectRemoteHost()
        let again = try XCTUnwrap(app.palettePanel)
        XCTAssertEqual(again.palette.shown.map(\.entry.title), ["devbox", "Clear Recent Hosts"])
        let table = try XCTUnwrap(again.palette.subviews.first?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
        again.sendEvent(try key(again, "\u{e}", code: 45, modifiers: .control, ignoring: "n"))
        XCTAssertEqual(table.selectedRow, 1)
        again.sendEvent(try key(again, "\u{10}", code: 35, modifiers: .control, ignoring: "p"))
        XCTAssertEqual(table.selectedRow, 0)
        again.sendEvent(try key(again, String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125))
        XCTAssertEqual(table.selectedRow, 1)
        again.sendEvent(try key(again, String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126))
        XCTAssertEqual(table.selectedRow, 0)
        again.sendEvent(try key(again, "\r", code: 36))
        XCTAssertEqual(opened, [.remote("devbox"), .remote("devbox")])
        app.connectRemoteHost()
        let clear = try XCTUnwrap(app.palettePanel)
        clear.palette.choose(1)
        XCTAssertTrue(app.routes.recent.isEmpty)
        clear.sendEvent(try key(clear, "\u{7f}", code: 51))
        XCTAssertEqual(clear.palette.mode, .root)
        XCTAssertEqual(clear.palette.shown.map(\.entry.title), ["New Session", "Connect to Remote Host…"])
        clear.sendEvent(try key(clear, "\u{1b}", code: 53))
        XCTAssertNil(app.palettePanel)
    }

    func testCommandsRunAgainstCurrentMenuState() throws {
        final class Target: NSObject, NSMenuItemValidation {
            var enabled = true
            func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
            var calls = 0
            @objc func closeWindow() { calls += 1 }
        }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        let previous = NSApp.mainMenu
        defer { app.closePalette(); owner.close(); NSApp.mainMenu = previous }
        let target = Target()
        let menu = NSMenu(title: "File")
        let item = menu.addItem(withTitle: "Close Window", action: #selector(Target.closeWindow), keyEquivalent: "")
        item.target = target
        NSApp.mainMenu = menu
        target.enabled = false
        app.togglePalette()
        XCTAssertTrue(app.palettePanel?.palette.shown.isEmpty == true)
        app.closePalette()
        target.enabled = true
        app.togglePalette()
        let palette = try XCTUnwrap(app.palettePanel?.palette)
        XCTAssertEqual(palette.shown.map(\.entry.title), ["Close Window"])
        target.enabled = false
        palette.choose(0)
        XCTAssertEqual(palette.error, "Not available now")
        XCTAssertEqual(target.calls, 0)
        XCTAssertNotNil(app.palettePanel)
    }

    func testCloseSessionConfirmsAndKills() async throws {
        let dir = "/tmp/kp-" + UUID().uuidString.prefix(8)
        let result = try await Child.run(tools.kido, ["server", "--server", dir], env: tools.environment)
        XCTAssertEqual(result.status, 0, result.err)
        let server = try JSONDecoder().decode(Server.self, from: Data(result.out.utf8))
        let board = NSPasteboard(name: .init("kp-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        owner.testEndpoint = Endpoint(server: server, kido: tools.kido)
        addTeardownBlock { @MainActor in
            app.closePalette(); owner.close(); board.releaseGlobally()
            for id in ["$0", "$1", "$2"] {
                _ = try? await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-session", "-t", id], env: tools.environment)
            }
            try? FileManager.default.removeItem(atPath: dir)
        }
        let commands = ["new-session", "-d", "-s", "survivor", ";", "respawn-pane", "-k", "-t", "$0:", "printf '\\033]7501;state=working:app=claude-code\\007hello\\r\\n'; exec /bin/cat"]
        let setup = try await Child.run(server.tmux, ["-u", "-S", server.socket] + commands, env: tools.environment)
        XCTAssertEqual(setup.status, 0, setup.err)
        owner.start()
        let first = SessionID(number: 0), survivor = SessionID(number: 1)
        try await wait("two sessions and running cat") { owner.snapshot?.sessions.count == 2 && closeScope(owner.snapshot, target: .session(first)).running }
        owner.perform(.selectSession(first))
        try await wait("selected session") { owner.navigation.session == first && PaneView.owner(owner.window.firstResponder) != nil }
        let pane = try XCTUnwrap(PaneView.owner(owner.window.firstResponder))
        NSApp.mainMenu = app.mainMenu()
        app.togglePalette()
        let listed = try XCTUnwrap(app.palettePanel?.palette)
        XCTAssertNil(app.current)
        app.paletteStateChanged()
        for title in ["Rename Session…", "Close Session", "Close Window"] {
            XCTAssertTrue(listed.shown.contains { $0.entry.title == title }, title)
        }
        XCTAssertNotNil(listed.shown.first { $0.entry.title == "Prompt…" })
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "select_all", 10))
        try await wait("pane selection") { pane.hasSelection }
        app.paletteStateChanged()
        XCTAssertNotNil(listed.shown.first { $0.entry.title == "Prompt with Selection…" })
        app.closePalette()
        let originalSnapshot = try XCTUnwrap(owner.snapshot)
        app.renameSession()
        let stalePanel = try XCTUnwrap(app.palettePanel)
        owner.testReceive(try sidebarFixture { $0["server_instance"] = ["started_at": 1, "pid": 77777] })
        stalePanel.palette.rename("must-not-rename")
        XCTAssertEqual(stalePanel.palette.error, "That session is gone")
        owner.testReceive(originalSnapshot)
        var barrier = false
        owner.send([Command("display-message", "-p", "barrier")]) { _ in barrier = true }
        try await wait("stale rename barrier") { barrier }
        let unchanged = try await Child.run(server.tmux, ["-u", "-S", server.socket, "display-message", "-p", "-t", first.description, "#{session_name}"], env: tools.environment)
        XCTAssertEqual(unchanged.out.trimmingCharacters(in: .whitespacesAndNewlines), originalSnapshot.sessions.first { $0.id == first }?.name)
        app.closePalette()
        app.renameSession()
        let latePanel = try XCTUnwrap(app.palettePanel)
        let gate = "palette-" + UUID().uuidString
        owner.send([Command("wait-for", gate)])
        latePanel.palette.rename("late")
        app.closePalette()
        app.togglePalette()
        let replacement = try XCTUnwrap(app.palettePanel)
        _ = try await Child.run(server.tmux, ["-u", "-S", server.socket, "wait-for", "-S", gate], env: tools.environment)
        barrier = false
        owner.send([Command("display-message", "-p", "barrier")]) { _ in barrier = true }
        try await wait("late rename reply") { barrier }
        XCTAssertTrue(app.palettePanel === replacement)
        XCTAssertNil(replacement.palette.error)
        app.closePalette()
        try await wait("late rename snapshot") { owner.snapshot?.sessions.first { $0.id == first }?.name == "late" }
        app.renameSession()
        let renamePanel = try XCTUnwrap(app.palettePanel)
        let renameEditor = try XCTUnwrap(renamePanel.firstResponder as? NSTextView)
        XCTAssertEqual(renameEditor.selectedRange(), NSRange(location: 0, length: renamePanel.palette.field.stringValue.utf16.count))
        func rename(_ name: String) throws {
            renameEditor.selectAll(nil)
            renameEditor.insertText(name, replacementRange: renameEditor.selectedRange())
            renamePanel.sendEvent(try key(renamePanel, "\r", code: 36))
        }
        try rename("survivor")
        XCTAssertEqual(renamePanel.palette.error, "A session named “survivor” already exists.")
        try rename("main.2")
        XCTAssertEqual(renamePanel.palette.error, "Session names can’t contain “:” or “.”.")
        try rename("renamed")
        try await wait("palette renames the key window's session") { app.palettePanel == nil && owner.snapshot?.sessions.first { $0.id == first }?.name == "renamed" }
        app.closeSession()
        let alert = try XCTUnwrap(owner.preparedAlert?.alert)
        XCTAssertEqual(alert.informativeText, "Processes are still running in this session. Closing the session will end them.")
        owner.respondToAlert(.alertSecondButtonReturn)
        XCTAssertEqual(owner.snapshot?.sessions.count, 2)
        app.closeSession()
        owner.respondToAlert(.alertFirstButtonReturn)
        try await wait("control follows the surviving session") { owner.navigation.session == survivor && owner.snapshot?.sessions.count == 1 }
        owner.send([Command("new-session", "-d", "-s", "quiet")])
        let quiet = SessionID(number: 2)
        try await wait("quiet session appears") { owner.snapshot?.sessions.contains { $0.id == quiet } == true }
        XCTAssertFalse(closeScope(owner.snapshot, target: .session(quiet)).running)
        owner.confirmClose(.session(quiet), name: "quiet")
        XCTAssertNil(owner.preparedAlert)
        try await wait("quiet session closes without a sheet") { owner.snapshot?.sessions.contains { $0.id == quiet } == false }
    }

    func testNewSessionWithoutAWindowOpensOneOnce() throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("palette-" + UUID().uuidString))))
        let app = AppDelegate(runtime: runtime)
        var requests: [RPCRequest] = []
        app.routes.ready(isDefaultLaunch: true) { host, cause in
            app.open(host, start: false, cause: cause)?.request = { request, _ in requests.append(request) }
        }
        defer { app.owners.forEach { $0.close() } }
        app.newSession()
        let owner = try XCTUnwrap(app.owners.first)
        XCTAssertEqual(owner.host, .local)
        XCTAssertTrue(requests.isEmpty)
        owner.testReceive(try sidebarFixture())
        owner.testReceive(try sidebarFixture())
        XCTAssertEqual(requests, [.newSession])
        owner.close()
        app.newSession()
        let pending = try XCTUnwrap(app.owners.last)
        pending.close()
        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let reopened = try XCTUnwrap(app.owners.last)
        reopened.testReceive(try sidebarFixture())
        XCTAssertEqual(requests, [.newSession], "closing the pending owner drops its New Session intent")
    }
}

@MainActor private func sendKey(_ window: NSWindow?, _ text: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) throws {
    let event = try key(window, text, code: code, modifiers: modifiers)
    var rebound: [(NSMenuItem, Bool)] = []
    func bind(_ menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { bind(submenu) }
            guard item.target == nil, let action = item.action else { continue }
            var responder = window?.firstResponder
            var target: AnyObject?
            while let candidate = responder {
                if candidate.responds(to: action) { target = candidate; break }
                if let supplemental = candidate.supplementalTarget(forAction: action, sender: item) { target = supplemental as AnyObject; break }
                responder = candidate.nextResponder
            }
            if target == nil, let window {
                if window.responds(to: action) { target = window }
                else if let supplemental = window.supplementalTarget(forAction: action, sender: item) { target = supplemental as AnyObject }
                else if let delegate = window.delegate, delegate.responds(to: action) { target = delegate }
            }
            guard let target else { continue }
            rebound.append((item, item.isEnabled))
            item.target = target
            if let validator = target as? NSMenuItemValidation { item.isEnabled = validator.validateMenuItem(item) }
            else if let validator = target as? NSUserInterfaceValidations { item.isEnabled = validator.validateUserInterfaceItem(item) }
            else { item.isEnabled = true }
        }
    }
    if NSApp.keyWindow == nil, let menu = NSApp.mainMenu { bind(menu) }
    defer { for (item, enabled) in rebound { item.target = nil; item.isEnabled = enabled } }
    if window?.performKeyEquivalent(with: event) == true { return }
    if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
    window?.sendEvent(event)
}

@MainActor private func key(_ window: NSWindow?, _ text: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [], ignoring: String? = nil) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: ignoring ?? text, isARepeat: false, keyCode: code))
}

@MainActor private extension PalettePrompt {
    func type(_ text: String) { textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
}
