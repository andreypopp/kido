import AppKit
import GhosttyKit
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
            owner.testReceive(try sidebarFixture { object in
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
            })
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
        let commands = ["new-session", "-d", "-s", "survivor", ";", "respawn-pane", "-k", "-t", "$0:", "printf '\\033]7501;state=working:app=builder\\007hello\\r\\n'; exec /bin/cat"]
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

@MainActor private func key(_ window: NSWindow?, _ text: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [], ignoring: String? = nil) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: ignoring ?? text, isARepeat: false, keyCode: code))
}
