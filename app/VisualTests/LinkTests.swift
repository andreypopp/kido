import AppKit
import GhosttyKit
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class LinkTests: VisualTestCase {
    func testCmdClickLinks() async throws {
        let board = NSPasteboard(name: .init("kido-link-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        for host in [Host.local, .remote("example")] {
            var opened: [URL] = []
            var handled: [String] = []
            let owner = WindowOwner(host: host, runtime: runtime, start: false, openBrowser: { opened.append($0) })
            defer { owner.close() }
            for (text, osc8) in [("https://example.com/osc8?x=1", true), ("file:///tmp/kido-link-test", true), ("https://example.com/regex", false)] {
                let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13, host: host) { _ in })
                defer { pane.dispose() }
                owner.window.contentView = pane
                pane.resize(cols: 80, rows: 24)
                XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
                pane.onURL = { handled.append($0); owner.openLink($0) }
                let content = osc8 ? "\u{1b}]8;;\(text)\u{1b}\\click here\u{1b}]8;;\u{1b}\\" : text
                XCTAssertTrue(pane.feed(Data(("\u{1b}c" + content).utf8), kind: .snapshot, epoch: pane.historyEpoch))
                if host == .local, !osc8 {
                    for kind in [GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, GHOSTTY_ACTION_OPEN_URL_KIND_HTML] {
                        var target = ghostty_target_s()
                        target.tag = GHOSTTY_TARGET_SURFACE
                        target.target.surface = pane.surface
                        var action = ghostty_action_s()
                        action.tag = GHOSTTY_ACTION_OPEN_URL
                        action.action.open_url.kind = kind
                        text.withCString { bytes in
                            action.action.open_url.url = bytes
                            action.action.open_url.len = UInt(text.utf8.count)
                            XCTAssertFalse(GhosttyRuntime.action(runtime.app, target, action), "local non-OSC 8 links must use Ghostty's opener")
                        }
                    }
                    for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
                    XCTAssertEqual(handled, ["https://example.com/osc8?x=1", "file:///tmp/kido-link-test"])
                    continue
                }
                let point = pane.convert(NSPoint(x: pane.cell.width * 2, y: pane.bounds.height - pane.cell.height * 0.5), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    if type == .leftMouseDown { pane.mouseDown(with: event) } else { pane.mouseUp(with: event) }
                }
                for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(handled.last, text, "\(host.label) Cmd-click must reach the app URL handler")
                XCTAssertEqual(opened.map(\.absoluteString), handled.filter { $0.hasPrefix("https:") }, "non-HTTP links must not reach NSWorkspace")
            }
            XCTAssertEqual(opened.map(\.absoluteString), host == .local ? ["https://example.com/osc8?x=1"] : ["https://example.com/osc8?x=1", "https://example.com/regex"])
            XCTAssertFalse(owner.window.isVisible || owner.window.isKeyWindow || owner.window.isMainWindow || NSApp.isActive)
        }
    }
}
