import AppKit
import KoClientKit
import WebKit
import XCTest
import KoClient
import KoModel
@testable import Kido

// The tests that keep the real chain: a private ko server, koa, a pi over the fake provider, and the page.
@MainActor final class KoaHostTests: AppWindowCase {
    // koa on a private fake provider, in a private home.
    private func koaBare(script: [[String: Any]] = [], env: [String: String] = [:], exec: Bool = true) async throws -> (command: String, provider: KoaProvider) {
        let home = directory.appendingPathComponent("home").resolvingSymlinksInPath(), cwd = home.appendingPathComponent("Workspace/kido")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let provider = try await KoaProvider.start(self, directory: directory, script: script, models: koaModels, settings: ["defaultThinkingLevel": "high", "defaultProvider": koaModels[0]["provider"] as Any, "defaultModel": koaModels[0]["id"] as Any], extensionModels: true)
        let visual = directory.appendingPathComponent("models.json")
        try JSONSerialization.data(withJSONObject: koaModels).write(to: visual)
        let variables = ["KOA_PROVIDER_URL": provider.baseUrl, "PATH": koaPath(self)].merging(env) { _, new in new }
        return (koaShell(self, directory: directory, home: home, session: nil, visual: visual, cwd: cwd, exec: exec, env: variables), provider)
    }

