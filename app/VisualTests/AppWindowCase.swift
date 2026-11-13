import AppKit
import GhosttyKit
import KoClient
import KoClientKit
import KoModel
import SnapshotTesting
import SidebarFeed
import PaneGeometry
import WebKit
import XCTest
@testable import Kido

@MainActor class AppWindowCase: VisualTestCase {
    var directory: URL!
    var window: NSWindow!
    private static var processRuntime: GhosttyRuntime?
    // Outlives every test class: Ghostty reads the file again on each appearance change, so it goes at process exit.
    nonisolated private static let processConfig = FileManager.default.temporaryDirectory.appendingPathComponent("kido-visual-\(getpid()).yaml")
    var runtime: GhosttyRuntime!
    private(set) var session: SessionView!
    // The harness's own client of the private server, as an owner's: it shows the session's windows.
    var client: KoClient?
    var editor: LayoutEditor?
    var model = SessionModel()
    private(set) var koModel: KoModel?
    // The sizes that the harness sent the server.
    var sentSizes: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: try koServerDir())
        PaneView.renderOffscreen = true
    }

    override func tearDown() async throws {
        client?.close()
        client = nil
        editor = nil
        session?.close()
        window?.contentView = nil
        window?.close()
        session = nil
        runtime?.onConfigChange = {}
        runtime?.onConfigReload = { _ in }
        runtime = nil
        PaneView.renderOffscreen = false
        NSApp.appearance = nil
        try await super.tearDown()
    }

    // The pane that the harness starts with runs `cat` in raw mode, so what a test writes to it comes back as output.
    func rawPane(dark: Bool = false) async throws -> PaneView {
        try await start(dark: dark)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        window.makeFirstResponder(pane)
        return pane
    }

    // A new snapshot of the pane from the server.
    func restore(_ pane: PaneView) async throws {
        try XCTUnwrap(pane.koView).resync()
        try await wait("the pane restored") { !pane.restoring }
        try await settle()
        window.makeFirstResponder(pane)
    }

    // Writes `text` to the raw pane, which echoes it, and waits until the surface parsed all of it; a
    // frozen pane drops it once the server parsed it.
    // The fence title is cleared again, so that no tab shows it.
    func emit(_ pane: PaneView, _ text: String, until marker: String? = nil) async throws {
        if !rawPanes.contains(pane.pane) {
            try await wait("the pane's tty is raw", within: 5) { self.koModel?.panes.first { $0.id == pane.pane }?.title.isEmpty == false }
            rawPanes.insert(pane.pane)
        }
        let title = "raw-output-" + UUID().uuidString
        let data = Data((text + "\u{1b}]2;" + title + "\u{7}\u{1b}]2;\u{7}").utf8)
        let dropped = pane.visualDropped.withLock { $0 }
        try XCTUnwrap(pane.koView).text(data)
        let cleared = { self.koModel?.panes.first { $0.id == pane.pane }?.title.isEmpty == true }
        if pane.frozen {
            try await wait("the frozen pane dropped the echo", within: 5) { pane.visualDropped.withLock { $0 } >= dropped + data.count && cleared() }
            return
        }
        try await wait("the surface parsed the output", within: 5) { pane.visualTitles.contains(title) && cleared() }
        if let marker { XCTAssertTrue(surfaceText(pane).contains(marker)) }
    }
    private var rawPanes: Set<PaneID> = []

    // A layout edit through the core, as a gesture sends it.
    @discardableResult func edit(_ edit: KoSchema.Edit) async throws -> KoSchema.Edited {
        let client = try XCTUnwrap(client)
        return try await Task.detached { try client.edit(edit) }.value
    }

    // A pane that runs `cat` in raw mode, so what a test writes to it comes back as output.
    let rawCat = KoSchema.CreatePane(command: .shell(.init(command: rawScript)))

    // A new raw `cat` pane beside `pane`: `.h` to its right, `.v` below it.
    func split(_ pane: Int, _ axis: KoSchema.Axis) async throws {
        let split = KoSchema.Edit.split(KoSchema.EditSplit(axis: axis, new: rawCat, pane: PaneID(number: UInt32(pane))))
        let edited = try await edit(split)
        let created = try XCTUnwrap(selectedPane(by: split, edited))
        try client?.select(KO_SELECT_PANE, created)
    }

    // Zooms the pane's window to it, or ends the zoom.
    func toggleZoom(_ pane: Int) async throws {
        let zoom = KoSchema.Edit.toggleZoom(KoSchema.EditToggleZoom(pane: PaneID(number: UInt32(pane))))
        let edited = try await edit(zoom)
        if let selected = selectedPane(by: zoom, edited) { try client?.select(KO_SELECT_PANE, selected) }
    }

    var terminal: WindowView? { session?.windows.values.first { !$0.isHidden } }

    func loadRuntime(configFile: String? = nil) throws {
        if let configFile {
            let board = NSPasteboard(name: .init("config-test-\(UUID().uuidString)"))
            addTeardownBlock { @MainActor in board.releaseGlobally() }
            runtime = try XCTUnwrap(GhosttyRuntime(configFile: configFile, pasteboard: board))
            return
        }
        if Self.processRuntime == nil {
            let config = Self.processConfig
            try "app: {font: {size: 13}}\n".write(to: config, atomically: true, encoding: .utf8)
            atexit { try? FileManager.default.removeItem(at: AppWindowCase.processConfig) }
            Self.processRuntime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))))
            Self.processRuntime?.loadTestBindings("keybind = super+e=text:X\nkeybind = super+shift+c=text:Y\n")
        }
        runtime = try XCTUnwrap(Self.processRuntime)
    }

    func sidebarOwner() throws -> WindowOwner {
        try loadRuntime()
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        addTeardownBlock { @MainActor in owner.close() }
        return owner
    }

    // A private server whose session "visual" has the window "zsh" of one pane that runs `pane`, or the
    // given windows, shown in a 700-point session view.
    func start(width: CGFloat = 700, height: CGFloat = 560, dark: Bool = false, configFile: String? = nil, pane: String = rawScript, windows: String? = nil) async throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        try loadRuntime(configFile: configFile)
        window = OwnerWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .displayP3
        session = SessionView(runtime: runtime)
        runtime.onConfigReload = { [weak self] font in self?.session.reloadConfig(font: font) }
        runtime.onConfigChange = { [weak self] in self?.session?.updateWebview() }
        session.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = session
        _ = try await KoServer.launch(dir: directory.path)
        try await koPut(directory.path, #"[{"name":"visual","windows":\#(windows ?? #"[{"name":"zsh","tree":\#(koPane(pane))}]"#)}]"#)
        let client = try KoClient.connect(socket: directory.path + "/socket", hello: KoHello(name: "visual", viewport: KoSize(cols: 80, rows: 24, cell: nil), webview: runtime.values.webview.enabled)) { [weak self] event in
            self?.handle(event)
        }
        self.client = client
        let editor = LayoutEditor { try client.edit($0) }
        editor.onFailure = { _, text in XCTFail("edit failed: \(text)") }
        editor.onSettled = { [weak self] in self?.session?.editsSettled() }
        self.editor = editor
        session.client = client
        session.webview = { [weak self] in self?.koModel?.pane($0)?.webview }
        session.edit = { edit, key in editor.submit(edit, key: key) }
        session.editing = { editor.holding }
        session.selectPane = { pane in try? client.select(KO_SELECT_PANE, pane) }
        session.sizeClient = { [weak self] viewport, windows in
            self?.sentSizes.append("\(viewport.cols)x\(viewport.rows)")
            do { try client.size(viewport: viewport, windows: windows); return true }
            catch { return false }
        }
        session.paneCommand = { [weak self] command, pane in
            guard let self, let window = koModel?.layout.layout.locate(pane)?.window,
                  let action = command.action(pane, in: window, new: KoSchema.CreatePane(), cell: session.cell ?? .zero) else { return }
            switch action {
            case .edit(let edit):
                editor.submit(edit) { result in
                    guard case .success(let edited) = result, let pane = selectedPane(by: edit, edited) else { return }
                    try? client.select(KO_SELECT_PANE, pane)
                }
            case .select(let target): try? client.select(KO_SELECT_PANE, target)
            }
        }
        try await wait("initial layout") { self.terminal?.displayedPanes.isEmpty == false }
        try await settle()
        if dark { try await darken() }
    }

    private func handle(_ event: KoEvent) {
        switch event {
        case .layout(let revision):
            receive()
            editor?.layoutChanged(revision: Int(revision))
        case .welcome, .model, .selected: receive()
        case .failed, .mismatch, .viewRestored, .viewClosed, .viewLink: break
        case .clipboardWrite(_, let contents): (window.delegate as? WindowOwner)?.writeClipboard(contents)
        case .clipboardRead(let read): session.pane(read.pane)?.receiveClipboardRead(read)
        }
    }

    private func receive() {
        guard let client, let next = try? client.model() else { return }
        koModel = next
        if next.selection.session == nil, let first = next.layout.layout.sessions.first { try? client.select(KO_SELECT_SESSION, first.id) }
        model = SessionModel(next)
        let windows = next.layout.layout.windows
        session.update(model.session.flatMap { next.layout.layout.session($0) }?.windows ?? [],
                       alive: Set(windows.map(\.id)), selected: next.selection.pane, marks: next.runtimeMarks)
        session.show(model.window)
        let snapshot = Snapshot(model: next)
        (window.contentViewController as? Sidebar)?.tabs.entries = model.navigation(snapshot, panes: PaneProjection(snapshot), activePanes: session.windows.compactMapValues(\.active)).tabs
    }

    func hover(_ pane: PaneView, _ inside: Bool) async throws {
        let chrome = try XCTUnwrap(terminal?.visualChromes.first { $0.pane == pane.pane })
        let ended = chrome.subviews.compactMap { $0 as? PaneToolbar }.first?.visualAnimationsEnded ?? 0
        let point = inside ? NSPoint(x: chrome.toolbarFrame.midX, y: chrome.toolbarFrame.maxY + 4) : NSPoint(x: 20, y: chrome.bounds.maxY - 20)
        chrome.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: chrome.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        try await wait("toolbar fade settled", within: 2) {
            guard let toolbar = chrome.subviews.compactMap({ $0 as? PaneToolbar }).first else { return true }
            return toolbar.visualAnimationsEnded > ended && (inside ? toolbar.alphaValue == 1 : toolbar.alphaValue == 0)
        }
    }

    func darken(_ appearance: NSAppearance.Name = .darkAqua) async throws {
        let changed = expectation(description: "appearance config changed")
        runtime.onConfigChange = { [weak self] in self?.session.updateColorScheme(); self?.session.updateBackground(); changed.fulfill() }
        window.appearance = NSAppearance(named: appearance)
        NSApp.appearance = NSAppearance(named: appearance)
        await fulfillment(of: [changed], timeout: 20)
        try await settle()
    }

    func settle() async throws {
        try await wait("authoritative restore and presented frame") {
            guard let terminal = self.terminal else { return false }
            return terminal.visualGeometryReady && !terminal.displayedPanes.isEmpty && terminal.displayedPanes.filter { !$0.isHidden }.allSatisfy(\.visualReady)
        }
    }

    // Fills every shown pane with coloured rows, or `content`, through its raw cat.
    func paint(lines: Int? = nil, alternate: Bool = false, content: String? = nil) async throws {
        for pane in try XCTUnwrap(terminal).displayedPanes.filter({ !$0.isHidden }) {
            let grid = ghostty_surface_size(pane.surface)
            let count = lines ?? Int(grid.rows)
            var text = alternate ? "\u{1b}[?1049h" : ""
            text += "\u{1b}[2J\u{1b}[H"
            for i in 0..<count {
                let color = i == count - 1 ? 32 : i == 0 ? 31 : [34, 35, 36, 33][i % 4]
                text += "\u{1b}[\(color)m" + String(repeating: "█", count: Int(grid.columns)) + "\u{1b}[0m"
                if i != count - 1 { text += "\r\n" }
            }
            if let content { text = "\u{1b}[2J\u{1b}[H" + content }
            try await emit(pane, text)
        }
        try await settle()
    }

    // Waits until every shown pane presented a frame of what it holds.
    func presented() async throws {
        try await settle()
        let terminal = try XCTUnwrap(terminal)
        window.contentView?.layoutSubtreeIfNeeded()
        for pane in terminal.displayedPanes.filter({ !$0.isHidden }) {
            await presentedFrame(pane)
        }
    }

    var paintRetry: ((String) async throws -> Void)?

    private func webviewPage(_ pane: PaneView) async throws -> NSImage {
        let webview = try XCTUnwrap(pane.webviewView)
        let deadline = Date().addingTimeInterval(5)
        while true {
            window.contentView?.layoutSubtreeIfNeeded()
            webview.layoutSubtreeIfNeeded()
            let shown = try await webviewJS(webview.browser, "Array.from(document.images).filter(i=>i.complete&&i.naturalWidth>0).map(i=>{let r=i.getBoundingClientRect(),box={l:r.left,t:r.top,r:r.right,b:r.bottom};for(let n=i.parentElement;n;n=n.parentElement){if(getComputedStyle(n).overflow==='visible')continue;const c=n.getBoundingClientRect();box={l:Math.max(box.l,c.left),t:Math.max(box.t,c.top),r:Math.min(box.r,c.right),b:Math.min(box.b,c.bottom)}}box={l:Math.max(box.l,0),t:Math.max(box.t,0),r:Math.min(box.r,innerWidth),b:Math.min(box.b,innerHeight)};const w=box.r-box.l,h=box.b-box.t;return{src:i.src,x:box.l+w/4,y:box.t+h/4,w:w/2,h:h/2,ok:w>=16&&h>=16&&document.elementFromPoint(box.l+w/2,box.t+h/2)===i}}).filter(r=>r.ok)")
            let rects = try JSONDecoder().decode([ImageRect].self, from: Data(shown.utf8))
            let done = expectation(description: "WebKit snapshot")
            var image: NSImage?
            webview.browser.takeSnapshot(with: nil) { result, error in
                XCTAssertNil(error)
                image = result
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 10)
            let page = try XCTUnwrap(image)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(page.tiffRepresentation)))
            let scale = CGFloat(bitmap.pixelsWide) / webview.browser.bounds.width
            guard let empty = rects.first(where: { rect in
                let colors = stride(from: Int(rect.y * scale), to: Int((rect.y + rect.h) * scale), by: 3).flatMap { y in
                    stride(from: Int(rect.x * scale), to: Int((rect.x + rect.w) * scale), by: 3).map { bitmap.colorAt(x: $0, y: y) }
                }
                return colors.allSatisfy { $0 == colors.first }
            }) else { return page }
            _ = try XCTUnwrap(Date() < deadline ? true : nil, "Image not painted in the snapshot: \(empty.src)")
            try await paintRetry?(empty.src)
        }
    }

    private struct ImageRect: Decodable { let src: String; let x, y, w, h: CGFloat }

    func webviewPageSnapshot(_ pane: PaneView, _ name: String, file: StaticString = #filePath, testName: String = #function) async throws {
        let image = try await webviewPage(pane)
        checkSnapshot { verifySnapshot(of: image, as: .pixels, named: name, record: $0, file: file, testName: testName) }
    }

    @discardableResult
    func webviewSnapshot(_ pane: PaneView, _ name: String, file: StaticString = #filePath, testName: String = #function, afterCapture: (() -> Void)? = nil) async throws -> (chrome: NSBitmapImageRep, page: NSBitmapImageRep) {
        let webview = try XCTUnwrap(pane.webviewView)
        let image = try await webviewPage(pane)
        afterCapture?()
        let overlay = NSImageView(frame: webview.browser.frame)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        webview.addSubview(overlay)
        defer { overlay.removeFromSuperview() }
        try await snapshot(name, file: file, testName: testName)
        let chrome = try XCTUnwrap(webview.superview)
        let terminal = try XCTUnwrap(terminal)
        let bitmap = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
        terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / terminal.bounds.width
        let area = terminal.convert(chrome.bounds, from: chrome)
        let cropped = try XCTUnwrap(bitmap.cgImage?.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)))
        let page = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.converting(to: .sRGB, renderingIntent: .default))
        return (try XCTUnwrap(NSBitmapImageRep(cgImage: cropped).converting(to: .sRGB, renderingIntent: .default)), page)
    }

    func snapshot(_ name: String, file: StaticString = #filePath, testName: String = #function, view: NSView? = nil) async throws {
        try await presented()
        let terminal = try XCTUnwrap(terminal)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertFalse(NSApp.isActive)
        CATransaction.flush()
        terminal.displayedPanes.forEach { $0.scroller.isHidden = true }
        CATransaction.flush()
        XCTAssertTrue(terminal.hostWindows.allSatisfy { !$0.isVisible }, "the float windows stay off screen")
        if let view { checkSnapshot { verifyWindowView(view, named: name, record: $0, file: file, testName: testName) } }
        else if terminal.visualFloatHosts.isEmpty && terminal.visualGhost == nil {
            checkSnapshot { verifySnapshot(of: terminal, as: .pixels, named: name, record: $0, file: file, testName: testName) }
        } else { checkSnapshot { verifySnapshot(of: terminal, as: .family, named: name, record: $0, file: file, testName: testName) } }
        checkSnapshot { verifySnapshot(of: terminal.visualLayout, as: .lines, named: name, record: $0, file: file, testName: testName) }
    }
}
