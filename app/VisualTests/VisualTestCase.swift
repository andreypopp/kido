import AppKit
import GhosttyKit
import KoModel
import SidebarFeed
import SnapshotTesting
import PaneGeometry
import XCTest
@testable import Kido

// A pane that runs `cat` in raw mode, so what a test writes to it comes back as output.
let rawScript = "stty raw -echo; printf '\\033]2;raw-ready\\007'; exec /bin/cat"

@MainActor class VisualTestCase: XCTestCase {
    var serverEnvironment: [String: String] = [:]

    func checkSnapshot(file: StaticString = #filePath, line: UInt = #line, _ verify: (Bool) -> String?) {
        let record = ProcessInfo.processInfo.environment["KIDO_VISUAL_RECORD"] == "1"
        if let failure = verify(record), !record || !failure.hasPrefix("Record mode is on.") {
            XCTFail(failure, file: file, line: line)
        }
    }
    func surfaceText(_ pane: PaneView, in tag: ghostty_point_tag_e = GHOSTTY_POINT_SCREEN) -> String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                                            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(pane.surface, selection, &text), let bytes = text.text else { return "" }
        defer { ghostty_surface_free_text(pane.surface, &text) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    func observeFrames(_ layer: CALayer, _ frame: @escaping @MainActor () -> Void) -> NSKeyValueObservation {
        layer.observe(\.contents, options: .new) { layer, _ in
            guard layer.contents != nil else { return }
            MainActor.assumeIsolated { frame() }
        }
    }

    func sidebarSnapshot(_ list: SidebarView, _ name: String, file: StaticString = #filePath, testName: String = #function) {
        let window = list.window!
        window.layoutIfNeeded()
        list.layoutSubtreeIfNeeded()
        list.visualTable.tile()
        list.visualTable.layoutSubtreeIfNeeded()
        list.displayIfNeeded()
        CATransaction.flush()
        list.layoutSubtreeIfNeeded()
        list.visualTable.tile()
        list.visualTable.layoutSubtreeIfNeeded()
        if list.visualTable.numberOfRows > 0 { list.visualTable.scrollRowToVisible(0) }
        list.visualScroll.reflectScrolledClipView(list.visualScroll.contentView)
        list.displayIfNeeded()
        CATransaction.flush()
        XCTAssertFalse(window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive)
        checkSnapshot { verifySnapshot(of: list, as: .image, named: name, record: $0, file: file, testName: testName) }
    }

    func mainQueueFence() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func drain(_ runtime: GhosttyRuntime) async throws {
        var quiet = 0
        for _ in 0..<20 where quiet < 3 {
            ghostty_app_tick(runtime.app)
            let wakeups = runtime.visualWakeups
            await mainQueueFence()
            quiet = runtime.visualWakeups == wakeups ? quiet + 1 : 0
        }
    }

    func wait(_ description: String, within seconds: Double = 20, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let done = expectation(description: description)
        var finished = false
        func finish() { if !finished { finished = true; done.fulfill() } }
        @MainActor func poll() {
            if finished { return }
            if predicate() { finish() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { poll() } }
        }
        // One block at the original deadline, never a poll's own clock check: after a main-queue stall,
        // main-queue timers due earlier than this deadline still run before the verdict.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if !finished { if !predicate() { XCTFail("Timed out: \(description)") }; finish() }
        }
        poll()
        await fulfillment(of: [done], timeout: seconds + 1)
    }

    override func invokeTest() {
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { super.invokeTest() }
    }

