import AppKit
import KoClientKit
import WebKit
import XCTest
import KoModel
@testable import Kido

@MainActor final class KoaFocusTests: AppWindowCase {
    func testTiledFocusFromAnotherWindowsFloatMakesTheMainWindowKey() async throws {
        try loadRuntime()
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(policy) }
        _ = try await KoServer.launch(dir: directory.path)
        let pane = #"{"new":{"command":{"type":"argv","argv":["/bin/cat"]}}}"#
        try await koPut(directory.path, #"[{"name":"first","windows":[{"name":"one","tree":{"pane":\#(pane)}}]},{"name":"second","windows":[{"name":"two","tree":{"pane":\#(pane)},"floats":[{"pane":\#(pane),"x":2,"y":2,"cols":30,"rows":8}]}]}]"#)
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        defer { owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("all floats are ready", within: 5) { owner.testBanner.isHidden && owner.testSession?.hostWindows.count == 1 }
        let session = try XCTUnwrap(owner.testSession)
        let host = try XCTUnwrap(session.hostWindows.first)
        let floating = try XCTUnwrap(session.pane(PaneID(number: 3)))
        let tiled = try XCTUnwrap(session.pane(PaneID(number: 1)))
        owner.window.makeKeyAndOrderFront(nil)
        try await wait("the main window is key", within: 5) { owner.window.isKeyWindow }
        host.makeKeyAndOrderFront(nil)
        try await wait("the float is key and selected", within: 5) { host.isKeyWindow && owner.testModel?.selection.pane == floating.pane }
        XCTAssertEqual(session.windows.first { !$0.value.isHidden }?.key, WindowID(number: 1))
        owner.perform(.jump(.init(session: SessionID(number: 1), window: WindowID(number: 1), pane: tiled.pane)))
        try await wait("the tiled focus route makes the main window key", within: 5) { owner.window.isKeyWindow && owner.testModel?.selection.pane == tiled.pane }
        XCTAssertTrue(PaneView.owner(owner.window.firstResponder) === tiled)
        let floatKeys = floating.visualKeyEvents, tiledKeys = tiled.visualKeyEvents
        let key = try XCTUnwrap(NSApp.keyWindow)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: key.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        key.sendEvent(event)
        XCTAssertEqual(tiled.visualKeyEvents, tiledKeys + 1)
        XCTAssertEqual(floating.visualKeyEvents, floatKeys)
        try await wait("the input reaches the tiled pane", within: 5) { tiled.visualText.contains("x") }
        host.makeKeyAndOrderFront(nil)
        try await wait("the float is key again", within: 5) { host.isKeyWindow && owner.testModel?.selection.pane == floating.pane }
        floating.placeCapsule.invoke()
        XCTAssertEqual(session.windows.first { !$0.value.isHidden }?.key, WindowID(number: 2))
        XCTAssertTrue(host.isKeyWindow)
    }

    func testKoaWebviewPromptDismissalRestoresComposer() async throws {
        try loadRuntime()
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(policy) }
        _ = try await KoServer.launch(dir: directory.path)
        let assets = directory.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        WebviewPaneView.visualInitialScript = "const Source=EventSource;window.EventSource=class extends Source{constructor(...args){super(...args);window.testSource=this;this.addEventListener('message',event=>{const value=JSON.parse(event.data);if(value.type==='state')window.testState=value})}};"
        defer { WebviewPaneView.visualInitialScript = nil }
        let command = "printf '\\033]7501;state=working:app=koa\\007'; export PATH=\(SSH.quote(koaPath(self))); exec node \(SSH.quote(checkoutRoot.appendingPathComponent("koa/testdata/replay.ts").path)) transcript testKoaWebviewQuoteSelectionMenu \(SSH.quote(assets.path))"
        try await koPut(directory.path, #"[{"name":"visual","windows":[{"name":"koa","tree":\#(koPane(command))}]}]"#)
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        defer { app.closePalette(); owner.close() }
        owner.testServerDir = directory.path
        owner.start()
        try await wait("koa webview ready") {
            let web = owner.testSession?.activePane?.webviewView?.browser
            return web?.url?.scheme == "ko" && web?.isLoading == false
        }
        let pane = try XCTUnwrap(owner.testSession?.activePane)
        let web = try XCTUnwrap(pane.webviewView?.browser)
        try await webviewUntil(web, "!!window.composer && !document.querySelector('#field').inert && document.querySelector('#model-name').textContent!==''")
        owner.window.makeKeyAndOrderFront(nil)
        owner.window.makeFirstResponder(pane.inputResponder)
        try await webviewUntil(web, "document.hasFocus()")
        _ = try await webviewJS(web, "(()=>{window.focusEvents=[];for(const name of ['focus','blur','focusin'])window.addEventListener(name,event=>focusEvents.push([name,event.target.tagName||'window']),true);composer.focus();return true})()")
        func type(_ character: String, code: UInt16) throws {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: owner.window.windowNumber, context: nil, characters: character,
                                                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
                owner.window.sendEvent(event)
            }
        }
        let initiallyFocused = try await webviewJS(web, "document.activeElement===document.querySelector('#prompt .cm-content')")
        XCTAssertEqual(initiallyFocused, "true")
        try await wait("composer menu state") { pane.webviewView?.composerAction == .focus }
        XCTAssertEqual(pane.promptMenuTitle, "Focus Composer")
        pane.canPrompt = { false }
        let quoteItem = NSMenuItem(title: pane.promptMenuTitle, action: #selector(PaneView.promptSelectionItem(_:)), keyEquivalent: "o")
        XCTAssertTrue(pane.validateMenuItem(quoteItem))
        try await webviewUntil(web, "document.querySelector('#items .assistant p')?.textContent==='Keep this quote in the composer.'")
        _ = try await webviewJS(web, "(()=>{const text=document.querySelector('#items .assistant p');const range=document.createRange();range.selectNodeContents(text);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);return true})()")
        try await wait("quote menu state") { pane.webviewView?.composerAction == .quote }
        XCTAssertEqual(pane.promptMenuTitle, "Quote Selection")
        pane.promptSelectionItem(nil)
        try await webviewUntil(web, "composer.text().startsWith('> ')&&composer.text().endsWith('\\n')&&getSelection().isCollapsed")
        XCTAssertNil(app.palettePanel)
        _ = try await webviewJS(web, "(composer.setText(''),true)")
        pane.canPrompt = { true }
        pane.onPrompt = { pane, quote, preselect in app.openPrompt(owner: owner, pane: pane, quote: quote, preselect: preselect) }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Prompt with Selection…", action: #selector(PaneView.promptSelectionItem(_:)), keyEquivalent: "o")
        item.target = pane
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                               windowNumber: owner.window.windowNumber, context: nil, characters: "o",
                                               charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
        XCTAssertTrue(menu.performKeyEquivalent(with: key))
        XCTAssertNil(app.palettePanel)
        pane.openPrompt()
        try await wait("Prompt with Selection popup") { app.palettePanel?.palette.prompt != nil }
        let panel = try XCTUnwrap(app.palettePanel)
        let prompt = try XCTUnwrap(panel.palette.prompt)
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.firstResponder === prompt.textView)
        try await webviewUntil(web, "!document.hasFocus()")
        _ = try await webviewJS(web, "(focusEvents=[],true)")
        app.closePalette()
        owner.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(pane.webviewFocused, "prompt dismissal restores the webview, not its terminal parent")
        try await webviewUntil(web, "focusEvents.some(([name,target])=>name==='focus'&&target==='window')")
        let afterPrompt = try await webviewJS(web, "document.activeElement===document.querySelector('#prompt .cm-content')")
        let focusDetails = try await webviewJS(web, "({active:document.activeElement.outerHTML.slice(0,300),events:focusEvents,focus:document.hasFocus(),inert:document.querySelector('#field').inert,hidden:document.visibilityState})")
        XCTAssertEqual(afterPrompt, "true", focusDetails)
        try type("x", code: 7)
        try await webviewUntil(web, "composer.text()==='x'")
        let field = NSTextField()
        owner.window.contentView?.addSubview(field)
        owner.window.makeFirstResponder(field)
        try await webviewUntil(web, "!document.hasFocus()")
        _ = try await webviewJS(web, "(focusEvents=[],true)")
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: pane.convert(.zero, to: nil), modifierFlags: [], timestamp: 0,
                                                   windowNumber: owner.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        pane.mouseDown(with: click)
        pane.mouseUp(with: click)
        XCTAssertTrue(pane.webviewFocused, "pane band click restores its webview")
        try await webviewUntil(web, "focusEvents.some(([name,target])=>name==='focus'&&target==='window')")
        let afterClick = try await webviewJS(web, "document.activeElement===document.querySelector('#prompt .cm-content')")
        XCTAssertEqual(afterClick, "true")
        try type("y", code: 16)
        try await webviewUntil(web, "composer.text()==='xy'")
        field.removeFromSuperview()
        let position = try XCTUnwrap(owner.projection.placements[pane.pane]?.position)
        let root = KoSchema.Candidate(session: position.session, target: .init(pane: pane.pane, record: ""), title: "ko", window: position.window)
        let child = KoSchema.Candidate(session: position.session, target: .init(pane: pane.pane, record: "agents/reviewer"), title: "reviewer", window: position.window)
        owner.testPrompt = { request, done in
            if case .resolve = request { done(.success(.candidates([root, child]))) }
        }
        owner.window.makeFirstResponder(pane.inputResponder)
        _ = try await webviewJS(web, "(()=>{testSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...testState,view:{type:'job',id:'j1',record:'agents/reviewer/jobs/j1',path:[{id:'s1',name:'ko',type:'agent'},{id:'child',name:'reviewer',type:'agent'},{id:'j1',name:'build',type:'job'}],job:{name:'build',command:'make',service:false,startedAt:1700000000000,place:{type:'mac'},log:'/tmp/build.log',state:{type:'running'}}}})}));testSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'job-reset',view:'j1',epoch:'job',start:0,end:9,data:btoa('job error')})}));return true})()")
        try await wait("job prompt menu") { pane.webviewView?.composerAction == .prompt(record: "agents/reviewer/jobs/j1") }
        XCTAssertEqual(pane.promptMenuTitle, "Prompt…")
        try await webviewUntil(web, "document.querySelector('#jobv').textContent.includes('job error')")
        _ = try await webviewJS(web, "(()=>{const range=document.createRange();range.selectNodeContents(document.querySelector('#jobv .job-output')||document.querySelector('#jobv'));const selection=getSelection();selection.removeAllRanges();selection.addRange(range);return true})()")
        try await wait("job quote menu") { pane.webviewView?.composerAction == .promptQuote(record: "agents/reviewer/jobs/j1") }
        XCTAssertEqual(pane.promptMenuTitle, "Prompt with Selection…")
        pane.promptSelectionItem(nil)
        try await wait("job owner prompt") { app.palettePanel?.palette.prompt?.target == child }
        let jobPrompt = try XCTUnwrap(app.palettePanel?.palette.prompt)
        XCTAssertEqual(jobPrompt.source.preselect, .init(pane: pane.pane, record: "agents/reviewer/jobs/j1"))
        XCTAssertTrue(jobPrompt.textView.string.contains("job error"))
    }
}
