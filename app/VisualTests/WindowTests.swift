import AppKit
import GhosttyKit
import XCTest
import SnapshotTesting
import SidebarFeed
import TmuxControl
@testable import Kido

func assertPaperPixel(_ image: NSBitmapImageRep, x: Int, y: Int, expected: [Double], _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) throws {
    let pixels = try XCTUnwrap(image.converting(to: .sRGB, renderingIntent: .default), file: file, line: line)
    let color = try XCTUnwrap(pixels.colorAt(x: x, y: y), file: file, line: line)
    XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, message, file: file, line: line)
    for (value, expected) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
        XCTAssertEqual(value * 255, expected, accuracy: 2, message, file: file, line: line)
    }
}

@MainActor final class WindowTests: VisualTestCase {

    func testKidoSettings() async throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("other"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("kido-app.conf")
        let notes = directory.appendingPathComponent("notes.log")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.conf"),
                                                  withDestinationURL: directory.appendingPathComponent("other/theme.conf"))
        func load(_ text: String) throws -> (settings: GhosttyRuntime.KidoSettings, lines: [Substring]) {
            try ("background = #172029\nkido-unknown-key = 1\n" + text + "\n").write(to: config, atomically: false, encoding: .utf8)
            FileManager.default.createFile(atPath: notes.path, contents: nil)
            let log = try FileHandle(forWritingTo: notes)
            let saved = dup(STDERR_FILENO)
            dup2(log.fileDescriptor, STDERR_FILENO)
            let loaded = GhosttyRuntime.loadConfig(file: config.path, home: directory.path)
            dup2(saved, STDERR_FILENO)
            close(saved)
            try log.close()
            let parsed = try XCTUnwrap(loaded)
            ghostty_config_free(parsed.config)
            return (parsed.settings, try String(contentsOf: notes, encoding: .utf8).split(separator: "\n"))
        }
        for (text, files, shade, note) in [
            ("kido-unfocused-background-shift = 30%", [:], 0.3, nil),
            ("kido-unfocused-background-shift = 30", [:], 0.3, nil),
            ("kido-unfocused-background-shift = 0", [:], 0, nil),
            ("kido-unfocused-background-shift = -0", [:], 0, nil),
            ("kido-unfocused-background-shift = -100", [:], 1, nil),
            ("kido-unfocused-background-shift = \"\"", [:], nil, nil),
            ("kido-unfocused-background-shift = 20%\nkido-unfocused-background-shift = 40%", [:], 0.4, nil),
            ("kido-unfocused-background-shift =   \" 30.5% \"  ", [:], 0.305, nil),
            ("kido-unfocused-background-shift = +30", [:], nil, "+30"),
            ("kido-unfocused-background-shift = 1e1", [:], nil, "1e1"),
            ("kido-unfocused-background-shift = 0x1p4", [:], nil, "0x1p4"),
            ("kido-unfocused-background-shift = 100%", [:], 1, nil),
            ("kido-unfocused-background-shift = 101", [:], nil, "101"),
            ("kido-unfocused-background-shift = -10%", [:], 0.1, nil),
            ("kido-unfocused-background-shift = -101", [:], nil, "-101"),
            ("kido-unfocused-background-shift = dark", [:], nil, "dark"),
            ("", [:], nil, nil),
            ("kido-unfocused-background-shift = 20%\nkido-unfocused-background-shift =", [:], nil, nil),
            ("kido-unfocused-background-shift = 20%\nkido-unfocused-background-shift =   ", [:], nil, nil),
            ("config-file = included.conf", ["included.conf": "kido-unfocused-background-shift = 30%"], 0.3, nil),
            ("kido-unfocused-background-shift = 20%\nconfig-file = ?missing.conf\nconfig-file = ?\"included.conf\"",
             ["included.conf": "config-file = nested.conf", "nested.conf": "kido-unfocused-background-shift = \"30%\""], 0.3, nil),
            ("kido-unfocused-background-shift = 20%\nconfig-file = included.conf",
             ["included.conf": "kido-unfocused-background-shift ="], nil, nil),
            ("config-file = included.conf\nconfig-file = sibling.conf",
             ["included.conf": "kido-unfocused-background-shift = 10%\nconfig-file = nested.conf",
              "sibling.conf": "kido-unfocused-background-shift = 20%",
              "nested.conf": "kido-unfocused-background-shift = 30%\nconfig-file = included.conf"], 0.3, nil),
            ("config-file = linked.conf",
             ["other/theme.conf": "config-file = child.conf", "other/child.conf": "kido-unfocused-background-shift = 40%",
              "child.conf": "kido-unfocused-background-shift = 50%"], 0.4, nil)
        ] as [(String, [String: String], Double?, String?)] {
            for (name, contents) in files {
                try contents.write(to: directory.appendingPathComponent(name), atomically: false, encoding: .utf8)
            }
            let (settings, lines) = try load(text)
            XCTAssertEqual(settings.unfocusedShift, shade ?? 0.03, text)
            XCTAssertFalse(lines.contains { $0.contains("kido-unfocused-background-shift: unknown field") }, "\(text): \(lines)")
            XCTAssertTrue(lines.contains { $0.contains("kido-unknown-key: unknown field") }, text)
            XCTAssertEqual(lines.contains { $0.contains("not a percentage") }, note != nil, text)
            if let note { XCTAssertTrue(lines.contains { $0.hasSuffix("kido-unfocused-background-shift: not a percentage from -100 to 100: " + note) }, text) }
        }

