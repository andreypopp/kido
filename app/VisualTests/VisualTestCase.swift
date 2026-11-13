import AppKit
import Carbon
import GhosttyKit
import KoModel
import SidebarFeed
import SnapshotTesting
import PaneGeometry
import XCTest
import WebKit
@testable import Kido

// Compares the decoded pixel values and ignores the embedded colour profile, which follows the display.
private func pixelsDiffing() -> Diffing<NSImage> {
    let reference = Diffing<NSImage>.image
    return .init(toData: reference.toData, fromData: reference.fromData) { old, new in
        func raw(_ image: NSImage) -> (Int, Int, [UInt8])? {
            guard let rep = image.representations.lazy.compactMap({ $0 as? NSBitmapImageRep }).first, let bytes = rep.bitmapData else { return nil }
            return (rep.pixelsWide, rep.pixelsHigh, Array(UnsafeBufferPointer(start: bytes, count: rep.bytesPerRow * rep.pixelsHigh)))
        }
        if let old = raw(old), let new = raw(new), old.0 == new.0, old.1 == new.1, old.2 == new.2 { return nil }
        return reference.diff(old, new)
    }
}

extension Snapshotting where Value == NSImage, Format == NSImage {
    static var pixels: Snapshotting { .init(pathExtension: "png", diffing: pixelsDiffing()) }
}