    func headerImage(_ tabs: WindowTabs) throws -> NSImage {
        let root = try XCTUnwrap(tabs.window?.contentView?.superview)
        let rect = tabs.convert(tabs.bounds, to: root)
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: rect))
        root.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: tabs.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    override func setUp() async throws {
        serverEnvironment = tools.environment
        WindowOwner.clipboardConsent.reset()
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    // A state directory for a private ko server that an owner launches; the test ends the server.
    func koServerDir() throws -> String {
        var template = Array("/tmp/ko-vt-XXXXXX".utf8CString)
        let dir = String(cString: try XCTUnwrap(mkdtemp(&template)))
        addTeardownBlock { @MainActor in
            _ = try? await Child.run(tools.ko, ["kill-server", "--server", dir])
            try? FileManager.default.removeItem(atPath: dir)
        }
        return dir
    }

    @discardableResult func ko(_ arguments: [String], dir: String) async throws -> String {
        let split = arguments.firstIndex(of: "--") ?? arguments.endIndex
        let result = try await Child.run(tools.ko, Array(arguments[..<split]) + ["--server", dir] + arguments[split...])
        XCTAssertEqual(result.status, 0, "\(arguments): \(result.err)")
        return result.out
    }

    // Waits until the server's answer at `path` contains `text`.
    func koUntil(_ dir: String, _ path: String, contains text: String, within seconds: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try await !ko(["api", path], dir: dir).contains(text) {
            guard Date() < deadline else { return XCTFail("Timed out: \(path) has no \(text)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // A new pane that runs `script` under sh.
    // The default prints the title "raw-ready" once its tty is raw.
    func koPane(_ script: String = rawScript, vars: String = "{}") -> String {
        let command = try! String(decoding: JSONSerialization.data(withJSONObject: ["type": "shell", "command": script]), as: UTF8.self)
        return #"{"pane":{"new":{"vars":\#(vars),"command":\#(command)}}}"#
    }

    // Replaces the server's layout; `sessions` is the JSON array of draft sessions.
    func koPut(_ dir: String, _ sessions: String) async throws {
        try await ko(layoutPut(#"{"revision":0,"layout":{"sessions":\#(sessions)}}"#, dir: dir), dir: dir)
    }

    // A running private server whose one session "main" has one window of one pane.
    func koLaunched(pane: String? = nil) async throws -> String {
        let dir = try koServerDir()
        _ = try await KoServer.launch(dir: dir)
        try await koMain(dir, pane: pane)
        return dir
    }

    // One session "main" with one window of one pane, the start of most tests.
    func koMain(_ dir: String, pane: String? = nil) async throws {
        try await koPut(dir, #"[{"name":"main","windows":[{"name":"w","tree":\#(pane ?? koPane())}]}]"#)
    }

    // The snapshot with the lifecycle and the core's mark of one pane replaced, as a status change of the pane would change them.
    func withLifecycle(_ snapshot: Snapshot, pane: PaneID, _ lifecycle: Lifecycle, mark: KoSchema.Mark) -> Snapshot {
        func item(_ item: Item) -> Item {
            var updated = item
            if item.id == pane {
                updated.fixtureLifecycle = lifecycle
                updated.pane.mark = mark
            }
            updated.children = item.children.map(node)
            return updated
        }
        func node(_ node: SidebarFeed.Node) -> SidebarFeed.Node {
            switch node {
            case .item(let i): .item(item(i))
            case .window(let group): .window(.init(id: group.id, children: group.children.map(item)))
            }
        }
        var snapshot = snapshot
        snapshot.sessions = snapshot.sessions.map { SessionNodes(id: $0.id, name: $0.name, nodes: $0.nodes.map(node)) }
        return snapshot
    }
}

extension PaneView {
    // A pane that no server view feeds: what its surface writes goes to `input`.
    convenience init?(runtime: GhosttyRuntime, pane: PaneID, font: Float, host: Kido.Host = .local, input: @escaping (Data) -> Void) {
        self.init(runtime: runtime, pane: pane, font: font, host: host)
        visualInput = input
    }

    // The grid of a pane that no server view feeds.
    func resize(cols: Int, rows: Int) {
        XCTAssertTrue(ghostty_surface_set_grid_size(surface, UInt16(cols), UInt16(rows), nil))
        refreshScroller()
    }

    // The bytes of a pane that no server view feeds, written to its surface.
    func visualFeed(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            ghostty_surface_process_output(surface, base.assumingMemoryBound(to: CChar.self), UInt(buffer.count))
        }
    }
}