    func testKoaEditorFloatTakesFocusAndReturnsTheEditedText() async throws {
        let gate = directory.appendingPathComponent("gate"), editor = directory.appendingPathComponent("editor.sh")
        try "#!/bin/sh\nwhile [ ! -e \(SSH.quote(gate.path)) ]; do sleep 0.05; done\nprintf 'edited by editor' > \"$1\"\n".write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        let koa = try await koaBare(env: ["VISUAL": editor.path])
        try await start(pane: koa.command)
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = directory.path; owner.start()
        defer { owner.close() }
        try await wait("koa page in the owner") { owner.testSession?.activePane?.webviewView?.browser.isLoading == false && owner.testSession?.activePane?.webviewView?.browser.url?.scheme == "ko" }
        let pane = try XCTUnwrap(owner.testSession?.activePane), view = try XCTUnwrap(pane.webviewView), web = view.browser
        view.visualAttended = true
        try await webviewUntil(web, "window.composer&&document.querySelector('#status').textContent==='idle'")
        _ = try await webviewJS(web, "(()=>{composer.setText('draft');composer.focus();return true})()")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'g',ctrlKey:true,bubbles:true,cancelable:true}));return true})()")
        let floats = { owner.testModel?.layout.layout.windows.flatMap(\.floats).map(\.pane) ?? [] }
        try await wait("the editor float", within: 15) { !floats().isEmpty }
        let float = try XCTUnwrap(floats().first)
        try await wait("the float has the focus", within: 10) { owner.testModel?.selection.pane == float }
        try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('Editing…')")
        try "".write(to: gate, atomically: true, encoding: .utf8)
        try await wait("the float is gone", within: 15) { floats().isEmpty }
        try await webviewUntil(web, "composer.text()==='edited by editor'", within: 15)
        try await wait("the selection is back on koa", within: 10) { owner.testModel?.selection.pane == pane.pane }
    }

    func testKoaInterruptRestoresNativeInput() async throws {
        WebviewPaneView.visualInitialScript = "document.hasFocus=()=>true;window.requestAnimationFrame=callback=>setTimeout(()=>callback(performance.now()),0);window.cancelAnimationFrame=clearTimeout;"
        defer { WebviewPaneView.visualInitialScript = nil }
        let koa = try await koaBare(exec: false)
        try await start(pane: "trap ':' INT; " + koa.command + "; " + rawScript)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("koa page") { pane.webviewView != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        try await wait("koa document loaded") { web.url?.scheme == "ko" && !web.isLoading }
        try await webviewUntil(web, "document.getElementById('prompt') !== null")
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: web) == true, "A page in the focused pane starts with the WKWebView as first responder")
        try await webviewUntil(web, "window.composer&&document.querySelector('#status').textContent==='idle'")
        let accent = try XCTUnwrap(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        let expectedFocus = "rgba(\(Int(accent.redComponent * 255)),\(Int(accent.greenComponent * 255)),\(Int(accent.blueComponent * 255)),0.5)"
        let pageFocus = try await webviewJS(web, "getComputedStyle(document.documentElement).getPropertyValue('--ko-focus').trim()")
        XCTAssertEqual(pageFocus, String(data: try JSONSerialization.data(withJSONObject: expectedFocus, options: .fragmentsAllowed), encoding: .utf8))
        _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();return true})()")
        let unfocused = try await webviewJS(web, "(()=>{const field=document.getElementById('field');const reference=document.createElement('div');reference.style.color=getComputedStyle(document.documentElement).getPropertyValue('--ko-focus');document.body.append(reference);const result=!field.matches(':focus-within')&&field.classList.contains('focus')&&getComputedStyle(field).borderTopColor===getComputedStyle(reference).color;reference.remove();return result})()")
        XCTAssertEqual(unfocused, "true", "The composer keeps the focus border when focus moves to the transcript")
        _ = try await webviewJS(web, "(()=>{window.composer.focus();return true})()")
        try await webviewUntil(web, "window.composer&&document.querySelector('#status').textContent==='idle'")
        _ = try await webviewJS(web, "(()=>{const reference=document.createElement('div');reference.style.color='var(--ko-cursor)';document.body.append(reference);window.expectedCursorColor=getComputedStyle(reference).color;reference.remove();return true})()")
        try await webviewUntil(web, "document.querySelector('#prompt .cm-cursor')&&getComputedStyle(document.querySelector('#prompt .cm-cursor')).display!=='none'")
        let cursorStyle = try await webviewJS(web, "(()=>{const cursor=document.querySelector('#prompt .cm-cursor'),style=getComputedStyle(cursor);return {display:style.display,height:cursor.getBoundingClientRect().height,width:style.borderLeftWidth,color:style.borderLeftColor,expected:window.expectedCursorColor,caret:getComputedStyle(document.querySelector('#prompt .cm-content')).caretColor}})()")
        let visibleCursor = try await webviewJS(web, "(()=>{const cursor=document.querySelector('#prompt .cm-cursor'),style=getComputedStyle(cursor);return style.display!=='none'&&cursor.getBoundingClientRect().height>0&&parseFloat(style.borderLeftWidth)>0&&style.borderLeftColor===window.expectedCursorColor&&getComputedStyle(document.querySelector('#prompt .cm-content')).caretColor==='rgba(0, 0, 0, 0)'})()")
        XCTAssertEqual(visibleCursor, "true", cursorStyle)
        _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();return true})()")
        try await webviewUntil(web, "Array.from(document.querySelectorAll('#prompt .cm-cursor')).every(cursor=>getComputedStyle(cursor).display==='none')")
        _ = try await webviewJS(web, "(()=>{window.composer.focus();return true})()")
        let result = try await webviewJS(web, #"""
        (async()=>{
          const requests=[], original=window.fetch;
          window.fetch=(raw,options,path=String(raw).split('?')[0])=>path==='/history'?Promise.resolve({ok:true,json:async()=>({entries:['recent prompt','earlier prompt','!!echo quiet','!echo normal']})}):path==='/queue/clear'?(requests.push({path}),Promise.resolve({ok:true,json:async()=>({steering:[{text:'queued steer',attachments:[]}],followUp:[]})})):['/prompt','/quit'].includes(path)?(requests.push({path,...JSON.parse(options.body)}),Promise.resolve({ok:true,json:async()=>({})})):original(raw,options);
          const input=document.querySelector('#prompt .cm-content'), editor=window.composer;
          const key=(key,options={})=>{const event=new KeyboardEvent('keydown',{key,keyCode:key.length===1?key.toUpperCase().charCodeAt(0):({Enter:13,Tab:9,Escape:27}[key]||0),bubbles:true,cancelable:true,...options});input.dispatchEvent(event);return event.defaultPrevented};
          const sent=async(text,options,mode)=>{editor.setText(text);const handled=key('Enter',options);await Promise.resolve();await Promise.resolve();await Promise.resolve();return handled&&requests.at(-1)?.text===text&&requests.at(-1)?.mode===mode};
          try {
            editor.focus();
            if(!await sent('send',{},'prompt'))return 'Return';
            editor.setText('line');key('Enter',{shiftKey:true});if(editor.text()!=='line\n')return 'Shift Return';
            for(const [text,expected] of [['- item','- item\n- '],['2. item','2. item\n3. '],['> quote','> quote\n> '],['- [x] item','- [x] item\n- [ ] '],['- ','']]){editor.setText(text);key('Enter',{shiftKey:true});if(editor.text()!==expected)return 'markup continuation '+JSON.stringify({text,actual:editor.text(),expected})}
            editor.setText('- item');for(let i=0;i<4;i++)key('ArrowLeft');key('Backspace');if(editor.text()!=='item')return 'markup Backspace';editor.setText('plain');key('Backspace');if(editor.text()!=='plai')return 'plain Backspace';
            if(!await sent('- item',{},'prompt'))return 'markup Return';
            if(!await sent('follow',{altKey:true},'follow_up'))return 'Option Return';
            editor.setText('draft');const count=requests.length;key('d',{ctrlKey:true});key('c',{ctrlKey:true});if(requests.length!==count||editor.text()!=='draft')return 'Control keys';
            key('Escape');if(editor.text()!=='draft')return 'first Escape';key('Escape');if(editor.text()!=='')return 'second Escape';
            key('d',{ctrlKey:true});if(requests.at(-1)?.path!=='/quit')return 'Control D';
            editor.setText('base');editor.insert('history');const before=editor.text();key('z',{metaKey:true});if(editor.text()===before)return 'undo';key('Z',{metaKey:true,shiftKey:true});if(editor.text()!==before)return 'redo';
            const historyTick=async()=>{for(let i=0;i<8;i++)await Promise.resolve()};
            editor.setText('unfinished');key('ArrowUp');if(editor.text()!=='unfinished')return 'history first Up';key('ArrowUp');await historyTick();if(editor.text()!=='recent prompt')return 'history recall';key('ArrowDown');await historyTick();if(editor.text()!=='unfinished')return 'history draft';
            editor.setText('');for(let i=0;i<3;i++){key('ArrowUp');await historyTick()}if(editor.text()!=='!!echo quiet'||!editor.bash()?.excludeFromContext||!document.querySelector('#field').classList.contains('bash-mode'))return 'quiet bash history';
            key('ArrowUp');await historyTick();if(editor.text()!=='!echo normal'||editor.bash()?.excludeFromContext!==false)return 'bash history Up';key('ArrowDown');await historyTick();if(editor.text()!=='!!echo quiet'||!editor.bash()?.excludeFromContext)return 'bash history Down';key('ArrowDown');await historyTick();if(editor.text()!=='earlier prompt'||editor.bash()||document.querySelector('#field').classList.contains('bash-mode'))return 'leave bash history';
            editor.setText('word '.repeat(80));key('ArrowUp');await historyTick();if(editor.text()!=='word '.repeat(80))return 'history visual line';
            editor.setText('draft');key('ArrowUp',{altKey:true});key('ArrowUp',{altKey:true});await historyTick();if(requests.filter(r=>r.path==='/queue/clear').length!==1||requests.some(r=>r.path==='/abort')||editor.text()!=='draft\n\nqueued steer')return 'Option Up';
            if(!key('Tab'))return 'Tab';
            editor.setText('');const transfer=new DataTransfer();transfer.setData('text/plain','pasted\nplain');transfer.setData('text/html','<b>other</b>');input.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:transfer}));if(editor.text()!=='pasted\nplain')return 'paste';
            editor.setText('- composed');const prior=requests.length, composed=editor.text();input.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));for(const options of [{},{shiftKey:true},{altKey:true}])key('Enter',{isComposing:true,...options});input.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}));if(requests.length!==prior||editor.text()!==composed)return 'composition keymap';
            return 'ok';
          } finally {window.fetch=original;}
        })()
        """#)
        XCTAssertEqual(result, "\"ok\"")
        _ = try await webviewJS(web, "(()=>{window.imeRequests=[];window.imeEvents=[];window.imeFetch=window.fetch;window.fetch=(path,options)=>path==='/prompt'?(imeRequests.push(JSON.parse(options.body)),Promise.resolve({ok:true,json:async()=>({})})):imeFetch(path,options);const input=document.querySelector('#prompt .cm-content');for(const name of ['compositionstart','compositionend','keydown','beforeinput','input'])input.addEventListener(name,event=>imeEvents.push({type:event.type,key:event.key,code:event.keyCode,trusted:event.isTrusted,inputType:event.inputType}));return true})()")
        let inputClient = try XCTUnwrap(window.firstResponder as? NSTextInputClient, "Native composer input client: \(String(describing: window.firstResponder))")
        let commit = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        // @codemirror/view treats the first Safari key within 100 ms after compositionend as an input-method commit key.
        // Native marked-text calls cannot simulate an input method that consumes Return.
        _ = try await webviewJS(web, "(()=>{window.composer.setText('draft');window.composer.focus();return true})()")
        inputClient.setMarkedText("候", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await webviewUntil(web, "window.composer.text()==='draft候'")
        inputClient.insertText("候", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await webviewUntil(web, "imeEvents.some(event=>event.type==='compositionend')")
        let committed = try await webviewJS(web, "(()=>{const start=imeEvents.findIndex(e=>e.type==='compositionstart'),end=imeEvents.findIndex(e=>e.type==='compositionend');return {text:window.composer.text(),requests:imeRequests,events:imeEvents,ordered:start>=0&&end>start&&imeEvents.every(e=>e.trusted)}})()")
        XCTAssertTrue(committed.contains("\"ordered\":true"), committed)
        XCTAssertTrue(committed.contains("\"text\":\"draft候\""), committed)
        XCTAssertTrue(committed.contains("\"requests\":[]"), committed)
        _ = try await webviewJS(web, "new Promise(resolve=>setTimeout(()=>resolve(true),200))")
        window.sendEvent(commit)
        try await webviewUntil(web, "imeRequests.length===1")
        let delayed = try await webviewJS(web, "({text:window.composer.text(),requests:imeRequests,lineBreak:imeEvents.some(e=>e.inputType==='insertLineBreak'||e.inputType==='insertParagraph')})")
        XCTAssertTrue(delayed.contains("\"text\":\"\""), delayed)
        XCTAssertTrue(delayed.contains("\"text\":\"draft候\""), delayed)
        XCTAssertTrue(delayed.contains("\"lineBreak\":false"), delayed)
        _ = try await webviewJS(web, "(()=>{window.fetch=window.imeFetch;return true})()")
        try XCTUnwrap(pane.koView).text(Data([3]))
        try await wait("koa left its page") { pane.webviewView == nil }
        XCTAssertTrue(window.firstResponder === pane, "Interrupting koa restores the terminal first responder")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        window.sendEvent(event)
        try await koUntil(directory.path, "/panes/\(pane.pane)/screen", contains: "z")
    }
    func testKoaFeedHeldTail() async throws {
        let part = String(repeating: "x", count: 4096)
        let koa = try await koaBare(script: [["chunks": [part], "stages": [["gate": "f2", "chunks": [part]], ["gate": "f3", "chunks": [part]]], "tokens": ["prompt": 83990, "completion": 10]]])
        try await start(width: 980, height: 560, pane: koa.command)
        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = host
        host.addSubview(session)
        session.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            session.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
            session.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            session.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
            session.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        koaContentSize(window: window, width: 980, height: 560)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("koa webview", within: 20) { (pane.webviewView?.visualDocuments ?? 0) > 0 }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#model-name').textContent==='claude-opus-5-5'")
        pane.webviewView?.visualFeedPath = "/events"
        pane.webviewView?.visualFeedScript = #"""
        const NativeEventSource=EventSource;
        window.EventSource=class extends NativeEventSource{constructor(...args){super(...args);window.feedSource=this}};
        """#
        web.reload()
        try await wait("reloaded feed", within: 10) { !web.isLoading }
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#model-name').textContent==='claude-opus-5-5'")
        for index in 1...3 {
            let before = pane.webviewView!.visualFeedBytes
            if index == 1 {
                let response = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'next',mode:'prompt',attachments:[]})}).then(async r=>({status:r.status,body:await r.json()}))")
                XCTAssertTrue(response.contains("\"status\":200"), response)
            } else { koa.provider.release("f\(index)") }
            try await wait("feed chunk \(index) handed to WebKit", within: 5) { pane.webviewView!.visualFeedBytes > before + 4096 }
        }
        let handed = pane.webviewView!.visualFeedBytes
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('.assistant p')?.textContent==='x'.repeat(12288)", within: 5)
        XCTAssertEqual(pane.webviewView!.visualFeedBytes, handed)
        let open = try await webviewJS(web, "feedSource.readyState===EventSource.OPEN")
        XCTAssertEqual(open, "true")
        let final = try await webviewJS(web, "document.querySelector('.assistant p').textContent")
        XCTAssertEqual(final, "\"" + String(repeating: "x", count: 12288) + "\"")
    }
    func testKoaLifecyclePromptFeedQuitReturnsToTerminal() async throws {
        let koa = try await koaBare(script: [["text": "The sweep keeps a start failure for the linger grace.", "tokens": ["prompt": 83990, "completion": 10]]], exec: false)
        try await start(pane: koa.command + "; " + rawScript)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("koa page") { pane.webviewView != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        try await wait("koa document loaded") { web.url?.scheme == "ko" && !web.isLoading }
        try await webviewUntil(web, "window.composer&&document.querySelector('#status').textContent==='idle'&&document.querySelector('#model-name').textContent==='claude-opus-5-5'")
        let response = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'Make the sweep keep a start failure',mode:'prompt',attachments:[]})}).then(async r=>({status:r.status,body:await r.json()}))")
        XCTAssertTrue(response.contains("\"status\":200"), response)
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('.user')!==null&&document.querySelector('.assistant p')?.textContent==='The sweep keeps a start failure for the linger grace.'", within: 20)
        _ = try await webviewJS(web, "fetch('/quit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.status)")
        try await wait("koa left its page") { pane.webviewView == nil }
        window.makeFirstResponder(pane)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        window.sendEvent(event)
        try await koUntil(directory.path, "/panes/\(pane.pane)/screen", contains: "z")
    }
}
