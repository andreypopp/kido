import AppKit
import WebKit
import GhosttyKit
import XCTest
import SnapshotTesting
import QuickLookUI
import KoModel
import KoClient
import SidebarFeed
@testable import Kido

@MainActor private final class PreviewTestWindow: NSWindow {
    var key = false
    var responder: NSResponder?
    override var firstResponder: NSResponder? { responder ?? super.firstResponder }
    override var isKeyWindow: Bool { key }
}

@MainActor private final class WebviewMenuProbe: NSObject {
    var keys: [String] = []
    @objc func invoke(_ sender: NSMenuItem) { keys.append(sender.keyEquivalent) }
}

@MainActor final class WebviewPaneTests: AppWindowCase {
    private func webviewEqual(_ web: WKWebView, _ script: String, _ expected: String) async throws {
        let actual = try await webviewJS(web, script)
        XCTAssertEqual(actual, expected, script)
    }

    private func webviewStart(gates: Bool = false, toy supplied: WebviewToy? = nil) async throws -> PaneView {
        let toy = try supplied ?? WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        try await toy.start()
        addTeardownBlock { toy.stop() }
        let config = directory.appendingPathComponent("webview.yaml")
        try "app: {webview: {keep_hidden: 4}}\n".write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path, pane: "'\(tools.ko)' webview enter --path '\(gates ? "/?gates" : "/")'; exec '\(tools.ko)' webview serve --socket '\(toy.path)'")
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("webview page loaded") { pane.webviewView?.browser.isLoading == false && pane.webviewView?.browser.url != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        XCTAssertEqual(web.configuration.writingToolsBehavior, .none)
        let result = try await webviewJS(web, "Promise.all([window.echo,window.sandbox])")
        XCTAssertTrue(result.contains("hello"), result)
        try await webviewEqual(web, "window.ready", "true")
        return pane
    }

    func testWebviewLinks() async throws {
        _ = try await webviewStart()
        var opened: [URL] = []
        let owner = WindowOwner(host: .local, runtime: runtime, start: false, openBrowser: { opened.append($0) })
        owner.testServerDir = directory.path; owner.start()
        defer { owner.close() }
        try await wait("link owner page") { owner.testSession?.activePane?.webviewView?.browser.isLoading == false && owner.testSession?.activePane?.webviewView?.browser.url != nil }
        let pane = try XCTUnwrap(owner.testSession?.activePane), view = try XCTUnwrap(pane.webviewView), web = view.browser
        let click: (String, String, Bool) async throws -> Void = { href, target, real in
            let rect = try await self.webviewJS(web, "(()=>{document.body.innerHTML='<a style=\"display:block;padding:20px\" href=\"\(href)\" target=\"\(target)\">link</a>';const r=document.querySelector('a').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
            let coordinates = try JSONDecoder().decode([Double].self, from: Data(rect.utf8))
            if real {
                let point = web.convert(NSPoint(x: coordinates[0], y: web.isFlipped ? coordinates[1] : web.bounds.height - coordinates[1]), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
                }
            } else {
                _ = try await self.webviewJS(web, "(()=>{document.querySelector('a').click();return true})()")
            }
        }
        var rejected = view.visualRejectedNavigations
        try await click("https://example.com/a", "", true)
        try await wait("same-frame link policy") { view.visualRejectedNavigations > rejected }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a"])
        rejected = view.visualRejectedNavigations
        try await click("https://example.com/b", "_blank", true)
        try await wait("new-window link policy") { view.visualRejectedNavigations > rejected }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a", "https://example.com/b"])
        rejected = view.visualRejectedNavigations
        try await click("https://example.com/script", "", false)
        try await wait("script link policy") { view.visualRejectedNavigations > rejected }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a", "https://example.com/b"])
        rejected = view.visualRejectedNavigations
        try await click("mailto:test@example.com", "", true)
        try await wait("mail link policy") { view.visualRejectedNavigations > rejected }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a", "https://example.com/b"])
        try await click("javascript:void(0)", "", true)
        _ = try await webviewJS(web, "true")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a", "https://example.com/b"])
    }

    func testWebviewFocusPane() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        _ = try await webviewStart(toy: toy)
        let other = directory.appendingPathComponent("other.json")
        try Data(#"{"command":{"type":"shell","command":"exec cat"}}"#.utf8).write(to: other)
        let target = try JSONDecoder().decode(Snapshot.Position.self, from: Data(try await ko(["api", "-X", "POST", "--input", other.path, "/panes"], dir: directory.path).utf8))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path; owner.start()
        defer { owner.close() }
        try await wait("focus owner page") { owner.testSession?.activePane?.webviewView?.browser.isLoading == false && owner.projection.placements[target.pane] != nil }
        let pane = try XCTUnwrap(owner.testSession?.activePane), view = try XCTUnwrap(pane.webviewView), web = view.browser
        let key = PreviewTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        key.isReleasedWhenClosed = false; key.delegate = owner; key.contentView = view; key.responder = web
        defer { key.key = false; key.contentView = nil; key.close() }
        var focused: [Snapshot.Position] = []
        view.visualFocus = { focused.append($0) }
        try await webviewEqual(web, "typeof window.ko.focus", "\"function\"")
        _ = try await webviewJS(web, "(()=>{ko.focus('\(target.pane)');return true})()")
        key.key = true
        _ = try await webviewJS(web, """
        (()=>{
          webkit.messageHandlers.koFocus.postMessage({document:'wrong',pane:'\(target.pane)'});
          ko.focus('pane_9999');ko.focus('not a pane');
          ko.focus('\(target.pane)');
          return true;
        })()
        """)
        try await wait("one focus") { !focused.isEmpty }
        _ = try await webviewJS(web, "true")
        XCTAssertEqual(focused, [target])
        key.responder = nil
        _ = try await webviewJS(web, "(()=>{ko.focus('\(target.pane)');return true})()")
        _ = try await webviewJS(web, "true")
        key.responder = web
        _ = try await webviewJS(web, "(()=>{ko.focus('\(target.pane)');return true})()")
        try await wait("focus after the unfocused page") { !focused.isEmpty && focused.count >= 2 }
        _ = try await webviewJS(web, "true")
        XCTAssertEqual(focused, [target, target], "a page that is not the first responder asks for nothing")
        view.visualFocus = nil
        _ = try await webviewJS(web, "(()=>{ko.focus('\(target.pane)');return true})()")
        try await wait("focus selects the pane") { owner.snapshot?.client.pane == target.pane }
    }

    func testWebviewNativePreview() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        _ = try await webviewStart(toy: toy)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path; owner.start()
        defer { owner.close(); ImagePreview.shared.close() }
        try await wait("preview owner page") { owner.testSession?.activePane?.webviewView?.browser.isLoading == false && owner.testSession?.activePane?.webviewView?.browser.url != nil }
        let pane = try XCTUnwrap(owner.testSession?.activePane), view = try XCTUnwrap(pane.webviewView), web = view.browser
        let key = PreviewTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        key.isReleasedWhenClosed = false; key.delegate = owner; key.contentView = view; key.responder = web
        defer { key.key = false; key.contentView = nil; key.close() }
        view.visualPreviewLimit = 8
        var prepared = 0
        view.visualPreview = { source, rect in Task { if await ImagePreview.shared.prepare(source, rect: rect) { prepared += 1 } } }
        try await webviewEqual(web, "typeof window.ko.preview", "\"function\"")
        _ = try await webviewJS(web, "(()=>{window.ko.preview('/images/nonkey',{x:0,y:0,width:10,height:10});return true})()")
        key.key = true
        XCTAssertTrue(key.isKeyWindow)
        XCTAssertTrue(view.window === key)
        XCTAssertTrue(key.firstResponder === web, String(describing: key.firstResponder))
        _ = try await webviewJS(web, """
        (()=>{
          const r={x:1,y:2,width:30,height:40};
          webkit.messageHandlers.koPreview.postMessage({document:'wrong',url:location.origin+'/images/generation',rect:r});
          ko.preview('ko://other/images/foreign',r);ko.preview('/images/rect',{...r,width:-1});ko.preview('/images/bool',{...r,x:true});ko.preview('/images/infinite',{...r,x:Infinity});
          ko.preview('/files/held',r);ko.preview('/images/second',r);
          return true;
        })()
        """)
        try await wait("one held preview") { toy.previews.contains("/files/held") }
        toy.releasePreviews()
        try await wait("preview file prepared") { prepared == 1 }
        XCTAssertEqual(toy.previews, ["/files/held"])
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        let item = try XCTUnwrap(ImagePreview.shared.previewPanel(panel, previewItemAt: 0)), url = try XCTUnwrap(item.previewItemURL)
        XCTAssertEqual(url.lastPathComponent, "source.swift")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().path, ImagePreview.directory.path)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try Data(contentsOf: url), Data("preview".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        ImagePreview.shared.close(); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for path in ["/images/big", "/images/missing"] {
            let notices = owner.notices.testTransients.entries.count
            _ = try await webviewJS(web, "(()=>{ko.preview('\(path)',{x:0,y:0,width:1,height:1});return true})()")
            try await wait("preview failure notice") { owner.notices.testTransients.entries.count > notices }
            XCTAssertEqual(prepared, 1); XCTAssertFalse(ImagePreview.shared.ready)
            for entry in owner.notices.testTransients.entries { XCTAssertEqual(entry.title, "Kido could not preview the file"); if path.hasSuffix("big") { XCTAssertEqual(entry.detail, "The file is over 64 MB") }; owner.notices.dismiss(entry.id) }
        }
        _ = try await webviewJS(web, "(()=>{ko.preview('/attachments/held',{x:0,y:0,width:1,height:1});return true})()")
        try await wait("preview waiting at navigation") { toy.previews.contains("/attachments/held") }
        let documents = view.visualDocuments
        web.reload()
        try await wait("new preview document") { view.visualDocuments > documents }
        toy.releasePreviews()
        _ = try await webviewJS(web, "(()=>{ko.preview('/images/after',{x:0,y:0,width:1,height:1});return true})()")
        try await wait("new document preview") { prepared == 2 }
        XCTAssertEqual(prepared, 2)
        _ = web.load(URLRequest(url: try XCTUnwrap(URL(string: "ko://\(pane.pane)/held"))))
        try await wait("provisional preview navigation") { toy.heldDocumentCount == 1 }
        _ = try await webviewJS(web, "(()=>{ko.preview('/images/provisional',{x:0,y:0,width:1,height:1});return true})()")
        let heldDocuments = view.visualDocuments
        toy.releaseDocuments()
        try await wait("held navigation committed") { view.visualDocuments > heldDocuments }
        _ = try await webviewJS(web, "(()=>{ko.preview('/images/committed',{x:0,y:0,width:1,height:1});return true})()")
        try await wait("committed document preview") { prepared == 3 }
        XCTAssertFalse(toy.previews.contains("/images/provisional"))
    }

