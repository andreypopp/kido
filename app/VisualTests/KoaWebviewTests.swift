import AppKit
import KoClientKit
import WebKit
import XCTest
import KoClient
import KoModel
import SidebarFeed
@testable import Kido

@MainActor final class KoaWebviewTests: AppWindowCase {
    private enum KoaScenario { case transcript, dialogs, controls, exit, feed, completion, markdown, media, attachments, userMarkdown, thinkingMarkdown, reveal, preview, lightbox, agents, composer, questions, bang, commands, notices, sessions }
    func testKoaWebviewSubmitFollowsClampedBottom() async throws {
        WebviewPaneView.visualInitialScript = "const ClockDate=Date;window.Date=class extends ClockDate{constructor(...args){super(...(args.length?args:[1700000012000]))}static now(){return 1700000012000}};window.requestAnimationFrame=callback=>setTimeout(()=>callback(performance.now()),16);window.cancelAnimationFrame=clearTimeout;const Source=EventSource;window.EventSource=class extends Source{constructor(...args){super(...args);window.scrollSource=this}};"
        defer { WebviewPaneView.visualInitialScript = nil }
        let stamp = 1700000000000, question = Array(repeating: "Keep the cache?", count: 12).joined(separator: "\n\n")
        let usage: [String: Any] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]
        let history: [String: Any] = ["role": "user", "timestamp": stamp - 1, "content": [["type": "text", "text": Array(repeating: "Earlier message", count: 80).joined(separator: "\n\n")]]]
        let reply: [String: Any] = ["role": "assistant", "api": "test", "provider": "test", "model": "test", "usage": usage, "timestamp": stamp, "stopReason": "stop", "content": [["type": "text", "text": question]]]
        let entry: [String: Any] = ["type": "custom", "id": "question", "parentId": NSNull(), "customType": "reply-annotations", "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(stamp + 1) / 1000)), "data": ["reply": ["at": stamp, "block": 0, "length": question.count], "annotations": [["type": "question", "kind": "yes_no", "range": [0, question.count]]]]]
        let steps: [[String: Any]] = [["type": "respond", "command": "get_messages", "data": ["messages": [history, reply]]], ["type": "respond", "command": "get_entries", "data": ["entries": [entry], "leafId": "question"]]]
        let script = directory.appendingPathComponent("scroll-trace.jsonl")
        try steps.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        let fake = checkoutRoot.appendingPathComponent("share/koa/koa-fake-pi.ts").path
        try await start(pane: "export KOA_FAKE_SCRIPT=\(SSH.quote(script.path)); \(SSH.quote(tools.prefix + "/share/ko/bin/koa")) --pi \(SSH.quote(fake))")
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("koa page") { pane.webviewView != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        try await wait("koa document loaded") { web.url?.scheme == "ko" && !web.isLoading }
        try await webviewUntil(web, "window.composer&&document.querySelector('.ann-opt')&&document.querySelector('#status').textContent==='idle'")
        let result = try await webviewJS(web, #"""
        (async()=>{
          const s=document.querySelector('#scroll'),dock=document.querySelector('#dock'),results=[],originalFetch=window.fetch,raf=window.requestAnimationFrame;
          const tick=()=>new Promise(resolve=>setTimeout(resolve,100));let seq=100;
          for(const mode of ['composer','chip','up']){
            if(mode==='chip')document.querySelector('.ann-opt').click();else composer.setText(Array(20).fill('Submitted paragraph').join('\n\n'));
            await tick();s.scrollTop=mode==='up'?200:s.scrollHeight;s.dispatchEvent(new Event('scroll'));await tick();
            const frames=[],before=s.scrollTop;let pending,clamped;
            window.requestAnimationFrame=callback=>(frames.push(callback),frames.length);
            window.fetch=async(path,options)=>{if(path!=='/prompt')return originalFetch(path,options);pending=JSON.parse(options.body).text;return {ok:true,json:async()=>({})}};
            await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{observer.disconnect();reject(Error('No dock clamp'))},10000);const observer=new ResizeObserver(()=>{if(pending===undefined||composer.text()||dock.getBoundingClientRect().height>100)return;void s.scrollHeight;clamped=s.scrollTop;if(mode!=='up'&&clamped>=before){observer.disconnect();clearTimeout(timer);reject(Error('Expected the dock shrink to clamp scrollTop'));return}scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'item',item:{kind:'user',seq:seq++,revision:0,at:Date.now(),final:true,text:pending,images:[],attachments:[]}})}));pending=undefined;observer.disconnect();clearTimeout(timer);resolve()});observer.observe(dock);document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));});
            s.dispatchEvent(new Event('scroll'));window.requestAnimationFrame=raf;for(const callback of frames)callback(performance.now());await tick();
            window.fetch=originalFetch;results.push({mode,before,clamped,top:s.scrollTop,distance:s.scrollHeight-s.scrollTop-s.clientHeight,bottom:s.scrollHeight-s.scrollTop-s.clientHeight<1&&document.querySelector('.user:last-child').getBoundingClientRect().bottom<=dock.getBoundingClientRect().top,stationary:s.scrollTop===200});
          }
          s.scrollTop=s.scrollHeight;s.dispatchEvent(new Event('scroll'));await tick();
          const bottom=s.scrollTop;s.scrollTop=bottom-.5;
          if(s.scrollTop===bottom-.5){
            for(let i=1;i<=130;i++){s.scrollTop=bottom-i*.5;s.dispatchEvent(new Event('scroll'))}
            const top=s.scrollTop;
            scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'item',item:{kind:'user',seq:seq++,revision:0,at:Date.now(),final:true,text:'After fractional scroll up',images:[],attachments:[]}})}));await tick();
            results.push({mode:'fractional-up',stationary:s.scrollTop===top});
            const end=s.scrollHeight-s.clientHeight;
            for(let next=s.scrollTop;next<end;next+=.5){s.scrollTop=next;s.dispatchEvent(new Event('scroll'))}
            s.scrollTop=end;s.dispatchEvent(new Event('scroll'));
            scrollSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({type:'item',item:{kind:'user',seq:seq++,revision:0,at:Date.now(),final:true,text:'After fractional scroll down',images:[],attachments:[]}})}));await tick();
            results.push({mode:'fractional-down',bottom:s.scrollHeight-s.scrollTop-s.clientHeight<1});
          }else results.push({mode:'fractional-unsupported'});
          return results;
        })()
        """#, within: 30)
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]])
        for result in results {
            let mode = result["mode"] as? String
            if mode == "fractional-unsupported" { NSLog("WK rounds scrollTop; skip the sub-pixel case"); continue }
            XCTAssertEqual(result[mode == "up" || mode == "fractional-up" ? "stationary" : "bottom"] as? Bool, true, String(describing: result))
        }
    }
    func testKoaEditorFloatTakesFocusAndReturnsTheEditedText() async throws {
        let script = directory.appendingPathComponent("script"), gate = directory.appendingPathComponent("gate"), editor = directory.appendingPathComponent("editor.sh")
        try "".write(to: script, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nwhile [ ! -e \(SSH.quote(gate.path)) ]; do sleep 0.05; done\nprintf 'edited by editor' > \"$1\"\n".write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        let path = [tools.prefix + "/bin", "/opt/homebrew/bin", ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let fake = checkoutRoot.appendingPathComponent("share/koa/koa-fake-pi.ts").path
        try await start(pane: "export PATH=\(SSH.quote(path)) VISUAL=\(SSH.quote(editor.path)) KOA_FAKE_SCRIPT=\(SSH.quote(script.path)); exec \(SSH.quote(tools.prefix + "/share/ko/bin/koa")) --pi \(SSH.quote(fake))")
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
        try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('Editing in editor.sh')")
        try "".write(to: gate, atomically: true, encoding: .utf8)
        try await wait("the float is gone", within: 15) { floats().isEmpty }
        try await webviewUntil(web, "composer.text()==='edited by editor'", within: 15)
        try await wait("the selection is back on koa", within: 10) { owner.testModel?.selection.pane == pane.pane }
    }

    func testKoaInterruptRestoresNativeInput() async throws {
        WebviewPaneView.visualInitialScript = "document.hasFocus=()=>true;window.requestAnimationFrame=callback=>setTimeout(()=>callback(performance.now()),0);window.cancelAnimationFrame=clearTimeout;"
        defer { WebviewPaneView.visualInitialScript = nil }
        let script = directory.appendingPathComponent("quit-script.jsonl")
        try "".write(to: script, atomically: true, encoding: .utf8)
        let fake = checkoutRoot.appendingPathComponent("share/koa/koa-fake-pi.ts").path
        try await start(pane: "trap ':' INT; export KOA_FAKE_SCRIPT=\(SSH.quote(script.path)); \(SSH.quote(tools.prefix + "/share/ko/bin/koa")) --pi \(SSH.quote(fake)); " + rawScript)
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
          window.fetch=(path,options)=>path==='/history'?Promise.resolve({ok:true,json:async()=>({entries:['recent prompt','earlier prompt','!!echo quiet','!echo normal']})}):path==='/queue/clear'?(requests.push({path}),Promise.resolve({ok:true,json:async()=>({steering:[{text:'queued steer',attachments:[]}],followUp:[]})})):['/prompt','/quit'].includes(path)?(requests.push({path,...JSON.parse(options.body)}),Promise.resolve({ok:true,json:async()=>({})})):original(path,options);
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

    func testKoaWebviewBangCompletionWide() async throws {
        try await koaWebview(width: 980, height: 360, scenario: .bang, captures: ["bang-tab", "bang-tab-cap", "bang-tab-none", "bang-tab-pending"])
    }
    func testKoaWebviewBangCompletionNarrow() async throws {
        try await koaWebview(width: 470, height: 360, scenario: .bang, captures: ["narrow-bang-tab", "narrow-bang-tab-cap", "narrow-bang-tab-none", "narrow-bang-tab-pending"])
    }
    func testKoaWebviewBangWide() async throws {
        try await koaWebview(width: 980, height: 220, scenario: .bang, captures: ["bang", "bang2", "bang-attachments", "bang-drop", "bang-runs", "bang-done", "bang-error", "bang-cancelled", "bang-truncated", "bang-quiet", "bang-running", "bang-typing", "bang-busy", "bang-completed"])
    }
    func testKoaWebviewBangNarrow() async throws {
        try await koaWebview(width: 470, height: 220, scenario: .bang, captures: ["narrow-bang", "narrow-bang2", "narrow-bang-attachments", "narrow-bang-drop", "narrow-bang-runs", "narrow-bang-done", "narrow-bang-error", "narrow-bang-cancelled", "narrow-bang-truncated", "narrow-bang-quiet", "narrow-bang-running", "narrow-bang-typing", "narrow-bang-busy", "narrow-bang-completed"])
    }
    func testKoaWebviewComposerFootResponsive() async throws {
        try await koaWebview(width: 674, height: 300, scenario: .composer, captures: ["foot-responsive"])
    }
    func testKoaWebviewComposerFootIdleWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-idle"])
    }
    func testKoaWebviewComposerFootIdleNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-idle"])
    }
    func testKoaWebviewComposerFootWorkingWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-working"])
    }
    func testKoaWebviewComposerFootWorkingNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-working"])
    }
    func testKoaWebviewComposerFootWaitingWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-waiting"])
    }
    func testKoaWebviewComposerFootWaitingNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-waiting"])
    }
    func testKoaWebviewComposerFootExitedWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-exited"])
    }
    func testKoaWebviewComposerFootExitedNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-exited"])
    }
    func testKoaWebviewComposerFootPickerWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .composer, captures: ["foot-picker"])
    }
    func testKoaWebviewComposerFootPickerNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .composer, captures: ["narrow-foot-picker"])
    }
    func testKoaWebviewComposerFootNoticeWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-toast"])
    }
    func testKoaWebviewComposerFootNoticeNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-toast"])
    }
    func testKoaWebviewComposerFootErrorNoticeWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-toast-err"])
    }
    func testKoaWebviewComposerFootErrorNoticeNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-toast-err"])
    }
    func testKoaWebviewComposerFootLongWorkingWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-narrow"])
    }
    func testKoaWebviewComposerFootLongWorkingNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-narrow"])
    }

    func testKoaWebviewComposerFootStatusesWide() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .composer, captures: ["foot-extras"])
    }
    func testKoaWebviewComposerFootStatusesNarrow() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .composer, captures: ["narrow-foot-extras"])
    }
    func testKoaWebviewComposerStateGeometryWide() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["geometry"])
    }
    func testKoaWebviewComposerStateGeometryNarrow() async throws {
        try await koaWebview(width: 470, height: 560, captures: ["geometry"])
    }
    func testKoaWebviewFocusBorderTranscript() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["focus-border-transcript"])
    }

    func testKoaWebviewFocusBorderDialog() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .dialogs, captures: ["focus-border-dialog"])
    }

    func testKoaWebviewComposerFocus() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["focus"])
    }
    func testKoaWebviewFeedHeldTail() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .feed, captures: [])
    }
    func testKoaWebviewCommandsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .commands, captures: Set(["copy", "export", "refused", "session-closed", "session-open", "compacting", "compacted-open", "compact-cancelled", "compact-failed", "popup"].map { "commands-" + $0 }))
    }

    func testKoaWebviewCommandsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .commands, captures: Set(["copy", "export", "refused", "session-closed", "session-open", "compacting", "compacted-open", "compact-cancelled", "compact-failed", "popup", "export-open"].map { "narrow-commands-" + $0 }))
    }

    func testKoaWebviewMockupStates() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["user-well", "stream", "lines", "details"])
    }

    func testKoaWebviewNoticesWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .notices, captures: Set(["closed", "open"].map { "notices-" + $0 }))
    }

    func testKoaWebviewNoticesNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .notices, captures: Set(["closed", "open"].map { "narrow-notices-" + $0 }))
    }

    func testKoaWebviewErrorState() async throws {
        try await koaWebview(width: 980, height: 593, captures: ["error"])
    }

    func testKoaWebviewShortStates() async throws {
        try await koaWebview(width: 980, height: 300, captures: ["idle", "composer-multi", "composer-working", "run-running", "run-done"])
    }

    func testKoaWebviewNarrowStates() async throws {
        try await koaWebview(width: 470, height: 560, captures: ["narrow-stream", "narrow-details"])
    }

    func testKoaWebviewDialogs() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .dialogs, captures: ["dialog-select", "dialog-editor"])
    }

    func testKoaWebviewDialogFields() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .dialogs, captures: ["dialog-confirm", "dialog-input"])
    }

    func testKoaWebviewControls() async throws {
        try await koaWebview(width: 980, height: 300, scenario: .controls, captures: ["queue", "picker-model", "picker-thinking", "toast-info", "toast-warn", "toast-error"])
    }

    func testKoaWebviewNarrowControls() async throws {
        try await koaWebview(width: 470, height: 300, scenario: .controls, captures: ["narrow-queue", "narrow-picker-model", "narrow-toast-warn"])
    }

    func testKoaWebviewExit() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .exit, captures: ["exited", "times"])
    }

    func testKoaWebviewNarrowExit() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .exit, captures: ["narrow-exited"])
    }

    func testKoaWebviewAgentsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .agents, captures: Set(["out", "failed", "in", "jobs", "fold-a", "fold-b", "tools"].map { "agents-" + $0 }))
    }

    func testKoaWebviewAgentsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .agents, captures: Set(["out", "failed", "in", "jobs", "fold-a", "fold-b", "tools"].map { "narrow-agents-" + $0 }))
    }

    func testKoaWebviewLightbox() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .lightbox, captures: ["media-lightbox"])
    }

    func testKoaWebviewPreviewHover() async throws {
        try await koaWebview(width: 980, height: 400, scenario: .preview, captures: ["media-preview-hover"])
    }

    func testKoaWebviewMediaWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .media, captures: ["media-read-image", "media-user-images", "media-image-gone"])
    }

    func testKoaWebviewMediaNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .media, captures: ["narrow-media-read-image", "narrow-media-user-images", "narrow-media-image-gone"])
    }

    func testKoaWebviewAttachmentsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .attachments, captures: Set(["chips", "drop", "folder", "queue", "sent"].map { "media-" + $0 }))
    }

    func testKoaWebviewAttachmentsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .attachments, captures: Set(["chips", "drop", "folder", "queue", "sent"].map { "narrow-media-" + $0 }))
    }

    func testKoaWebviewUserMarkdownWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .userMarkdown, captures: ["user-markdown", "user-quote", "user-quote2", "user-code"])
    }

    func testKoaWebviewUserMarkdownNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .userMarkdown, captures: ["narrow-user-markdown", "narrow-user-quote", "narrow-user-quote2", "narrow-user-code"])
    }

    func testKoaWebviewReveal() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .reveal, captures: ["reveal-fold", "reveal-mid"])
    }

    func testKoaWebviewThinkingMarkdownWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .thinkingMarkdown, captures: ["thinking-markdown"])
    }

    func testKoaWebviewThinkingMarkdownNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .thinkingMarkdown, captures: ["narrow-thinking-markdown"])
    }

    func testKoaWebviewComposerMarkdown() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .markdown, captures: ["composer-markdown", "composer-markdown-code"])
    }

    func testKoaWebviewQuestionsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .questions, captures: ["questions-reply", "questions-answered", "questions-ordered"])
    }

    func testKoaWebviewQuestionsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .questions, captures: ["narrow-questions-reply", "narrow-questions-answered", "narrow-questions-ordered"])
    }

    func testKoaWebviewCompletionWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .completion, captures: Set(["slash-all", "slash-filter", "at-agents", "at-files", "at-mid", "none"].map { "complete-" + $0 }))
    }

    func testKoaWebviewCompletionNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .completion, captures: Set(["slash-all", "slash-filter", "at-agents", "at-files", "at-mid", "none"].map { "narrow-complete-" + $0 }))
    }

    func testKoaWebviewSessionsWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .sessions, captures: Set(["pick", "all", "filtered", "empty", "no-match", "loading", "after", "new", "confirm", "confirm-bash"].map { "sessions-" + $0 }))
    }

    func testKoaWebviewSessionsNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .sessions, captures: Set(["pick", "all", "filtered", "empty", "no-match", "loading", "after", "new", "confirm", "confirm-bash"].map { "narrow-sessions-" + $0 }))
    }

    private func koaContentSize(window: NSWindow, width: CGFloat, height: CGFloat) {
        let chrome = window.frame.height - window.contentLayoutRect.height
        window.setContentSize(NSSize(width: width, height: height + chrome))
    }

    private func koaBangCompletion(web: WKWebView, window: NSWindow, width: CGFloat, capture: (String) async throws -> Void) async throws {
            let prefix = width < 750 ? "narrow-" : ""
            _ = try await webviewJS(web, #"(()=>{window.tabFetch=window.fetch;window.tabRequests=0;window.tabResolve=null;window.tabKind='list';window.fetch=(url,options)=>{if(url!='/complete')return tabFetch(url,options);tabRequests++;const q=JSON.parse(options.body),from=q.text.lastIndexOf(' ')+1;let result={type:'shell',from,to:q.text.length,common:'verify',more:0,options:['verify','verify-app','verify-linux','verify-rs','verify-ts'].map(label=>({label,insert:label+' ',cursor:label.length+1}))};if(tabKind==='none')result.options=[];if(tabKind==='cap'){result.common='/usr/bin/';result.more=184;result.options=['2to3-','AssetCacheLocatorUtil','AssetCacheManagerUtil','AssetCacheTetheratorUtil','DeRez','GetFileInfo','IOAccelMemory','IOMPSCompiler','ResMerger','Rez','SafeEjectGPU','SetFile','SplitForks'].map(label=>({label,insert:'/usr/bin/'+label+' ',cursor:10+label.length}))}return tabKind==='pending'?new Promise(resolve=>{window.tabResolve=()=>resolve({ok:true,json:async()=>result})}):Promise.resolve({ok:true,json:async()=>result})};window.tabKey=key=>document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key,code:key==='Tab'?'Tab':key,bubbles:true,cancelable:true}));window.composer.setText('!make ver');tabKey('Tab');return true})()"#)
            try await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null&&window.composer.text()==='!make verify'")
            try await capture(prefix + "bang-tab")
            let resetClosed = try await webviewJS(web, "(()=>{window.composer.resetCompletion();return !document.querySelector('.koa-complete')})()")
            XCTAssertEqual(resetClosed, "true", "Session reset closes the real editor completion")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make ver');tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null")
            let typedClosed = try await webviewJS(web, "(()=>{window.composer.insert('x');return !document.querySelector('.koa-complete')})()")
            XCTAssertEqual(typedClosed, "true", "Typing closes completion without a nested editor update")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make ver');window.tabRequests=0;tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('.koa-complete.sh')!==null")
            _ = try await webviewJS(web, "(()=>{tabKey('Tab');return true})()")
            let moved = try await webviewJS(web, "document.querySelector('.koa-complete li[aria-selected]')?.textContent==='verify-app'&&tabRequests===1")
            XCTAssertEqual(moved, "true")
            _ = try await webviewJS(web, "(()=>{tabKey('Enter');return true})()")
            let accepted = try await webviewJS(web, "window.composer.text()==='!make verify-app '&&!document.querySelector('.koa-complete')")
            XCTAssertEqual(accepted, "true")
            _ = try await webviewJS(web, "(()=>{tabKey('Escape');window.tabKind='cap';window.composer.setText('!ls /usr/bin/');tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('.koa-complete .more')!==null")
            _ = try await webviewJS(web, "(()=>{const list=document.querySelector('.koa-complete ul');list.scrollTop=list.scrollHeight;return true})()")
            let contained = try await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),user=document.querySelector('.user').getBoundingClientRect();return popup.top>=user.bottom&&popup.bottom<=dock.top})()")
            XCTAssertEqual(contained, "true", "Shell completion stays in the transcript above the dock")
            try await capture(prefix + "bang-tab-cap")
            koaContentSize(window: window, width: width, height: 220)
            window.contentView?.layoutSubtreeIfNeeded()
            web.superview?.layoutSubtreeIfNeeded()
            try await webviewUntil(web, "(()=>{const popup=document.querySelector('.koa-complete')?.getBoundingClientRect(),dock=document.querySelector('#dock').getBoundingClientRect(),list=document.querySelector('.koa-complete ul');return innerHeight<250&&!!popup&&popup.top>=0&&popup.bottom<=dock.top&&list.scrollHeight>list.clientHeight})()")
            _ = try await webviewJS(web, "(()=>{tabKey('Escape');window.tabKind='none';window.composer.setText('!make checkz');window.tabTimeout=window.setTimeout;window.setTimeout=(fn,ms,...args)=>ms===1500?(window.tabNone=fn,0):tabTimeout(fn,ms,...args);tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='no completions'")
            try await capture(prefix + "bang-tab-none")
            _ = try await webviewJS(web, "(()=>{window.setTimeout=window.tabTimeout;tabNone();return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='run'")
            _ = try await webviewJS(web, "(()=>{window.tabKind='pending';window.composer.setText('!git checkout kido-');tabKey('Tab');tabKey('Tab');return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='completing…'&&document.querySelector('#dot').classList.contains('spin')")
            try await capture(prefix + "bang-tab-pending")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!git checkout other');tabResolve();return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='run'&&!document.querySelector('.koa-complete')")
            let stale = try await webviewJS(web, "window.composer.text()==='!git checkout other'&&tabRequests===4")
            XCTAssertEqual(stale, "true")
    }

    private func koaWebview(width: CGFloat, height: CGFloat, scenario: KoaScenario = .transcript, captures: Set<String>) async throws {
        let composerState = captures.first?.replacingOccurrences(of: "narrow-foot-", with: "").replacingOccurrences(of: "foot-", with: "") ?? ""
        let fake = checkoutRoot.appendingPathComponent("share/koa/koa-fake-pi.ts").path
        let script = directory.appendingPathComponent("koa-script.jsonl")
        let sessionFile = directory.appendingPathComponent("session.jsonl")
        let home = directory.appendingPathComponent("home")
        let cwd = home.appendingPathComponent("Workspace/kido")
        let attachmentPaths = (shot: home.appendingPathComponent("Desktop/Screenshot 2026-11-10 at 09.11.42.png"), diagram: home.appendingPathComponent("Desktop/diagram.png"), notes: home.appendingPathComponent("Desktop/notes.md"), source: cwd.appendingPathComponent("app/App/SidebarRow.swift"))
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["cwd": cwd.path]).write(to: sessionFile)
        let completionCaptures = captures.contains { $0.contains("bang-tab") }
        let mediaClock: Bool
        switch scenario {
        case .commands, .sessions, .media, .attachments, .preview, .lightbox, .agents, .composer: mediaClock = true
        default: mediaClock = completionCaptures
        }
        let stamp = Int(try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: mediaClock ? 10 : 8, hour: mediaClock ? 9 : 14, minute: mediaClock ? 12 : 32))).timeIntervalSince1970 * 1000)
        let measured: Bool
        switch scenario {
        case .commands, .sessions, .questions, .completion, .attachments, .userMarkdown, .thinkingMarkdown, .exit, .lightbox: measured = true
        default: measured = completionCaptures || captures.contains("focus-border-transcript") || captures.contains("focus-border-dialog")
        }
        let measurementClock = "const ClockDate=Date;window.Date=class extends ClockDate{constructor(...args){super(...(args.length?args:[\(stamp + 12000)]))}static now(){return \(stamp + 12000)}};"
        WebviewPaneView.visualInitialScript = measurementClock
        // WebKit pauses animation frames in an off-screen window.
        if measured {
            WebviewPaneView.visualInitialScript = measurementClock + "window.koaPendingFrames=new Set();window.requestAnimationFrame=callback=>{const id=setTimeout(()=>{koaPendingFrames.delete(id);callback(performance.now())},0);koaPendingFrames.add(id);return id};window.cancelAnimationFrame=id=>{koaPendingFrames.delete(id);clearTimeout(id)};"
        }
        if scenario == .reveal {
            WebviewPaneView.visualInitialScript = measurementClock + "Object.defineProperty(document,'hidden',{value:false});window.koaClock=0;window.koaFrames=new Map();window.koaFrame=0;performance.now=()=>koaClock;window.requestAnimationFrame=callback=>{koaFrames.set(++koaFrame,callback);return koaFrame};window.cancelAnimationFrame=id=>koaFrames.delete(id);const nativeTimeout=window.setTimeout,nativeClear=window.clearTimeout;window.koaTimers=new Map();window.setTimeout=(callback,ms,...args)=>{if(!(ms>=1000&&ms<=1500))return nativeTimeout(callback,ms,...args);const id=-(++koaFrame);koaTimers.set(id,{at:koaClock+ms,callback});return id};window.clearTimeout=id=>{koaTimers.delete(id);nativeClear(id)};window.koaStep=ms=>{koaClock+=ms;for(const [id,timer] of [...koaTimers])if(timer.at<=koaClock){koaTimers.delete(id);timer.callback()}for(const [id,callback] of [...koaFrames]){koaFrames.delete(id);callback(koaClock)}};"
        }
        if captures.contains("focus") || captures.contains("focus-border-transcript") || captures.contains("focus-border-dialog") {
            // The off-screen WKWebView reports no document focus.
            WebviewPaneView.visualInitialScript = "document.hasFocus=()=>true;" + (WebviewPaneView.visualInitialScript ?? "")
        }
        if captures.contains("foot-responsive") {
            WebviewPaneView.visualInitialScript = (WebviewPaneView.visualInitialScript ?? "") + "const FootSource=EventSource;window.EventSource=class extends FootSource{constructor(...args){super(...args);window.footSource=this;this.addEventListener('message',event=>{const record=JSON.parse(event.data);if(record.type==='state')window.footState=record})}};"
        }
        defer { WebviewPaneView.visualInitialScript = nil }
        let usage: [String: Any] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]
        func assistant(_ content: [[String: Any]], stop: String = "stop") -> [String: Any] {
            ["role": "assistant", "api": "test", "provider": "test", "model": "test", "usage": usage, "timestamp": stamp, "stopReason": stop, "content": content]
        }
        let user: [String: Any] = ["role": "user", "timestamp": stamp, "content": [["type": "text", "text": "Make the sweep keep a start failure for the linger grace, then test it"]]]
        let markdown = """
        ## What the sweep does

        The sweep reads the pane rows, never a process. It removes a pane with the default `close: exit` as soon as its program exits, and keeps three other kinds for a while:

        - a start failure, so the error stays readable;
        - a `close: on_exit` pane, for the linger grace;
        - a pane whose parent is gone, until no focused client shows it.

        | Cause | Removed | Keeps descendants |
        | --- | --- | --- |
        | exit | at once | no |
        | failed | linger grace | no |
        | parent gone | when unfocused | cascade |

        The cascade is the server's: every removal takes the pane's descendants in the same change.

        ```rust
        fn sweep(&mut self, now: Instant) -> Vec<PaneId> {
            let gone = self.rows.iter()
                .filter(|row| row.due(now))
                .map(|row| row.id)
                .collect::<Vec<_>>();
            gone.iter().for_each(|id| self.remove(*id));
            gone
        }
        ```

        Next I would check how `linger` interacts with a focused client that is itself
        """
        var streamUser = user
        streamUser["content"] = [["type": "text", "text": "Explain how the sweep decides what to remove, with a table"]]
        let text = assistant([["type": "text", "text": markdown]])
        let blocks: [[String: Any]] = [
            ["type": "thinking", "thinking": "The sweep needs to distinguish a start failure from a program exit. Check the close policy and preserve the focus rule."],
            ["type": "toolCall", "id": "read", "name": "read", "arguments": ["path": "ko_server/src/sweep.rs"]],
            ["type": "toolCall", "id": "edit", "name": "edit", "arguments": ["path": "ko_server/src/sweep.rs", "oldText": "    fn due(&self, now: Instant) -> bool {\n        self.exited && self.close == Close::Exit\n    }", "newText": "    fn due(&self, now: Instant) -> bool {\n        match self.close {\n            Close::Exit => self.exited && !self.failed,\n            Close::OnExit => self.dead_since.is_some_and(|t| now - t > self.linger),\n        }\n    }"]],
            ["type": "toolCall", "id": "bash", "name": "bash", "arguments": ["command": "make cargo ARGS='test -p ko_server sweep'"]]
        ]
        let calls = assistant(blocks, stop: "toolUse")
        func result(_ id: String, _ text: String, error: Bool = false) -> [String: Any] {
            ["role": "toolResult", "toolCallId": id, "toolName": id, "timestamp": stamp + (["read": 6100, "edit": 6300, "bash": 10000, "bad": 40000][id] ?? 10000), "content": [["type": "text", "text": text]], "isError": error]
        }
        let results = [result("read", Array(repeating: "    row", count: 212).joined(separator: "\n")), result("edit", "Edit applied"), result("bash", "running 3 tests\ntest sweep::tests::removes_on_exit ... ok\ntest sweep::tests::keeps_a_start_failure ... ok\ntest sweep::tests::linger_waits_for_focus ... ok\n\ntest result: ok. 3 passed; 0 failed; 0 ignored; finished in 0.41s")]
        var replayCalls = [assistant([blocks[0]])]
        for index in 1...3 {
            var call = assistant([blocks[index]], stop: "toolUse")
            call["timestamp"] = stamp + [6000, 6100, 6800][index - 1]
            replayCalls.append(call)
            replayCalls.append(results[index - 1])
        }
        var steps: [[String: Any]] = [
            ["type": "respond", "command": "get_state", "data": ["sessionName": "koa reference", "thinkingLevel": "high", "model": ["id": "claude-opus-5-5", "provider": "anthropic"], "sessionFile": sessionFile.path]],
            ["type": "respond", "command": "get_messages", "data": ["messages": []]],
            ["type": "respond", "command": "get_session_stats", "data": ["contextUsage": ["tokens": 84000, "contextWindow": 200000, "percent": 42]]]
        ]
        func prompt(_ events: [[String: Any]]) { steps.append(["type": "wait", "command": "prompt", "events": events]) }
        prompt([["type": "agent_start"]])
        prompt([["type": "message_end", "message": streamUser], ["type": "message_start", "message": text]])
        prompt([["type": "message_update", "usage": usage, "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "\n\nThe patch keeps the earlier selection.\n\n"]]])
        prompt([["type": "message_end", "message": text], ["type": "compaction_end"]])
        steps.append(["type": "respond", "command": "get_messages", "data": ["messages": [user]], "after": [["type": "message_start", "message": calls], ["type": "tool_execution_start", "toolCallId": "bash", "toolName": "bash", "args": ["command": "make cargo ARGS='test -p ko_server sweep'"]]]])
        let done = assistant([["type": "text", "text": "Done. `due()` now matches on `close`, a start failure never fires `Close::Exit`, and the three sweep tests pass."]])
        prompt([["type": "agent_settled", "aborted": false], ["type": "compaction_end"]])
        steps.append(["type": "respond", "command": "get_messages", "data": ["messages": [user] + replayCalls + [done]]])
        prompt([["type": "compaction_end"]])
        steps.append(["type": "respond", "command": "get_messages", "data": ["messages": [user] + replayCalls]])
        prompt([["type": "compaction_end"], ["type": "agent_settled", "aborted": true]])
        let errorUser: [String: Any] = ["role": "user", "timestamp": stamp, "content": [["type": "text", "text": "Run the whole unit stage"]]]
        let failedRead = assistant([["type": "toolCall", "id": "failed-read", "name": "read", "arguments": ["path": "Makefile"]]], stop: "toolUse")
        var failedReadResult = result("failed-read", Array(repeating: "    target", count: 388).joined(separator: "\n"))
        failedReadResult["timestamp"] = stamp + 100
        var failure = assistant([["type": "toolCall", "id": "bad", "name": "bash", "arguments": ["command": "make verify STAGES=unit"]]], stop: "toolUse")
        failure["timestamp"] = stamp + 1000
        var failureResult = result("bad", "test sweep::tests::linger_waits_for_focus ... FAILED\n\nfailures:\n---- sweep::tests::linger_waits_for_focus stdout ----\nassertion `left == right` failed\n  left: Some(%7)\n right: None\n\nFAIL unit 40.2s\n\nCommand exited with code 101", error: true)
        failureResult["timestamp"] = stamp + 41000
        let explanation = assistant([["type": "text", "text": "The linger test fails because `dead_since` is set before the focus check. Looking at the order in `sweep()`."]])
        let aborted = assistant([["type": "thinking", "thinking": "the order in sweep()"], ["type": "toolCall", "id": "abort", "name": "edit", "arguments": ["path": "ko_server/src/sweep.rs", "oldText": "", "newText": ""]]], stop: "aborted")
        steps.append(["type": "respond", "command": "get_messages", "data": ["messages": [errorUser, failedRead, failedReadResult, failure, failureResult, explanation, aborted]]])
        let testDialogs = scenario == .dialogs
        let testControls = scenario == .controls

        func ui(_ id: String, _ method: String, _ fields: [String: Any]) -> [String: Any] { fields.merging(["type": "extension_ui_request", "id": id, "method": method]) { _, value in value } }
        func replay(_ messages: [[String: Any]], after: [[String: Any]] = []) {
            prompt([["type": "compaction_end"]])
            steps.append(["type": "respond", "command": "get_messages", "data": ["messages": messages], "after": after])
        }
        var releaseUser = user
        releaseUser["content"] = [["type": "text", "text": "Release 0.32 and write the notes"]]
        let select = ui("select", "select", ["title": "Which tap revision?", "options": ["0.31.1 · 20857320", "0.31.0 · 6153fce8", "custom…"], "timeout": 20000])
        let confirm = ui("confirm", "confirm", ["title": "Force-push main?", "message": "origin/main moves from 20857320 to 88bdb070. Other clones need a reset."])
        if testDialogs {
            let releaseCalls = assistant([["type": "toolCall", "id": "release-read", "name": "read", "arguments": ["path": "scripts/release.sh"]], ["type": "toolCall", "id": "release", "name": "release", "arguments": [:]]], stop: "toolUse")
            replay([releaseUser], after: [["type": "agent_start"], ["type": "message_start", "message": releaseCalls], ["type": "tool_execution_end", "toolCallId": "release-read", "result": ["content": [["type": "text", "text": "Read"]]], "isError": false], ["type": "tool_execution_start", "toolCallId": "release", "toolName": "release", "args": [:]], select, confirm])
            steps.append(["type": "wait", "command": "extension_ui_response"])
            steps.append(["type": "wait", "command": "extension_ui_response", "events": [ui("input", "input", ["title": "Version for the tap", "placeholder": "0.32.0", "timeout": 49000])]])
            steps.append(["type": "wait", "command": "extension_ui_response", "events": [ui("editor", "editor", ["title": "Release notes", "prefill": "## 0.32\n\n- The sidebar shows status at the right and folds children\n- A program can show a webview page in its pane"]) ]])
            steps.append(["type": "wait", "command": "extension_ui_response", "events": [["type": "agent_settled", "aborted": false]]])
        }
        var queueUser = releaseUser
        queueUser["content"] = [["type": "text", "text": "Release 0.32"]]
        let queueBlocks: [[String: Any]] = [["type": "toolCall", "id": "queue-read", "name": "read", "arguments": ["path": "Makefile"]], ["type": "toolCall", "id": "queue-check", "name": "bash", "arguments": ["command": "git status"]], ["type": "toolCall", "id": "verify", "name": "bash", "arguments": ["command": "make verify"]]]
        let queueCalls = assistant(queueBlocks, stop: "toolUse")
        if testControls {
            var queueEarlier = assistant(Array(queueBlocks.prefix(2)), stop: "toolUse")
            queueEarlier["timestamp"] = stamp - 50000
            var queueRead = result("queue-read", "Read")
            queueRead["timestamp"] = stamp - 49900
            var queueCheck = result("queue-check", "Clean")
            queueCheck["timestamp"] = stamp - 49000
            replay([queueUser, queueEarlier, queueRead, queueCheck], after: [["type": "agent_start"], ["type": "message_start", "message": assistant([queueBlocks[2]], stop: "toolUse")], ["type": "tool_execution_start", "toolCallId": "verify", "toolName": "bash", "args": [:]], ["type": "queue_update", "steering": ["skip the Linux check, I'll run it in CI", "use the tap's revision from the last release, not HEAD"], "followUp": ["then draft the release notes from the commits since 0.31"]]])
            steps.append(["type": "wait", "command": "clear_queue", "data": ["steering": ["skip the Linux check, I'll run it in CI", "use the tap's revision from the last release, not HEAD"], "followUp": ["then draft the release notes from the commits since 0.31"]], "events": [["type": "queue_update", "steering": [], "followUp": []], ["type": "agent_settled", "aborted": false]]])
            replay([])
            steps.append(["type": "wait", "command": "get_available_models", "data": ["models": [["id": "claude-opus-5-5", "provider": "anthropic"], ["id": "claude-sonnet-5-5", "provider": "anthropic"], ["id": "claude-fable-5-1", "provider": "claude-bridge"], ["id": "gpt-6.1-sol", "provider": "openai-codex"], ["id": "gpt-6-astra", "provider": "openai-codex"]]]])
            prompt([ui("git", "setStatus", ["statusKey": "git", "statusText": "↑2"]), ui("tests", "setStatus", ["statusKey": "tests", "statusText": "3 failing"]), ui("info", "notify", ["message": "Worktree ~/Workspace/kido-release created", "notifyType": "info"])])
            prompt([["type": "agent_start"], ui("tests", "setStatus", ["statusKey": "tests"]), ui("warning", "notify", ["message": "Context at 78%, compaction soon", "notifyType": "warning"])])
            prompt([["type": "agent_settled", "aborted": false], ui("git", "setStatus", ["statusKey": "git"]), ui("error", "notify", ["message": "extension release: tap checkout is dirty, refusing to commit", "notifyType": "error"])])
        }
        var timedBlocks = blocks
        timedBlocks[0] = ["type": "thinking", "thinking": "where the rule belongs"]
        let timedCalls = assistant(timedBlocks, stop: "toolUse")
        var timesUser = user
        timesUser["content"] = [["type": "text", "text": "Make the sweep keep a start failure, then run the whole unit stage"]]
        replay([timesUser], after: [["type": "agent_start"], ["type": "message_start", "message": assistant([])], ["type": "message_update", "usage": usage, "assistantMessageEvent": ["type": "thinking_start", "contentIndex": 0]]])
        prompt([["type": "message_update", "usage": usage, "assistantMessageEvent": ["type": "thinking_end", "contentIndex": 0, "content": "where the rule belongs"]], ["type": "message_end", "message": timedCalls], ["type": "tool_execution_start", "toolCallId": "read", "toolName": "read", "args": ["path": "ko_server/src/sweep.rs"]]])
        prompt([["type": "tool_execution_end", "toolCallId": "read", "result": ["content": [["type": "text", "text": Array(repeating: "    row", count: 212).joined(separator: "\n")]]], "isError": false], ["type": "tool_execution_start", "toolCallId": "edit", "toolName": "edit", "args": [:]]])
        prompt([["type": "tool_execution_end", "toolCallId": "edit", "result": ["content": [["type": "text", "text": "Edit applied"]]], "isError": false]])
        prompt([["type": "tool_execution_start", "toolCallId": "bash", "toolName": "bash", "args": [:]]])
        let secondCalls = assistant([["type": "thinking", "thinking": "which stages the unit stage runs"], ["type": "toolCall", "id": "unit", "name": "bash", "arguments": ["command": "make verify STAGES=unit"]]], stop: "aborted")
        prompt([["type": "tool_execution_end", "toolCallId": "bash", "result": ["content": [["type": "text", "text": "Passed"]]], "isError": false], ["type": "message_end", "message": assistant([["type": "text", "text": "Done. Now the unit stage."]])], ["type": "message_start", "message": assistant([])], ["type": "message_update", "usage": usage, "assistantMessageEvent": ["type": "thinking_start", "contentIndex": 0]]])
        prompt([["type": "message_update", "usage": usage, "assistantMessageEvent": ["type": "thinking_end", "contentIndex": 0, "content": "which stages the unit stage runs"]], ["type": "message_update", "usage": usage, "assistantMessageEvent": ["type": "toolcall_end", "contentIndex": 1, "toolCall": ["type": "toolCall", "id": "unit", "name": "bash", "arguments": ["command": "make verify STAGES=unit"]]]], ["type": "tool_execution_start", "toolCallId": "unit", "toolName": "bash", "args": [:]]])
        prompt([["type": "message_end", "message": secondCalls], ["type": "agent_settled", "aborted": true]])
        var exitCalls = queueCalls
        exitCalls["timestamp"] = stamp
        var exitRead = result("queue-read", "Read")
        exitRead["timestamp"] = stamp + 100
        var exitCheck = result("queue-check", "Clean")
        exitCheck["timestamp"] = stamp + 1000
        var exitVerify = result("verify", "Passed")
        exitVerify["timestamp"] = stamp + 48000
        replay([queueUser, exitCalls, exitRead, exitCheck, exitVerify, assistant([["type": "text", "text": "The tap formula is updated; pushing now."]])])
        prompt([])
        steps.append(["type": "stderr", "text": "node:internal/process/esm_loader:108\n    throw new ERR_MODULE_NOT_FOUND(packageName, fileURLToPath(base), null);\nError [ERR_MODULE_NOT_FOUND]: Cannot find package '@kido/webview'\n    at packageResolve (node:internal/modules/esm/resolve:873:9)\n    at moduleResolve (node:internal/modules/esm/resolve:946:18)\n"])
        steps.append(["type": "exit", "code": 1])
        steps.insert(["type": "respond", "command": "get_available_thinking_levels", "data": ["levels": ["off", "minimal", "low", "medium", "high", "xhigh"]]], at: 3)
        if scenario == .completion {
            steps = Array(steps.prefix(4))
            let commands = [("gh-watch", "Watch main and report each head’s CI", "prompt"), ("release", "Release Kido.app first, then ko", "prompt"), ("koa", "Use the koa harness for child agents", "extension"), ("runtime", "Run the built-in tools in a runtime of this session", "extension"), ("skill:ko", "Read and change the ko layout: sessions, windows, panes", "skill"), ("skill:simplify", "Clean up the changed code without changing behavior", "skill"), ("skill:rex", "Manage Rex sessions, tabs and panes with the rex CLI", "skill"), ("plan", "Write a plan in plans/ before the code", "prompt"), ("review", "Run the correctness and modules reviewers on the diff", "extension"), ("skill:ko-api", "Call ko api routes from a prompt", "skill")]
            steps.append(["type": "respond", "command": "get_commands", "data": ["commands": commands.map { ["name": $0.0, "description": $0.1, "source": $0.2] }]])
            var completionUser = user
            completionUser["content"] = [["type": "text", "text": "Review the sidebar unit before it lands"]]
            prompt([])
            replay([completionUser])
            replay([])
        }
        func image(_ width: Int, _ height: Int, _ a: UInt32, _ b: UInt32, _ label: String) throws -> [String: Any] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            defer { NSGraphicsContext.restoreGraphicsState() }
            let w = CGFloat(width), h = CGFloat(height)
            func color(_ value: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1) }
            try XCTUnwrap(NSGradient(starting: color(a), ending: color(b))).draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -45)
            NSColor.white.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: NSRect(x: w * 0.08, y: h * 0.14, width: w * 0.84, height: h * 0.72), xRadius: min(w, h) * 0.03, yRadius: min(w, h) * 0.03).fill()
            for (x, y, rw, rh, alpha) in [(0.12, 0.75, 0.5, 0.05, 0.55), (0.12, 0.66, 0.76, 0.04, 0.3), (0.12, 0.58, 0.7, 0.04, 0.3)] {
                NSColor(white: 0.2, alpha: alpha).setFill(); NSBezierPath(roundedRect: NSRect(x: w * x, y: h * y, width: w * rw, height: h * rh), xRadius: 3, yRadius: 3).fill()
            }
            color(a).withAlphaComponent(0.35).setFill(); NSBezierPath(roundedRect: NSRect(x: w * 0.12, y: h * 0.24, width: w * 0.76, height: h * 0.3), xRadius: 4, yRadius: 4).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (label as NSString).draw(in: NSRect(x: 0, y: h * 0.015, width: w, height: h * 0.08), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: max(10, h * 0.045), weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph])
            return ["type": "image", "mimeType": "image/png", "data": try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).base64EncodedString()]
        }
        if scenario == .agents {
            let task = """
            Implement the **sidebar** indicators with `SidebarRow.swift`; see [the reference](https://example.com/sidebar).

            - Keep the **status** at the right.
            - Update `SidebarView.swift`.

            Rules from the approved mockup (app/design/sidebar/mockup.html, NOTES.md "Indicator on the right"):
            1. status and the hover-close × share one 12pt trailing slot centred 18pt from the row's right edge;
            2. title, activity and folded circles start at 12pt;
            3. nesting stays 15pt per level;
            4. the session + aligns with the rightmost indicator;
            5. idle indicators are muted gray at 50% on every row.

            Add snapshot tests for every state of the mockup (light and dark, docked and floating). Run the app's make test; report the pre-fix failures and the diff summary. Do not commit.
            """
            let report = """
            Built the **right-side** indicators with `SidebarRow.swift`; see [the reference](https://example.com/sidebar). Pre-fix failures: 6 snapshot tests (SidebarTests.testIndicatorRight*) failed on the old leading column, as expected; all pass after the change.

            - **SidebarRow.swift**: the trailing slot, 12pt, centred 18pt from the edge; the title inset.
            - `SidebarView.swift`: the session + alignment.
            - Rows.swift: the fold-state key for record rows.

            Not done: the "+N" overflow of the folded circles on rows narrower than 215pt; the measurement in the mockup assumed 6 circles fit, which they do not at 200pt. Needs a decision.

            Snapshots: `app/Tests/__Snapshots__/SidebarTests/` (12 new).
            """
            func person(_ text: String) -> [String: Any] { var value = user; value["content"] = [["type": "text", "text": text]]; return value }
            func prose(_ text: String) -> [String: Any] { assistant([["type": "text", "text": text]]) }
            func call(_ id: String, _ name: String, _ args: [String: Any], _ details: [String: Any]?, _ minute: Int = 2, start: Int = 0, duration: Int = 100) -> [[String: Any]] {
                var value = assistant([["type": "toolCall", "id": id, "name": name, "arguments": args]], stop: "toolUse"); value["timestamp"] = stamp + minute * 60000 + start
                guard let details else { return [value] }
                return [value, ["role": "toolResult", "toolCallId": id, "toolName": name, "timestamp": stamp + minute * 60000 + start + duration, "isError": false, "content": [["type": "text", "text": details["text"] ?? "Opaque model-facing result"]], "details": details]]
            }
            func inbound(_ name: String, _ form: String, _ body: String, _ minute: Int, relation: String? = nil, reported: Bool? = nil) -> [String: Any] {
                var inbound: [String: Any] = ["form": form]
                if let relation { inbound["relation"] = relation }
                else if form == "report" || form == "ended" { inbound["relation"] = "child" }
                if let reported { inbound["reported"] = reported }
                let details: [String: Any] = ["agent": ["name": name, "session": name + "-session"], "body": body, "inbound": inbound]
                let type = form == "message" ? "ko-message" : form == "steer" ? "ko-steer" : "ko-notice"
                return ["role": "custom", "customType": type, "display": true, "timestamp": stamp + minute * 60000, "content": "Header is not parsed by the page", "details": details]
            }
            func job(_ id: String, _ name: String, _ end: [String: Any]?, _ body: String, _ minute: Int, service: Bool = false, omitted: Int = 0) -> [String: Any] {
                var ref: [String: Any] = ["id": id, "name": name, "log": "/Users/andrepopp/Library/Caches/ko-pi/jobs/" + name + "-" + id + ".log", "service": service]
                var details: [String: Any] = ["job": ref]
                if let end { ref["end"] = end; details = ["kind": "job", "job": ref, "tail": body] }
                else { details["batch"] = body; details["omitted"] = omitted; details["cut"] = false }
                return ["role": "custom", "customType": end == nil ? "ko-stream" : "ko-notice", "display": true, "timestamp": stamp + minute * 60000, "content": "Do not parse this output", "details": details]
            }
            let success: [String: Any] = ["outcome": ["ok": true]]
            var out: [[String: Any]] = [person("Hand the sidebar unit to an implementer and tell the reviewer when it builds")]
            out += call("a-read", "read", ["path": "app/design/sidebar/NOTES.md"], ["text": Array(repeating: "line", count: 612).joined(separator: "\n")], 0, duration: 100)
            out += call("a-bash", "bash", ["command": "git worktree add --detach ~/Workspace/kido-sidebar-right main"], ["text": "Done"], 0, start: 100, duration: 1100)
            out += call("a-spawn", "spawn_agent", ["name": "sidebar-right", "task": task], success.merging(["name": "sidebar-right", "session": "9702ddd1"]) { _, last in last })
            out += [prose("The implementer is building. I will tell the reviewer when it reports.")]
            out += call("a-msg", "message_agent", ["to": "sidebar-right", "message": "The user decided the chevron reflects explicit fold state, not whether waiting children are visible: a folded parent keeps › even when a waiting child is force-shown."], success.merging(["to": "sidebar-right"]) { _, last in last }, 10)
            out += call("a-steer", "message_agent", ["to": "html-refine", "mode": "steer", "message": "Pause the koa-runline implementer until the user approves; the mockups show the five decisions but nothing is approved yet."], success.merging(["to": "html-refine"]) { _, last in last }, 11)
            out += call("a-interrupt", "message_agent", ["to": "sidebar-right", "mode": "interrupt-and-steer", "message": "Stop: the user changed the indicator side back to the left. Wait for the new spec."], success.merging(["to": "sidebar-right"]) { _, last in last }, 13)
            out += call("a-pending", "spawn_agent", ["name": "correctness-review", "task": "Review the diff of ~/Workspace/kido-sidebar-right against AGENTS.md \"Review\"; trace the fold state of a record row end to end."], nil, 14)
            let refusal = "refusing window name \"modules/review\": it must be one path-safe name, not an empty, dot or slashed path"
            var failed = [person("Spawn the reviewer")]
            failed += call("b-spawn", "spawn_agent", ["name": "modules-review", "task": "Review"], ["outcome": ["ok": false, "failure": "error", "message": refusal]])
            failed += call("b-message", "message_agent", ["to": "sidebar-right", "message": "Please also update the NOTES.md heading."], ["to": "sidebar-right", "outcome": ["ok": false, "failure": "not_found", "message": "no agent named sidebar-right"]], 15)
            failed += [prose("The implementer has ended; I will resume it with the message instead.")]
            let incoming: [[String: Any]] = [
                inbound("kido-app", "message", "User approval for the sidebar redesign, just now: \"approved\". Start the sidebar-right unit; the reference is app/design/sidebar/mockup.html and NOTES.md as of 12:35.", 204, relation: "parent"),
                prose("Starting the unit: a planner first, then the implementer."),
                inbound("sidebar-right", "report", report, 230),
                inbound("kido-app", "steer", "Skip the Linux check; CI runs it.", 232, relation: "parent"),
                inbound("html-refine", "message", "The koa page is on webview at ae5abf40; your mockups are unchanged in content and clean against HEAD.", 238, relation: "sibling"),
                inbound("simplify-reuse", "ended", "ended: exit 0; it had reported on its last work.\n--- last 4000 bytes of its screen ---\n> Reported. Waiting for the manager.\n$ \n\nmessage it to continue it, or stop_agent to end it", 239, reported: true),
                inbound("perf-notes", "ended", "ended: signal SIGKILL; it had not reported on its last work.\n--- last 4000 bytes of its screen ---\n…measuring the sidebar at 200pt\nKilled: 9\n\nmessage it to continue it, or stop_agent to end it", 239, reported: false),
                inbound("ko-pi", "notice", "2 async_bash jobs of the previous ko-pi version were stopped at /reload: main-watch, lint", 240)
            ]
            let lint = "scripts/lint.sh: docs/design-app.md:1466 names app/App/Toolbar.swift, which does not exist\nscripts/lint.sh: 1 broken reference\nFAIL lint 3s"
            let jobs: [[String: Any]] = [
                person("Run the unit stage in the background and watch main"), prose("Both are running; I will read the notices when they end."),
                job("3", "verify-unit", ["type": "exit", "code": 0], "test sweep::tests::keeps_a_start_failure ... ok\ntest sweep::tests::linger_waits_for_focus ... ok\n\ntest result: ok. 212 passed; 0 failed; 0 ignored; finished in 41.02s\n\nPASS unit 44s", 19),
                job("4", "lint", ["type": "exit", "code": 1], lint, 20),
                job("5", "main-watch", nil, "main 88bdb070: CI queued\nmain 88bdb070: ubuntu running · macos running", 28, omitted: 212),
                job("5", "main-watch", nil, "main 88bdb070: ubuntu PASS 6m12s\nmain 88bdb070: macos running", 33),
                job("5", "main-watch", nil, "main 88bdb070: macos PASS 9m03s\nmain 88bdb070: CI green", 37),
                job("6", "ci-like", ["type": "timeout", "seconds": 600], "[podman] pulling ko-ci-like:4f2a9c1e8b77 …\n[podman] layer 7/12", 40),
                job("7", "demo", ["type": "signal", "signal": "SIGKILL"], "Kido.app 0.32 (debug) · pid 48112\nwindow 1 connected to /tmp/ko-demo/socket", 50, service: true)
            ]
            let folded = [inbound("sidebar-right", "report", report, 230), job("4", "lint", ["type": "exit", "code": 1], "scripts/lint.sh: docs/design-app.md:1466 names app/App/Toolbar.swift, which does not exist\nscripts/lint.sh: share/pi/ko-pi.ts:3381 is not a line of ko-pi.ts\nscripts/lint.sh: 2 broken references\nscripts/lint.sh: run make lint after the fix\nFAIL lint 3s", 20)]
            var tools = [person("What are my agents doing? Stop the stale one.")]
            tools += call("t-list", "list_agents", [:], ["text": "sidebar-right  subagent  running  \"applying the review findings\"  reported: no\nsimplify-reuse subagent  ended    reported: yes\nhtml-refine    peer      running  \"unit 12\""], 0, duration: 300)
            tools += call("t-read", "read_report", ["agent": "simplify-reuse"], ["text": "The report"], 0, start: 300, duration: 100)
            tools += call("t-stop", "stop_agent", ["agent": "simplify-reuse"], ["text": "Stopped"], 0, start: 400, duration: 1700)
            tools += [prose("sidebar-right is applying the review findings; simplify-reuse had reported and is stopped.")]
            steps = Array(steps.prefix(3)); steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": out]]
            for messages in [failed, incoming, jobs, folded, tools] { replay(messages) }
        }
        if scenario == .preview {
            var first = user; first["content"] = [["type": "text", "text": "Move the weight rule into the row state"]]
            var messages = [first]
            for (id, name, args, start, end, body) in [
                ("p-read", "read", ["path": "app/App/SidebarRow.swift"], 0, 100, Array(repeating: "row", count: 412).joined(separator: "\n")),
                ("p-edit", "edit", ["path": "app/App/SidebarRow.swift", "oldText": "a\nb\nc\nd", "newText": "1\n2\n3\n4\n5\n6\n7\n8\n9"], 200, 400, "Edit applied"),
                ("p-bash", "bash", ["command": "make test"], 600, 4000, "Tests pass")
            ] {
                var call = assistant([["type": "toolCall", "id": id, "name": name, "arguments": args]], stop: "toolUse"); call["timestamp"] = stamp + start
                messages += [call, ["role": "toolResult", "toolCallId": id, "toolName": name, "timestamp": stamp + end, "isError": false, "content": [["type": "text", "text": body]]]]
            }
            messages.append(assistant([["type": "text", "text": "Done; the tests pass."]]))
            steps = Array(steps.prefix(3)); steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": messages]]
        }
        if scenario == .media || scenario == .lightbox {
            let shot = try image(1440, 900, 0x2f6fd6, 0x8b3fc9, "screenshot 1440×900")
            let diagram = try image(800, 800, 0xe0742d, 0xc42a5b, "diagram 800×800")
            let sidebar = try image(1200, 500, 0x1f9d7a, 0x1f6fa6, "sidebar 1200×500")
            func message(_ text: String, _ images: [[String: Any]] = []) -> [String: Any] { ["role": "user", "timestamp": stamp, "content": [["type": "text", "text": text]] + images] }
            func read(_ id: String, _ path: String, _ at: Int) -> [[String: Any]] {
                var call = assistant([["type": "toolCall", "id": id, "name": "read", "arguments": ["path": path]]], stop: "toolUse"); call["timestamp"] = stamp + at
                return [call, ["role": "toolResult", "toolCallId": id, "toolName": "read", "timestamp": stamp + at + 200, "isError": false, "content": [["type": "text", "text": "Read image file [image/png]"], shot]]]
            }
            var code = assistant([["type": "toolCall", "id": "images", "name": "codemode", "arguments": ["code": "image() x2"]]], stop: "toolUse"); code["timestamp"] = stamp + 7900
            steps = Array(steps.prefix(4))
            replay([message("Look at the two screenshots in /tmp/koa-shots and tell me what differs")] + read("light", "/tmp/koa-shots/complete-at-agents-light-wide.png", 0) + read("dark", "/tmp/koa-shots/complete-at-agents-dark-wide.png", 200) + [code, ["role": "toolResult", "toolCallId": "images", "toolName": "codemode", "timestamp": stamp + 9000, "isError": false, "content": [["type": "text", "text": "sidebar rows: 28 vs 32pt"], sidebar, diagram]], assistant([["type": "text", "text": "The light render has the kind tags; the dark one lost them to the ellipsis. Two things differ…"]])])
            replay([message("Make the sidebar look like this", [sidebar, diagram]), assistant([["type": "text", "text": "Reading both fixtures."]])])
            replay([message("Compare with the earlier screenshot", [shot, shot]), assistant([["type": "text", "text": "I can see the second one; the first is no longer available in this session."]])])
        }
        if scenario == .thinkingMarkdown {
            let thinking = "# Check the close policy\n\nKeep **start failures** visible and use `close` for the exit rule.\n\n- Read the pane state\n- Keep the focus rule\n\n```swift\nif pane.close == .exit {\n    remove(pane)\n}\n```"
            steps = Array(steps.prefix(3))
            let content: [[String: Any]] = [["type": "thinking", "thinking": thinking]]
            let messages: [[String: Any]] = [user, assistant(content)]
            steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": messages]]
        }
        if scenario == .reveal {
            let code = (1...20).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
            let history = assistant([["type": "text", "text": "The sweep keeps this helper:\n\n```swift\n\(code)\n```\n\nIt reads each row once."]])
            steps = Array(steps.prefix(3))
            steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": [user, history]]]
            let arriving = assistant([["type": "text", "text": "First the rows are read.\n\n- one\n- two\n\n```swift\nlet a = 1\nlet b = 2\nlet c"]])
            prompt([["type": "agent_start"]])
            prompt([["type": "message_end", "message": streamUser], ["type": "message_start", "message": arriving]])
        }
        if scenario == .userMarkdown {
            var rich = user; rich["content"] = [["type": "text", "text": "Use `inline` and the same Markdown rules, see [the reference](https://example.com/ref).\n\n> Keep the quoted instruction clear on the tint.\n\n- First item\n- Second item\n\n```js\nconst x = 1;\n```\n\n<b>raw HTML stays text</b>"]]
            var plain = user; plain["timestamp"] = stamp + 1; plain["content"] = [["type": "text", "text": "A plain one-line message"]]
            steps = Array(steps.prefix(3)); steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": [rich, assistant([["type": "text", "text": "The text column is the same width."]]), plain]]]
            for text in [
                "> The breadcrumb test is flaky on Linux. I recommend skipping it on Linux for now.\nYes",
                "> error[E0599]: no method named `place` found for struct `Model`\n>   --> ko_client/src/model.rs:412:18\nWhy does this appear only on the musl target? The method is `pub(crate)`.\n\n> Should I push now, or wait for CI on the rebase?\nwait for CI",
                "Use this as the fixture:\n\n```json\n{ \"reply\": { \"at\": 1762764720000, \"block\": 0, \"length\": 212 },\n  \"annotations\": [ { \"type\": \"question\", \"range\": [96, 142],\n    \"kind\": \"choice\", \"options\": [[106, 114], [119, 130]] } ] }\n```\n\nand make the test read it from a `file`."
            ] {
                var value = user; value["content"] = [["type": "text", "text": text]]
                replay([value])
            }
        }
        if scenario == .attachments {
            for (path, w, h, a, b, label, length) in [(attachmentPaths.shot, 1440, 900, UInt32(0x2f6fd6), UInt32(0x8b3fc9), "screenshot 1440×900", 2516582), (attachmentPaths.diagram, 800, 800, UInt32(0xe0742d), UInt32(0xc42a5b), "diagram 800×800", 310 * 1024)] {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                var bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(image(w, h, a, b, label)["data"] as? String)))
                if bytes.count < length { bytes.append(Data(count: length - bytes.count)) }
                try bytes.write(to: path)
            }
            try Data(repeating: 32, count: 8192).write(to: attachmentPaths.notes)
            try FileManager.default.createDirectory(at: attachmentPaths.source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "row\n".write(to: attachmentPaths.source, atomically: true, encoding: .utf8)
            var first = user; first["content"] = [["type": "text", "text": "Here is what I have so far"]]
            steps = Array(steps.prefix(3))
            steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": [first]]]
            var release = user; release["content"] = [["type": "text", "text": "Release 0.32"]]
            replay([release], after: [["type": "agent_start"], ["type": "message_start", "message": assistant([["type": "toolCall", "id": "release", "name": "bash", "arguments": ["command": "make verify"]]], stop: "toolUse")]])
            prompt([["type": "queue_update", "steering": ["skip the Linux check, I'll run it in CI"], "followUp": []]])
            prompt([["type": "queue_update", "steering": ["skip the Linux check, I'll run it in CI"], "followUp": ["then compare with these two renders"]]])
            steps.append(["type": "wait", "command": "clear_queue", "data": ["steering": ["skip the Linux check, I'll run it in CI"], "followUp": ["then compare with these two renders"]], "events": [["type": "queue_update", "steering": [], "followUp": []], ["type": "agent_settled", "aborted": false], ["type": "compaction_end"]]])
            steps.append(["type": "respond", "command": "get_messages", "data": ["messages": []]])
            steps.append(["type": "wait", "command": "prompt", "echo": true, "events": [["type": "agent_start"], ["type": "message_start", "message": assistant([["type": "toolCall", "id": "sent-read", "name": "read", "arguments": ["path": "notes.md"]]], stop: "toolUse")]]])
        }
        if scenario == .feed {
            steps = Array(steps.prefix(4))
            let part = String(repeating: "x", count: 4096)
            prompt([["type": "agent_start"], ["type": "message_start", "message": assistant([["type": "text", "text": part]])]])
            prompt([["type": "message_update", "usage": usage, "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": part]]])
            prompt([["type": "message_end", "message": assistant([["type": "text", "text": part + part + part]])], ["type": "agent_settled", "aborted": false]])
        }
        if scenario == .composer {
            let name = composerState
            var person = user; person["content"] = [["type": "text", "text": ["waiting", "exited", "toast-err"].contains(name) ? "Release 0.32" : name == "toast" ? "Use Sonnet for the rest of this" : "Run the unit stage"]]
            steps = Array(steps.prefix(3)); steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": [person]]]
            if name == "waiting" { steps[2] = ["type": "respond", "command": "get_session_stats", "data": ["contextUsage": ["tokens": 156000, "contextWindow": 200000, "percent": 78]]] }
            var events: [[String: Any]] = []
            if ["working", "narrow", "toast-err", "responsive"].contains(name) {
                events = [["type": "agent_start"], ["type": "message_start", "message": assistant([["type": "toolCall", "id": "foot-run", "name": "bash", "arguments": ["command": "make verify STAGES=unit"]]], stop: "toolUse")], ["type": "tool_execution_start", "toolCallId": "foot-run"]]
            } else if name == "waiting" { events = [["type": "message_end", "message": assistant([["type": "text", "text": "Which tap revision? (see the dialog)"]])], ["type": "extension_ui_request", "id": "foot-wait", "method": "input", "title": "Which tap revision?"]] }
            if name == "toast" || name == "toast-err" { events.append(["type": "extension_ui_request", "id": "foot-notify", "method": "notify", "notifyType": name == "toast" ? "info" : "error", "message": name == "toast" ? "Switched to claude-sonnet-5-5 · thinking medium" : "extension release: tap checkout is dirty, refusing to commit"]) }
            if name == "extras" { events = [["type": "extension_ui_request", "id": "foot-git", "method": "setStatus", "statusKey": "git", "statusText": "↑2"], ["type": "extension_ui_request", "id": "foot-tests", "method": "setStatus", "statusKey": "tests", "statusText": "3 failing"]] }
            prompt(events)
            if name == "exited" { steps.append(["type": "stderr", "text": "Killed: 9\n"]); steps.append(["type": "exit", "code": 137]) }
            if name == "picker" { steps.append(["type": "wait", "command": "get_available_models", "data": ["models": [["id": "claude-opus-5-5", "provider": "anthropic"], ["id": "claude-sonnet-5-5", "provider": "anthropic"], ["id": "claude-fable-5-1", "provider": "claude-bridge"], ["id": "gpt-6.1-sol", "provider": "openai-codex"], ["id": "gpt-6-astra", "provider": "openai-codex"]]]]) }
            if name == "responsive" { steps.insert(["type": "wait", "command": "get_available_models", "data": ["models": [["id": "claude-opus-5-5", "provider": "anthropic"]]]], at: 3) }
        }
        if scenario == .bang {
            var person = user; person["content"] = [["type": "text", "text": "Verify the sidebar unit"]]
            steps = Array(steps.prefix(3)); steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": [person]]]
            let commands: [(String, String, Int, Bool, Bool, Bool)] = [
                ("make checks DRY=1", "plan: lint-sh unit(ko_client) app visual(SidebarTests)\nunit: cargo test -p ko_client\napp: make -C app test\nvisual: make -C app visual VISUAL_ONLY=SidebarTests", 0, false, false, false),
                ("git status --short", " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", 0, false, false, true),
                ("make verify STAGES=unit", "test result: FAILED. 1 failed; 212 passed\n---- model::place stays on the host pane ----\nassertion `left == right` failed\n  left: Some(Runtime(\"tools\"))\n right: None\nmake: *** [verify] Error 2", 2, false, false, false),
                ("make e2e", "running 64 tests\n......................", 0, true, false, false),
                ("find . -type f", "./AGENTS.md\n./Cargo.toml\n./Makefile\n./README.md", 0, false, true, false),
            ]
            var messages: [[String: Any]] = []
            for command in commands {
                var message: [String: Any] = ["role": "bashExecution", "command": command.0, "output": command.1, "exitCode": command.2, "cancelled": command.3, "truncated": command.4, "excludeFromContext": command.5, "timestamp": stamp + messages.count + 1]
                if command.4 { message["fullOutputPath"] = "/tmp/pi-bash-abc123.log" }
                messages.append(message)
            }
            prompt([["type": "compaction_end"]])
            let allMessages: [[String: Any]] = [person] + messages
            steps.append(["type": "respond", "command": "get_messages", "data": ["messages": allMessages]])
            for index in [0, 2, 3, 4, 1] {
                prompt([["type": "compaction_end"]])
                let oneMessage: [[String: Any]] = [person, messages[index]]
                steps.append(["type": "respond", "command": "get_messages", "data": ["messages": oneMessage]])
            }
            prompt([["type": "compaction_end"]])
            steps.append(["type": "respond", "command": "get_messages", "data": ["messages": [person]]])
            steps.append(["type": "wait", "command": "bash", "gate": true, "events": [["type": "bash_execution_update", "delta": "running 212 tests\ntest model::place_stays_on_host ... ok\ntest model::runtime_name ... ok\n......................"]], "data": ["output": "cancelled", "cancelled": true, "truncated": false]])
            let busyReply: [String: Any] = assistant([["type": "text", "text": "The sweep needs to distinguish a start failure from a program exit. Checking the close policy."]])
            let busyEvents: [[String: Any]] = [["type": "agent_start"], ["type": "message_start", "message": busyReply]]
            prompt(busyEvents)
            steps.append(["type": "wait", "command": "bash", "gate": true, "events": [["type": "bash_execution_update", "delta": " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png"]], "data": ["output": " M app/App/SidebarRow.swift\n?? app/Tests/__Snapshots__/SidebarTests/testIndicatorRight.1.png", "exitCode": 0, "cancelled": false, "truncated": false]])
        }
        if scenario == .questions {
            let reply = """
            The sidebar unit is verified: fmt, clippy, lint, unit, e2e and the TypeScript suite pass. Two things before I push.

            - Should I push now, or wait for CI on the rebase?
            - The breadcrumb test is flaky on Linux. I recommend skipping it on Linux for now.

            Do you want the Linux check at all? It costs 4 minutes of CI, and the user-facing change is macOS only.

            I could also fold the two commits into one before the push.

            What should the release be called?
            """
            func span(_ text: String) throws -> [Int] {
                let range = try XCTUnwrap(reply.range(of: text))
                return [reply[..<range.lowerBound].unicodeScalars.count, reply[..<range.upperBound].unicodeScalars.count]
            }
            let questions: [[String: Any]] = [
                ["type": "question", "kind": "choice", "range": try span("Should I push now, or wait for CI on the rebase?"), "options": [try span("push now"), try span("wait for CI")]],
                ["type": "question", "kind": "yes_no", "range": try span("The breadcrumb test is flaky on Linux. I recommend skipping it on Linux for now."), "options": []],
                ["type": "question", "kind": "yes_no", "range": try span("Do you want the Linux check at all?"), "options": []],
                ["type": "question", "kind": "choice", "range": try span("I could also fold the two commits into one before the push."), "options": [try span("fold the two commits into one")]],
                ["type": "question", "kind": "open", "range": try span("What should the release be called?"), "options": []],
            ]
            let person: [String: Any] = ["role": "user", "timestamp": stamp, "content": [["type": "text", "text": "Verify the sidebar unit and tell me what is left"]]]
            let entry: [String: Any] = ["type": "custom", "id": "questions", "parentId": NSNull(), "customType": "reply-annotations", "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(stamp + 1) / 1000)), "data": ["reply": ["at": stamp, "block": 0, "length": reply.unicodeScalars.count], "annotations": questions]]
            steps = Array(steps.prefix(3))
            steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": [person, assistant([["type": "text", "text": reply]])]]]
            steps.append(["type": "respond", "command": "get_entries", "data": ["entries": [entry], "leafId": "questions"]])
            let ordered = "Which should I do?\n\n1. Rebase the branch onto main and rerun the full verification before the push, including the application tests and all checks for the changed files.\n2. Push the branch as it is now and let CI check the combination on main, including the application tests and all checks for the changed files."
            let marked = ordered + "\n\n😀 Pick `one` or **two**?\r\n\r\n- Keep the cache?\r\n\r\n## Use alpha or beta?\r\n\r\n| Choice |\r\n| --- |\r\n| Use red or blue? |\r\n\r\nLiteral \u{E012}999;x\u{E012}"
            func markedSpan(_ text: String) throws -> [Int] {
                let range = try XCTUnwrap(marked.range(of: text))
                return [marked[..<range.lowerBound].unicodeScalars.count, marked[..<range.upperBound].unicodeScalars.count]
            }
            let markedQuestions: [[String: Any]] = [
                ["type": "question", "kind": "choice", "range": try markedSpan(ordered), "options": [try markedSpan("Rebase the branch onto main and rerun the full verification before the push, including the application tests and all checks for the changed files"), try markedSpan("Push the branch as it is now and let CI check the combination on main, including the application tests and all checks for the changed files")]],
                ["type": "question", "kind": "choice", "range": try markedSpan("😀 Pick `one` or **two**?"), "options": [try markedSpan("`one`"), try markedSpan("**two**")]],
                ["type": "question", "kind": "yes_no", "range": try markedSpan("Keep the cache?"), "options": []],
                ["type": "question", "kind": "choice", "range": try markedSpan("Use alpha or beta?"), "options": [try markedSpan("alpha"), try markedSpan("beta")]],
                ["type": "question", "kind": "choice", "range": try markedSpan("Use red or blue?"), "options": [try markedSpan("red"), try markedSpan("blue")]],
            ]
            var markedMessage = assistant([["type": "text", "text": marked]])
            markedMessage["timestamp"] = stamp + 1000
            let markedEntry: [String: Any] = ["type": "custom", "id": "marked-questions", "parentId": "questions", "customType": "reply-annotations", "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(stamp + 2000) / 1000)), "data": ["reply": ["at": stamp + 1000, "block": 0, "length": marked.unicodeScalars.count], "annotations": markedQuestions]]
            prompt([["type": "message_start", "message": markedMessage], ["type": "message_end", "message": markedMessage], ["type": "entry_appended", "entry": markedEntry]])
        }
        let sessionRows = directory.appendingPathComponent("session-rows.json")
        let sessionGate = directory.appendingPathComponent("session-gate")
        if scenario == .sessions {
            let titles: [(String?, String, Int)] = [
                ("sidebar-right", "Hand the sidebar unit to an implementer and tell the reviewer when it builds", 212),
                ("koa-md", "Agent cards render Markdown; the queue goes above the field", 96),
                (nil, "Why does ko_client::Model::place fail on the musl target only?", 14),
                ("runtimes-u4", "Design the runtime indicator for Kido.app and ko_tui", 341),
                ("release-0.31", "Release 0.31: Kido.app first, then ko", 58),
                (nil, "Explain the view write path in ko_server::conn", 9),
                ("notices", "Redesign the sidebar errors as notices", 187),
                ("html-mockups", "koa webview mockups: streaming, runs, composer", 402),
                ("bench", "Why does allocations/record rise after the deflate change?", 27),
            ]
            var rows: [[String: Any]] = []
            for (index, title) in titles.enumerated() {
                let age = index < 2 ? (index == 0 ? 600000 : 3480000) : index * 86400000
                var row: [String: Any] = ["cwd": cwd.path, "firstMessage": title.1, "messageCount": title.2, "modified": stamp - age]
                row["id"] = index == 0 ? "fake" : "session-\(index)"
                row["path"] = "/tmp/koa-visual-session-\(index)"
                if let name = title.0 { row["name"] = name }
                rows.append(row)
            }
            rows.append(["id": "other", "path": "/tmp/koa-visual-other", "cwd": home.appendingPathComponent("Workspace/pi-infer-questions").path, "name": "pi-infer-questions", "firstMessage": "Train the option tagger on the new corpus", "messageCount": 77, "modified": stamp - 1800000])
            try JSONSerialization.data(withJSONObject: rows).write(to: sessionRows)
            let person: [String: Any] = ["role": "user", "timestamp": stamp, "content": [["type": "text", "text": "Verify the sidebar unit"]]]
            steps = Array(steps.prefix(3))
            steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": [person, assistant([["type": "text", "text": "Verified: every stage passes. The snapshots that changed are the twelve of SidebarTests."]])]]]
            steps.append(["type": "wait", "command": "switch_session", "data": ["cancelled": false]])
            steps.append(["type": "respond", "command": "get_state", "data": ["sessionId": "session-1", "sessionName": "koa-md", "sessionFile": sessionFile.path, "thinkingLevel": "high", "model": ["id": "claude-opus-5-5", "provider": "anthropic"]]])
            let nextUser: [String: Any] = ["role": "user", "timestamp": stamp - 3480000, "content": [["type": "text", "text": "Agent cards render Markdown; the queue goes above the field"]]]
            let nextReply = assistant([["type": "text", "text": "Done: the cards render through the reply's Markdown renderer, collapsed to one plain line."]])
            let nextMessages: [[String: Any]] = [nextUser, nextReply]
            steps.append(["type": "respond", "command": "get_messages", "data": ["messages": nextMessages]])
            steps.append(["type": "respond", "command": "get_session_stats", "data": ["totalMessages": 96, "contextUsage": ["tokens": 46000, "contextWindow": 200000, "percent": 23]]])
            let commandEvent: [String: Any] = ["type": "bash_execution_update", "delta": "running 212 tests"]
            let commandResult: [String: Any] = ["output": "cancelled", "cancelled": true, "truncated": false]
            steps.append(["type": "wait", "command": "bash", "gate": true, "events": [commandEvent], "data": commandResult])
            let running = assistant([["type": "toolCall", "id": "verify", "name": "bash", "arguments": ["command": "make verify STAGES=unit"]]], stop: "toolUse")
            prompt([["type": "agent_start"], ["type": "message_start", "message": person], ["type": "message_end", "message": person], ["type": "message_start", "message": running], ["type": "tool_execution_start", "toolCallId": "verify"]])
            steps.append(["type": "wait", "command": "abort", "events": [["type": "agent_settled", "aborted": true]]])
            steps.append(["type": "wait", "command": "new_session", "data": ["cancelled": false]])
            steps.append(["type": "respond", "command": "get_state", "data": ["sessionId": "fresh", "sessionName": "pi", "sessionFile": sessionFile.path, "thinkingLevel": "high", "model": ["id": "claude-opus-5-5", "provider": "anthropic"]]])
            steps.append(["type": "respond", "command": "get_messages", "data": ["messages": []]])
            steps.append(["type": "respond", "command": "get_session_stats", "data": ["totalMessages": 0, "contextUsage": ["tokens": 0, "contextWindow": 200000, "percent": 0]]])
        }
        if captures.contains("geometry") {
            steps = Array(steps.prefix(3))
            steps.append(["type": "wait", "command": "get_available_models", "data": ["models": [["id": "claude-opus-5-5", "provider": "anthropic"]]]])
            prompt([])
        }
        if scenario == .notices {
            steps = Array(steps.prefix(4))
            steps[0]["data"] = ["sessionName": "sidebar-right", "thinkingLevel": "high", "model": ["id": "claude-opus-5-5", "provider": "anthropic"], "sessionFile": sessionFile.path]
            var failed = assistant([["type": "text", "text": "Verified: every stage passes."]], stop: "error")
            failed["errorMessage"] = "provider down: 529 overloaded, retry in a minute or switch the model with /model"
            steps[1]["data"] = ["messages": [
                ["role": "user", "timestamp": stamp, "content": "Verify the sidebar unit"], failed,
                ["role": "compactionSummary", "timestamp": stamp + 60000, "tokensBefore": 184000, "summary": "The session verified the sidebar-right unit and fixed two snapshot tests.\n\nOpen: the +N overflow on rows under 215pt, and the tap revision for the release notes."],
                ["role": "branchSummary", "timestamp": stamp + 120000, "fromId": "entry", "summary": "The abandoned branch tried a fixed row height and dropped it because folded clusters clip."],
                ["role": "custom", "customType": "release-check", "display": true, "timestamp": stamp + 180000, "content": "Release check passed\nThe tap is clean.\nThe revision is 20857320.", "details": ["from": "release"]],
            ]]
        }
        if scenario == .commands {
            steps = Array(steps.prefix(4))
            steps[0]["data"] = ["sessionName": "sidebar-right", "thinkingLevel": "high", "model": ["id": "claude-opus-5-5", "provider": "anthropic"], "sessionFile": sessionFile.path]
            steps[1]["data"] = ["messages": [["role": "user", "timestamp": stamp, "content": "Verify the sidebar unit"], assistant([["type": "text", "text": "Verified: every stage passes. The snapshots that changed are the twelve of SidebarTests."]])]]
            steps[2]["data"] = ["sessionId": "9702ddd1-4c2a-7e31-b0f8-6d1a2e9c0a11", "sessionFile": "~/.pi/agent/sessions/--Users-andrepopp-Workspace-kido/2026-11-10T09-02-11_9702ddd1.jsonl", "userMessages": 61, "assistantMessages": 98, "toolCalls": 53, "toolResults": 53, "totalMessages": 212, "tokens": ["input": 184000, "output": 12000, "cacheRead": 1600000, "cacheWrite": 142000, "total": 1938000], "cost": 1.42, "contextUsage": ["tokens": 84000, "contextWindow": 200000, "percent": 42]]
            steps.append(["type": "respond", "command": "get_commands", "data": ["commands": [["name": "release", "description": "Release Kido.app first, then ko", "source": "prompt"]]]])
            steps.append(["type": "wait", "command": "get_last_assistant_text", "data": ["text": String(repeating: "x", count: 2100)]])
            steps.append(["type": "wait", "command": "export_html", "data": ["path": "~/Workspace/kido/.pi/export/2026-11-10-sidebar.html"]])
            steps.append(["type": "wait", "command": "compact", "events": [["type": "compaction_start", "reason": "manual"]]])
            prompt([["type": "compaction_end", "reason": "manual", "result": ["summary": "The session verified the sidebar-right unit (right-side indicators, chevrons, folded clusters) and fixed two snapshot tests; the user approved the dividers-and-fill grouping and the breadcrumb pill. Open: the +N overflow on rows under 215pt. Files touched: SidebarRow.swift, SidebarView.swift, Rows.swift.", "firstKeptEntryId": "first", "tokensBefore": 184000, "estimatedTokensAfter": 31000], "willRetry": false]])
            steps.append(["type": "wait", "command": "compact", "defer": true, "events": [["type": "compaction_start", "reason": "manual"]]])
            steps.append(["type": "wait", "command": "abort", "events": [["type": "compaction_end", "reason": "manual", "aborted": true, "willRetry": false]]])
            steps.append(["type": "wait", "command": "compact", "error": "The model request failed"])
        }
        try steps.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        let path = [tools.prefix + "/bin", "/opt/homebrew/bin", ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let clock = directory.appendingPathComponent("clock.mjs")
        let now = directory.appendingPathComponent("now")
        try String(stamp).write(to: now, atomically: true, encoding: .utf8)
        let nowJSON = String(decoding: try JSONSerialization.data(withJSONObject: now.path, options: .fragmentsAllowed), as: UTF8.self)
        try "import {readFileSync} from 'node:fs'; Date.now = () => Number(readFileSync(\(nowJSON), 'utf8'));".write(to: clock, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("koa.stderr")
        let fd = directory.appendingPathComponent("fd")
        if scenario == .completion {
            try #"""
            #!/usr/bin/env node
            const args=process.argv.slice(2);let rest=args.slice(16),shallow=rest[0]==='--max-depth';if(shallow)rest=rest.slice(2);if(rest[0]==='--')rest=rest.slice(1);const query=new RegExp(rest[0]||'','i');const paths=['share/pi/skills/','share/pi/ko-pi.ts','app/App/SidebarView.swift','app/App/SidebarRow.swift','app/design/sidebar/mockup.html','ko_server/src/sign.rs','scripts/ci-like.sh','ko_sys/src/signal.rs','ko_pane/src/io.rs','ko_tui/src/mirror.rs','ko_server/','ko_shell/','ko_sys/','ko_server/src/','ko_server/src/sweep.rs','ko_server/src/state.rs','ko_server/src/api.rs','ko_shell/src/session.rs','ko_sys/src/spawn.rs','ko_sys/src/pid.rs','ko_server/src/lib.rs','ko_shell/src/bin_dir.rs'];console.log(paths.filter(p=>(!shallow||p.replace(/\/$/,'').split('/').length===1)&&query.test(p)).join('\n'));
            """#.write(to: fd, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fd.path)
        }
        let command = "export HOME=\(SSH.quote(home.path)) PATH=\(SSH.quote(path)) KOA_FAKE_SCRIPT=\(SSH.quote(script.path)) NODE_OPTIONS=\(SSH.quote("--import " + clock.path))" + (scenario == .completion ? " KOA_FD=\(SSH.quote(fd.path))" : "") + (scenario == .sessions ? " KOA_FAKE_SESSIONS_FILE=\(SSH.quote(sessionRows.path)) KOA_FAKE_SESSION_FILE_GATE=\(SSH.quote(sessionGate.path))" : "") + "; exec \(SSH.quote(tools.prefix + "/share/ko/bin/koa")) --pi \(SSH.quote(fake)) 2>\(SSH.quote(output.path))"
        if scenario == .completion {
            let idle = "stty raw -echo; printf '\\033]7501;state=idle:app=pi\\033\\\\'; exec cat"
            let working = "stty raw -echo; printf '\\033]7501;state=working:app=pi\\033\\\\'; exec cat"
            let rootVars = String(decoding: try JSONEncoder().encode(["pi.name": "kido-app", "pi.session": "kido-app-session"]), as: UTF8.self)
            try await start(width: width, height: height, windows: #"[{"tree":\#(koPane(idle, vars: rootVars))}]"#)
            func create(_ name: String, parent: PaneID, script: String, activity: String = "") async throws -> Snapshot.Position {
                let body = KoSchema.CreatePane(command: .shell(.init(command: script)), parent: parent, vars: ["pi.name": .string(name), "pi.session": .string(name + "-session"), "pi.activity": .string(activity)])
                let input = directory.appendingPathComponent(name + ".json")
                try JSONEncoder().encode(body).write(to: input)
                return try JSONDecoder().decode(Snapshot.Position.self, from: Data(try await ko(["api", "-X", "POST", "--input", input.path, "/panes"], dir: directory.path).utf8))
            }
            let manager = try await create("sidebar-right", parent: PaneID(number: 1), script: working, activity: "applying the review findings")
            let viewer = try await create("viewer", parent: manager.pane, script: command)
            _ = try await create("simplify-reuse", parent: manager.pane, script: idle)
            _ = try await create("simplify-altitude", parent: manager.pane, script: working, activity: "reading the diff")
            for name in ["sidebar-right", "simplify-reuse", "simplify-altitude"] {
                try await koUntil(directory.path, "/layout", contains: "\"session\":\"\(name)-session\"")
            }
            try client?.select(KO_SELECT_PANE, viewer.pane)
            try await wait("completion viewer selected") { self.terminal?.activePane?.pane == viewer.pane }
        } else {
            try await start(width: width, height: height, pane: command)
        }
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
        koaContentSize(window: window, width: width, height: height)
        let pane = try XCTUnwrap(terminal?.displayedPanes.first)
        try await wait("koa webview", within: 20) { (pane.webviewView?.visualDocuments ?? 0) > 0 }
        let diagnostics = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let web = try XCTUnwrap(pane.webviewView?.browser, diagnostics)
        if scenario == .feed {
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
                let response = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'next',mode:'prompt',attachments:[]})}).then(async r=>({status:r.status,body:await r.json()}))")
                XCTAssertTrue(response.contains("\"status\":200"), response)
                try await wait("feed chunk \(index) handed to WebKit", within: 5) { pane.webviewView!.visualFeedBytes > before + 4096 }
            }
            let handed = pane.webviewView!.visualFeedBytes
            try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('.assistant p')?.textContent==='x'.repeat(12288)", within: 5)
            XCTAssertEqual(pane.webviewView!.visualFeedBytes, handed)
            let open = try await webviewJS(web, "feedSource.readyState===EventSource.OPEN")
            XCTAssertEqual(open, "true")
            let final = try await webviewJS(web, "document.querySelector('.assistant p').textContent")
            XCTAssertEqual(final, "\"" + String(repeating: "x", count: 12288) + "\"")
            return
        }
        func settle() async throws {
            guard measured else { return }
            _ = try await webviewJS(web, "new Promise((resolve,reject)=>{let previous,stable=0,frame;const timer=setTimeout(()=>{cancelAnimationFrame(frame);reject(Error('Koa capture did not settle'))},5000);function sample(){const cursor=document.querySelector('#prompt .cm-cursor')?.getBoundingClientRect();const state=JSON.stringify([document.querySelector('#scroll').scrollTop,document.querySelector('#dock').getBoundingClientRect().height,cursor?[cursor.x,cursor.y,cursor.width,cursor.height]:null]);stable=koaPendingFrames.size===0&&state===previous?stable+1:0;previous=state;if(stable>=2){clearTimeout(timer);resolve(true)}else frame=requestAnimationFrame(sample)}frame=requestAnimationFrame(sample)})")
        }
        func pageSnapshot(_ name: String, _ appearance: String) async throws {
            if name.hasPrefix("focus-border") {
                try await webviewSnapshot(pane, name + appearance, testName: "testKoaWebviewMockupStates()")
            } else {
                let baseline = ["foot-responsive-190-cwd": "foot-responsive-190-working", "foot-responsive-250-cwd": "foot-responsive-250-working",
                                "foot-responsive-374-cwd": "foot-responsive-374-working", "narrow-foot-extras": "narrow-foot-idle"][name] ?? name
                try await webviewPageSnapshot(pane, baseline + appearance, testName: "testKoaWebviewMockupStates()")
            }
        }
        func capture(_ name: String) async throws {
            guard captures.contains(name) || captures.contains("foot-responsive") else { return }
            let ordered = name == "questions-ordered" || name == "narrow-questions-ordered"
            let top = scenario == .questions || scenario == .media || scenario == .lightbox || scenario == .agents || scenario == .composer
            window.contentView?.layoutSubtreeIfNeeded()
            pane.webviewView?.layoutSubtreeIfNeeded()
            let viewportHeight = try await webviewJS(web, "innerHeight")
            XCTAssertEqual(viewportHeight, String(Int(web.bounds.height)), "The page fills the native webview at capture \(name)")
            _ = try await webviewJS(web, "(()=>{if(\(name != "focus-border-transcript")&&!document.querySelector('.lightbox')&&!document.querySelector('.dialog')&&!document.querySelector('#exited:not([hidden])')&&document.querySelector('#picker').hidden)window.composer.focus();const scroll=document.querySelector('#scroll');scroll.scrollTop=\(top ? "0" : "scroll.scrollHeight");if(\(ordered))document.querySelectorAll('.assistant')[1].scrollIntoView({block:'start'});return true})()")
            try await webviewUntil(web, "(()=>{const dock=document.querySelector('#dock');return Number.parseFloat(getComputedStyle(document.body).getPropertyValue('--dock-h'))===dock.getBoundingClientRect().height})()")
            try await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');if(\(ordered)){document.querySelectorAll('.assistant')[1].scrollIntoView({block:'start'});return true}scroll.scrollTop=\(top ? "0" : "scroll.scrollHeight");return \(top ? "scroll.scrollTop===0" : "scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<1")})()")
            let lastAboveDock = try await webviewJS(web, "(()=>{const last=document.querySelector('#items').lastElementChild;return !last||last.getBoundingClientRect().bottom<=document.querySelector('#dock').getBoundingClientRect().top})()")
            if !top { XCTAssertEqual(lastAboveDock, "true", "dock space keeps the last message above the composer") }
            if name.hasSuffix("queue") {
                let order = try await webviewJS(web, "(()=>{const composer=document.querySelector('#composer'),queue=document.querySelector('#queue'),attachments=document.querySelector('#attachments'),field=document.querySelector('#field');return composer.firstElementChild===queue&&queue.nextElementSibling===attachments&&Math.abs(queue.getBoundingClientRect().bottom+8-(attachments.hidden?field:attachments).getBoundingClientRect().top)<.5})()")
                XCTAssertEqual(order, "true", "Queued steers and follow-ups stay above the attachment chips and composer field")
            }
            try await settle()
            try await pageSnapshot(name, "-light")
            try await darken()
            pane.webviewView?.updateTheme()
            try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
            try await settle()
            try await pageSnapshot(name, "-dark")
            try await darken(.aqua)
            pane.webviewView?.updateTheme()
            try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='light'")
        }
        func advance() async throws {
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'next',mode:'prompt',attachments:[]})}).then(async r=>{const result=await r.json();if(!r.ok)throw Error(result.error||'Prompt failed');return result})")
        }
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#model-name').textContent==='claude-opus-5-5'")
        _ = try await webviewJS(web, "(()=>{const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[\(stamp + 12000)]))}static now(){return \(stamp + 12000)}};const style=document.createElement('style');style.textContent='.caret,.spin,.spin::before,.dot.on,.cm-cursorLayer,.typing i\(scenario == .reveal ? "" : ",.grow"){animation:none!important}\(scenario == .reveal ? ".grow{animation-play-state:paused!important;animation-delay:-110ms!important}" : "").info .chev{transition:none!important}';document.head.append(style);return true})()")
        if scenario == .reveal {
            try await webviewUntil(web, "document.querySelector('.more')?.textContent==='Show 5 more lines'")
            let history = try await webviewJS(web, "document.querySelector('.assistant pre').classList.contains('folded')&&!document.querySelector('.grow,.typing')")
            XCTAssertEqual(history, "true", "A history fence is folded and nothing is revealed")
            try await capture("reveal-fold")
            let opened = try await webviewJS(web, "(()=>{const pre=document.querySelector('.assistant pre'),before=pre.getBoundingClientRect().height;document.querySelector('.more').click();return !document.querySelector('.more')&&!pre.classList.contains('folded')&&pre.getBoundingClientRect().height>before})()")
            XCTAssertEqual(opened, "true", "A click expands the fence in place")
            try await advance(); try await advance()
            try await webviewUntil(web, "document.querySelector('.typing')")
            _ = try await webviewJS(web, "(()=>{koaStep(16);return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.grow').length>=2")
            try await capture("reveal-mid")
            let hidden = try await webviewJS(web, "document.querySelectorAll('.assistant')[1].querySelector('pre')===null")
            XCTAssertEqual(hidden, "true", "A tail fence with unfinished lines stays hidden until the time cap")
            _ = try await webviewJS(web, "(()=>{koaStep(1500);return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.assistant')[1].querySelector('pre code')?.textContent==='let a = 1\\nlet b = 2\\n'")
            return
        }
        if scenario == .thinkingMarkdown {
            try await webviewUntil(web, "document.querySelector('.step')!==null")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelector('.step>.line').click();return true})()")
            try await webviewUntil(web, "document.querySelector('.think h1')!==null&&document.querySelector('.think strong')!==null&&document.querySelector('.think ul')!==null&&document.querySelector('.think pre code')!==null")
            let styles = try await webviewJS(web, "(()=>{const think=document.querySelector('.think'),pre=think.querySelector('pre'),heading=think.querySelector('h1'),style=getComputedStyle(think),code=getComputedStyle(pre);return style.maxHeight==='260px'&&style.whiteSpace==='normal'&&code.maxHeight==='none'&&code.overflowY==='hidden'&&code.color===style.color&&getComputedStyle(heading).fontSize===style.fontSize&&Math.abs(pre.getBoundingClientRect().height-62)<4})()")
            XCTAssertEqual(styles, "true", "Thinking uses one vertical scroller and compact code and headings")
            try await capture(width < 750 ? "narrow-thinking-markdown" : "thinking-markdown")
            return
        }
        if captures.contains("focus-border-transcript") {
            try await advance(); try await advance()
            try await webviewUntil(web, "document.querySelector('.assistant p')!==null")
            _ = try await webviewJS(web, "(()=>{const transcript=document.querySelector('#transcript');transcript.tabIndex=-1;transcript.focus();const range=document.createRange();range.selectNodeContents(document.querySelector('.assistant p'));getSelection().removeAllRanges();getSelection().addRange(range);return true})()")
            let focused = try await webviewJS(web, "document.activeElement===document.querySelector('#transcript')&&document.querySelector('#field').classList.contains('focus')")
            XCTAssertEqual(focused, "true")
            try await capture("focus-border-transcript")
            return
        }
        let idleHint = try await webviewJS(web, "document.querySelector('#hint .spin')===null")
        XCTAssertEqual(idleHint, "true")
        if scenario == .bang && completionCaptures {
            try await koaBangCompletion(web: web, window: window, width: width, capture: capture)
            return
        }
        if scenario == .bang {
            let prefix = width < 750 ? "narrow-" : ""
            func resize(_ height: CGFloat) { koaContentSize(window: window, width: width, height: height) }
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make checks DRY=1');return true})()")
            try await capture(prefix + "bang")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!!git status --short');return true})()")
            try await capture(prefix + "bang2")
            resize(300)
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');window.ko.local=true;window.dispatchEvent(new CustomEvent('ko-drop',{detail:{files:[{id:'bang-chip',name:'notes.md',path:'/tmp/notes.md',origin:'path',kind:'file',mimeType:'text/markdown',size:8192}],refused:false}}));window.composer.setText('!make checks DRY=1');return true})()")
            try await capture(prefix + "bang-attachments")
            _ = try await webviewJS(web, "(()=>{window.ko.local=true;window.dispatchEvent(new CustomEvent('ko-drop',{detail:{files:[{id:'refused-drop',name:'other.md',path:'/tmp/other.md',origin:'path',kind:'file',mimeType:'text/markdown',size:1}],refused:false}}));return true})()")
            try await webviewUntil(web, "document.querySelector('#error').textContent==='a command takes no attachments'")
            try await capture(prefix + "bang-drop")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.attach-remove').click();window.composer.setText('');document.querySelector('#error').textContent='';return true})()")
            resize(560)
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===5")
            _ = try await webviewJS(web, "(()=>{const lines=document.querySelectorAll('.cmdrun>.line');lines[0].click();lines[2].click();lines[4].click();return true})()")
            try await capture(prefix + "bang-runs")
            resize(330)
            for name in ["done", "error", "cancelled", "truncated", "quiet"] {
                try await advance()
                try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===1")
                if name != "quiet" { _ = try await webviewJS(web, "(()=>{document.querySelector('.cmdrun>.line').click();return true})()") }
                try await capture(prefix + "bang-" + name)
            }
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===0")
            resize(220)
            try String(stamp + 9000).write(to: now, atomically: true, encoding: .utf8)
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!make verify STAGES=unit',mode:'prompt',attachments:[]})}).then(r=>r.json())")
            try await webviewUntil(web, "document.querySelector('.cmdrun .live')?.textContent.includes('running 212 tests')&&document.querySelector('#status').textContent.startsWith('running')")
            try await capture(prefix + "bang-running")
            _ = try await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
            try await webviewUntil(web, "!document.querySelector('.cmdrun .live')")
            try String(stamp).write(to: now, atomically: true, encoding: .utf8)
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('working')")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!git status --short');return true})()")
            try await capture(prefix + "bang-typing")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 14000);return true})()")
            try String(stamp + 13000).write(to: now, atomically: true, encoding: .utf8)
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!git status --short',mode:'prompt',attachments:[]})}).then(r=>{window.composer.setText('');return r.json()})")
            try await webviewUntil(web, "document.querySelector('.cmdrun .live')?.textContent.includes('SidebarRow.swift')")
            try await capture(prefix + "bang-busy")
            try String(stamp + 14000).write(to: now, atomically: true, encoding: .utf8)
            _ = try await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
            try await webviewUntil(web, "document.querySelector('.cmdrun .meta')?.textContent==='cancelled1s'")
            resize(330)
            try await capture(prefix + "bang-completed")
            return
        }
        if scenario == .notices {
            let prefix = width < 600 ? "narrow-notices-" : "notices-"
            try await webviewUntil(web, "document.querySelectorAll('.nrow').length===4")
            try await capture(prefix + "closed")
            try await webviewUntil(web, "document.querySelectorAll('.nrow.more').length>=3")
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.nrow.more>.hd').forEach(header=>header.click());return true})()")
            try await capture(prefix + "open")
            return
        }
        if scenario == .commands {
            let prefix = width < 600 ? "narrow-commands-" : "commands-"
            func submit(_ text: String) async throws {
                let value = String(decoding: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
                _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:\(value),mode:'prompt',attachments:[]})}).then(async r=>{const body=await r.json();if(!r.ok)throw Error(body.error);return body})")
            }
            try await submit("/copy")
            try await webviewUntil(web, "document.querySelector('.nrow')?.textContent.includes('copied the last reply')")
            try await capture(prefix + "copy")
            try await submit("/export")
            try await webviewUntil(web, "document.querySelectorAll('.nrow').length===2")
            try await capture(prefix + "export")
            if width < 600 {
                try await webviewUntil(web, "document.querySelector('.nrow.more')!==null")
                _ = try await webviewJS(web, "(()=>{document.querySelector('.nrow.more>.hd').click();return true})()")
                try await capture(prefix + "export-open")
                _ = try await webviewJS(web, "(()=>{document.querySelector('.nrow.more>.hd').click();return true})()")
            }
            try await submit("/settings")
            try await webviewUntil(web, "document.querySelector('.nrow.warning')!==null")
            try await capture(prefix + "refused")
            try await submit("/session")
            try await webviewUntil(web, "document.querySelector('.nrow .kv')!==null")
            try await capture(prefix + "session-closed")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.nrow .kv').closest('.nrow').querySelector('.hd').click();return true})()")
            try await capture(prefix + "session-open")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.nrow .kv').closest('.nrow').querySelector('.hd').click();return true})()")
            try await submit("/compact")
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('compacting')")
            try await capture(prefix + "compacting")
            try await advance()
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.nrow')).some(node=>node.textContent.includes('compacted'))")
            _ = try await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.nrow')).find(node=>node.textContent.includes('compacted')).querySelector('.hd').click();return true})()")
            try await capture(prefix + "compacted-open")
            try await submit("/compact")
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('compacting')")
            _ = try await webviewJS(web, "fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())")
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.nrow')).some(node=>node.textContent.includes('compaction cancelled'))")
            try await capture(prefix + "compact-cancelled")
            try await submit("/compact")
            try await webviewUntil(web, "document.querySelector('.nrow.error')!==null")
            try await capture(prefix + "compact-failed")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');window.composer.focus();document.execCommand('insertText',false,'/');return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.koa-complete li').length>0")
            try await capture(prefix + "popup")
            return
        }
        if scenario == .sessions {
            let prefix = width < 600 ? "narrow-sessions-" : "sessions-"
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker').dataset.state==='list'")
            try await capture(prefix + "pick")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.sess .scope button:last-child').click();return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.sess .row').length===10")
            try await capture(prefix + "all")
            _ = try await webviewJS(web, "(()=>{const q=document.querySelector('.sess .q');q.value='side';q.dispatchEvent(new Event('input'));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker').dataset.state==='filtered'&&document.querySelectorAll('.sess .row').length>0&&document.querySelectorAll('.sess .row').length<10")
            try await capture(prefix + "filtered")
            _ = try await webviewJS(web, "(()=>{const q=document.querySelector('.sess .q');q.value='no-such-session';q.dispatchEvent(new Event('input'));return true})()")
            try await webviewUntil(web, "document.querySelector('.sess .empty')?.textContent.includes('no match')")
            try await capture(prefix + "no-match")
            let savedSessions = try Data(contentsOf: sessionRows)
            try Data("[]".utf8).write(to: sessionRows)
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('.sess .empty')?.textContent.includes('no sessions')")
            try await capture(prefix + "empty")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true})()")
            try savedSessions.write(to: sessionRows)
            try Data("hold".utf8).write(to: sessionGate)
            _ = try await webviewJS(web, "(()=>{void fetch('/sessions/switch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,path:'/tmp/koa-visual-session-1'})});return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='loading'")
            try await capture(prefix + "loading")
            try FileManager.default.removeItem(at: sessionGate)
            try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#items').textContent.includes('session: koa-md · 96 messages')")
            try await capture(prefix + "after")
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'!make verify STAGES=unit',mode:'prompt',attachments:[]})}).then(r=>r.json())")
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('running')&&document.querySelector('.cmdrun .live')?.textContent.trim()==='running 212 tests'")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker .msg2')?.textContent==='a command is running; it will be cancelled.'")
            try await capture(prefix + "confirm-bash")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())})()")
            try await webviewUntil(web, "document.querySelectorAll('.cmdrun').length===0&&document.querySelector('#status').textContent==='idle'")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent.startsWith('working')")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/resume');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#session-picker .title')?.textContent==='Switch session?'")
            try await capture(prefix + "confirm")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#session-picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return fetch('/abort',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId})}).then(r=>r.json())})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='aborted'")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/new');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#items').textContent.includes('new session')&&!document.querySelector('#items').textContent.includes('Done:')")
            try await capture(prefix + "new")
            return
        }
        if scenario == .questions {
            try await webviewUntil(web, "document.querySelectorAll('.ann-opt').length===13")
            let structure = try await webviewJS(web, "(()=>{const first=document.querySelector('.assistant li'),paragraph=Array.from(document.querySelectorAll('.assistant p')).find(p=>p.textContent.includes('Do you want'));return first.querySelectorAll('[role=button]').length===2&&first.querySelectorAll('button').length===1&&paragraph.querySelector('.ann-ctl').nextSibling.textContent.startsWith(' It costs')&&!document.querySelector('.assistant').textContent.match(/[\\uE010-\\uE012]/)})()")
            XCTAssertEqual(structure, "true")
            _ = try await webviewJS(web, "(()=>{const style=document.createElement('style');style.textContent='.ann-opt.snapshot-hover{background:color-mix(in srgb,var(--ko-color-4) 12%,var(--ko-bg));text-decoration-color:var(--ko-color-4)}.ann-ctl .snapshot-hover{border-color:var(--ko-color-4)}';document.head.append(style);const choices=document.querySelectorAll('.assistant li');choices[0].querySelectorAll('.ann-opt')[1].classList.add('snapshot-hover');choices[1].querySelector('button').classList.add('snapshot-hover');return true})()")
            try await capture("questions-reply")
            try await capture("narrow-questions-reply")
            let answered = try await webviewJS(web, #"(()=>{const rows=document.querySelectorAll('.assistant li');rows[0].querySelectorAll('.ann-opt')[1].dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));rows[1].querySelector('button').click();document.querySelectorAll('.snapshot-hover').forEach(b=>b.classList.remove('snapshot-hover'));return window.composer.text()})()"#)
            XCTAssertEqual(answered, #""> Should I push now, or wait for CI on the rebase?\nwait for CI\n\n> The breadcrumb test is flaky on Linux. I recommend skipping it on Linux for now.\nYes""#)
            try await capture("questions-answered")
            try await capture("narrow-questions-answered")
            let clicks = try await webviewJS(web, #"(()=>{const rows=document.querySelectorAll('.assistant li'),editor=window.composer;rows[0].querySelector('.ann-opt').dispatchEvent(new KeyboardEvent('keydown',{key:' ',bubbles:true,cancelable:true}));if(!editor.text().includes('\npush now\n\n> ')||document.querySelectorAll('.ann-opt.sel').length!==2)return 'replace';rows[0].querySelector('.ann-ctl button').click();if(!editor.text().includes('rebase?\n\n\n> '))return 'Other';const open=Array.from(document.querySelectorAll('.ann-ctl button')).find(b=>b.textContent==='Answer');open.click();editor.setText(editor.text()+'Food');open.click();if(!editor.text().endsWith('called?\nFood'))return 'Answer';editor.setText('');if(document.querySelector('.ann-opt.sel'))return 'clear selected';editor.setText('not a boundary > Should I push now, or wait for CI on the rebase?\npush now');if(rows[0].querySelector('.sel'))return 'invalid quote boundary selected';editor.setText('');return 'ok'})()"#)
            XCTAssertEqual(clicks, "\"ok\"")
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.assistant').length===2&&document.querySelectorAll('.ann-ctl').length===10")
            try await capture("questions-ordered")
            try await capture("narrow-questions-ordered")
            let marked = try await webviewJS(web, #"(()=>{const reply=document.querySelectorAll('.assistant')[1];if(!reply.textContent.includes('Literal �999;x�')||/[\uE010-\uE012]/.test(reply.textContent)||!reply.querySelector('.ann-opt code')||!reply.querySelector('.ann-opt strong')||!reply.querySelector('li .ann-ctl')||!reply.querySelector('h2 .ann-ctl')||!reply.querySelector('td .ann-ctl'))return reply.innerHTML;reply.querySelector('.ann-opt code').parentElement.click();return window.composer.text()})()"#)
            XCTAssertEqual(marked, #""> 😀 Pick one or two?\none""#)
            return
        }
        if scenario == .composer && captures.contains("foot-responsive") {
            func widths(_ state: String, sizes: [CGFloat] = [674, 554, 374, 250, 190]) async throws {
                for size in sizes {
                    koaContentSize(window: window, width: size, height: height)
                    window.contentView?.layoutSubtreeIfNeeded(); pane.webviewView?.layoutSubtreeIfNeeded()
                    let viewportWidth = Int(web.bounds.width)
                    try await webviewUntil(web, "innerWidth===\(viewportWidth)")
                    let fits = try await webviewJS(web, "(()=>{const foot=document.querySelector('.field .foot'),field=document.querySelector('#field');return foot.scrollWidth<=foot.clientWidth&&foot.getBoundingClientRect().right<=field.getBoundingClientRect().right})()")
                    XCTAssertEqual(fits, "true", "The foot stays inside the field at pane width \(viewportWidth)")
                    try await capture("foot-responsive-\(Int(size))-" + state)
                }
            }
            try await widths("idle")
            koaContentSize(window: window, width: 374, height: height)
            window.contentView?.layoutSubtreeIfNeeded(); pane.webviewView?.layoutSubtreeIfNeeded()
            let pickerViewportWidth = Int(web.bounds.width)
            try await webviewUntil(web, "innerWidth===\(pickerViewportWidth)&&document.querySelector('#model-cell').offsetParent===null")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('/model');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&Array.from(document.querySelectorAll('#picker .ph')).some(node=>node.textContent==='Thinking')")
            let modelPickerFits = try await webviewJS(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()")
            XCTAssertEqual(modelPickerFits, "true", "The model picker stays inside the viewport when its foot cell is hidden")
            try await capture("foot-responsive-374-picker")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));window.composer.setText('/thinking');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelector('#picker .ph').textContent==='Thinking'")
            let thinkingPickerFits = try await webviewJS(web, "(()=>{const r=document.querySelector('#picker').getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()")
            XCTAssertEqual(thinkingPickerFits, "true", "The thinking picker stays inside the viewport when its foot cell is hidden")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('!make checks');return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='run'")
            try await widths("run")
            _ = try await webviewJS(web, "(()=>{const nativeFetch=window.fetch;window.fetch=(url,options)=>url==='/complete'?new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(new DOMException('Aborted','AbortError')),{once:true})):nativeFetch(url,options);window.composer.setText('!git checkout kido-');document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',keyCode:9,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "document.querySelector('#status').textContent==='completing…'")
            try await widths("completing")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');Date.now=()=>\(stamp + 754000);return true})()")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent==='working 12m 34s'")
            try await widths("working")
            _ = try await webviewJS(web, "(()=>{footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,cwd:footState.home+'/Workspace/kido-sidebar-layout/app/App/SidebarFeed'})}));return true})()")
            try await widths("cwd")
            _ = try await webviewJS(web, "(()=>{footSource.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({...footState,model:{provider:'anthropic',id:'claude-opus-5-5-with-a-long-provider-specific-model-identifier-20261110'}})}));return true})()")
            try await widths("long-model", sizes: [674, 420])
            return
        }
        if scenario == .composer {
            let captureName = captures.first!, name = composerState
            let elapsed = name == "narrow" ? 754 : name == "toast-err" ? 62 : 12
            let offset = name == "toast" ? 60000 : name == "toast-err" ? 120000 : 0
            try String(stamp + offset).write(to: now, atomically: true, encoding: .utf8)
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + offset + 12000);return true})()")
            try await advance()
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + offset + elapsed * 1000);return true})()")
            if name == "exited" { try await webviewUntil(web, "document.querySelector('#status').textContent==='exited 137'&&!document.querySelector('#exited').hidden&&document.querySelector('#field').inert") }
            else if name == "waiting" { try await webviewUntil(web, "document.querySelector('#status').textContent==='waiting'") }
            else if ["working", "narrow", "toast-err"].contains(name) {
                let clock = name == "narrow" ? "12m 34s" : name == "toast-err" ? "1m 02s" : "12s"
                try await webviewUntil(web, "document.querySelector('#status').textContent==='working \(clock)'")
            }
            if name == "toast" || name == "toast-err" { try await webviewUntil(web, "document.querySelector('.nrow')!==null") }
            if name == "extras" { try await webviewUntil(web, "document.querySelectorAll('.foot .ext').length===2") }
            if name == "picker" {
                _ = try await webviewJS(web, "(()=>{document.querySelector('#model').click();return true})()")
                try await webviewUntil(web, "!document.querySelector('#picker').hidden")
                _ = try await webviewJS(web, "document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}))")
            }
            let facts = try await webviewJS(web, "document.querySelectorAll('.field .foot>.cell').length===4&&document.querySelector('#send')===null&&document.querySelector('#notice')===null&&document.querySelector('footer.status')===null&&document.querySelector('#model-cell').contains(document.querySelector('#thinking'))&&Math.abs(document.querySelector('#dock').getBoundingClientRect().bottom-innerHeight)<.1")
            XCTAssertEqual(facts, "true", "The bottom-edge composer has four fixed facts and no old controls")
            try await capture(captureName)
            return
        }
        if captures.contains("geometry") {
            let fixed = try await webviewJS(web, "(()=>{const label=document.querySelector('#status'),positions=()=>['model','context-bar','cwd'].map(id=>document.getElementById(id).getBoundingClientRect().left);label.textContent='idle';const idle=positions();label.textContent='working 9s';const short=positions();label.textContent='working 100m 00s';const long=positions();return idle.every((x,i)=>Math.abs(x-short[i])<.1&&Math.abs(x-long[i])<.1)})()")
            XCTAssertEqual(fixed, "true", "State and elapsed-time changes move no other composer cell")
            web.configuration.preferences.tabFocusesLinks = true
            XCTAssertTrue(window.makeFirstResponder(web))
            func key(_ text: String, _ code: UInt16) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                window.sendEvent(event)
            }
            _ = try await webviewJS(web, "(()=>{document.querySelector('#model').focus();return true})()")
            try key("\r", 36)
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelector('#picker .ph').textContent==='Model'")
            if width > 750 {
                _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));document.querySelector('#model').focus();return true})()")
                _ = try await webviewJS(web, "(()=>{document.querySelector('#thinking').focus();return true})()")
                try key("\r", 36)
                try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelector('#picker .ph').textContent==='Thinking'")
            } else {
                let levels = try await webviewJS(web, "Array.from(document.querySelectorAll('#picker .ph')).some(node=>node.textContent==='Thinking')")
                XCTAssertEqual(levels, "true", "The narrow model picker keeps levels reachable")
            }
            return
        }
        if scenario == .agents {
            let prefix = width < 750 ? "narrow-agents-" : "agents-"
            func size(_ height: CGFloat) { koaContentSize(window: window, width: width, height: height) }
            func openRuns(_ firstStep: Bool = false) async throws {
                _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.run>.line').forEach(line=>{if(line.getAttribute('aria-expanded')!=='true')line.click()});if(\(firstStep)){const line=document.querySelector('.step>.line');if(line?.getAttribute('aria-expanded')!=='true')line?.click()}return true})()")
            }
            func aligned() async throws {
                let result = try await webviewJS(web, "(()=>{const column=document.querySelector('#transcript'),edge=column.getBoundingClientRect().right-parseFloat(getComputedStyle(column).paddingRight),scroll=document.querySelector('#scroll').getBoundingClientRect();return Array.from(document.querySelectorAll('.user time,.aline time,.run .time,.job time')).every(time=>Math.abs(time.getBoundingClientRect().right-edge)<.5)&&Array.from(document.querySelectorAll('.user')).every(card=>{const r=card.getBoundingClientRect();return r.left>=scroll.left+4&&r.right<=scroll.right-4})})()")
                XCTAssertEqual(result, "true", "All times end at the column edge and wells keep the narrow paper margin")
            }
            try await webviewUntil(web, "document.querySelectorAll('.aline').length===5")
            try await openRuns(); try await aligned()
            _ = try await webviewJS(web, "(()=>{document.querySelector('.aline .hd').click();return true})()")
            let taskMarkdown = try await webviewJS(web, "(()=>{const body=document.querySelector('.aline .bd');return !!body.querySelector('ul li')&&!!body.querySelector('code')&&!!body.querySelector('strong')&&body.querySelector('a')?.getAttribute('href')==='https://example.com/sidebar'})()")
            XCTAssertEqual(taskMarkdown, "true", "Outbound task renders Markdown elements")
            try await capture(prefix + "out")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.aline').length===2&&document.querySelectorAll('.aline.err').length===2")
            size(330); try await aligned(); try await capture(prefix + "failed")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.aline').length===7")
            size(560)
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.aline .hd')[1].click();return true})()")
            let rendered = try await webviewJS(web, "(()=>{const body=document.querySelectorAll('.aline')[1].querySelector('.bd');return !!body.querySelector('ul li')&&!!body.querySelector('code')&&!!body.querySelector('strong')&&body.querySelector('a')?.getAttribute('href')==='https://example.com/sidebar'&&!body.querySelector('.caret')})()")
            XCTAssertEqual(rendered, "true", "Expanded agent body renders final Markdown elements")
            try await capture(prefix + "in")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.job').length===5")
            _ = try await webviewJS(web, "(()=>{Array.from(document.querySelectorAll('.job')).find(job=>job.querySelector('.nm').textContent==='lint').querySelector('.hd').click();return true})()")
            let gaps = try await webviewJS(web, "(()=>{const jobs=Array.from(document.querySelectorAll('.job')).filter(job=>job.getClientRects().length);return jobs.slice(1).map((job,index)=>Math.round(job.getBoundingClientRect().top-jobs[index].getBoundingClientRect().bottom)-(jobs[index].classList.contains('open')?14:2)).every(gap=>gap===0)})()")
            XCTAssertEqual(gaps, "true", "Consecutive job rows are 2pt apart, an opened row 14pt")
            try await aligned(); try await capture(prefix + "jobs")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.job').length===1&&document.querySelectorAll('.aline').length===1")
            let summary = try await webviewJS(web, "document.querySelector('.aline .tx').textContent==='Built the right-side indicators with SidebarRow.swift; see the reference. Pre-fix failures: 6 snapshot tests (SidebarTests.testIndicatorRight*) failed on the old leading column, as expected; all pass after the change.'")
            XCTAssertEqual(summary, "true", "Collapsed agent body has no Markdown syntax")
            size(330); try await capture(prefix + "fold-a")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.aline .hd').click();document.querySelector('.job .hd').click();return true})()")
            try await capture(prefix + "fold-b")
            try await advance(); try await webviewUntil(web, "document.querySelectorAll('.step').length===3&&document.querySelectorAll('.aline').length===0")
            size(300); try await openRuns(true); try await capture(prefix + "tools")
            return
        }
        if scenario == .preview {
            try await webviewUntil(web, "document.querySelectorAll('.step').length===3")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Meta',metaKey:true,shiftKey:true}));return true})()")
            _ = try await webviewJS(web, "(()=>{const rule=Array.from(document.styleSheets).flatMap(sheet=>Array.from(sheet.cssRules)).find(rule=>rule.selectorText?.includes('.preview-file:hover'));if(!rule)throw Error('Missing hover rule');const style=document.createElement('style');style.textContent=rule.cssText.replace(':hover','.snapshot-hover');document.head.append(style);document.querySelectorAll('.step .preview-file')[1].classList.add('snapshot-hover');return true})()")
            try await webviewUntil(web, "getComputedStyle(document.querySelectorAll('.step .preview-file')[1]).textDecorationLine.includes('underline')")
            try await capture("media-preview-hover")
            return
        }
        if scenario == .userMarkdown {
            try await webviewUntil(web, "document.querySelectorAll('.user').length===2&&document.querySelector('.user ul li')&&document.querySelector('.user pre code')&&document.querySelector('.user blockquote')")
            let markdown = try await webviewJS(web, "(()=>{const user=document.querySelector('.user'),plain=Array.from(document.querySelectorAll('.user')).at(-1),assistant=document.querySelector('.assistant .prose'),p=plain.querySelector('.prose p'),u=user.querySelector('.t').getBoundingClientRect(),a=assistant.getBoundingClientRect(),well=plain.getBoundingClientRect(),time=plain.querySelector('time').getBoundingClientRect(),scroll=document.querySelector('#scroll').getBoundingClientRect(),font=parseFloat(getComputedStyle(document.body).fontSize),terminal=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-font-size')),editor=getComputedStyle(document.querySelector('.cm-content'));return plain.querySelector('time').textContent==='14:32'&&user.querySelectorAll('ul li').length===2&&user.querySelectorAll('code').length===2&&user.querySelector('b')===null&&user.textContent.includes('<b>raw HTML stays text</b>')&&Math.abs(u.left-a.left)<.1&&Math.abs(u.right-a.right)<.1&&well.left>=scroll.left+4&&well.right<=scroll.right-4&&getComputedStyle(p).marginTop==='0px'&&getComputedStyle(p).marginBottom==='0px'&&Math.abs(well.height-p.getBoundingClientRect().height-16)<.1&&Math.abs(time.top-p.getBoundingClientRect().top)<.1&&Math.abs(font-terminal*.92)<.01&&Math.abs(parseFloat(editor.fontSize)-font)<.01&&Number.isInteger(parseFloat(editor.minHeight))})()")
            XCTAssertEqual(markdown, "true", "Markdown, first-line time, equal text widths, compact spacing and rounded composer size")
            let prefix = width < 750 ? "narrow-user-" : "user-"
            try await capture(prefix + "markdown")
            for (name, condition) in [("quote", "document.querySelectorAll('.user').length===1&&document.querySelectorAll('.user blockquote').length===1"), ("quote2", "document.querySelectorAll('.user blockquote').length===2"), ("code", "document.querySelector('.user pre code.language-json')!==null")] {
                try await advance(); try await webviewUntil(web, condition)
                if name == "code" {
                    let label = try await webviewJS(web, "getComputedStyle(document.querySelector('.user pre .lang')).display==='none'&&getComputedStyle(document.querySelector('.user pre code')).backgroundColor==='rgba(0, 0, 0, 0)'")
                    XCTAssertEqual(label, "true", "User code has no language label or doubled background")
                }
                try await capture(prefix + name)
            }
            return
        }
        if scenario == .attachments {
            let prefix = width < 750 ? "narrow-media-" : "media-"
            let shot = try Data(contentsOf: attachmentPaths.shot).base64EncodedString(), diagram = try Data(contentsOf: attachmentPaths.diagram).base64EncodedString()
            let source = String(decoding: try JSONSerialization.data(withJSONObject: attachmentPaths.source.path, options: .fragmentsAllowed), as: UTF8.self)
            _ = try await webviewJS(web, #"""
            (()=>{
              const timeout=window.setTimeout.bind(window);window.setTimeout=(fn,delay,...args)=>timeout(fn,delay===4000?60000:delay,...args);
              const bytes=text=>Uint8Array.from(atob(text),character=>character.charCodeAt(0));
              window.attachFiles={shot:new File([bytes('\#(shot)')],'Screenshot 2026-11-10 at 09.11.42.png',{type:'image/png'}),diagram:new File([bytes('\#(diagram)')],'diagram.png',{type:'image/png'}),notes:new File([new Uint8Array(8192)],'notes.md',{type:'text/plain'}),readme:new File([new Uint8Array(3072)],'README.md',{type:'text/plain'})};
              window.dropAttachments=files=>{const transfer=new DataTransfer();files.forEach(file=>transfer.items.add(file));document.querySelector('.cm-content').dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true};
              window.clearAttachments=()=>{document.querySelectorAll('.attach-remove').forEach(button=>button.click());window.composer.setText('');return true};
              const nativeFetch=window.fetch;window.fetch=async(url,options)=>{
                if(window.progressId&&String(url).startsWith('/attachments/'+window.progressId+'/')&&Number(String(url).split('/').at(-1))>=18*1048576){await new Promise((resolve,reject)=>{window.releaseUpload=resolve;options.signal.addEventListener('abort',()=>reject(new DOMException('Removed','AbortError')),{once:true})})}
                const response=await nativeFetch(url,options);
                if(url==='/attachments'&&typeof options?.body==='string'){const name=JSON.parse(options.body).name;if(name==='kido-demo.mov'||name==='notes.md'){const result=await response.clone().json();if(name==='kido-demo.mov')window.progressId=result.id;else window.notesPath=result.path}}
                return response;
              };
              window.composer.setText('Attach these to the review');
              const clipboard=new DataTransfer();clipboard.items.add(attachFiles.shot);clipboard.items.add(attachFiles.notes);document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:clipboard}));
              window.ko.local=true;
              return true;
            })()
            """#)
            pane.webviewView?.drop(files: [attachmentPaths.source.path], refused: false)
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&document.querySelectorAll('.attach-icon.spin').length===0")
            _ = try await webviewJS(web, "(()=>{window.ko.local=false;const large=new File([],'archive.tar.gz');Object.defineProperty(large,'size',{value:65*1048576});dropAttachments([new File([new Uint8Array(41*1048576)],'kido-demo.mov'),large]);return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===5&&Array.from(document.querySelectorAll('.attach-detail')).some(node=>node.textContent==='18 / 41 MB')&&document.querySelectorAll('.attach-icon img').length===1")
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.attach-icon img')).every(image=>image.complete&&image.naturalWidth>0)")
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.attach-icon img'),image=>image.decode())).then(()=>true)")
            let refusedStyle = try await webviewJS(web, "(()=>{const reason=document.querySelector('.attach-chip.refused .attach-detail'),reference=document.createElement('i');reference.style.color='var(--ko-color-1)';document.body.append(reference);const matches=getComputedStyle(reason).color===getComputedStyle(reference).color&&getComputedStyle(reason.closest('.attach-chip')).borderColor!==getComputedStyle(document.querySelector('.attach-chip')).borderColor;reference.remove();return matches})()")
            XCTAssertEqual(refusedStyle, "true", "The refused reason and border use the theme's error colour")
            let pasted = try await webviewJS(web, "window.composer.text()")
            XCTAssertEqual(pasted, "\"Attach these to the review\"", "File paste does not insert text")
            try await capture(prefix + "chips")
            _ = try await webviewJS(web, "(()=>{clearAttachments();const transfer=new DataTransfer();transfer.items.add(attachFiles.shot);document.dispatchEvent(new DragEvent('dragenter',{bubbles:true,cancelable:true,dataTransfer:transfer}));document.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true})()")
            try await webviewUntil(web, "document.querySelector('#field').classList.contains('drop')&&document.querySelector('.cm-placeholder').textContent==='Drop to attach'")
            try await capture(prefix + "drop")
            _ = try await webviewJS(web, "(()=>{const transfer=new DataTransfer();const folder=transfer.items.add(new File([],'fixtures'));Object.defineProperty(folder,'webkitGetAsEntry',{value:()=>({isDirectory:true})});transfer.items.add(attachFiles.diagram);transfer.items.add(attachFiles.readme);document.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&!document.querySelector('.attach-notice').hidden&&document.querySelectorAll('.attach-icon img').length===1&&document.querySelectorAll('.attach-icon.spin').length===0")
            try await webviewUntil(web, "Array.from(document.querySelectorAll('.attach-icon img')).every(image=>image.complete&&image.naturalWidth>0)")
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.attach-icon img'),image=>image.decode())).then(()=>true)")
            try await capture(prefix + "folder")
            _ = try await webviewJS(web, "(()=>{clearAttachments();window.Date.now=()=>\(stamp + 3000);return true})()")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent==='working 3s'&&document.querySelector('.run')!==null")
            _ = try await webviewJS(web, "(()=>{const run=document.querySelector('.run');if(run.classList.contains('open'))run.querySelector('.line').click();window.composer.setText(\"skip the Linux check, I'll run it in CI\");document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.queue .qmsg').length===1&&window.composer.text()===''")
            _ = try await webviewJS(web, "(()=>{dropAttachments([attachFiles.shot,attachFiles.diagram]);window.composer.setText('then compare with these two renders');return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&document.querySelectorAll('.attach-icon img').length===2")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',altKey:true,bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.queue .qmsg').length===2&&document.querySelector('.queue .att')?.textContent==='2'&&document.querySelectorAll('.attach-chip').length===0")
            try await capture(prefix + "queue")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',code:'ArrowUp',altKey:true,bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&window.composer.text().includes('then compare')&&document.querySelectorAll('#items .msg').length===0")
            let restored = try await webviewJS(web, "Array.from(document.querySelectorAll('.attach-detail')).every(node=>!node.classList.contains('path'))")
            XCTAssertEqual(restored, "true", "Take-back restores upload chips, not path chips")
            _ = try await webviewJS(web, #"""
            (()=>{clearAttachments();dropAttachments([attachFiles.shot,attachFiles.notes]);window.ko.local=true;window.composer.setText('Attach these to the review');return true})()
            """#)
            pane.webviewView?.drop(files: [attachmentPaths.source.path], refused: false)
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&document.querySelectorAll('.attach-icon.spin').length===0&&!document.querySelector('#field').inert")
            _ = try await webviewJS(web, "window.ko.local=false")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===0&&document.querySelector('.user .paths')?.textContent.includes('SidebarRow.swift')&&document.querySelector('.user .thumb img')!==null&&document.querySelector('#status').textContent==='working 3s'")
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.user .thumb img'),image=>image.decode())).then(()=>true)")
            let text = try await webviewJS(web, "document.querySelector('.user .t .prose').firstElementChild.textContent")
            XCTAssertEqual(text, "\"Attach these to the review\"", "The appended paths are separate data, not repeated prose")
            let actualPaths = try await webviewJS(web, #"document.querySelector('.user .paths').textContent===window.notesPath+'\n'+\#(source)"#)
            XCTAssertEqual(actualPaths, "true", "Sent paths identify the stored copy and the original file")
            let pathStyle = try await webviewJS(web, "(()=>{const p=getComputedStyle(document.querySelector('.user .paths')),u=getComputedStyle(document.querySelector('.user'));return p.fontFamily===getComputedStyle(document.querySelector('#status')).fontFamily&&Math.abs(parseFloat(p.fontSize)/parseFloat(u.fontSize)-.92)<.001})()")
            XCTAssertEqual(pathStyle, "true", "Attachment paths use the terminal font at .92em")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.user .paths').textContent='/Users/andrepopp/Desktop/notes.md\\n/Users/andrepopp/Workspace/kido/app/App/SidebarRow.swift';return true})()")
            try await capture(prefix + "sent")
            XCTAssertEqual(try String(contentsOf: attachmentPaths.source, encoding: .utf8), "row\n", "Removing a path chip never deletes the original")
            return
        }
        if scenario == .media || scenario == .lightbox {
            let prefix = width < 750 ? "narrow-media-" : "media-"
            func loaded(_ count: Int) async throws {
                try await webviewUntil(web, "document.querySelectorAll('.thumb:not(.gone) img').length===\(count)")
                _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.thumb:not(.gone) img'),image=>image.decode())).then(()=>true)")
                let dimensions = try await webviewJS(web, "Array.from(document.querySelectorAll('.thumb:not(.gone) img')).every(image=>image.naturalWidth>0&&image.naturalWidth===Number(image.getAttribute('width'))&&image.naturalHeight===Number(image.getAttribute('height')))")
                XCTAssertEqual(dimensions, "true", "The decoded pixels belong to this transcript epoch")
            }
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('.step').length===3")
            let lazy = try await webviewJS(web, "document.querySelectorAll('.thumb img').length")
            XCTAssertEqual(lazy, "0", "Collapsed steps do not create or request images")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelectorAll('.step>.line')[0].click();document.querySelectorAll('.step>.line')[2].click();return true})()")
            try await loaded(3)
            if scenario == .lightbox {
                window.contentView?.layoutSubtreeIfNeeded(); pane.webviewView?.layoutSubtreeIfNeeded()
                _ = try await webviewJS(web, "(()=>{delete window.ko.preview;document.querySelector('.step .thumb').click();return true})()")
                try await webviewUntil(web, "document.querySelector('.lightbox img')?.naturalWidth===1440&&document.querySelector('.lightbox .cap').textContent.includes('1440×900')")
                func captureLightbox(_ appearance: String) async throws {
                    _ = try await webviewJS(web, "document.querySelector('.lightbox img').decode().then(()=>true)")
                    let shadow = try await webviewJS(web, "getComputedStyle(document.querySelector('.lightbox img')).boxShadow!=='none'")
                    XCTAssertEqual(shadow, "true", "The lightbox image has a shadow")
                    _ = try await webviewJS(web, "(()=>{const style=document.createElement('style');style.id='capture-lightbox';style.textContent='.lightbox img{box-shadow:none!important}';document.head.append(style);return true})()")
                    try await settle()
                    try await webviewPageSnapshot(pane, "media-lightbox-" + appearance, testName: "testKoaWebviewMockupStates()")
                    _ = try await webviewJS(web, "(()=>{document.querySelector('#capture-lightbox').remove();return true})()")
                }
                try await captureLightbox("light")
                try await darken(); pane.webviewView?.updateTheme()
                try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
                try await captureLightbox("dark")
                _ = try await webviewJS(web, "(()=>{document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
                try await webviewUntil(web, "document.querySelector('.lightbox')===null")
                return
            }
            try await capture(prefix + "read-image")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.user .t p')?.textContent==='Make the sidebar look like this'")
            try await loaded(2)
            try await capture(prefix + "user-images")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.user .t')?.textContent.includes('Compare with the earlier screenshot')")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.thumb img').src='/images/gone';return true})()")
            try await webviewUntil(web, "document.querySelector('.thumb.gone[role=img]')!==null")
            try await loaded(1)
            try await capture(prefix + "image-gone")
            return
        }
        if scenario == .markdown {
            _ = try await webviewJS(web, #"(()=>{window.composer.setText('# Plan\n- **Strong** and *emphasis* with ~~old~~\n- Read `inline` and [link](https://kido.tools)');return true})()"#)
            try await webviewUntil(web, "document.querySelector('#prompt .cm-monospace')&&document.querySelector('#prompt .cm-strikethrough')")
            let mutedURL = try await webviewJS(web, "(()=>{const url=Array.from(document.querySelectorAll('#prompt .cm-markup')).find(node=>node.textContent==='https://kido.tools');return !!url&&getComputedStyle(url).color!==getComputedStyle(document.querySelector('#prompt .cm-content')).color})()")
            XCTAssertEqual(mutedURL, "true", "The URL is muted while the link text keeps the prose colour")
            try await capture("composer-markdown")
            _ = try await webviewJS(web, #"(()=>{window.composer.setText('- [ ] Review the patch\n> Keep the prompt literal\n```ts\nconst target = \"@sidebar\";\n```');return true})()"#)
            let markers = try await webviewJS(web, "(()=>{const spans=Array.from(document.querySelectorAll('#prompt .cm-markup')),info=spans.find(node=>node.textContent==='ts'),task=spans.find(node=>node.textContent==='[ ]');return !!info&&info.classList.contains('cm-monospace')&&!!task})()")
            XCTAssertEqual(markers, "true", "Fence info and task markers use the markup styles")
            try await capture("composer-markdown-code")
            return
        }
        if scenario == .completion {
            _ = try await webviewJS(web, "(()=>{window.completePrompts=[];window.lastComplete=null;const nativeFetch=window.fetch;window.fetch=async(path,options)=>{if(path==='/prompt')completePrompts.push(JSON.parse(options.body));const response=await nativeFetch(path,options);if(path==='/complete'){lastComplete={query:JSON.parse(options.body),result:await response.clone().json()};document.body.dataset.complete=String(Number(document.body.dataset.complete||0)+1)}return response};return true})()")
            let warmed = try await webviewJS(web, "(async()=>{const deadline=performance.now()+5000;while(performance.now()<deadline){const result=await(await fetch('/complete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sessionId:document.body.dataset.sessionId,text:'@si',pos:3})})).json();if(result.options.filter(o=>o.kind==='agent').length===3)return true}throw Error('agent completion deadline')})()")
            XCTAssertEqual(warmed, "true")
            let prefix = width < 750 ? "narrow-complete-" : "complete-"
            func show(_ before: String, _ token: String, _ after: String = "", empty: Bool = false) async throws {
                let data = String(decoding: try JSONSerialization.data(withJSONObject: ["before": before, "token": token, "after": after]), as: UTF8.self)
                _ = try await webviewJS(web, "(()=>{const {before,token,after}=\(data);lastComplete=null;window.composer.setText(before+token.slice(0,-1)+after);window.composer.focus();const input=document.querySelector('#prompt .cm-content');for(let i=0;i<after.length;i++)input.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',keyCode:37,bubbles:true,cancelable:true}));document.execCommand('insertText',false,token.slice(-1));return true})()")
                try await webviewUntil(web, "lastComplete?.query.text===\(String(reflecting: before + token + after))&&lastComplete?.query.pos===\(before.utf16.count + token.utf16.count)")
                if empty { try await webviewUntil(web, "!document.querySelector('.koa-complete')") }
                else {
                    try await webviewUntil(web, "(()=>{const popup=document.querySelector('.koa-complete'),field=document.querySelector('#field');return !!popup&&popup.getBoundingClientRect().top>=0&&popup.getBoundingClientRect().bottom<=field.getBoundingClientRect().top-5})()")
                    let contained = try await webviewJS(web, "(()=>{const popup=document.querySelector('.koa-complete').getBoundingClientRect(),field=document.querySelector('#field').getBoundingClientRect();return popup.left>=field.left-.5&&popup.right<=field.right+.5})()")
                    XCTAssertEqual(contained, "true", "Completion stays inside the field width")
                    let backdropRoot = try await webviewJS(web, "(()=>{for(let node=document.querySelector('.koa-complete').parentElement;node;node=node.parentElement){const s=getComputedStyle(node);if((s.backdropFilter&&s.backdropFilter!=='none')||(s.webkitBackdropFilter&&s.webkitBackdropFilter!=='none')||s.filter!=='none'||Number(s.opacity)<1||(s.maskImage&&s.maskImage!=='none')||(s.webkitMaskImage&&s.webkitMaskImage!=='none'))return node.id||node.className||node.tagName}return ''})()")
                    XCTAssertEqual(backdropRoot, "\"\"", "Completion has no ancestor that isolates its backdrop")
                }
            }
            func resize(_ height: CGFloat) async throws {
                koaContentSize(window: window, width: width, height: height)
                window.contentView?.layoutSubtreeIfNeeded()
                try await settle()
            }
            func key(_ name: String) async throws {
                _ = try await webviewJS(web, "document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'\(name)',bubbles:true,cancelable:true}))")
            }
            try await show("", "/")
            try await capture(prefix + "slash-all")
            try await key("ArrowDown"); try await key("Tab")
            try await webviewUntil(web, "window.composer.text()==='/thinking '&&!document.querySelector('.koa-complete')&&completePrompts.length===0")
            try await resize(300)
            try await show("", "/re")
            try await capture(prefix + "slash-filter")
            _ = try await webviewJS(web, "(()=>{const index=lastComplete.result.options.findIndex(option=>option.label==='/release');if(index<0)throw Error('missing release command');for(let i=0;i<index;i++)document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));return true})()")
            try await key("Enter")
            try await webviewUntil(web, "window.composer.text()===''&&completePrompts.length===1&&completePrompts[0].text==='/release '")
            try await resize(height)
            try await advance()
            try await webviewUntil(web, "document.querySelector('.user')?.textContent.includes('Review the sidebar unit')")
            try await show("Ask ", "@si")
            try await capture(prefix + "at-agents")
            try await key("Tab")
            let accepted = try await webviewJS(web, "window.composer.text()==='Ask '+lastComplete.result.options[0].insert&&completePrompts.length===2")
            XCTAssertEqual(accepted, "true")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#items').children.length===0")
            try await show("Read ", "@ko_s")
            try await capture(prefix + "at-files")
            try await key("Enter")
            try await webviewUntil(web, "window.composer.text()==='Read @ko_sys/'&&completePrompts.length===3")
            try await show("Hand the weight rule to ", "@si", " and tell me when it lands")
            try await key("ArrowDown")
            try await capture(prefix + "at-mid")
            try await key("Enter")
            try await webviewUntil(web, "window.composer.text()==='Hand the weight rule to '+lastComplete.result.options[1].insert+' and tell me when it lands'&&completePrompts.length===3")
            try await resize(300)
            try await show("Read ", "@zzz", empty: true)
            try await capture(prefix + "none")
            try await show("", "/re")
            try await key("Escape")
            try await webviewUntil(web, "!document.querySelector('.koa-complete')&&window.composer.text()==='/re'")
            try await key("Escape")
            let escapedOnce = try await webviewJS(web, "window.composer.text()")
            XCTAssertEqual(escapedOnce, "\"/re\"")
            try await key("Escape")
            let escapedTwice = try await webviewJS(web, "window.composer.text()")
            XCTAssertEqual(escapedTwice, "\"\"")
            try await resize(height)
            try await show("", "@si")
            try await key("Escape")
            try await show("", "/re")
            try await key("Escape")
            let excluded = try await webviewJS(web, #"""
            (async()=>{
              const fetchNow=window.fetch;let calls=0;
              window.fetch=(...args)=>{if(args[0]==='/complete'){calls++;dispatchEvent(new Event('code-completion-request'))}return fetchNow(...args)};
              const quietWindow=()=>new Promise(resolve=>{
                const observer=new MutationObserver(check), timer=setTimeout(()=>finish(true),200);
                function finish(ok){clearTimeout(timer);observer.disconnect();removeEventListener('code-completion-request',check);resolve(ok)}
                function check(){if(calls||document.querySelector('.koa-complete'))finish(false)}
                addEventListener('code-completion-request',check);observer.observe(document.documentElement,{childList:true,subtree:true});check();
              });
              try {
                const input=document.querySelector('#prompt .cm-content');
                for(const [before,token,after] of [['Read `','@si','`'],['```md\n','@si','\n```'],['    ','/re','']]) {
                  window.composer.setText(before+token.slice(0,-1)+after);window.composer.focus();
                  for(let i=0;i<after.length;i++)input.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true,cancelable:true}));
                  document.execCommand('insertText',false,token.slice(-1));
                  if(!await quietWindow())return 'completion inside code '+JSON.stringify({before,token,calls});
                }
                return 'ok';
              } finally {window.fetch=fetchNow;}
            })()
            """#)
            XCTAssertEqual(excluded, "\"ok\"")
            _ = try await webviewJS(web, "(()=>{const fetchNow=window.fetch;window.completionWaiting=false;window.fetch=async(...args)=>{const response=await fetchNow(...args);if(args[0]==='/complete'){completionWaiting=true;await new Promise(resolve=>window.releaseCompletion=resolve)}return response};window.composer.setText('/r');document.execCommand('insertText',false,'e');return true})()")
            try await webviewUntil(web, "completionWaiting")
            try await key("Escape")
            let cancelled = try await webviewJS(web, "(async()=>{releaseCompletion();await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);return !document.querySelector('.koa-complete')&&window.composer.text()==='/re'})()")
            XCTAssertEqual(cancelled, "true", "Escape cancels a pending completion without changing the draft")
            return
        }
        try await capture("idle")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('Three things, in order:\\n1. make the sweep keep a start failure for the linger grace\\n2. add the e2e test `sweep_keeps_a_start_failure` beside the linger test\\n3. then update docs/design.md, \"Window lifecycle\"\\n\\nDo not touch the cascade.');return true})()")
        try await capture("composer-multi")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#status').textContent==='working 12s'")
        let workingState = try await webviewJS(web, "document.querySelector('#status').textContent==='working 12s'&&document.querySelector('.foot .dot.on')!==null&&document.querySelector('#hint')===null&&document.querySelector('#send')===null&&getComputedStyle(document.querySelector('#field'),'::after').content==='none'")
        XCTAssertEqual(workingState, "true")
        try await capture("user-well")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.typing')&&document.querySelector('table')")
        if captures.contains("focus") {
            try await split(1, .h)
            try await wait("koa focus split") { self.terminal?.displayedPanes.count == 2 }
            let other = try XCTUnwrap(terminal?.displayedPanes.first { $0 !== pane })
            window.makeFirstResponder(other)
            _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();return true})()")
            window.makeFirstResponder(pane.inputResponder)
            XCTAssertTrue(window.firstResponder === web)
            try await webviewUntil(web, "(()=>{const p=document.querySelector('.assistant p');if(!p)return false;document.querySelector('#prompt .cm-content').blur();const range=document.createRange();range.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(range);return getSelection().toString().length>0})()")
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
            window.sendEvent(key)
            try await webviewUntil(web, "window.composer.text()==='z'&&document.activeElement===document.querySelector('#prompt .cm-content')")
            try await settle()
            try await webviewPageSnapshot(pane, "composer-focus", testName: "testKoaWebviewComposerFocus()")
            return
        }
        try await capture("stream")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('Also keep the failure message.');return true})()")
        try await capture("composer-working")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
        try await capture("narrow-stream")
        let caretCount = try await webviewJS(web, "document.querySelectorAll('.typing').length")
        XCTAssertEqual(caretCount, "1")
        _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();window.savedUser=document.querySelector('.user .t');window.savedText=savedUser.querySelector('p').firstChild;const range=document.createRange();range.setStart(savedText,0);range.setEnd(savedText,4);getSelection().removeAllRanges();getSelection().addRange(range);return true})()")
        let initialSelection = try await webviewJS(web, "getSelection().toString()")
        XCTAssertEqual(initialSelection, "\"Expl\"")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#items').textContent.includes('earlier selection')")
        let stableNode = try await webviewJS(web, "savedUser===document.querySelector('.user .t')")
        let stableText = try await webviewJS(web, "savedText===savedUser.querySelector('p').firstChild&&savedText.isConnected")
        let selection = try await webviewJS(web, "getSelection().toString()")
        XCTAssertEqual(stableNode, "true")
        XCTAssertEqual(stableText, "true")
        XCTAssertEqual(selection, "\"Expl\"")
        _ = try await webviewJS(web, "(()=>{getSelection().removeAllRanges();return true})()")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.run')&&!document.querySelector('table')")
        try await capture("run-running")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#items').textContent.includes('three sweep tests pass')")
        try await capture("run-done")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();return true})()")
        try await capture("lines")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.run')&&!document.querySelector('#items').textContent.includes('three sweep tests pass')")
        _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.querySelectorAll('.step>.line').forEach((row,index)=>{if(index===0||index===2||index===3)row.click()});const scroll=document.querySelector('#scroll');scroll.scrollTop=scroll.scrollHeight;return true})()")
        try await capture("details")
        try await capture("narrow-details")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#items .run .names .err')?.textContent==='bash'&&document.querySelector('#items').textContent.includes('aborted,')")
        let openRuns = try await webviewJS(web, "document.querySelectorAll('.run.open').length")
        XCTAssertEqual(openRuns, "0")
        let collapsed = try await webviewJS(web, "document.querySelectorAll('.run.open').length===0")
        XCTAssertEqual(collapsed, "true")
        _ = try await webviewJS(web, "(()=>{const runs=[...document.querySelectorAll('.run')];runs.forEach(run=>run.querySelector('.line').click());runs[0].querySelectorAll('.step>.line')[1].click();return true})()")
        try await webviewUntil(web, "document.querySelector('.run .names .err')?.textContent==='bash'&&document.querySelector('.run .step.open').textContent.includes('FAIL unit 40.2s')&&document.querySelectorAll('.run')[1].textContent.includes('aborted, you pressed Escape')")
        try await capture("error")
        XCTAssertEqual(pane.webviewView?.visualDocuments, 1)
        func dialogScenario() async throws {
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 8000);return true})()")
            func post(_ route: String, _ body: [String: Any] = [:]) async throws {
                let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
                _ = try await webviewJS(web, "fetch('\(route)',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...\(json),sessionId:document.body.dataset.sessionId})}).then(async r=>{const v=await r.json();if(!r.ok)throw Error(v.error);return v})")
            }
            try await advance()
            try await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Which tap revision?'&&document.querySelector('.queued-next')&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            try await capture("dialog-select")
            try await post("/dialog", ["id": "select", "value": "0.31.1 · 20857320"])
            try await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Force-push main?'&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            try await capture("dialog-confirm")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 6000);return true})()")
            try await post("/dialog", ["id": "confirm", "confirmed": true])
            try await webviewUntil(web, "document.querySelector('.dialog input')&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 6000);document.querySelector('.dialog input').value='0.32.0';return true})()")
            try await webviewUntil(web, "document.querySelector('.dialog .count').textContent==='43s'")
            try await capture("dialog-input")
            if captures.contains("focus-border-dialog") {
                let focused = try await webviewJS(web, "document.activeElement===document.querySelector('.dialog input')&&!document.querySelector('#field').classList.contains('focus')")
                XCTAssertEqual(focused, "true")
                try await capture("focus-border-dialog")
                return
            }
            try await post("/dialog", ["id": "input", "value": "0.32.0"])
            try await webviewUntil(web, "document.querySelector('.dialog textarea')&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            try await capture("dialog-editor")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.dialog textarea').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',ctrlKey:true,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('.dialog')")
        }
        func controlsScenario() async throws {
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('#queue .qmsg').length===3")
            try await capture("queue")
            try await capture("narrow-queue")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',code:'ArrowUp',altKey:true,bubbles:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('#queue .qmsg')&&window.composer.text().includes('release notes')")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
            try await advance()
            try await webviewUntil(web, "!document.querySelector('.user')")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#model').click();return true})()")
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelectorAll('#picker .row').length===\(width > 750 ? 5 : 11)")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));return true})()")
            try await capture("picker-model")
            try await capture("narrow-picker-model")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            if width > 750 {
                _ = try await webviewJS(web, "(()=>{document.querySelector('#thinking').click();return true})()")
                try await webviewUntil(web, "document.querySelector('#picker .ph')?.textContent==='Thinking'")
                _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true,cancelable:true}));return true})()")
                try await capture("picker-thinking")
                _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            }
            try await advance()
            try await webviewUntil(web, "document.querySelector('.nrow')&&document.querySelectorAll('.foot .ext').length===2")
            try await capture("toast-info")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.nrow.warning')")
            try await capture("toast-warn")
            try await capture("narrow-toast-warn")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.nrow.error')")
            try await capture("toast-error")
        }
        func exitScenario() async throws {
            try await advance()
            for offset in [6000, 6100, 6300, 6800, 10000, 14000, 37000] {
                try String(stamp + offset).write(to: now, atomically: true, encoding: .utf8)
                try await advance()
            }
            try await webviewUntil(web, "document.querySelector('#status').textContent==='aborted'&&document.querySelectorAll('.run').length===2")
            _ = try await webviewJS(web, "(()=>{document.querySelectorAll('.run>.line').forEach(row=>row.click());return true})()")
            try await capture("times")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#items').textContent.includes('pushing now')")
            try String(stamp + 9 * 60000).write(to: now, atomically: true, encoding: .utf8)
            try await advance()
            try await webviewUntil(web, "!document.querySelector('#exited').hidden&&document.querySelector('#exited pre').textContent.includes('ERR_MODULE_NOT_FOUND')")
            try await capture("exited")
            try await capture("narrow-exited")
        }
        switch scenario {
        case .transcript, .feed, .completion, .markdown, .media, .attachments, .userMarkdown, .thinkingMarkdown, .reveal, .preview, .lightbox, .agents, .composer, .questions, .bang, .commands, .notices, .sessions: break
        case .dialogs: try await dialogScenario()
        case .controls: try await controlsScenario()
        case .exit: try await exitScenario()
        }
    }
}
