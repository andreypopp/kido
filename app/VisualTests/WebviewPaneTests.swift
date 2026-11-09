import AppKit
import WebKit
import XCTest
import SnapshotTesting
import KoModel
@testable import Kido

@MainActor private final class WebviewMenuProbe: NSObject {
    var keys: [String] = []
    @objc func invoke(_ sender: NSMenuItem) { keys.append(sender.keyEquivalent) }
}

extension VisualTests {
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
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await wait("webview page loaded") { pane.webviewView?.browser.isLoading == false && pane.webviewView?.browser.url != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        let result = try await webviewJS(web, "Promise.all([window.echo,window.sandbox])")
        XCTAssertTrue(result.contains("hello"), result)
        try await webviewEqual(web, "window.ready", "true")
        return pane
    }

    func webviewSnapshot(_ pane: PaneView, _ name: String, testName: String = #function) async throws {
        let webview = try XCTUnwrap(pane.webviewView)
        window.contentView?.layoutSubtreeIfNeeded()
        webview.layoutSubtreeIfNeeded()
        let done = expectation(description: "WebKit snapshot")
        var image: NSImage?
        webview.browser.takeSnapshot(with: nil) { result, error in
            XCTAssertNil(error)
            image = result
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        let overlay = NSImageView(frame: webview.browser.frame)
        overlay.image = try XCTUnwrap(image)
        overlay.imageScaling = .scaleAxesIndependently
        webview.addSubview(overlay)
        defer { overlay.removeFromSuperview() }
        try await snapshot(name, testName: testName)
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