    func testWebviewNativeFileDrop() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        _ = try await webviewStart(toy: toy)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path
        addTeardownBlock { @MainActor in owner.close() }
        owner.start()
        try await wait("native owner page loaded") { owner.testSession?.activePane?.webviewView?.browser.isLoading == false && owner.testSession?.activePane?.webviewView?.browser.url != nil }
        let pane = try XCTUnwrap(owner.testSession?.activePane)
        let web = try XCTUnwrap(pane.webviewView?.browser)
        try await webviewEqual(web, "window.ko.local===true", "true")
        _ = try await webviewJS(web, "(()=>{window.drops=[];addEventListener('ko-drop',event=>drops.push(event.detail));return true})()")
        try await webviewEqual(web, "fetch('/attachments',{method:'POST',headers:{'Content-Type':'application/json','kIdO-nAtIvE-dRoP':'1'},body:JSON.stringify({path:'/etc/passwd'})}).then(r=>r.status)", "403")
        XCTAssertFalse(toy.attachmentRequests.last?.lowercased().contains("kido-native-drop") ?? true, toy.attachmentRequests.joined(separator: "\n"))
        let file = directory.appendingPathComponent("original.txt"), folder = directory.appendingPathComponent("folder", isDirectory: true)
        try "original".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let board = NSPasteboard.withUniqueName()
        board.writeObjects([file as NSURL, folder as NSURL])
        let drag = SyntheticDrag(board)
        owner.window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(owner.window.contentView)
        let point = content.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), from: pane)
        var hit = content.hitTest(point)
        while let view = hit, !view.registeredDraggedTypes.contains(where: { board.types?.contains($0) == true }) { hit = view.superview }
        let destination = try XCTUnwrap(hit)
        XCTAssertFalse(destination === pane, "The browser, not its covered parent, receives the drag")
        XCTAssertEqual(destination.draggingEntered(drag), .copy)
        XCTAssertTrue(destination.performDragOperation(drag))
        try await wait("native attachment request: \(toy.attachmentRequests)") { toy.attachmentRequests.count == 2 }
        try await webviewUntil(web, "drops.length===1")
        let detail = try await webviewJS(web, "drops[0]")
        let expected = String(data: try JSONSerialization.data(withJSONObject: ["files": [["id": "native", "path": file.path, "name": "original.txt", "origin": "path", "kind": "file", "size": 8]], "refused": true], options: [.sortedKeys]), encoding: .utf8)!
        let actual = try XCTUnwrap(detail.data(using: .utf8))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: actual) as? NSDictionary, try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        board.clearContents(); board.writeObjects([link as NSURL])
        XCTAssertTrue(destination.performDragOperation(SyntheticDrag(board)))
        XCTAssertFalse(owner.notices.testTransients.entries.isEmpty)
        try await webviewEqual(web, "drops.length", "1")
        board.clearContents(); board.writeObjects([file as NSURL, link as NSURL])
        XCTAssertTrue(destination.prepareForDragOperation(SyntheticDrag(board)))
        XCTAssertTrue(destination.performDragOperation(SyntheticDrag(board)))
        try await wait("second native attachment request") { toy.attachmentRequests.count == 3 }
        try await webviewUntil(web, "drops.length===2")
        try await webviewEqual(web, "[drops[1].files.length,drops[1].refused]", "[1,false]")
        pane.runtimeMark = .unavailable(RuntimeKey(name: "box", source: .config), routed: true)
        try await webviewEqual(web, "window.ko.local", "false")
        XCTAssertEqual(pane.draggingEntered(drag), [])
        XCTAssertFalse(pane.performDragOperation(drag))
        pane.runtimeMark = nil
        try await webviewEqual(web, "window.ko.local", "true")
        board.clearContents(); board.setString("text", forType: .string)
        XCTAssertEqual(pane.draggingEntered(SyntheticDrag(board)), [])
    }

    func testWebviewLeaveRestoresNativeInput() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        try await toy.start()
        addTeardownBlock { toy.stop() }
        let ttyFile = directory.appendingPathComponent("page-tty")
        try await start(pane: "tty > \(SSH.quote(ttyFile.path)); tail -f /dev/null | '\(tools.ko)' webview serve --socket '\(toy.path)' & " + rawScript)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        let fill = String(repeating: String(repeating: "M", count: 160) + "\r\n", count: 60)
        try await emit(pane, "\u{1b}[41m" + fill + "\u{1b}]7502;a=enter\u{7}")
        try await wait("webview loaded") { pane.webviewView?.browser.isLoading == false && pane.webviewView?.browser.url != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        XCTAssertEqual(web.configuration.writingToolsBehavior, .none)
        try await webviewUntil(web, "document.querySelector('input') !== null")
        window.makeFirstResponder(web)
        _ = try await webviewJS(web, "(()=>{const editor=document.createElement('textarea');document.body.append(editor);editor.focus();return true})()")
        let selector = NSSelectorFromString("allowsWritingToolsAffordance")
        // Call WebKit's getter to confirm the same editor state triggers https://bugs.webkit.org/show_bug.cgi?id=327446
        let inherited = unsafeBitCast(try XCTUnwrap(class_getMethodImplementation(WKWebView.self, selector)),
                                     to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        try await wait("WebKit allows the writing tools affordance for the focused textarea", within: 5) { inherited(web, selector) }
        XCTAssertEqual(web.value(forKey: "allowsWritingToolsAffordance") as? Bool, false)
        var written = Data()
        pane.visualInput = { written.append($0) }
        _ = try await webviewJS(web, "(()=>{document.querySelector('textarea').blur();document.body.tabIndex=0;document.body.focus();return true})()")
        for (characters, code, modifiers) in [("\u{3}", UInt16(8), NSEvent.ModifierFlags.control), ("x", UInt16(7), [])] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
        _ = try await webviewJS(web, "true")
        XCTAssertEqual(written, Data(), "Keys that the page does not handle must not reach the pty")
        pane.visualInput = nil
        let oldSize = ghostty_surface_size(pane.surface)
        window.setContentSize(NSSize(width: 810, height: 610))
        try await wait("hidden terminal resized") { ghostty_surface_size(pane.surface).columns != oldSize.columns && ghostty_surface_size(pane.surface).rows != oldSize.rows }
        let tty = try String(contentsOf: ttyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let ttySize = try await Child.run("/bin/stty", ["-f", tty, "size"])
        let grid = ghostty_surface_size(pane.surface)
        XCTAssertEqual(ttySize.status, 0, ttySize.err)
        XCTAssertEqual(ttySize.out.trimmingCharacters(in: .whitespacesAndNewlines), "\(grid.rows) \(grid.columns)")
        try await settle()
        try await emit(pane, "LIVE-WHILE-PAGE")
        XCTAssertTrue(surfaceText(pane).contains("LIVE-WHILE-PAGE"))
        let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let paper = try XCTUnwrap(pane.paperColor.usingColorSpace(.sRGB))
        for (x, y) in [(0, bitmap.pixelsHigh / 2), (bitmap.pixelsWide - 1, bitmap.pixelsHigh / 2), (bitmap.pixelsWide / 2, 0), (bitmap.pixelsWide / 2, bitmap.pixelsHigh - 1)] {
            let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertEqual(pixel.redComponent, paper.redComponent, accuracy: 0.02)
            XCTAssertEqual(pixel.greenComponent, paper.greenComponent, accuracy: 0.02)
            XCTAssertEqual(pixel.blueComponent, paper.blueComponent, accuracy: 0.02)
        }
        try await emit(pane, "\u{1b}]7502;a=leave\u{7}")
        try await wait("webview left") { pane.webviewView == nil }
        XCTAssertTrue(window.firstResponder === pane, "Leaving a page restores the terminal first responder")
        try await presented()
        let visible = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
        pane.cacheDisplay(in: pane.bounds, to: visible)
        let restored = try XCTUnwrap(visible.colorAt(x: visible.pixelsWide / 2, y: visible.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(restored.redComponent - restored.greenComponent, 0.2, "Leaving the page shows the live terminal")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        window.sendEvent(event)
        try await koUntil(directory.path, "/panes/\(pane.pane)/screen", contains: "z")
    }

    func testWebviewChromeEdges() async throws {
        let pane = try await webviewStart()
        let web = try XCTUnwrap(pane.webviewView?.browser)
        _ = try await webviewJS(web, "(()=>{document.body.innerHTML='';document.body.style.background='#ffffff';return true})()")
        try await split(1, .h)
        try await split(1, .v)
        try await wait("both split axes") { self.terminal?.displayedPanes.count == 3 }
        try client?.select(KO_SELECT_PANE, pane.pane)
        try await wait("webview selected") { self.terminal?.active == pane.pane }
        window.makeFirstResponder(pane.inputResponder)
        for dark in [false, true] {
            if dark { try await darken() }
            terminal?.updateFocusTreatment()
            let image = try await webviewSnapshot(pane, dark ? "dark" : "light").chrome
            for (x, y) in [(image.pixelsWide / 2, 0), (image.pixelsWide / 2, image.pixelsHigh - 1), (0, image.pixelsHigh / 2), (image.pixelsWide - 1, image.pixelsHigh / 2)] {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y))
                XCTAssertGreaterThan(color.blueComponent - color.redComponent, 0.1, "webview accent edge at \(x),\(y)")
            }
            let chrome = try XCTUnwrap(pane.webviewView?.superview as? PaneChrome)
            chrome.runtimeMark = .unavailable(.init(name: "buildbox", source: .config), routed: true)
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
            let striped = try await webviewSnapshot(pane, dark ? "stripe-dark" : "stripe-light").chrome
            let mark = try XCTUnwrap(chrome.runtimeMark)
            let stripe = try XCTUnwrap(Chrome.runtimeStripe(Chrome.runtimeTint(mark, dark: dark), focused: true).usingColorSpace(.sRGB))
            let pixel = try XCTUnwrap(striped.colorAt(x: striped.pixelsWide / 2, y: 1))
            for (actual, expected) in zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent], [stripe.redComponent, stripe.greenComponent, stripe.blueComponent]) {
                XCTAssertEqual(actual, expected, accuracy: 0.02, "runtime stripe stays outside the page")
            }
            chrome.runtimeMark = nil
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
    }

    func testWebviewFocusPaper() async throws {
        let pane = try await webviewStart()
        let view = try XCTUnwrap(pane.webviewView)
        let web = view.browser
        _ = try await webviewJS(web, "(()=>{document.body.innerHTML='<div id=foreground style=\"position:fixed;left:20px;top:20px;width:40px;height:40px;background:var(--ko-fg)\"></div><div id=hard style=\"position:fixed;left:80px;top:20px;width:40px;height:40px;background:#123456\"></div>';return true})()")
        try await split(1, .h)
        try await wait("paper split") { self.terminal?.displayedPanes.count == 2 }
        try client?.select(KO_SELECT_PANE, pane.pane)
        try await wait("paper selected") { self.terminal?.active == pane.pane }
        window.contentView?.layoutSubtreeIfNeeded()
        for dark in [false, true] {
            if dark { try await darken() }
            window.makeFirstResponder(pane.inputResponder)
            terminal?.updateFocusTreatment()
            let before = try await webviewJS(web, "[ko.theme['--ko-fg'],ko.theme['--ko-cursor'],ko.theme['--ko-color-1'],getComputedStyle(document.querySelector('#hard')).backgroundColor]")
            let documents = view.visualDocuments
            let frame = view.frame
            for (name, focused) in [("focused", true), ("unfocused", false), ("refocused", true), ("not-key", false)] {
                window.makeFirstResponder(focused ? pane.inputResponder : window)
                session.sidebarFocused = { name == "unfocused" }
                if name == "not-key" { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window) }
                terminal?.updateFocusTreatment()
                XCTAssertEqual(view.frame, frame, "focus does not resize the page")
                let expected = try XCTUnwrap(pane.paperColor.usingColorSpace(.sRGB))
                let rgb = "rgb(\(Int(expected.redComponent * 255)),\(Int(expected.greenComponent * 255)),\(Int(expected.blueComponent * 255)))"
                try await webviewEqual(web, "ko.theme['--ko-bg']", "\"\(rgb)\"")
                try await webviewUntil(web, "getComputedStyle(document.body).backgroundColor==='\(rgb.replacingOccurrences(of: ",", with: ", "))'")
                let underPage = try XCTUnwrap(web.underPageBackgroundColor?.usingColorSpace(.sRGB))
                for (actual, value) in zip([underPage.redComponent, underPage.greenComponent, underPage.blueComponent], [expected.redComponent, expected.greenComponent, expected.blueComponent]) {
                    XCTAssertEqual(actual, value, accuracy: 1.0 / 255, "WebKit backing follows pane paper")
                }
                let after = try await webviewJS(web, "[ko.theme['--ko-fg'],ko.theme['--ko-cursor'],ko.theme['--ko-color-1'],getComputedStyle(document.querySelector('#hard')).backgroundColor]")
                XCTAssertEqual(after, before)
                XCTAssertEqual(view.visualDocuments, documents)
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderBack(nil)
                defer { window.orderOut(nil) }
                _ = try await webviewJS(web, "new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))")
                let baseline = ["refocused": "focused", "not-key": "unfocused"][name] ?? name
                let captured = try await webviewSnapshot(pane, "\(baseline)-\(dark ? "dark" : "light")", afterCapture: { self.window.orderOut(nil) })
                let image = captured.chrome
                let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2))
                for (actual, value) in zip([color.redComponent, color.greenComponent, color.blueComponent], [expected.redComponent, expected.greenComponent, expected.blueComponent]) {
                    XCTAssertEqual(actual, value, accuracy: 0.01, "webview paper follows pane focus")
                }
                let chrome = try XCTUnwrap(view.superview)
                let scale = CGFloat(image.pixelsWide) / chrome.bounds.width
                let foreground = try XCTUnwrap(runtime.foreground.usingColorSpace(.sRGB))
                for (x, swatch, label) in [(40.0, foreground, "foreground swatch"),
                                           (100.0, NSColor(srgbRed: 18.0 / 255, green: 52.0 / 255, blue: 86.0 / 255, alpha: 1), "hard-coded swatch")] {
                    let pageScale = CGFloat(captured.page.pixelsWide) / web.bounds.width
                    let pixel = try XCTUnwrap(captured.page.colorAt(x: Int(x * pageScale), y: Int(40 * pageScale)))
                    for (actual, value) in zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent], [swatch.redComponent, swatch.greenComponent, swatch.blueComponent]) {
                        XCTAssertEqual(actual, value, accuracy: 0.01, label)
                    }
                }
                let strip = try XCTUnwrap(image.colorAt(x: Int((frame.minX - 2) * scale), y: Int(frame.midY * scale)))
                for (actual, value) in zip([strip.redComponent, strip.greenComponent, strip.blueComponent], [expected.redComponent, expected.greenComponent, expected.blueComponent]) {
                    XCTAssertEqual(actual, value, accuracy: 0.01, "surrounding strip matches page paper")
                }
            }
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
    }

    func testWebviewUnpaintedPaper() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        try await toy.start()
        addTeardownBlock { toy.stop() }
        let config = directory.appendingPathComponent("unpainted.yaml")
        try "app: {webview: {keep_hidden: 4}}\n".write(to: config, atomically: true, encoding: .utf8)
        try await start(configFile: config.path, pane: "'\(tools.ko)' webview enter --path /held; exec '\(tools.ko)' webview serve --socket '\(toy.path)'")
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("held first document") { toy.heldDocumentCount == 1 }
        try await split(1, .h)
        try await wait("unpainted split") { self.terminal?.displayedPanes.count == 2 }
        try client?.select(KO_SELECT_PANE, pane.pane)
        try await wait("unpainted pane selected") { self.terminal?.active == pane.pane }
        for keep in [4, 0] {
            if keep == 0 {
                runtime.onConfigChange = { [weak self] in self?.session.updateColorScheme(); self?.session.updateBackground(); self?.session.updateWebview() }
                try "app: {webview: {keep_hidden: 0}}\n".write(to: config, atomically: true, encoding: .utf8)
                try await wait("release hidden pages configured") { self.runtime.values.webview.keepHidden == 0 }
                try await darken(.aqua)
            }
            for dark in [false, true] {
                if dark { try await darken() }
                for shifted in [false, true] {
                    session.sidebarFocused = { shifted }
                    window.makeFirstResponder(shifted ? window : pane.inputResponder)
                    terminal?.updateFocusTreatment()
                    for exposure in ["first", "reshown"] {
                        if exposure == "reshown" {
                            let previous = try XCTUnwrap(pane.webviewView)
                            try await toggleZoom(2)
                            try await wait("page hidden") { pane.isHiddenOrHasHiddenAncestor }
                            session.updateWebview()
                            await mainQueueFence()
                            if keep == 0 { XCTAssertNil(pane.webviewView) }
                            else { XCTAssertTrue(pane.webviewView === previous) }
                            let requests = toy.heldDocumentCount
                            try await toggleZoom(2)
                            try await wait("page visible again") { !pane.isHiddenOrHasHiddenAncestor && pane.webviewView != nil }
                            if keep == 0 { try await wait("replacement document held") { toy.heldDocumentCount > requests } }
                            try client?.select(KO_SELECT_PANE, pane.pane)
                            try await wait("reshown page selected") { self.terminal?.active == pane.pane }
                            window.makeFirstResponder(shifted ? window : pane.inputResponder)
                            terminal?.updateFocusTreatment()
                        }
                        let view = try XCTUnwrap(pane.webviewView)
                        XCTAssertTrue(view.browser.isLoading)
                        XCTAssertEqual(view.browser.value(forKey: "drawsBackground") as? Bool, false)
                        window.contentView?.layoutSubtreeIfNeeded()
                        view.browser.needsDisplay = true
                        view.browser.displayIfNeeded()
                        let name = "keep-\(keep)-\(dark ? "dark" : "light")-\(shifted ? "shifted" : "focused")-\(exposure)"
                        let baseline = "\(dark ? "dark" : "light")-\(shifted ? "shifted" : "focused")"
                        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let image = try XCTUnwrap(bitmap.converting(to: .sRGB, renderingIntent: .default))
                        let captured = NSImage(size: view.bounds.size)
                        captured.addRepresentation(image)
                        checkSnapshot { verifySnapshot(of: captured, as: .image, named: baseline, record: $0) }
                        let pixel = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2))
                        let paper = try XCTUnwrap(pane.paperColor.usingColorSpace(.sRGB))
                        for (actual, expected) in zip([pixel.redComponent, pixel.greenComponent, pixel.blueComponent], [paper.redComponent, paper.greenComponent, paper.blueComponent]) {
                            XCTAssertEqual(actual, expected, accuracy: 1.0 / 255, "unpainted page shows pane paper: \(name)")
                        }
                    }
                }
            }
        }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        toy.releaseDocuments()
        try await wait("released page loaded") { !web.isLoading && web.url != nil }
        try await webviewEqual(web, "Promise.all([window.echo,window.sandbox]).then(()=>true)", "true")
    }

    func testRetainedWebviewPanesCountTowardSurfaceBudget() async throws {
        let terminals = Array(repeating: koPane(rawScript), count: 31).joined(separator: ",")
        let (owner, slot, _, child) = try await webviewChildSlot(keepHidden: 4,
            extraWindows: #",{"name":"budget","tree":{"split":"h","children":[\#(terminals)]}}"#)
        let session = try XCTUnwrap(owner.testSession)
        let other = try XCTUnwrap(session.windows.first { $0.value !== slot }?.key)
        try owner.testClient?.select(KO_SELECT_PANE, child)
        try await wait("displaced budget pane retained") {
            session.activePane?.pane == child && slot.retainedPanes.count == 2
        }
        XCTAssertEqual(slot.displayedPanes.count, 1)
        XCTAssertEqual(session.visualHotSurfaces, 2)
        try owner.testClient?.select(KO_SELECT_WINDOW, other)
        session.show(other)
        XCTAssertEqual(session.visualHotSurfaces, 33)
        try await wait("retained window evicted over budget") { slot.retainedPanes.isEmpty }
        XCTAssertFalse(slot.hot)
        XCTAssertEqual(session.visualHotSurfaces, 31)
    }

    func testWebviewChildSlotFrames() async throws {
        try await webviewChildSlotFrames(keepHidden: 4)
    }

    func testWebviewChildSlotReleasedFrames() async throws {
        try await webviewChildSlotFrames(keepHidden: 0)
    }

    private func webviewChildSlot(keepHidden: Int, extraWindows: String = "") async throws -> (WindowOwner, WindowView, PaneID, PaneID) {
        let config = directory.appendingPathComponent("slot.yaml")
        try "app: {webview: {keep_hidden: \(keepHidden)}}\n".write(to: config, atomically: true, encoding: .utf8)
        let toy = try WebviewToy(path: directory.appendingPathComponent("slot.sock").path)
        try await toy.start()
        addTeardownBlock { toy.stop() }
        func command(_ color: String) -> String {
            "printf '\\033[41m'; i=0; while [ $i -lt 60 ]; do printf 'TERMINAL-BEHIND-PAGE %080d\\r\\n' 0; i=$((i+1)); done; '\(tools.ko)' webview enter --path '/?solid=\(color)'; exec '\(tools.ko)' webview serve --socket '\(toy.path)'"
        }
        try await start(configFile: config.path, windows: #"[{"name":"parent","tree":\#(koPane(command("126a42")))}\#(extraWindows)]"#)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path
        addTeardownBlock { @MainActor in owner.close() }
        owner.start()
        try await wait("parent page loaded") {
            guard let web = owner.testSession?.activePane?.webviewView?.browser else { return false }
            return !web.isLoading && web.url != nil
        }
        let session = try XCTUnwrap(owner.testSession)
        let parent = try XCTUnwrap(session.activePane?.pane)
        let slot = try XCTUnwrap(session.windows.values.first { !$0.isHidden })
        let request = directory.appendingPathComponent("child.json")
        try JSONSerialization.data(withJSONObject: [
            "session": "session_1", "parent": parent.description, "close": "on_exit",
            "command": ["type": "argv", "argv": ["/bin/sh", "-c", command("234b91")]]
        ]).write(to: request)
        try await ko(["api", "-X", "POST", "--input", request.path, "/panes"], dir: directory.path)
        try await wait("child page serving") { owner.testModel?.panes.contains { $0.parent == parent && $0.webview?.page != nil && $0.webview?.serving == true } == true }
        let child = try XCTUnwrap(owner.testModel?.panes.first { $0.parent == parent }?.id)
        return (owner, slot, parent, child)
    }

    private func webviewChildSlotFrames(keepHidden: Int) async throws {
        let (owner, slot, parent, child) = try await webviewChildSlot(keepHidden: keepHidden)
        let session = try XCTUnwrap(owner.testSession)
        let parentWeb = try XCTUnwrap(session.activePane?.webviewView?.browser)
        weak var parentView = session.activePane
        var captures = 0
        func capture(_ view: WindowView) throws {
            guard let pane = view.displayedPanes.first, [parent, child].contains(pane.pane) else { return }
            XCTAssertTrue(view === slot, "parent and child must use the same window slot")
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.converting(to: .sRGB, renderingIntent: .default))
            let paper = try XCTUnwrap(pane.paperColor.usingColorSpace(.sRGB))
            let bytes: [CGFloat] = pane.pane == parent ? [18, 106, 66] : [35, 75, 145]
            let page = bytes.map { $0 / 255 }
            let allowed = pane.pane == parent && keepHidden > 0 ? [page] : [[paper.redComponent, paper.greenComponent, paper.blueComponent], page]
            let captured = NSImage(size: view.bounds.size)
            captured.addRepresentation(image)
            let attachment = XCTAttachment(image: captured)
            attachment.name = "slot-frame-\(captures)-\(pane.pane)"
            attachment.lifetime = .keepAlways
            add(attachment)
            pixels: for y in stride(from: image.pixelsHigh / 4, to: image.pixelsHigh * 3 / 4, by: 19) {
                for x in stride(from: image.pixelsWide / 4, to: image.pixelsWide * 3 / 4, by: 19) {
                    let pixel = try XCTUnwrap(image.colorAt(x: x, y: y))
                    let rgb = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                    if !allowed.contains(where: { zip(rgb, $0).allSatisfy { abs($0 - $1) < 0.03 } }) {
                        XCTFail("slot frame \(captures) pane \(pane.pane) pixel \(x),\(y): \(rgb)")
                        break pixels
                    }
                }
            }
            if pane.pane == parent {
                XCTAssertEqual(pane.webviewView?.browser === parentWeb, keepHidden > 0, "return must obey the hidden page budget")
            }
            XCTAssertTrue(pane.visualTerminalHidden, "slot frame \(captures) exposes the terminal layer for \(pane.pane)")
            captures += 1
        }
        session.visualReconciled = { view in
            do { try capture(view) } catch { XCTFail("slot capture: \(error)") }
        }
        defer { session.visualReconciled = { _ in } }
        weak var childView: PaneView?
        for target in [child, parent] {
            try owner.testClient?.select(KO_SELECT_PANE, target)
            try await wait("slot switches to \(target)") { session.activePane?.pane == target }
            if target == child && keepHidden == 0 {
                try await wait("released displaced pane leaves hierarchy") { parentView?.superview == nil }
                try await wait("released displaced pane deallocates") { parentView == nil }
            }
            let pane = try XCTUnwrap(session.activePane)
            if target == child { childView = pane }
            try await wait("slot page loaded") { pane.webviewView?.browser.isLoading == false && pane.webviewView?.browser.url != nil }
            let web = try XCTUnwrap(pane.webviewView?.browser)
            let color = target == parent ? "rgb(18, 106, 66)" : "rgb(35, 75, 145)"
            try await webviewUntil(web, "getComputedStyle(document.body).backgroundColor==='\(color)'")
            XCTAssertTrue(surfaceText(pane).contains("TERMINAL-BEHIND-PAGE"))
            for _ in 0..<3 {
                try capture(try XCTUnwrap(session.windows.values.first { !$0.isHidden }))
                await mainQueueFence()
            }
        }
        XCTAssertGreaterThanOrEqual(captures, 8)
        if keepHidden > 0 {
            XCTAssertNotNil(childView)
            try await ko(["api", "-X", "DELETE", "/panes/\(child)"], dir: directory.path)
            try await wait("removed displaced pane leaves hierarchy") { childView?.superview == nil }
            try await wait("removed displaced pane deallocates") { childView == nil }
        }
    }

    func testWebviewReloadMenu() async throws {
        let pane = try await webviewStart()
        let view = try XCTUnwrap(pane.webviewView)
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let entries = items(menu)
        let reload = try XCTUnwrap(entries.first { $0.title == "Reload Page" })
        XCTAssertEqual(reload.keyEquivalent, "r")
        XCTAssertEqual(reload.keyEquivalentModifierMask, .command)
        XCTAssertEqual(entries.filter { $0.keyEquivalent.lowercased() == "r" && $0.keyEquivalentModifierMask == .command }.count, 1)
        window.makeFirstResponder(pane.inputResponder)
        XCTAssertTrue(pane.validateMenuItem(reload))
        let documents = view.visualDocuments
        XCTAssertTrue(pane.tryToPerform(try XCTUnwrap(reload.action), with: reload))
        try await wait("menu reloads the page") { view.visualDocuments > documents }
        try await split(1, .h)
        try await wait("terminal for reload validation") { self.terminal?.displayedPanes.count == 2 }
        let terminalPane = try XCTUnwrap(terminal?.displayedPanes.first { $0 !== pane })
        window.makeFirstResponder(terminalPane)
        XCTAssertFalse(terminalPane.validateMenuItem(reload))
    }

    func testWebviewPendingFetchLimit() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        let pane = try await webviewStart(toy: toy)
        let web = try XCTUnwrap(pane.webviewView?.browser)
        _ = try await webviewJS(web, "(()=>{window.pendingAbort=new AbortController();window.limitResults=[];window.limitRequests=Array.from({length:71},(_,id)=>fetch('/slot/'+id,{signal:id===6?pendingAbort.signal:undefined}).then(r=>r.text()).then(v=>limitResults.push(v),e=>limitResults.push('error:'+id)));return true})()")
        try await wait("six active requests") { toy.acceptedSlots.count == 6 }
        try await webviewEqual(web, "Promise.race([limitRequests[70].then(()=>limitResults.includes('error:70')),new Promise(resolve=>setTimeout(()=>resolve(false),3000))])", "true")
        _ = try await webviewJS(web, "(()=>{pendingAbort.abort();return true})()")
        toy.releaseSlot(0)
        try await wait("cancelled waiter skipped") { toy.acceptedSlots.count == 7 }
        XCTAssertEqual(toy.acceptedSlots, [0, 1, 2, 3, 4, 5, 7])
        for id in 1..<70 where id != 6 { toy.releaseSlot(id) }
        _ = try await webviewJS(web, "Promise.all(limitRequests).then(()=>true)")
        XCTAssertEqual(toy.acceptedSlots.sorted(), Array(0..<70).filter { $0 != 6 })
    }

    func testWebviewSocketPendingLimit() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        let pane = try await webviewStart(toy: toy)
        let web = try XCTUnwrap(pane.webviewView?.browser)
        for bytes in [0, 65536] {
            let before = toy.messageCount
            let result = try await webviewJS(web, """
            new Promise(resolve=>{
              const socket=new WebSocket('/burst');let errors=0,closes=0,release;
              const blob=new Blob([new Uint8Array(\(bytes))]);
              blob.arrayBuffer=()=>new Promise(done=>{release=()=>done(new ArrayBuffer(\(bytes)))});
              socket.onerror=()=>errors++;
              socket.onclose=e=>{closes++;release();setTimeout(()=>resolve([errors,closes,e.code,e.wasClean,socket.readyState]),0)};
              socket.onopen=()=>{socket.send(blob);for(let i=0;i<\(bytes == 0 ? 256 : 16);i++)socket.send(new Uint8Array(\(bytes)))};
              setTimeout(()=>resolve('timeout'),3000);
            })
            """)
            XCTAssertEqual(result, "[1,1,1006,false,3]")
            try await webviewEqual(web, "new Promise(resolve=>{const s=new WebSocket('/sibling');s.onopen=()=>s.send('alive');s.onmessage=e=>{s.close();resolve(e.data)}})", #""alive""#)
            XCTAssertEqual(toy.messageCount, before + 1)
        }
    }

    func testWebviewFetchSlots() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        let pane = try await webviewStart(toy: toy)
        let web = try XCTUnwrap(pane.webviewView?.browser)
        _ = try await webviewJS(web, "fetch('/events').then(response=>{window.slotStream=response;window.slotRequests=Array.from({length:8},(_,id)=>fetch('/slot/'+id).then(response=>response.text()));return true})")
        try await wait("five short requests admitted", within: 5) { toy.acceptedSlots.count == 5 }
        XCTAssertEqual(toy.acceptedSlots, [0, 1, 2, 3, 4])
        XCTAssertEqual(toy.waitingSlots, 5)
        for id in 0..<3 {
            toy.releaseSlot(id)
            try await wait("the next queued request", within: 5) { toy.acceptedSlots.count == 6 + id }
            XCTAssertEqual(toy.acceptedSlots, Array(0..<(6 + id)))
            XCTAssertEqual(toy.waitingSlots, 5)
        }
        for id in 3..<8 { toy.releaseSlot(id) }
        let result = try await webviewJS(web, "Promise.all(window.slotRequests)")
        XCTAssertEqual(result, #"["0","1","2","3","4","5","6","7"]"#)
        _ = try await webviewJS(web, "window.slotStream.body.cancel().then(()=>true)")
        let view = try XCTUnwrap(pane.webviewView)
        let documents = view.visualDocuments
        try await webviewEqual(web, "fetch('/encoded',{headers:{'Accept-Encoding':'gzip'}}).then(async r=>[r.status,(await r.text()).includes('gzip')])", "[502,true]")
        XCTAssertTrue(toy.encodedRequest.lowercased().contains("accept-encoding: identity\r\n"))
        try await webviewEqual(web, "fetch('/metadata').then(async r=>[r.headers.get('transfer-encoding'),r.headers.get('content-length'),r.headers.get('x-private'),r.headers.get('proxy-custom'),r.headers.get('x-public'),await r.text()])", #"[null,null,null,null,"kept","finite"]"#)
        try await webviewEqual(web, "fetch('/truncated').then(r=>r.text()).then(()=>false,()=>true)", "true")
        XCTAssertEqual(view.visualDocuments, documents)
        try await webviewEqual(web, "window.ready", "true")
    }

    func testWebviewEventSourceScheme() async throws {
        let pane = try await webviewStart()
        let web = try XCTUnwrap(pane.webviewView?.browser)
        let result = try await webviewJS(web, """
        new Promise(resolve=>{
          const source=new EventSource('/sse');
          const timer=setTimeout(()=>{source.close();resolve('timeout')},5000);
          source.onmessage=event=>{clearTimeout(timer);source.close();resolve(event.data)};
          source.onerror=()=>{clearTimeout(timer);source.close();resolve('error')};
        })
        """)
        XCTAssertEqual(result, #""{\"record\":1}""#)
    }

    func testWebviewFetchStashedChunks() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        let pane = try await webviewStart(toy: toy)
        let web = try XCTUnwrap(pane.webviewView?.browser)
        let view = try XCTUnwrap(pane.webviewView)
        view.visualFeedPath = "/stash"
        let before = view.visualFeedBytes
        let quietMilliseconds = 500
        let first = try await webviewJS(web, """
        (async()=>{
          window.stashReader=(await fetch('/stash')).body.getReader();
          window.stashBytes=(await stashReader.read()).value.byteLength;
          return stashBytes;
        })()
        """)
        XCTAssertEqual(first, "4096")
        toy.writeStash()
        try await wait("second chunk handed") { view.visualFeedBytes == before + 8192 }
        toy.writeStash()
        try await wait("third chunk handed") { view.visualFeedBytes == before + 12288 }
        // WebKit bug 322545; upstream fix 718031552ba1 (319981@main).
        let held = try await webviewJS(web, """
        (async()=>{
          window.stashDone=(async()=>{for(;;){const {value,done}=await stashReader.read();if(done)return;stashBytes+=value.byteLength}})();
          return await Promise.race([stashDone.then(()=>stashBytes),new Promise(resolve=>setTimeout(()=>resolve(stashBytes),\(quietMilliseconds)))]);
        })()
        """)
        XCTAssertEqual(held, "8192")
        toy.finishStash()
        let final = try await webviewJS(web, "stashDone.then(()=>stashBytes)")
        XCTAssertEqual(final, "12288")
    }

    func testWebviewPostBodies() async throws {
        let pane = try await webviewStart()
        let view = try XCTUnwrap(pane.webviewView)
        let result = try await webviewJS(view.browser, """
        (async()=>{
          const payload='stream-body-'.repeat(16384);
          const form=new FormData();form.append('file',new Blob([payload]),'body.txt');
          const bodies=[payload,new TextEncoder().encode(payload),new Blob([payload]),form];
          const results=[];
          for(const body of bodies){
            const request=new Request(new URL('/body',location.href),{method:'POST',body});
            const expected=await request.clone().text();
            const actual=await (await fetch(request)).text();
            results.push(results.length < 2 ? actual===expected : actual==='');
          }
          return results;
        })()
        """)
        // WebKit omits Blob and FormData bodies from WKURLSchemeTask requests.
        XCTAssertEqual(result, "[true,true,true,true]")
    }

    func testWebviewPaneLightAndDark() async throws {
        let pane = try await webviewStart()
        try await webviewSnapshot(pane, "light")
        try await webviewEqual(try XCTUnwrap(pane.webviewView?.browser), "window.ko.theme['--ko-cursor'].toLowerCase()", "\"rgb(170,170,170)\"")
        try await darken()
        pane.webviewView?.updateTheme()
        let web = try XCTUnwrap(pane.webviewView?.browser)
        try await webviewEqual(web, "window.ko.theme['--ko-appearance']", "\"dark\"")
        try await webviewEqual(web, "window.themeEvents>0", "true")
        try await webviewSnapshot(pane, "dark")
    }

    func testWebviewSandboxSocketAndFocus() async throws {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        board.clearContents()
        board.setString("kido-webview-private-" + UUID().uuidString, forType: .string)
        let change = board.changeCount
        defer {
            board.clearContents()
            board.writeObjects(saved.map { data in
                let item = NSPasteboardItem()
                for (type, bytes) in data { item.setData(bytes, forType: type) }
                return item
            })
        }
        let pane = try await webviewStart(gates: true)
        let webview = try XCTUnwrap(pane.webviewView)
        let web = try XCTUnwrap(webview.browser)
        let sandbox = try await webviewJS(web, "window.sandbox")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sandbox.utf8)) as? [String: Bool])
        XCTAssertEqual(values, ["https": true, "otherFetch": true, "popup": true, "otherSocket": true])
        try await webviewEqual(web, "window.httpsPolicy", "\"connect-src\"")
        try await webviewEqual(web, "window.echo", "\"hello:binary:blob\"")
        try await webviewEqual(web, "window.closedSocket", "[3001,\"done\",true]")
        try await webviewEqual(web, "fetch('/').then(r=>r.headers.get('Content-Security-Policy').includes(\"frame-src 'none'\"))", "true")
        let policy = try await webviewJS(web, """
        new Promise(resolve=>{addEventListener('securitypolicyviolation',e=>{if(e.blockedURI.startsWith('ws:'))resolve(e.violatedDirective)},{once:true});try{new window.__koNativeWebSocket('ws://example.invalid/')}catch(e){resolve(e.name)}})
        """)
        XCTAssertEqual(policy, "\"SecurityError\"")
        let secure = try await webviewJS(web, "window.isSecureContext")
        NSLog("webview ko: isSecureContext=%@", secure)
        let capabilities = try await webviewJS(web, "({clipboard:typeof navigator.clipboard,media:typeof navigator.mediaDevices,geolocation:typeof navigator.geolocation,notification:typeof Notification,serviceWorker:typeof navigator.serviceWorker})")
        NSLog("webview ko: capabilities=%@", capabilities)
        try await webviewEqual(web, "window.initialActivation", "false")
        try await webviewEqual(web, "window.clipboardRead", "{\"denied\":true,\"text\":null}")
        try await webviewEqual(web, "window.clipboardItemsRead", "{\"denied\":true,\"count\":0}")
        try await webviewEqual(web, "window.clipboardWrite", "true")
        let notification = try await webviewJS(web, "window.notificationPermission")
        XCTAssertNotEqual(notification, "\"granted\"")
        NSLog("webview ko: Notification permission=%@", notification)
        try await webviewEqual(web, "window.workerDenied", "true")
        XCTAssertEqual(board.changeCount, change)
        try await webviewEqual(web, "window.mediaDenied", "true")
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await webviewEqual(web, "window.geoDenied", "1")

        let point = webview.convert(NSPoint(x: 40, y: 40), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var selected = false
        pane.onSelect = { selected = true }
        _ = pane.visualEventMonitor?(click)
        XCTAssertTrue(selected)
        XCTAssertTrue(pane.webviewFocused)
        XCTAssertTrue(PaneView.owner(window.firstResponder) === pane)
        let copyItem = NSMenuItem(title: "Copy Mode", action: #selector(PaneView.toggleCopyMode(_:)), keyEquivalent: "c")
        XCTAssertFalse(pane.validateMenuItem(copyItem))
        _ = try await webviewJS(web, "(()=>{document.querySelector('input').focus();return true})()")
        for (characters, code) in [("x", UInt16(7)), ("\u{1b}", UInt16(53))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
        try await webviewEqual(web, "document.querySelector('input').value", "\"x\"")
        try await webviewEqual(web, "window.keys.includes('Escape')", "true")
        let found = expectation(description: "webview find")
        webview.find("terminal") { XCTAssertTrue($0); found.fulfill() }
        await fulfillment(of: [found], timeout: 5)
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu }
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let realMenu = try XCTUnwrap(oldMenu)
        NSApp.mainMenu = realMenu
        func entry(_ menu: NSMenu, action: Selector) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let submenu = item.submenu, let found = entry(submenu, action: action) { return found }
            }
            return nil
        }
        func command(_ key: String, _ code: UInt16, mods: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: key,
                                          charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        }
        let findItem = try XCTUnwrap(entry(realMenu, action: #selector(PaneView.showFind(_:))))
        let findTarget = findItem.target
        defer { findItem.target = findTarget }
        findItem.target = pane
        XCTAssertTrue(window.performKeyEquivalent(with: try command("f", 3)))
        let find = try XCTUnwrap(pane.find)
        let editor = try XCTUnwrap(find.field.currentEditor() as? NSTextView)
        editor.insertText("terminal", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait("WebKit match in pane find bar") { find.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Match" } }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("no-such-webview-match", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await wait("WebKit no match in pane find bar") { find.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "No matches" } }
        try XCTUnwrap(find.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Done (Escape)" }).performClick(nil)
        XCTAssertNil(pane.find)
        XCTAssertTrue(pane.webviewFocused)
        XCTAssertTrue(window.performKeyEquivalent(with: try command("p", 35)))
        XCTAssertNotNil(app.palettePanel)
        app.closePalette()
        window.makeFirstResponder(pane.inputResponder)
        let sidebarItem = try XCTUnwrap(entry(realMenu, action: #selector(Sidebar.toggleSidebar(_:))))
        let sidebar = try XCTUnwrap(sidebarItem.target as? Sidebar)
        let collapsed = sidebar.isCollapsed
        XCTAssertTrue(window.performKeyEquivalent(with: try command("S", 1, mods: [.command, .shift])))
        XCTAssertNotEqual(sidebar.isCollapsed, collapsed)
        sidebar.toggleSidebar(nil)
        window.makeFirstResponder(pane.inputResponder)
        let menu = NSMenu()
        let root = NSMenuItem(title: "webview keys", action: nil, keyEquivalent: "")
        root.submenu = NSMenu()
        menu.addItem(root)
        NSApp.mainMenu = menu
        let probe = WebviewMenuProbe()
        for (key, code) in [("1", UInt16(18))] {
            let item = root.submenu!.addItem(withTitle: key, action: #selector(WebviewMenuProbe.invoke(_:)), keyEquivalent: key)
            item.target = probe
            item.keyEquivalentModifierMask = .command
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(probe.keys, ["1"])
        let before = web.url
        let rejected = webview.visualRejectedNavigations
        _ = try await webviewJS(web, "(()=>{location.href='https://example.invalid/';return true})()")
        try await wait("webview navigation refused") { webview.visualRejectedNavigations > rejected }
        XCTAssertEqual(web.url, before)
    }

    func testWebviewSocketConnectingCloseAndReload() async throws {
        let toy = try WebviewToy(path: directory.appendingPathComponent("webview.sock").path)
        let pane = try await webviewStart(toy: toy)
        let webview = try XCTUnwrap(pane.webviewView)
        let web = webview.browser
        _ = try await webviewJS(web, """
        (()=>{let opened=false,error=false;window.delayed=new WebSocket('/delayed');window.delayedResult=new Promise(resolve=>{delayed.onopen=()=>opened=true;delayed.onerror=()=>error=true;delayed.onclose=e=>resolve([opened,error,e.code,e.wasClean])});return true})()
        """)
        try await wait("toy received delayed upgrade") { toy.delayedCount == 1 }
        _ = try await webviewJS(web, "(()=>{delayed.close();return true})()")
        try await webviewEqual(web, "window.delayedResult", "[false,true,1006,false]")
        try await webviewEqual(web, "new Promise(resolve=>{window.live=new WebSocket('/echo');live.onopen=()=>resolve(true)})", "true")
        try await wait("one live socket before reload") { toy.socketCount == 1 }
        let rejected = webview.visualRejectedNavigations
        _ = try await webviewJS(web, "(()=>{location.href='/download';return true})()")
        try await wait("non-showable navigation refused") { webview.visualRejectedNavigations > rejected }
        try await webviewEqual(web, "new Promise(resolve=>{live.onmessage=e=>resolve(e.data);live.send('after-refusal')})", "\"after-refusal\"")
        let documents = webview.visualDocuments
        XCTAssertNotNil(web.reload())
        try await wait("new main-frame document loaded") { webview.visualDocuments > documents }
        try await webviewEqual(web, "window.echo", "\"hello:binary:blob\"")
        try await webviewEqual(web, "window.closedSocket", "[3001,\"done\",true]")
        try await wait("reload closed the previous socket") { toy.socketCount == 0 }
    }

    func testWebviewHiddenPagesAreEvictedAndLeaveShowsTerminal() async throws {
        let pane = try await webviewStart()
        let webview = try XCTUnwrap(pane.webviewView)
        let page = try XCTUnwrap(koModel?.pane(pane.pane)?.webview)
        let marker = "kido-marker-" + UUID().uuidString
        try await webviewEqual(webview.browser, "(()=>{localStorage.setItem('\(marker)','present');return localStorage.getItem('\(marker)')})()", "\"present\"")
        let second = WebviewPaneView(pane: pane, client: try XCTUnwrap(client))
        defer { second.close() }
        second.frame = webview.frame
        window.contentView?.addSubview(second)
        second.update(path: "/", serving: true)
        try await wait("second isolated webview page loaded") { second.browser.url != nil && !second.browser.isLoading }
        try await webviewEqual(second.browser, "localStorage.getItem('\(marker)')", "null")
        let channel = "kido-channel-" + UUID().uuidString
        for web in [webview.browser, second.browser] {
            try await webviewEqual(web, "(()=>{window.channelMessages=[];window.receiver=new BroadcastChannel('\(channel)');window.sender=new BroadcastChannel('\(channel)');receiver.onmessage=e=>channelMessages.push(e.data);return true})()", "true")
        }
        try await webviewEqual(webview.browser, "new Promise(resolve=>{receiver.onmessage=e=>{channelMessages.push(e.data);if(e.data==='probe')resolve(true)};sender.postMessage('probe')})", "true")
        try await webviewEqual(second.browser, "new Promise(resolve=>{receiver.onmessage=e=>{channelMessages.push(e.data);if(e.data==='barrier')resolve(channelMessages)};sender.postMessage('barrier')})", "[\"barrier\"]")
        for web in [webview.browser, second.browser] {
            try await webviewEqual(web, "(()=>{receiver.close();sender.close();return true})()", "true")
        }
        second.close()
        pane.isHidden = true
        session.updateWebview()
        await mainQueueFence()
        XCTAssertTrue(pane.webviewView === webview)
        try "app: {webview: {keep_hidden: 0}}\n".write(toFile: runtime.configFile, atomically: true, encoding: .utf8)
        try await wait("hidden webview page evicted") { pane.webviewView == nil && self.runtime.values.webview.keepHidden == 0 }
        pane.updateWebview(page)
        XCTAssertNil(pane.webviewView)
        pane.isHidden = false
        pane.updateWebview(page)
        XCTAssertNotNil(pane.webviewView)
        XCTAssertFalse(pane.webviewView === webview)
        let replacement = try XCTUnwrap(pane.webviewView)
        try await wait("evicted webview page loaded again") { replacement.browser.url != nil && !replacement.browser.isLoading }
        try await webviewEqual(replacement.browser, "localStorage.getItem('\(marker)')", "null")
        pane.updateWebview(nil)
        XCTAssertNil(pane.webviewView)
        XCTAssertNotNil(pane.surface)
    }
}
