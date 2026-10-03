import AppKit
import GhosttyKit
import SnapshotTesting
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
        if !socket.isEmpty { _ = try? await command(["kill-session", "-t", "visual"]) }
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
}