        for (text, spacing, note) in [
            ("kido-pane-spacing = 8", 8, nil),
            ("kido-pane-spacing = \"12.5\"", 12.5, nil),
            ("kido-pane-spacing = 2", 2, nil),
            ("kido-pane-spacing = 32", 32, nil),
            ("", 8, nil),
            ("kido-pane-spacing = 12\nkido-pane-spacing =", 8, nil),
            ("kido-pane-spacing = 33", 8, "kido-pane-spacing: not a number of points from 2 to 32: 33"),
            ("kido-pane-spacing = 1.9", 8, "kido-pane-spacing: not a number of points from 2 to 32: 1.9"),
            ("kido-pane-spacing = 0", 8, "kido-pane-spacing: not a number of points from 2 to 32: 0"),
            ("kido-pane-spacing = wide", 8, "kido-pane-spacing: not a number of points from 2 to 32: wide"),
        ] as [(String, CGFloat, String?)] {
            let (parsed, lines) = try load(text)
            XCTAssertEqual(parsed.paneSpacing, spacing, text)
            XCTAssertFalse(lines.contains { $0.contains("kido-pane-spacing: unknown field") }, "\(text): \(lines)")
            XCTAssertEqual(lines.contains { $0.contains("not a number of points") }, note != nil, text)
            if let note { XCTAssertTrue(lines.contains { $0.hasSuffix(note) }, text) }
        }

