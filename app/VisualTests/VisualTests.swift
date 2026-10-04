import AppKit
import GhosttyKit
import SnapshotTesting
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class VisualTests: XCTestCase {
    private let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private var tmux = ""
    private var socket = ""
    private var directory: URL!
    private var window: NSWindow!
    private var runtime: GhosttyRuntime!
    private var session: SessionView!
    private var connection: Connection!

    override func setUp() async throws {
        directory = app.appendingPathComponent("build/visual/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socket = directory.appendingPathComponent("tmux.sock").path
        tmux = try XCTUnwrap(ProcessInfo.processInfo.environment["KIDO_VISUAL_TMUX"])
        PaneView.renderOffscreen = true
    }

    override func tearDown() async throws {
        if connection != nil { connection.gridFailed() }
        window?.contentView = nil
        window?.close()
        connection = nil
        session = nil
        runtime = nil
        if FileManager.default.fileExists(atPath: socket) { _ = try? await command(["kill-session", "-t", "visual"]) }
        PaneView.renderOffscreen = false
        NSApp.appearance = nil
    }

    @discardableResult private func command(_ args: [String]) async throws -> String {
        let (status, out, err) = try await Child.run(tmux, ["-S", socket] + args)
        XCTAssertEqual(status, 0, "\(args): \(err)")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wait(_ description: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let done = expectation(description: description)
        let deadline = Date().addingTimeInterval(20)
        @MainActor func poll() {
            if predicate() { done.fulfill() }
            else if Date() >= deadline { XCTFail("Timed out: \(description)"); done.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() } }
        }
        poll()
        await fulfillment(of: [done], timeout: 21)
    }

    private var terminal: WindowView? { session?.windows.values.first { !$0.isHidden } }

    private func start(height: CGFloat = 560, dark: Bool = false, history: Int = 1000) async throws {
        let config = directory.appendingPathComponent("ghostty.conf")
        NSApp.appearance = NSAppearance(named: .aqua)
        let themes = app.appendingPathComponent("Resources/themes").path
        let theme = "light:\(themes)/kido-light,dark:\(themes)/kido-dark"
        try "theme = \(theme)\nfont-family = Menlo\nfont-size = 13\n".write(to: config, atomically: true, encoding: .utf8)
        runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: height),
                          styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        session = SessionView(runtime: runtime)
        session.frame = NSRect(x: 0, y: 0, width: 700, height: height)
        window.contentView = session
        let tmuxConfig = directory.appendingPathComponent("tmux.conf")
        try "set -g history-limit \(history)\n".write(to: tmuxConfig, atomically: true, encoding: .utf8)
        _ = try await command(["-f", tmuxConfig.path, "new-session", "-d", "-s", "visual", "-x", "80", "-y", "30", "exec /bin/cat"])
        connection = try Connection(server: Server(tmux: tmux, socket: socket), view: session,
                                    onChange: { [weak self] model in self?.session.show(model.window) },
                                    onDiagnostic: { XCTFail($0) }, onClose: { _ in })
        try await wait("initial layout") { self.terminal?.panes.isEmpty == false }
        try await settle()
        if dark {
            let changed = expectation(description: "appearance config changed")
            runtime.onConfigChange = { [weak self] in self?.session.updateBackground(); changed.fulfill() }
            runtime.onColorSchemeChange = { [weak self] in self?.session.updateColorScheme() }
            window.appearance = NSAppearance(named: .darkAqua)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await fulfillment(of: [changed], timeout: 20)
            try await settle()
        }
    }

    private func settle() async throws {
        try await wait("authoritative restore and presented frame") {
            guard let terminal = self.terminal else { return false }
            return terminal.visualGeometryReady && !terminal.panes.isEmpty && terminal.panes.filter { !$0.isHidden }.allSatisfy(\.visualReady)
        }
    }

    private func paint(lines: Int? = nil, alternate: Bool = false) async throws {
        for pane in try XCTUnwrap(terminal).panes.filter({ !$0.isHidden }) {
            let grid = ghostty_surface_size(pane.surface)
            let count = lines ?? Int(grid.rows)
            var text = alternate ? "\u{1b}[?1049h" : ""
            text += "\u{1b}[2J\u{1b}[H"
            for i in 0..<count {
                let color = i == count - 1 ? 32 : i == 0 ? 31 : [34, 35, 36, 33][i % 4]
                text += "\u{1b}[\(color)m" + String(repeating: "█", count: Int(grid.columns)) + "\u{1b}[0m"
                if i != count - 1 { text += "\r\n" }
            }
            let fixture = directory.appendingPathComponent("pane-\(pane.pane.number).txt")
            try text.write(to: fixture, atomically: true, encoding: .utf8)
            let done = directory.appendingPathComponent("done-\(UUID().uuidString)")
            _ = try await command(["respawn-pane", "-k", "-t", pane.pane.description, "/bin/cat '" + fixture.path + "'; /usr/bin/touch '" + done.path + "'; exec /bin/sleep 600"])
            try await wait("fixture cat completed") { FileManager.default.fileExists(atPath: done.path) }
        }
        for pane in try XCTUnwrap(terminal).panes.filter({ !$0.isHidden }) {
            let restored = expectation(description: "tmux capture replayed")
            pane.markContentDirty()
            connection.sync(pane.pane) { restored.fulfill() }
            await fulfillment(of: [restored], timeout: 20)
        }
        try await settle()
    }

    private func snapshot(_ name: String, pill: Bool = false, testName: String = #function) async throws {
        try await settle()
        let terminal = try XCTUnwrap(terminal)
        XCTAssertEqual(terminal.panes.contains { $0.visualPill }, pill)
        for pane in terminal.panes.filter({ !$0.isHidden }) {
            let frame = expectation(description: "Ghostty presented \(pane.pane)")
            pane.visualFrame { success in XCTAssertTrue(success); frame.fulfill() }
            await fulfillment(of: [frame], timeout: 10)
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertFalse(NSApp.isActive)
        CATransaction.flush()
        terminal.panes.forEach { $0.scroller.isHidden = true }
        CATransaction.flush()
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        for failure in [
            verifySnapshot(of: terminal, as: .image, named: name, record: record, testName: testName),
            verifySnapshot(of: terminal.visualLayout, as: .lines, named: name, record: record, testName: testName),
        ].compactMap({ $0 }) {
            if !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
        }
    }

    func testSingle() async throws {
        try await start()
        try await paint()
        try await snapshot("560")
        for height in [CGFloat(420), 680] {
            window.setContentSize(NSSize(width: 700, height: height))
            try await settle()
            try await paint()
            try await snapshot("\(Int(height))")
        }
    }

    func testSplitZoomFloat() async throws {
        try await start()
        _ = try await command(["split-window", "-h", "-t", "visual", "exec /bin/cat"])
        _ = try await command(["split-window", "-v", "-t", "visual:0.0", "exec /bin/cat"])
        _ = try await command(["split-window", "-v", "-t", "visual:0.1", "exec /bin/cat"])
        _ = try await command(["select-layout", "-t", "visual", "tiled"])
        try await wait("four panes") { self.terminal?.panes.count == 4 }
        try await paint()
        try await snapshot("2x2")
        _ = try await command(["resize-pane", "-Z", "-t", "visual:0.0"])
        try await wait("zoom") { self.terminal?.panes.filter { !$0.isHidden }.count == 1 }
        try await paint()
        try await snapshot("zoom")
        _ = try await command(["resize-pane", "-Z", "-t", "visual:0.0"])
        _ = try await command(["break-pane", "-W", "-s", "visual:0.3", "-X", "5", "-Y", "0", "-x", "35", "-y", "10"])
        try await wait("floating layout") { self.terminal?.visualLayout.contains("float %") == true }
        try await settle()
        try await paint()
        try await snapshot("float-top")
    }

    func testFractionalAlternateResizeDark() async throws {
        try await start(dark: true)
        try await paint(lines: 200)
        try XCTUnwrap(terminal?.panes.first).visualScroll(8.35)
        try await snapshot("fractional-dark")
        try await paint(alternate: true)
        try await snapshot("alternate-dark")
        for height in [430, 610, 480, 620, 560] { window.setContentSize(NSSize(width: 700, height: height)) }
        try await settle()
        try await snapshot("resize-settled-dark")
    }

    func testHistoryChunksAndResizeAnchors() async throws {
        try await start(history: 200000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        let fixture = directory.appendingPathComponent("history.txt")
        try (0..<100000).map { "row-\($0)\r\n" }.joined().write(to: fixture, atomically: true, encoding: .utf8)
        let done = directory.appendingPathComponent("history-done")
        _ = try await command(["respawn-pane", "-k", "-t", pane.pane.description,
                               "/bin/cat '" + fixture.path + "'; /usr/bin/touch '" + done.path + "'; exec /bin/sleep 600"])
        try await wait("100k fixture completed") { FileManager.default.fileExists(atPath: done.path) }
        let restored = expectation(description: "100k restore")
        pane.markContentDirty()
        connection.sync(pane.pane) { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 20)
        try await settle()
        XCTAssertEqual(pane.scrollPosition().history, historyChunkSize)
        pane.requestScroll(historyChunkSize)
        try await wait("100k pill visible") { pane.visualPill }
        pane.onLoadMore()
        try await wait("pill adds one chunk") { pane.scrollPosition().history == 2 * historyChunkSize }
        pane.showFind()
        pane.find?.field.stringValue = "row-12345"
        pane.find?.search()
        try await wait("find loads deep match") { pane.scrollPosition().history > 80000 }
        try await wait("find navigates to deep match") {
            let position = pane.scrollPosition()
            return position.history - position.offset > 80000
        }
        pane.find?.close()
        pane.requestScroll(5000)
        try await settle()
        window.setContentSize(NSSize(width: 700, height: 590))
        try await settle()
        XCTAssertEqual(pane.scrollTarget ?? 0, 5000, accuracy: 4)
        pane.onLoadMore()
        try await wait("older chunk reloaded") { pane.scrollPosition().history == 2 * historyChunkSize }
        pane.requestScroll(15000)
        try await settle()
        window.setContentSize(NSSize(width: 700, height: 560))
        try await settle()
        XCTAssertEqual(pane.scrollTarget ?? 0, 0)
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testHistoryPill() async throws {
        try await start(history: 100000)
        try await paint(lines: historyChunkSize + 1000)
        let pane = try XCTUnwrap(terminal?.panes.first)
        pane.requestScroll(historyChunkSize)
        try await wait("Load more visible") { pane.visualPill }
        try await snapshot("history-top", pill: true)
    }

    private func sidebarFixture(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Snapshot {
        let url = app.appendingPathComponent("VisualTests/Fixtures/live-feed.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func sidebarSnapshot(_ list: SidebarView, _ name: String, testName: String = #function) {
        list.layoutSubtreeIfNeeded()
        list.visualTable.layoutSubtreeIfNeeded()
        list.displayIfNeeded()
        CATransaction.flush()
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verifySnapshot(of: list, as: .image, named: name, record: record, testName: testName),
           !record || !failure.hasPrefix("Record mode is on.") { XCTFail(failure) }
    }

    func testSidebarCards() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 680),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        SidebarView.visualNow = Date(timeIntervalSince1970: 1791131198)
        defer { SidebarView.visualNow = nil }
        let live = try sidebarFixture()
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            list.update(.running(live))
            sidebarSnapshot(list, dark ? "live-dark" : "live-light")
        }
        list.visualFold(SessionID(number: 0))
        sidebarSnapshot(list, "folded-dark")
        list.visualFold(SessionID(number: 0))
        let nested = try sidebarFixture { object in
            object["client"] = ["session": "$0", "window": "@458", "pane": "%502"]
            var sessions = object["sessions"] as! [[String: Any]]
            var nodes = sessions[0]["nodes"] as! [[String: Any]]
            var children = nodes[1]["children"] as! [[String: Any]]
            children[0]["tail"] = [["text": "Rebuilding the sidebar cards and testing nested window corners", "role": "dim"]]
            nodes[1]["children"] = children
            sessions[0]["nodes"] = nodes
            object["sessions"] = sessions
        }
        list.update(.running(nested))
        sidebarSnapshot(list, "active-parent-dark")
        window.appearance = NSAppearance(named: .aqua)
        sidebarSnapshot(list, "active-parent-light")
        window.setContentSize(NSSize(width: 236, height: 680))
        sidebarSnapshot(list, "narrow-light")
        list.visualSearch.stringValue = "no-such-session"
        list.visualSearch.isHidden = false
        list.update(.running(try sidebarFixture { $0["filter"] = "no-such-session"; $0["sessions"] = [] }))
        sidebarSnapshot(list, "no-matches-light")
    }

    func testFoldedFilteredEnterSendsOnce() async throws {
        for reply: Reply in [.success([]), .failure(["delayed failure"])] {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let list = SidebarView()
            window.contentView = list
            list.update(.running(try sidebarFixture { $0["filter"] = "main" }))
            list.visualFold(SessionID(number: 0))
            list.visualSearch.stringValue = "main"
            var commands: [[Command]] = []
            var pending: [@MainActor @Sendable ([Reply]?) -> Void] = []
            list.send = { batch, done in commands.append(batch); pending.append(done) }
            _ = list.control(list.visualSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(commands.count, 1, "one Enter must send one switch-client before delayed reply")
            let completed = expectation(description: "delayed reply")
            DispatchQueue.main.async {
                for done in pending { done([reply]) }
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(commands.count, 1, "delayed reply must not send another switch-client")
            XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
        }
    }

    func testSwitchWindowOutputAndReconnect() async throws {
        let scratch = app.appendingPathComponent("build/sbfix/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let script = scratch.appendingPathComponent("kido")
        let fixture = scratch.appendingPathComponent("feed.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent("VisualTests/Fixtures/live-feed.json")))
        try JSONSerialization.data(withJSONObject: object).write(to: fixture)
        try """
        #!/bin/sh
        if [ "$1" = switch-window ]; then
            sleep 0.2
            [ "$2" = next ] && printf '$3 @12\\n'
            exit 0
        fi
        cat '\(fixture.path)'
        printf '\\n'
        while IFS= read -r line; do
            [ "$line" = 'filter exit' ] && exit 0
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var starts = 0
        var snapshots = 0
        let feed = Feed(socket: scratch.appendingPathComponent("tmux.sock").path, locate: { done in
            done(.success((kido: script.path, client: "private-client")))
        }, query: { "" }, onChange: { status in
            if case .starting = status { starts += 1 }
            if case .running = status { snapshots += 1 }
        })
        defer { feed.stop() }
        try await wait("fake feed ready") { snapshots == 1 }
        let switched = expectation(description: "switch stdout")
        feed.switchWindow(next: true) { target, error in
            XCTAssertNil(error)
            XCTAssertEqual(target?.session, SessionID(number: 3), "navigation must return its own stdout session")
            XCTAssertEqual(target?.window, WindowID(number: 12), "navigation must return its own stdout window")
            switched.fulfill()
        }
        await fulfillment(of: [switched], timeout: 5)
        let noop = expectation(description: "empty stdout")
        feed.switchWindow(next: false) { target, error in
            XCTAssertNil(error)
            XCTAssertNil(target, "empty stdout must be a no-op")
            noop.fulfill()
        }
        await fulfillment(of: [noop], timeout: 5)
        let stale = expectation(description: "old generation completion")
        stale.isInverted = true
        feed.switchWindow(next: true) { _, _ in stale.fulfill() }
        feed.filter("exit")
        try await wait("feed reconnected") { starts == 2 && snapshots == 2 }
        await fulfillment(of: [stale], timeout: 0.5)
    }

    func testSidebarFoldingKeysAndAccessibility() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        let fixture = try sidebarFixture()
        list.update(.running(fixture))
        list.focus()
        list.layoutSubtreeIfNeeded()
        let header = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        XCTAssertEqual(header.accessibilityRole(), .button)
        XCTAssertEqual(header.accessibilityValue() as? String, "expanded")
        func key(_ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            list.visualTable.keyDown(with: event)
        }
        try key(123)
        XCTAssertFalse(list.visualRows.contains { $0.target?.session == fixture.client.session })
        XCTAssertEqual(list.visualTable.selectedRow, -1)
        try key(124)
        XCTAssertTrue(list.visualRows.contains { $0.target == fixture.client })
        XCTAssertEqual(list.visualTable.selectedRow, -1)
        list.focus()
        let selected = list.visualTable.selectedRow
        try key(124)
        XCTAssertEqual(list.visualTable.selectedRow, selected, "unfolding keeps selection")
        let expanded = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        XCTAssertTrue(expanded.accessibilityPerformPress())
        let collapsed = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCell)
        XCTAssertEqual(collapsed.accessibilityValue() as? String, "collapsed")
        XCTAssertFalse(collapsed.addWindow.isHidden)
        XCTAssertTrue(collapsed.accessibilityPerformPress())
        for row in list.visualRows where row.target != nil {
            let cell = SidebarCell(SidebarFonts())
            cell.configure(row, expanded: true)
            XCTAssertTrue(cell.toolTip?.contains(row.indicatorDescription) == true)
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testNavigationFeedFirst() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        let initial = try sidebarFixture()
        let destination = try sidebarFixture { $0["client"] = ["session": "$0", "window": "@458", "pane": "%502"] }
        list.update(.running(initial))
        list.layoutSubtreeIfNeeded()
        list.visualFold(SessionID(number: 0))
        list.update(.running(destination))
        list.completedNavigation(to: (destination.client.session, destination.client.window))
        let selected = list.visualTable.selectedRow
        XCTAssertGreaterThanOrEqual(selected, 0, "feed-first completion must select the destination")
        if selected >= 0 {
            XCTAssertEqual(list.visualRows[selected].target, destination.client)
            XCTAssertTrue(list.visualTable.visibleRect.intersects(list.visualTable.rect(ofRow: selected)), "destination must be visible")
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }

    func testNoOpNavigationConsumesReveal() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 260),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let list = SidebarView()
        window.contentView = list
        list.update(.running(try sidebarFixture()))
        list.visualFold(SessionID(number: 0))
        list.completedNavigation(to: nil)
        list.update(.running(try sidebarFixture { $0["client"] = ["session": "$0", "window": "@458", "pane": "%502"] }))
        XCTAssertFalse(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) }, "unrelated client change must not consume a completed no-op navigation")
    }

    func testSidebarNavigationAndAnchoring() async throws {
        try await start()
        let list = SidebarView()
        list.frame = NSRect(x: 0, y: 0, width: 292, height: 260)
        window.contentView = list
        let fixture = try sidebarFixture { object in
            let original = (object["sessions"] as! [[String: Any]])[0]
            object["sessions"] = (0..<20).map { i -> [String: Any] in
                var session = original
                session["id"] = "$\(i)"
                session["name"] = "session-\(i)"
                return session
            }
        }
        list.update(.running(fixture))
        list.layoutSubtreeIfNeeded()
        let anchorIndex = 12
        let anchorID = list.visualRows[anchorIndex].id
        list.visualScroll.contentView.scroll(to: NSPoint(x: 0, y: list.visualTable.rect(ofRow: anchorIndex).minY + 7.25))
        let before = list.visualScroll.contentView.bounds.minY - list.visualTable.rect(ofRow: anchorIndex).minY
        let stable = try sidebarFixture { object in
            let original = (object["sessions"] as! [[String: Any]])[0]
            object["sessions"] = ([99] + Array(0..<20)).map { i -> [String: Any] in
                var session = original
                session["id"] = "$\(i)"
                session["name"] = "session-\(i)"
                return session
            }
        }
        list.update(.running(stable))
        list.layoutSubtreeIfNeeded()
        let newIndex = try XCTUnwrap(list.visualRows.firstIndex { $0.id == anchorID })
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThan(newIndex, anchorIndex)
        XCTAssertEqual(list.visualScroll.contentView.bounds.minY - list.visualTable.rect(ofRow: newIndex).minY, before, accuracy: 1)
        list.visualFold(SessionID(number: 0))
        list.update(.running(fixture))
        XCTAssertFalse(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) })
        let navigated = try sidebarFixture { $0["client"] = ["session": "$0", "window": "@458", "pane": "%502"] }
        list.completedNavigation(to: (navigated.client.session, navigated.client.window))
        XCTAssertEqual(list.visualRows[list.visualTable.selectedRow].target?.window, navigated.client.window)
        list.update(.running(navigated))
        XCTAssertTrue(list.visualRows.contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 502)) })
        let row = try XCTUnwrap(list.visualRows.first { $0.target != nil })
        var commands: [[Command]] = []
        var left = 0
        var filters: [String] = []
        list.leave = { left += 1 }
        list.filter = { filters.append($0) }
        list.visualSearch.stringValue = "main"
        list.focus()
        list.send = { batch, done in commands.append(batch); done([.failure(["no such pane"])]) }
        list.visualJump(row)
        XCTAssertEqual(commands, [[Command("switch-client", "-t", "\(row.target!.session):\(row.target!.window).\(row.target!.pane)")]])
        XCTAssertEqual(list.query, "main")
        XCTAssertEqual(left, 0)
        XCTAssertEqual(list.visualDiagnostic, "no such pane")
        XCTAssertTrue(list.containsFocus)
        list.send = { batch, done in commands.append(batch); XCTAssertTrue(Thread.isMainThread); done([.success([])]) }
        list.visualJump(row)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(left, 1)
        XCTAssertEqual(list.query, "")
        XCTAssertEqual(filters, [""])
        list.visualSearch.stringValue = "keep-me"
        list.update(.running(try sidebarFixture()))
        XCTAssertEqual(list.query, "keep-me")
        _ = list.control(list.visualSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(list.query, "")
        XCTAssertTrue(list.visualSearch.isHidden)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        list.visualTable.keyDown(with: event)
        XCTAssertNotEqual(list.visualTable.selectedRow, -1)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        list.visualTable.keyDown(with: escape)
        XCTAssertEqual(left, 2)
        let target = try XCTUnwrap(list.visualRows.first { $0.target != nil })
        let failed = expectation(description: "real private tmux jump reply")
        list.send = { [weak self] batch, done in
            self?.connection.send(batch) { replies in XCTAssertTrue(Thread.isMainThread); done(replies); failed.fulfill() }
        }
        list.visualJump(target)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
    }
}