// A view as every snapshot captures it, with the native windows of the floats that lie over it drawn on top by their screen
// frames, each captured the same way. The picture is the view's own bitmap unless `extend` lets the union of the frames
// grow it, so a float past the edge and its shadow are in it.
@MainActor func familyImage(of view: NSView, in area: CGRect? = nil, hosts: [NSWindow], extend: Bool = false) -> NSImage {
    func capture(_ view: NSView, _ rect: CGRect) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep
    }
    let rect = area ?? view.bounds
    guard let window = view.window, let base = capture(view, rect) else { return NSImage() }
    let main = window.convertToScreen(view.convert(rect, to: nil))
    let parts = hosts.compactMap { host in host.contentView.flatMap { content in capture(content, content.bounds).map { ($0, host.frame) } } }
    let union = extend ? parts.reduce(main) { $0.union($1.1) } : main
    var canvas = base
    var origin = CGPoint.zero
    if union != main {
        let scale = CGFloat(base.pixelsWide) / base.size.width
        canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((union.width * scale).rounded()), pixelsHigh: Int((union.height * scale).rounded()),
                                  bitsPerSample: base.bitsPerSample, samplesPerPixel: base.samplesPerPixel, hasAlpha: base.hasAlpha, isPlanar: false,
                                  colorSpaceName: base.colorSpaceName, bitmapFormat: base.bitmapFormat, bytesPerRow: 0, bitsPerPixel: base.bitsPerPixel) ?? base
        canvas.size = union.size
        origin = CGPoint(x: main.minX - union.minX, y: main.minY - union.minY)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    func draw(_ rep: NSBitmapImageRep, in rect: CGRect) {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    if canvas !== base { draw(base, in: CGRect(origin: origin, size: main.size)) }
    // Both bitmaps hold premultiplied 8-bit RGBA at the same scale, so a float's pixels go over the picture by integer arithmetic;
    // drawing them through a context would blend in another colour space and change the shadow's pixels.
    let scale = CGFloat(canvas.pixelsWide) / canvas.size.width
    for (rep, frame) in parts {
        guard canvas.bitsPerPixel == 32, rep.bitsPerPixel == 32, let target = canvas.bitmapData, let source = rep.bitmapData else {
            draw(rep, in: CGRect(x: frame.minX - union.minX, y: frame.minY - union.minY, width: frame.width, height: frame.height))
            continue
        }
        let x0 = Int(((frame.minX - union.minX) * scale).rounded()), y0 = Int(((union.maxY - frame.maxY) * scale).rounded())
        for row in 0..<rep.pixelsHigh where (0..<canvas.pixelsHigh).contains(y0 + row) {
            for column in 0..<rep.pixelsWide where (0..<canvas.pixelsWide).contains(x0 + column) {
                let s = source + row * rep.bytesPerRow + column * 4, t = target + (y0 + row) * canvas.bytesPerRow + (x0 + column) * 4
                let inverse = 255 - Int(s[3])
                if inverse == 255 { continue }
                for channel in 0..<4 { t[channel] = UInt8(min(255, Int(s[channel]) + (Int(t[channel]) * inverse + 127) / 255)) }
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: canvas.size)
    image.addRepresentation(canvas)
    return image
}

// The notices window over `view`'s window, when it shows cards.
@MainActor func noticesOverlay(over view: NSView) -> NoticesWindow? {
    (view.window?.childWindows ?? []).compactMap { $0 as? NoticesWindow }.first { $0.shown }
}

// The visible float windows over `view`'s window, lowest first.
@MainActor func floatHosts(over view: NSView) -> [FloatWindow] {
    let children = (view.window?.childWindows ?? []).compactMap { $0 as? FloatWindow }.filter { !$0.content.isHidden }
    var logicals: [WindowView] = []
    for child in children { if let logical = child.content.logical, !logicals.contains(where: { $0 === logical }) { logicals.append(logical) } }
    return logicals.flatMap { $0.visualFloatHosts }.filter { host in children.contains { $0 === host } }
}

extension WindowView {
    func visualFamilyImage() -> NSImage {
        familyImage(of: self, hosts: visualFloatHosts + [visualGhostWindow].compactMap { visualGhost == nil ? nil : $0 }, extend: true)
    }
}

extension Snapshotting where Value == WindowView, Format == NSImage {
    static var family: Snapshotting {
        .init(pathExtension: "png", diffing: pixelsDiffing(), asyncSnapshot: { view in Async { $0(view.visualFamilyImage()) } })
    }
}

extension Snapshotting where Value == NSView, Format == NSImage {
    static var pixels: Snapshotting { .init(pathExtension: "png", diffing: pixelsDiffing(), asyncSnapshot: Snapshotting<NSView, NSImage>.image.snapshot) }
}

// A pane that runs `cat` in raw mode, so what a test writes to it comes back as output.
let rawScript = "stty raw -echo; printf '\\033]2;raw-ready\\007'; exec /bin/cat"

@MainActor class VisualTestCase: XCTestCase {
    var serverEnvironment: [String: String] = [:]
    var checkoutRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func webviewJS(_ web: WKWebView, _ script: String, within seconds: Double = 10) async throws -> String {
        let done = expectation(description: "webview script: " + script)
        var answer: Result<Any, Error>?
        web.callAsyncJavaScript("return JSON.stringify(await (\(script)))", arguments: [:], in: nil, in: .page) { answer = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: seconds + 1)
        return try XCTUnwrap(try XCTUnwrap(answer).get() as? String)
    }

    func webviewUntil(_ web: WKWebView, _ condition: String, within seconds: Double = 10) async throws {
        _ = try await webviewJS(web, "new Promise((resolve,reject)=>{const observer=new MutationObserver(check);const timer=setTimeout(()=>{clean();reject(Error('Webview condition deadline: '+\(String(reflecting: condition))+' | status='+document.querySelector('#status')?.textContent+' | items='+(document.querySelector('#items')?.textContent||'').slice(-400)+' | dialogs='+document.querySelectorAll('.dialog').length+' | runs='+document.querySelectorAll('.run').length+' | spin='+document.querySelectorAll('.spin').length))},\(seconds * 1000));function clean(){observer.disconnect();clearTimeout(timer);removeEventListener('resize',check)}function check(){if(\(condition)){clean();resolve(true)}}observer.observe(document.documentElement,{attributes:true,childList:true,characterData:true,subtree:true});addEventListener('resize',check);check()})", within: seconds)
    }

    func presentedFrame(_ pane: PaneView, attempts: Int = 3, file: StaticString = #filePath, line: UInt = #line) async {
        var status = GHOSTTY_RENDER_PRESENTATION_DISCARDED
        for _ in 0..<attempts where status == GHOSTTY_RENDER_PRESENTATION_DISCARDED {
            let frame = expectation(description: "Ghostty presented \(pane.pane)")
            pane.visualFrame { status = $0; frame.fulfill() }
            await fulfillment(of: [frame], timeout: 10)
        }
        XCTAssertEqual(status, GHOSTTY_RENDER_PRESENTATION_PRESENTED, file: file, line: line)
    }

    func fullscreenHeader(width: CGFloat, background: NSColor? = .white) -> NSWindow {
        final class NativeHeader: NSView {
            var background = NSColor.white
            override func draw(_ rect: NSRect) { background.setFill(); bounds.fill() }
        }
        let header = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 52),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        header.isReleasedWhenClosed = false
        if let background {
            let content = NativeHeader()
            content.background = background
            header.contentView = content
        }
        header.setFrame(NSRect(x: -20000, y: -20000, width: width, height: 52), display: false)
        return header
    }

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
        checkSnapshot { verifySnapshot(of: list, as: .pixels, named: name, record: $0, file: file, testName: testName) }
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

    func fullscreenHostImage(_ owner: WindowOwner, root: NSView, crop: NSRect? = nil) throws -> NSImage {
        let size = root.bounds.size
        let header = fullscreenHeader(width: size.width, background: nil)
        header.titlebarAppearsTransparent = true
        header.appearance = owner.window.appearance
        defer { header.close() }
        let host = try XCTUnwrap(header.contentView)
        host.wantsLayer = true
        host.layer?.backgroundColor = owner.runtime.background.cgColor
        let tabs = WindowTabs(frame: owner.sidebar.tabs.convert(owner.sidebar.tabs.bounds, to: root))
        tabs.frame.origin.y = 8
        tabs.sidebar = owner.sidebar
        tabs.theme = owner.sidebar.tabs.theme
        tabs.entries = owner.sidebar.tabs.entries
        host.addSubview(tabs)
        host.layoutSubtreeIfNeeded()
        header.display()
        let body = try croppedImage(root, to: root.bounds)
        let band = try croppedImage(host, to: host.bounds)
        let area = crop ?? NSRect(origin: .zero, size: size)
        return NSImage(size: area.size, flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.translateBy(x: -area.minX, y: -area.minY)
            body.draw(in: NSRect(origin: .zero, size: size))
            band.draw(in: NSRect(x: 0, y: size.height - 52, width: size.width, height: 52))
            return true
        }
    }

    // With floats over the window, the notices window goes over them in the picture; without, the cards are drawn in
    // the pane area's view, as a snapshot of a window has always had them.
    func croppedImage(_ root: NSView, to rect: NSRect) throws -> NSImage {
        let hosts = floatHosts(over: root)
        if !hosts.isEmpty { return familyImage(of: root, in: rect, hosts: (hosts as [NSWindow]) + [noticesOverlay(over: root)].compactMap { $0 }) }
        return try inlineNotices(over: root) {
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: rect))
            root.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            return image
        }
    }

    func inlineNotices<T>(over view: NSView, _ body: () throws -> T) rethrows -> T {
        guard let notices = noticesOverlay(over: view)?.contentView?.subviews.first as? Notices else { return try body() }
        return try notices.visualInline(body)
    }

    func verifyWindowView(_ view: NSView, named name: String, record: Bool, file: StaticString = #filePath, testName: String = #function) -> String? {
        let hosts = floatHosts(over: view)
        if hosts.isEmpty { return inlineNotices(over: view) { verifySnapshot(of: view, as: .pixels, named: name, record: record, file: file, testName: testName) } }
        return verifySnapshot(of: familyImage(of: view, hosts: (hosts as [NSWindow]) + [noticesOverlay(over: view)].compactMap { $0 }), as: .pixels, named: name, record: record, file: file, testName: testName)
    }

    func headerImage(_ tabs: WindowTabs) throws -> NSImage {
        let root = try XCTUnwrap(tabs.window?.contentView?.superview)
        return try croppedImage(root, to: tabs.convert(tabs.bounds, to: root))
    }

    // A float's window or a drag's ghost that outlives its test sits over the windows of the tests after it.
    func assertNoLeakedFloatWindows(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let leaked = NSApp.windows.compactMap { window -> String? in
            if let host = window as? FloatWindow { return host.contentView !== host.content ? nil : "float of \(host.content.pane.map(String.init(describing:)) ?? "?") visible=\(host.isVisible) parent=\(host.parent != nil)" }
            return window is GhostWindow && window.contentView != nil ? "ghost visible=\(window.isVisible)" : nil
        }
        XCTAssertTrue(leaked.isEmpty, "\(when): leaked windows: \(leaked)", file: file, line: line)
    }

    override func tearDown() async throws {
        assertNoLeakedFloatWindows("after \(name)")
    }

    override func setUp() async throws {
        assertNoLeakedFloatWindows("before \(name)")
        let sources = TISCreateInputSourceList([kTISPropertyInputSourceID: "com.apple.keylayout.US"] as CFDictionary, true).takeRetainedValue() as! [TISInputSource]
        let source = try XCTUnwrap(sources.first)
        let property = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        PaneView.visualKeyTranslation = { event, modifiers in
            withExtendedLifetime(data) {
                let flags = (modifiers.contains(.shift) ? shiftKey : 0)
                    | (modifiers.contains(.control) ? controlKey : 0)
                    | (modifiers.contains(.option) ? optionKey : 0)
                    | (modifiers.contains(.command) ? cmdKey : 0)
                    | (modifiers.contains(.capsLock) ? alphaLock : 0)
                var deadKey: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, event.keyCode, UInt16(kUCKeyActionDown),
                    UInt32(flags >> 8), UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKey, characters.count, &length, &characters)
                XCTAssertEqual(status, noErr)
                return status == noErr ? String(utf16CodeUnits: characters, count: length) : nil
            }
        }
        addTeardownBlock { @MainActor in PaneView.visualKeyTranslation = nil }
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