        for (text, width, note) in [
            ("kido-focus-ring-width = 0.75", 0.75, nil),
            ("kido-focus-ring-width = \"4\"", 4, nil),
            ("kido-focus-ring-width = 0.5", 0.5, nil),
            ("", 1.5, nil),
            ("kido-focus-ring-width = 3\nkido-focus-ring-width =", 1.5, nil),
            ("kido-focus-ring-width = 4.5", 1.5, "4.5"),
            ("kido-focus-ring-width = 0.4", 1.5, "0.4"),
            ("kido-focus-ring-width = thick", 1.5, "thick"),
        ] as [(String, CGFloat, String?)] {
            let (parsed, lines) = try load(text)
            XCTAssertEqual(parsed.focusRingWidth, width, text)
            XCTAssertFalse(lines.contains { $0.contains("kido-focus-ring-width: unknown field") }, "\(text): \(lines)")
            XCTAssertEqual(lines.contains { $0.contains("not a number of points") }, note != nil, text)
            if let note { XCTAssertTrue(lines.contains { $0.hasSuffix("kido-focus-ring-width: not a number of points from 0.5 to 4: " + note) }, text) }
        }
    }

    func testLiveConfigFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("kido-app.conf")
        let included = directory.appendingPathComponent("included.conf")
        try "kido-unfocused-background-shift = 20%\n".write(to: included, atomically: false, encoding: .utf8)
        let board = NSPasteboard(name: .init("live-config-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file.path, pasteboard: board))
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.03)
        let owner = WindowOwner(host: .local, runtime: runtime, accents: HostAccents(preferences: nil), start: false)
        defer { runtime.onConfigChange = {}; owner.close() }
        func reload(_ edit: () throws -> Void) async throws {
            let changed = expectation(description: "config reload")
            runtime.onConfigChange = { owner.updateAppearance(); changed.fulfill() }
            try edit()
            await fulfillment(of: [changed], timeout: 0.3)
        }
        for (text, shade, atomic) in [("kido-unfocused-background-shift = 30%\nbackground = #172029\n", 0.3, false),
                                      ("kido-unfocused-background-shift = 20%\nbackground = #fffaf0\n", 0.2, true),
                                      ("kido-unfocused-background-shift = 40%\n", 0.4, false),
                                      ("background = #172029\n", 0.03, false),
                                      ("kido-unfocused-background-shift =\n", 0.03, false),
                                      ("kido-unfocused-background-shift = bad\n", 0.03, false),
                                      ("kido-unfocused-background-shift = -10%\nbackground = #171717\n", 0.1, false),
                                      ("kido-unfocused-background-shift = 40%\nbackground = #171717\n", 0.4, false),
                                      ("background = #fefaf1\n", 0.03, false),
                                      ("background = #192028\n", 0.03, false),
                                      ("background = #fff9ec\n", 0.03, false),
                                      ("background = #171717\n", 0.03, false),
                                      (nil, 0.03, false)] as [(String?, Double, Bool)] {
            try await reload {
                if let text { try text.write(to: file, atomically: atomic, encoding: .utf8) }
                else { try FileManager.default.removeItem(at: file) }
            }
            XCTAssertEqual(runtime.settings.unfocusedShift, shade)
            owner.sidebar.viewDidLayout()
            XCTAssertEqual(owner.sidebar.list.layer?.backgroundColor, owner.sidebar.listBackground?.cgColor)
            if let text, let expected = ["background = #fefaf1\n": [238.76, 235, 226.54], "background = #192028\n": [16.25, 20.8, 26],
                                        "background = #fff9ec\n": [239.7, 234.06, 221.84], "background = #171717\n": [14.95, 14.95, 14.95]][text] {
                let color = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
                for (actual, target) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
                    XCTAssertEqual(actual, target / 255, accuracy: 0.000001)
                }
            }
            if text?.contains("#fffaf0") == true { XCTAssertEqual(owner.window.appearance?.name, .aqua) }
            if text?.contains("#172029") == true { XCTAssertEqual(owner.window.appearance?.name, .darkAqua) }
        }
        try await reload { try "config-file = included.conf\n".write(to: file, atomically: false, encoding: .utf8) }
        try await reload {
            try "kido-unfocused-background-shift = 70%\n".write(to: included, atomically: false, encoding: .utf8)
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_RELOAD_CONFIG
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_APP
            XCTAssertTrue(GhosttyRuntime.action(runtime.app, target, action))
        }
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.7)
        let events = runtime.visualWatchEvents, scheduled = runtime.visualReloadsScheduled
        try "swap".write(to: directory.appendingPathComponent("kido.conf"), atomically: true, encoding: .utf8)
        try await wait("unrelated directory event handled", within: 0.3) { runtime.visualWatchEvents > events }
        XCTAssertEqual(runtime.visualReloadsScheduled, scheduled)
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            try await reload { NSApp.appearance = NSAppearance(named: name) }
            XCTAssertEqual(owner.window.appearance?.name, name)
            XCTAssertEqual(runtime.settings.unfocusedShift, 0.7)
            let actual = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
            let expected = name == .darkAqua ? [14.95, 14.95, 14.95] : [239.7, 234.06, 221.84]
            for (channel, target) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent], expected) {
                XCTAssertEqual(channel, target / 255, accuracy: 0.000001)
            }
        }
        try await reload { try FileManager.default.removeItem(at: file) }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            try await reload { NSApp.appearance = NSAppearance(named: name) }
            XCTAssertEqual(runtime.settings.unfocusedShift, 0.03)
            let actual = try XCTUnwrap(owner.sidebar.listBackground?.usingColorSpace(.sRGB))
            let expected = name == .darkAqua ? [14.95, 14.95, 14.95] : [239.7, 234.06, 221.84]
            for (channel, target) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent], expected) {
                XCTAssertEqual(channel, target / 255, accuracy: 0.000001)
            }
        }
    }

    func testSymlinkConfigReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linked-config-\(UUID().uuidString)")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("target-config-\(UUID().uuidString)")
        for path in [directory, targetDirectory] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        defer { for path in [directory, targetDirectory] { try? FileManager.default.removeItem(at: path) } }
        let file = directory.appendingPathComponent("kido-app.conf")
        let target = targetDirectory.appendingPathComponent("target.conf")
        try "kido-unfocused-background-shift = 20%\n".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let board = NSPasteboard(name: .init("linked-config-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file.path, pasteboard: board))
        func reload(_ edit: () throws -> Void) async throws {
            let changed = expectation(description: "symlink target reload")
            runtime.onConfigChange = { changed.fulfill() }
            try edit()
            await fulfillment(of: [changed], timeout: 0.3)
        }
        try await reload { try FileManager.default.moveItem(at: target, to: targetDirectory.appendingPathComponent("old.conf")) }
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.03)
        try await reload { try "kido-unfocused-background-shift = 30%\n".write(to: target, atomically: false, encoding: .utf8) }
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.3)
        try await reload { try "kido-unfocused-background-shift = 40%\n".write(to: target, atomically: false, encoding: .utf8) }
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.4)
        runtime.onConfigChange = {}
    }

    func testConfigDirectoryCreatedAfterLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("missing-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("new/kido-app.conf")
        let board = NSPasteboard(name: .init("missing-config-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file.path, pasteboard: board))
        let changed = expectation(description: "directory and config created")
        runtime.onConfigChange = { changed.fulfill() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "kido-unfocused-background-shift = 30%\n".write(to: file, atomically: false, encoding: .utf8)
        await fulfillment(of: [changed], timeout: 0.3)
        XCTAssertEqual(runtime.settings.unfocusedShift, 0.3)
        runtime.onConfigChange = {}
    }

    func testLiveWindowTheme() async throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        let board = NSPasteboard(name: .init("live-theme-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, accents: HostAccents(preferences: nil), start: false)
        defer { runtime.onConfigChange = {}; owner.close() }
        for (hex, appearance) in [("fffaf0", NSAppearance.Name.aqua), ("172029", .darkAqua), ("fffaf0", .aqua)] {
            let changed = expectation(description: "Ghostty config reload \(hex)")
            runtime.onConfigChange = { [weak owner] in owner?.updateAppearance(); changed.fulfill() }
            let config = try XCTUnwrap(ghostty_config_new())
            let text = "background = #\(hex)\n"
            ghostty_config_load_string(config, text, UInt(text.utf8.count), "/live-theme")
            ghostty_config_finalize(config)
            ghostty_app_update_config(runtime.app, config)
            ghostty_config_free(config)
            await fulfillment(of: [changed], timeout: 3)
            XCTAssertEqual(owner.window.appearance?.name, appearance, "\(hex) main window")
            XCTAssertEqual(owner.window.backgroundColor, runtime.canvas, "\(hex) window canvas")
            XCTAssertEqual(owner.sidebar.content.layer?.backgroundColor, runtime.canvas.cgColor, "\(hex) content canvas")
        }
    }

    func testSeenIsSharedAcrossSameHostWindows() throws {
        let board = NSPasteboard(name: .init("kido-seen-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let host = Kido.Host.remote("seen-\(UUID().uuidString.prefix(8))")
        let publisher = WindowOwner(host: host, runtime: runtime, accents: HostAccents(preferences: nil), start: false)
        let peer = WindowOwner(host: host, runtime: runtime, accents: HostAccents(preferences: nil), start: false)
        let other = WindowOwner(host: .remote("other-\(UUID().uuidString.prefix(8))"), runtime: runtime, accents: HostAccents(preferences: nil), start: false)
        defer { [publisher, peer, other].forEach { $0.close() } }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"server_instance":{"started_at":1791000000,"pid":4242},"error":null,"sessions":[{"id":"$0","name":"s","current":true,"nodes":[{"kind":"pane","id":"%1","pane":"%1","window":"@1","title":"agent","lifecycle":["Live",["Some_agent",{"name":"claude-code","status":{"since":1791000000,"msg":null,"state":["Idle",{"outcome":{"serial":3,"result":"failure"}}]}}]],"program_status":{"serial":3,"records":[]},"run":null,"started":null,"children":[]}]}]}
        """.utf8))
        func status(_ owner: WindowOwner) -> SidebarRow.Status? { owner.sidebar.list.visualRows.first { $0.target != nil }?.status }
        let baseline = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"server_instance":{"started_at":1791000000,"pid":4242},"error":null,"sessions":[]}
        """.utf8))
        for owner in [peer, other] { owner.testReceive(baseline); owner.testReceive(snapshot) }
        XCTAssertEqual([peer, other].map(status), [.error, .error], "unattended windows leave the outcome unseen")
        publisher.testAttended = true
        publisher.testReceive(snapshot)
        XCTAssertEqual(status(publisher), .quiet, "the attended window marks its active pane's outcome seen")
        XCTAssertEqual(status(peer), .quiet, "a same-host window redraws from the shared seen record")
        XCTAssertEqual(status(other), .error, "another host's seen record is separate")
    }

    func testOrphanedWindow() throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data("""
        {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"server_instance":{"started_at":1791000000,"pid":4242},"sessions":[{"id":"$0","name":"s","current":true,"nodes":[{"kind":"pane","id":"%0","pane":"%0","window":"@0","title":"","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[{"kind":"pane","id":"%1","pane":"%1","window":"@1","title":"","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":"bash","started":null,"children":[]}]}]}]}
        """.utf8))
        let model = SessionModel(session: SessionID(number: 0), windows: [.init(id: WindowID(number: 1), name: "Child")], window: WindowID(number: 1))
        XCTAssertEqual(model.navigation(snapshot).windows.map(\.id), [WindowID(number: 1)], "orphan child must retain a window entry")
    }

    func testWindowSelectionTargetsSession() {
        let model = SessionModel(session: SessionID(number: 3), windows: [.init(id: WindowID(number: 7), name: "w")], window: WindowID(number: 7))
        XCTAssertEqual(model.select(.number(1)), RPCRequest.selectWindow(SessionID(number: 3), WindowID(number: 7)), "selection must target the tab's session")
        XCTAssertNil(PaneCommand.window(.number(1)).command(PaneID(number: 0), cell: .zero))
        XCTAssertEqual(model.select(.next), .switchWindow(next: true))
        XCTAssertEqual(model.select(.previous), .switchWindow(next: false))
        XCTAssertEqual(SessionModel().select(.next), .switchWindow(next: true))
        XCTAssertEqual(SessionModel().select(.previous), .switchWindow(next: false))
        XCTAssertNil(SessionModel().select(.number(1)))
        XCTAssertEqual(model.select(.last), model.select(.number(1)))
        let menus = SessionMenus()
        var commands: [RPCRequest] = []
        menus.send = { commands.append($0) }
        menus.update(model)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        XCTAssertTrue(menus.window.performKeyEquivalent(with: key))
        XCTAssertEqual(commands, [model.select(.number(1))!])
    }

    func testWindowShortcutsUseRPC() {
        let menus = SessionMenus()
        var requests: [RPCRequest] = []
        menus.send = { requests.append($0) }
        menus.update(SessionModel())
        for (key, next) in [("}", true), ("{", false)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            XCTAssertTrue(menus.window.performKeyEquivalent(with: event))
            XCTAssertEqual(requests.last, .switchWindow(next: next))
        }
        XCTAssertEqual(requests.count, 2)
        let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        XCTAssertFalse(view?.items.contains { $0.title.contains("Window in Sidebar") } == true)
        XCTAssertFalse(view?.items.contains { ["j", "k"].contains($0.keyEquivalent) && $0.keyEquivalentModifierMask == [.command, .control] } == true)
        XCTAssertNil(PaneCommand.newWindow.command(PaneID(number: 0), cell: .zero))
    }

    func testWindowMenuHasZoom() async throws {
        let app = AppDelegate(runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("zoom-" + UUID().uuidString)))))
        let owner = try XCTUnwrap(app.open(.local, start: false))
        defer { owner.close() }
        let menus = SessionMenus()
        menus.update(SessionModel())
        let zoom = try XCTUnwrap(menus.window.items.first { $0.title == "Zoom" })
        XCTAssertEqual(zoom.action, #selector(NSWindow.performZoom(_:)))
        owner.window.setFrame(NSRect(x: 100, y: 100, width: 600, height: 400), display: false)
        owner.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(owner.window.validateMenuItem(zoom))
        let before = owner.window.frame
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(zoom.action), to: owner.window, from: zoom))
        try await wait("window zooms") { owner.window.frame != before }
        XCTAssertTrue(owner.window.isZoomed)
    }

    func testSessionShortcutsUseRPCNavigationOnce() {
        let menus = SessionMenus()
        var commands: [RPCRequest] = []
        menus.send = { commands.append($0) }
        menus.update(SessionModel())
        for (key, code, next) in [("]", UInt16(30), true), ("[", UInt16(33), false)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            XCTAssertTrue(menus.session.performKeyEquivalent(with: event))
            XCTAssertEqual(commands.last, .switchSession(next: next))
        }
        XCTAssertEqual(commands, [.switchSession(next: true), .switchSession(next: false)])
    }

    func testOfflineDismissesFloatingSidebar() throws {
        let owner = try XCTUnwrap(delegate.open(.local, start: false))
        defer { owner.close() }
        let sidebar = owner.sidebar
        sidebar.isCollapsed = true
        sidebar.focusSidebar(nil)
        XCTAssertTrue(sidebar.isFloating)
        owner.down("Disconnected", "", button: "Reconnect")
        XCTAssertFalse(sidebar.isFloating, "offline must remove floating Outside blocker")
        XCTAssertTrue(sidebar.isCollapsed)
        sidebar.dismissFloating()
    }

}
