import AppKit
import GhosttyKit
import KoClient
import KoClientKit
import KoModel
import SnapshotTesting
import SidebarFeed
import PaneGeometry
import XCTest
@testable import Kido

@MainActor final class AppFocusTests: AppWindowCase {

    func testBackgroundLaunchIsNotActivatable() {
        XCTAssertTrue(background)
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited, "a background launch must not be activatable")
    }

    func testVsyncMeasurement() async throws {
        guard ProcessInfo.processInfo.environment["KIDO_VSYNC_MEASURE"] == "1" else { throw XCTSkip("authorized on-screen measurement only") }
        let go = directory.path + "/go"
        try await start(pane: "while [ ! -e " + SSH.quote(go) + " ]; do sleep 0.01; done; python3 -u -c 'import time; end=time.monotonic()+10; print(\"\\033[?25l\"); i=0\nwhile time.monotonic()<end: print(i); i+=1; time.sleep(0.004)\ntime.sleep(30)'")
        NSApp.setActivationPolicy(.regular)
        PaneView.renderOffscreen = false
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("private measurement window is unoccluded") { self.window.occlusionState.contains(.visible) }
        try Data().write(to: URL(fileURLWithPath: "/tmp/kido-vsync-visible-\(getpid())"))
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        var installations: [Double] = []
        let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { installations.append(CACurrentMediaTime()) }
        defer { observation.invalidate(); window.orderOut(nil) }
        let display = window.screen?.displayID ?? 0
        FileManager.default.createFile(atPath: go, contents: nil)
        try await Task.sleep(for: .seconds(10))
        let sorted = zip(installations.dropFirst(), installations).map { ($0.0 - $0.1) * 1000 }.sorted()
        XCTAssertGreaterThan(sorted.count, 30)
        let quantiles = [0.5, 0.95, 0.99].map { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * $0))] }
        let report = "host pid=\(getpid()), display_id=\(display), display=\(window.screen?.localizedName ?? "none"), maximum=\(window.screen?.maximumFramesPerSecond ?? 0)Hz, key=\(window.isKeyWindow), first_responder=\(window.firstResponder === pane)\nIOSurface installations (NOT physical presentation): count=\(installations.count), median/p95/p99_ms=\(quantiles)\n"
        try report.write(toFile: "/tmp/kido-vsync-measure-\(getpid()).txt", atomically: true, encoding: .utf8)
        print(report)
    }

    func testBecomingKeyRestoresPaneFocusUnlessSheetOrSidebarOwnsIt() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"a","tree":\#(koPane())}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("owner ready") { owner.testSession?.activePane != nil && owner.testBanner.isHidden }
        let pane = try XCTUnwrap(owner.testSession?.activePane)
        let window = try XCTUnwrap(owner.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        window.makeFirstResponder(nil)
        let sheetFocus = window.firstResponder
        XCTAssertNotNil(window.attachedSheet)
        window.becomeKey()
        XCTAssertTrue(window.firstResponder === sheetFocus, "activation must not take focus under a sheet")
        window.endSheet(sheet)
        sheet.close()

        owner.sidebar.focusSidebar(nil)
        let sidebarFocus = window.firstResponder
        XCTAssertFalse(owner.sidebar.isFloating)
        XCTAssertTrue(owner.sidebar.list.containsFocus)
        window.becomeKey()
        XCTAssertTrue(window.firstResponder === sidebarFocus, "explicit sidebar keyboard focus survives activation")

        owner.sidebar.list.leave()
        window.makeFirstResponder(nil)
        window.becomeKey()
        XCTAssertTrue(window.firstResponder === pane, "becoming key must restore the active pane")
    }

    func testBannerDismissalRestoresPaneFocus() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"a","tree":\#(koPane())}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        defer { owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("owner ready") { owner.snapshot != nil && owner.testSession?.activePane != nil && owner.testBanner.isHidden }
        let pane = try XCTUnwrap(owner.testSession?.activePane)
        owner.window.makeFirstResponder(pane)
        let snapshot = try XCTUnwrap(owner.snapshot)
        owner.down("Disconnected", "Reconnecting…", button: nil)
        XCTAssertFalse(owner.window.firstResponder === pane)
        owner.testReceive(snapshot)
        XCTAssertTrue(owner.testBanner.isHidden)
        XCTAssertTrue(owner.window.firstResponder === pane, "a restored connection must restore pane focus without activation")
    }

    func testPaletteDismissalDoesNotRestoreHiddenPane() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"a","tree":\#(koPane())},{"name":"b","tree":\#(koPane())}]}]"#)
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        defer { app.closePalette(); owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("two windows ready") { owner.testSession?.windows.count == 2 }
        let session = try XCTUnwrap(owner.testSession)
        let original = try XCTUnwrap(session.activePane)
        owner.window.makeFirstResponder(original)
        app.togglePalette()
        XCTAssertNotNil(app.palettePanel)
        let next = try XCTUnwrap(session.windows.first { !$0.value.displayedPanes.contains { $0 === original } }?.key)
        session.show(next)
        XCTAssertTrue(original.isHiddenOrHasHiddenAncestor)
        app.closePalette()
        XCTAssertTrue(owner.window.firstResponder === session.activePane, "palette dismissal must not restore a hidden pane")
    }

    func testSameWindowDeferredPaneFocus() async throws {
        try loadRuntime()
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"zsh","tree":{"split":"h","children":[\#(koPane()),\#(koPane())]}}]}]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path
        defer { owner.close() }
        owner.start()
        let split = PaneID(number: 2), first = PaneID(number: 1)
        try await wait("owner split snapshot") { owner.sidebar.list.visualRows.contains { $0.target?.pane == split } }
        let row = try XCTUnwrap(owner.sidebar.list.visualRows.first { $0.target?.pane == split })
        owner.sidebar.focusSidebar(nil)
        owner.sidebar.list.visualJump(row)
        XCTAssertTrue(owner.sidebar.list.containsFocus, "focus must wait until the pane becomes current")
        try await wait("the jump lands") { owner.window.firstResponder.flatMap(PaneView.owner)?.pane == split }
        let original = try XCTUnwrap(owner.sidebar.list.visualRows.first { $0.target?.pane == first })
        owner.sidebar.focusSidebar(nil)
        owner.sidebar.list.visualJump(original)
        owner.sidebar.focusSidebar(nil)
        try await wait("the server moved the client") { owner.testModel?.selection.pane == first }
        await mainQueueFence()
        XCTAssertTrue(owner.sidebar.list.containsFocus, "new focus intent must cancel a deferred pane target")
        let list = owner.sidebar.list, table = list.visualTable
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderBack(nil)
        owner.window.display()
        func click(_ index: Int) throws {
            let rect = table.rect(ofRow: index)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            for type: NSEvent.EventType in [.leftMouseUp, .leftMouseDown] {
                NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)), atStart: true)
            }
            owner.window.sendEvent(try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { owner.window.sendEvent(up) }
        }
        list.leave()
        let pane = try XCTUnwrap(owner.window.firstResponder as? PaneView)
        try await wait("the copy pane is ready") { !pane.restoring }
        pane.toggleCopyMode(nil)
        try await wait("the pane enters copy mode") { if case .cursor = pane.copyMode { true } else { false } }
        try click(try XCTUnwrap(list.visualRows.firstIndex { $0.target?.pane == pane.pane }))
        XCTAssertTrue(owner.window.firstResponder === pane)
        XCTAssertNotNil(pane.copyMode, "a sidebar click does not end the pane's copy mode")
        pane.endCopy()
        for floating in [false, true] {
            owner.sidebar.isCollapsed = floating
            owner.sidebar.focusSidebar(nil)
            let index = try XCTUnwrap(list.visualRows.firstIndex { $0.target != nil && $0.target != list.position })
            let target = try XCTUnwrap(list.visualRows[index].target)
            try click(index)
            try await wait("mouse selection completed") { list.position == target }
            XCTAssertTrue(list.containsFocus)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            NSApp.postEvent(event, atStart: true)
            owner.window.sendEvent(try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)))
            try await wait("Return leaves sidebar") { !list.containsFocus }
            XCTAssertFalse(owner.sidebar.isFloating)
        }
    }

    func testOSC52ClipboardConsentAndPrivatePaneTransport() async throws {
        let copy = Data("copied ✓".utf8).base64EncodedString()
        let script = directory.appendingPathComponent("clipboard.py")
        let result = directory.appendingPathComponent("clipboard-reply")
        let ready = directory.appendingPathComponent("clipboard-ready")
        let go = directory.appendingPathComponent("clipboard-go")
        try """
        import os, select, time, tty
        tty.setraw(0)
        deadline = time.monotonic() + 5
        while not os.path.exists('\(ready.path)') and time.monotonic() < deadline: time.sleep(0.02)
        os.write(1, b'\\x1b]52;p;?\\x1b\\\\')
        deadline = time.monotonic() + 12
        reply = b''
        while time.monotonic() < deadline:
            readable, _, _ = select.select([0], [], [], 0.4 if reply else 0.1)
            if readable: reply += os.read(0, 65536)
            elif reply: break
        open('\(result.path)', 'wb').write(reply)
        time.sleep(3)
        """.write(to: script, atomically: true, encoding: .utf8)
        try await start(pane: "while [ ! -e " + SSH.quote(go.path) + " ]; do sleep 0.02; done; printf '\\033]52;c;\(copy)\\007'; exec /usr/bin/python3 " + SSH.quote(script.path))
        XCTAssertNotEqual(runtime.pasteboard.name.rawValue, "NSGeneralPboard")
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        window.contentView = nil
        window.isReleasedWhenClosed = false
        window.close()
        window = owner.window
        window.contentView = session
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { owner.close() }
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        let board = runtime.pasteboard
        board.clearContents()
        board.setString("before", forType: .string)
        board.clearContents()
        board.setString("before-live", forType: .string)
        try client?.focus(true)
        try Data().write(to: go)
        try await wait("OSC52 private pane printf live copy") { board.string(forType: .string) == "copied ✓" }
        try Data().write(to: ready)
        try await wait("OSC52 private pane consent sheet") { owner.preparedAlert != nil }
        let alert = try XCTUnwrap(owner.preparedAlert?.alert)
        XCTAssertEqual(alert.messageText, "Allow applications on “Local” to read your Mac clipboard?")
        XCTAssertEqual(alert.informativeText, "This also permits applications reached through SSH inside its panes.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Allow for this connection", "Always allow", "Deny"])
        let text = "named ✓\nclipboard"
        board.clearContents()
        board.setString(text, forType: .string)
        owner.respondToAlert(.alertFirstButtonReturn)
        try await wait("OSC52 reply received in original private pane") { FileManager.default.fileExists(atPath: result.path) }
        let expected = Data("\u{1b}]52;p;\(Data(text.utf8).base64EncodedString())\u{1b}\\".utf8)
        XCTAssertEqual(try Data(contentsOf: result), expected, "the reply goes to the pane through the server")
    }
}
