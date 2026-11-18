import AppKit
import KoClientKit
import WebKit
import XCTest
import KoModel
@testable import Kido

@MainActor final class KoaFocusTests: AppWindowCase {
    func testKoaWebviewPromptDismissalRestoresComposer() async throws {
        try loadRuntime()
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(policy) }
        _ = try await KoServer.launch(dir: directory.path)
        let assets = directory.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let command = "printf '\\033]7501;state=working:app=koa\\007'; export PATH=\(SSH.quote(koaPath(self))); exec node \(SSH.quote(checkoutRoot.appendingPathComponent("share/koa/testdata/replay.ts").path)) transcript testKoaWebviewComposerFocus \(SSH.quote(assets.path))"
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
        pane.canPrompt = { true }
        pane.onPrompt = { pane, quote in app.openPrompt(owner: owner, pane: pane, quote: quote) }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Prompt with Selection…", action: #selector(PaneView.promptSelectionItem(_:)), keyEquivalent: "o")
        item.target = pane
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                               windowNumber: owner.window.windowNumber, context: nil, characters: "o",
                                               charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
        XCTAssertTrue(menu.performKeyEquivalent(with: key))
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
    }
}
