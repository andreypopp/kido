import AppKit
import WebKit
import XCTest
import KoClient
import KoModel
import SidebarFeed
@testable import Kido

extension VisualTests {
    private enum KoaScenario { case transcript, dialogs, controls, exit, feed, completion, markdown, media, attachments, userMarkdown, preview, lightbox }
    func testKoaInterruptRestoresNativeInput() async throws {
        let script = directory.appendingPathComponent("quit-script.jsonl")
        try "".write(to: script, atomically: true, encoding: .utf8)
        let fake = checkoutRoot.appendingPathComponent("share/koa/koa-fake-pi.ts").path
        try await start(pane: "trap ':' INT; export KOA_FAKE_SCRIPT=\(SSH.quote(script.path)); \(SSH.quote(tools.prefix + "/share/ko/bin/koa")) --pi \(SSH.quote(fake)); " + rawScript)
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await wait("koa page") { pane.webviewView != nil }
        let web = try XCTUnwrap(pane.webviewView?.browser)
        try await wait("koa document loaded") { web.url?.scheme == "ko" && !web.isLoading }
        try await webviewUntil(web, "document.getElementById('prompt') !== null")
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: web) == true, "A page in the focused pane starts with the WKWebView as first responder")
        let accent = try XCTUnwrap(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        let expectedFocus = "rgba(\(Int(accent.redComponent * 255)),\(Int(accent.greenComponent * 255)),\(Int(accent.blueComponent * 255)),0.5)"
        let pageFocus = try await webviewJS(web, "getComputedStyle(document.documentElement).getPropertyValue('--ko-focus').trim()")
        XCTAssertEqual(pageFocus, String(data: try JSONSerialization.data(withJSONObject: expectedFocus, options: .fragmentsAllowed), encoding: .utf8))
        _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();return true})()")
        let unfocused = try await webviewJS(web, "(()=>{const field=document.getElementById('field');const reference=document.createElement('div');reference.style.color=getComputedStyle(document.documentElement).getPropertyValue('--ko-focus');document.body.append(reference);const result=!field.matches(':focus-within')&&getComputedStyle(field).borderTopColor!==getComputedStyle(reference).color;reference.remove();return result})()")
        XCTAssertEqual(unfocused, "true", "The unfocused composer does not use the focus border")
        _ = try await webviewJS(web, "(()=>{window.composer.focus();return true})()")
        try await webviewUntil(web, "window.composer&&document.querySelector('#status').textContent==='idle'")
        let result = try await webviewJS(web, #"""
        (async()=>{
          const requests=[], original=window.fetch;
          window.fetch=(path,options)=>['/prompt','/quit'].includes(path)?(requests.push({path,...JSON.parse(options.body)}),Promise.resolve({ok:true,json:async()=>({})})):original(path,options);
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
            if(key('Tab'))return 'Tab';
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

    func testKoaWebviewComposerFocus() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["focus"])
    }
    func testKoaWebviewFeedHeldTail() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .feed, captures: [])
    }
    func testKoaWebviewMockupStates() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["user-well", "stream", "lines", "details"])
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
        try await koaWebview(width: 980, height: 560, scenario: .userMarkdown, captures: ["user-markdown"])
    }

    func testKoaWebviewUserMarkdownNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .userMarkdown, captures: ["narrow-user-markdown"])
    }

    func testKoaWebviewComposerMarkdown() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .markdown, captures: ["composer-markdown", "composer-markdown-code"])
    }

    func testKoaWebviewCompletionWide() async throws {
        try await koaWebview(width: 980, height: 560, scenario: .completion, captures: Set(["slash-all", "slash-filter", "at-agents", "at-files", "at-mid", "none"].map { "complete-" + $0 }))
    }

    func testKoaWebviewCompletionNarrow() async throws {
        try await koaWebview(width: 470, height: 560, scenario: .completion, captures: Set(["slash-all", "slash-filter", "at-agents", "at-files", "at-mid", "none"].map { "narrow-complete-" + $0 }))
    }

    private func koaWebview(width: CGFloat, height: CGFloat, scenario: KoaScenario = .transcript, captures: Set<String>) async throws {
        let fake = checkoutRoot.appendingPathComponent("share/koa/koa-fake-pi.ts").path
        let script = directory.appendingPathComponent("koa-script.jsonl")
        let sessionFile = directory.appendingPathComponent("session.jsonl")
        let home = directory.appendingPathComponent("home")
        let cwd = home.appendingPathComponent("Workspace/kido")
        let attachmentPaths = (shot: home.appendingPathComponent("Desktop/Screenshot 2026-11-10 at 09.11.42.png"), diagram: home.appendingPathComponent("Desktop/diagram.png"), notes: home.appendingPathComponent("Desktop/notes.md"), source: cwd.appendingPathComponent("app/App/SidebarRow.swift"))
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["cwd": cwd.path]).write(to: sessionFile)
        let mediaClock = scenario == .media || scenario == .attachments || scenario == .preview || scenario == .lightbox
        let stamp = Int(try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: mediaClock ? 10 : 8, hour: mediaClock ? 9 : 14, minute: mediaClock ? 12 : 32))).timeIntervalSince1970 * 1000)
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
        prompt([["type": "message_update", "usage": usage, "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": " The patch keeps the earlier selection."]]])
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
        if scenario == .userMarkdown {
            var rich = user; rich["content"] = [["type": "text", "text": "Use `inline` and the same Markdown rules.\n\n- First item\n- Second item\n\n```js\nconst x = 1;\n```\n\n<b>raw HTML stays text</b>"]]
            var plain = user; plain["timestamp"] = stamp + 1; plain["content"] = [["type": "text", "text": "A plain one-line message"]]
            steps = Array(steps.prefix(3)); steps[1] = ["type": "respond", "command": "get_messages", "data": ["messages": [rich, assistant([["type": "text", "text": "The text column is the same width."]]), plain]]]
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
        let command = "export HOME=\(SSH.quote(home.path)) PATH=\(SSH.quote(path)) KOA_FAKE_SCRIPT=\(SSH.quote(script.path)) NODE_OPTIONS=\(SSH.quote("--import " + clock.path))" + (scenario == .completion ? " KOA_FD=\(SSH.quote(fd.path))" : "") + "; exec \(SSH.quote(tools.prefix + "/share/ko/bin/koa")) --pi \(SSH.quote(fake)) 2>\(SSH.quote(output.path))"
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
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await wait("koa webview", within: 20) { (pane.webviewView?.visualDocuments ?? 0) > 0 }
        let diagnostics = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let web = try XCTUnwrap(pane.webviewView?.browser, diagnostics)
        if scenario == .completion || scenario == .attachments || scenario == .userMarkdown {
            // WebKit pauses animation frames in an off-screen window.
            pane.webviewView?.visualFeedScript = "const ClockDate=Date;window.Date=class extends ClockDate{constructor(...args){super(...(args.length?args:[\(stamp + 12000)]))}static now(){return \(stamp + 12000)}};window.requestAnimationFrame=callback=>setTimeout(()=>callback(performance.now()),0);window.cancelAnimationFrame=clearTimeout;"
            let documents = pane.webviewView?.visualDocuments ?? 0
            web.reload()
            try await wait("completion document with measurement clock") { (pane.webviewView?.visualDocuments ?? 0) > documents && !web.isLoading }
        }
        if scenario == .feed {
            try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#model').textContent==='claude-opus-5-5'")
            pane.webviewView?.visualFeedPath = "/events"
            pane.webviewView?.visualFeedScript = #"""
            const NativeEventSource=EventSource;
            window.EventSource=class extends NativeEventSource{constructor(...args){super(...args);window.feedSource=this}};
            """#
            web.reload()
            try await wait("reloaded feed", within: 10) { !web.isLoading }
            try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#model').textContent==='claude-opus-5-5'")
            for index in 1...3 {
                let before = pane.webviewView!.visualFeedBytes
                let response = try await webviewJS(web, "fetch('/prompt',{method:'POST',body:JSON.stringify({text:'next',mode:'prompt',attachments:[]})}).then(async r=>({status:r.status,body:await r.json()}))")
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
        func capture(_ name: String) async throws {
            guard captures.contains(name) else { return }
            let top = scenario == .media || scenario == .lightbox
            window.contentView?.layoutSubtreeIfNeeded()
            pane.webviewView?.layoutSubtreeIfNeeded()
            _ = try await webviewJS(web, "(()=>{if(!document.querySelector('.lightbox')&&!document.querySelector('.dialog')&&!document.querySelector('#exited:not([hidden])')&&document.querySelector('#picker').hidden)window.composer.focus();const scroll=document.querySelector('#scroll');scroll.scrollTop=\(top ? "0" : "scroll.scrollHeight");return true})()")
            try await webviewUntil(web, "(()=>{const dock=document.querySelector('#dock');return Number.parseFloat(getComputedStyle(document.body).getPropertyValue('--dock-h'))===dock.getBoundingClientRect().height})()")
            try await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');scroll.scrollTop=\(top ? "0" : "scroll.scrollHeight");return \(top ? "scroll.scrollTop===0" : "scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<1")})()")
            let lastAboveDock = try await webviewJS(web, "(()=>{const last=document.querySelector('#items').lastElementChild;return !last||last.getBoundingClientRect().bottom<=document.querySelector('#dock').getBoundingClientRect().top})()")
            if !top { XCTAssertEqual(lastAboveDock, "true", "dock space keeps the last message above the composer") }
            try await webviewSnapshot(pane, name + "-light", testName: "testKoaWebviewMockupStates()")
            try await darken()
            pane.webviewView?.updateTheme()
            try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
            try await webviewSnapshot(pane, name + "-dark", testName: "testKoaWebviewMockupStates()")
            try await darken(.aqua)
            pane.webviewView?.updateTheme()
            try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='light'")
        }
        func advance() async throws {
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',body:JSON.stringify({text:'next',mode:'prompt',attachments:[]})}).then(async r=>{const result=await r.json();if(!r.ok)throw Error(result.error||'Prompt failed');return result})")
        }
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#model').textContent==='claude-opus-5-5'")
        _ = try await webviewJS(web, "(()=>{const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[\(stamp + 12000)]))}static now(){return \(stamp + 12000)}};const style=document.createElement('style');style.textContent='.caret,.spin,.spin::before,.dot.on{animation:none!important}';document.head.append(style);return true})()")
        let idleHint = try await webviewJS(web, "document.querySelector('#hint .spin')===null")
        XCTAssertEqual(idleHint, "true")
        if scenario == .preview {
            try await webviewUntil(web, "document.querySelectorAll('.step').length===3")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.run>.line').click();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Meta',metaKey:true,shiftKey:true}));return true})()")
            _ = try await webviewJS(web, "(()=>{const rule=Array.from(document.styleSheets).flatMap(sheet=>Array.from(sheet.cssRules)).find(rule=>rule.selectorText?.includes('.preview-file:hover'));if(!rule)throw Error('Missing hover rule');const style=document.createElement('style');style.textContent=rule.cssText.replace(':hover','.snapshot-hover');document.head.append(style);document.querySelectorAll('.step .preview-file')[1].classList.add('snapshot-hover');return true})()")
            try await webviewUntil(web, "getComputedStyle(document.querySelectorAll('.step .preview-file')[1]).textDecorationLine.includes('underline')")
            try await capture("media-preview-hover")
            return
        }
        if scenario == .userMarkdown {
            try await webviewUntil(web, "document.querySelectorAll('.user').length===2&&document.querySelector('.user ul li')&&document.querySelector('.user pre code')")
            let markdown = try await webviewJS(web, "(()=>{const user=document.querySelector('.user'),plain=Array.from(document.querySelectorAll('.user')).at(-1),assistant=document.querySelector('.assistant .prose'),p=plain.querySelector('.prose p'),u=user.querySelector('.t').getBoundingClientRect(),a=assistant.getBoundingClientRect(),well=plain.getBoundingClientRect(),time=plain.querySelector('time').getBoundingClientRect(),scroll=document.querySelector('#scroll').getBoundingClientRect(),font=parseFloat(getComputedStyle(document.body).fontSize),terminal=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ko-font-size')),editor=getComputedStyle(document.querySelector('.cm-content'));return plain.querySelector('time').textContent==='14:32'&&user.querySelectorAll('ul li').length===2&&user.querySelectorAll('code').length===2&&user.querySelector('b')===null&&user.textContent.includes('<b>raw HTML stays text</b>')&&Math.abs(u.left-a.left)<.1&&Math.abs(u.right-a.right)<.1&&well.left>=scroll.left+4&&well.right<=scroll.right-4&&getComputedStyle(p).marginTop==='0px'&&getComputedStyle(p).marginBottom==='0px'&&Math.abs(well.height-p.getBoundingClientRect().height-14)<.1&&Math.abs(time.top-p.getBoundingClientRect().top)<.1&&Math.abs(font-terminal*.92)<.01&&Math.abs(parseFloat(editor.fontSize)-font)<.01&&Number.isInteger(parseFloat(editor.minHeight))})()")
            XCTAssertEqual(markdown, "true", "Markdown, first-line time, equal text widths, compact spacing and rounded composer size")
            try await capture(width < 750 ? "narrow-user-markdown" : "user-markdown")
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
              window.ko.local=true;window.dispatchEvent(new CustomEvent('ko-drop',{detail:{files:[\#(source)],refused:false}}));window.ko.local=false;
              const large=new File([],'archive.tar.gz');Object.defineProperty(large,'size',{value:65*1048576});
              dropAttachments([new File([new Uint8Array(41*1048576)],'kido-demo.mov'),large]);
              return true;
            })()
            """#)
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===5&&Array.from(document.querySelectorAll('.attach-detail')).some(node=>node.textContent==='18 / 41 MB')&&document.querySelectorAll('.attach-icon img').length===1")
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
            _ = try await webviewJS(web, "Promise.all(Array.from(document.querySelectorAll('.attach-icon img'),image=>image.decode())).then(()=>true)")
            try await capture(prefix + "folder")
            _ = try await webviewJS(web, "(()=>{clearAttachments();window.Date.now=()=>\(stamp + 3000);return true})()")
            try await advance()
            try await webviewUntil(web, "document.querySelector('#status').textContent==='working 3s'&&document.querySelector('.run')!==null")
            _ = try await webviewJS(web, "(()=>{const run=document.querySelector('.run');if(run.classList.contains('open'))run.querySelector('.line').click();window.composer.setText(\"skip the Linux check, I'll run it in CI\");document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.queue .q').length===1&&window.composer.text()===''")
            _ = try await webviewJS(web, "(()=>{dropAttachments([attachFiles.shot,attachFiles.diagram]);window.composer.setText('then compare with these two renders');return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&document.querySelectorAll('.attach-icon img').length===2")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',altKey:true,bubbles:true}));return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.queue .q').length===2&&document.querySelector('.queue .att')?.textContent==='2'&&document.querySelectorAll('.attach-chip').length===0")
            try await capture(prefix + "queue")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.queue .take button').click();return true})()")
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===2&&window.composer.text().includes('then compare')&&document.querySelectorAll('#items .msg').length===0")
            let restored = try await webviewJS(web, "Array.from(document.querySelectorAll('.attach-detail')).every(node=>!node.classList.contains('path'))")
            XCTAssertEqual(restored, "true", "Take-back restores upload chips, not path chips")
            _ = try await webviewJS(web, #"""
            (()=>{clearAttachments();dropAttachments([attachFiles.shot,attachFiles.notes]);window.ko.local=true;window.dispatchEvent(new CustomEvent('ko-drop',{detail:{files:[\#(source)],refused:false}}));window.ko.local=false;window.composer.setText('Attach these to the review');return true})()
            """#)
            try await webviewUntil(web, "document.querySelectorAll('.attach-chip').length===3&&!document.querySelector('#send').disabled")
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
                try await webviewSnapshot(pane, "media-lightbox-light", testName: "testKoaWebviewMockupStates()")
                try await darken(); pane.webviewView?.updateTheme()
                try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
                try await webviewSnapshot(pane, "media-lightbox-dark", testName: "testKoaWebviewMockupStates()")
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
            let warmed = try await webviewJS(web, "(async()=>{const deadline=performance.now()+5000;while(performance.now()<deadline){const result=await(await fetch('/complete',{method:'POST',body:JSON.stringify({text:'@si',pos:3})})).json();if(result.options.filter(o=>o.kind==='agent').length===3)return true}throw Error('agent completion deadline')})()")
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
                }
            }
            func resize(_ height: CGFloat) async throws {
                window.setContentSize(NSSize(width: width, height: height))
                window.contentView?.layoutSubtreeIfNeeded()
                try await settle()
            }
            func key(_ name: String) async throws {
                _ = try await webviewJS(web, "document.querySelector('#prompt .cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'\(name)',bubbles:true,cancelable:true}))")
            }
            try await show("", "/")
            try await capture(prefix + "slash-all")
            try await key("ArrowDown"); try await key("Tab")
            try await webviewUntil(web, "window.composer.text()==='/release '&&!document.querySelector('.koa-complete')&&completePrompts.length===0")
            try await resize(300)
            try await show("", "/re")
            try await capture(prefix + "slash-filter")
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
        try await webviewUntil(web, "document.querySelector('#field').classList.contains('working')")
        let workingHint = try await webviewJS(web, "document.querySelector('#hint .spin')!==null&&document.querySelector('#hint').textContent===document.querySelector('#status').textContent+' · ⎋ abort'&&document.querySelector('.dot.on')!==null&&getComputedStyle(document.querySelector('#field'),'::after').content==='none'")
        XCTAssertEqual(workingHint, "true")
        try await capture("user-well")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.caret')&&document.querySelector('table')")
        if captures.contains("focus") {
            try await split(1, .h)
            try await wait("koa focus split") { self.terminal?.panes.count == 2 }
            let other = try XCTUnwrap(terminal?.panes.first { $0 !== pane })
            window.makeFirstResponder(other)
            _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();return true})()")
            window.makeFirstResponder(pane.inputResponder)
            XCTAssertTrue(window.firstResponder === web)
            _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt .cm-content').blur();const range=document.createRange();range.selectNodeContents(document.querySelector('.assistant p'));getSelection().removeAllRanges();getSelection().addRange(range);return true})()")
            let selected = try await webviewJS(web, "getSelection().toString().length>0")
            XCTAssertEqual(selected, "true")
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
            window.sendEvent(key)
            try await webviewUntil(web, "window.composer.text()==='z'&&document.activeElement===document.querySelector('#prompt .cm-content')")
            try await webviewSnapshot(pane, "composer-focus", testName: "testKoaWebviewComposerFocus()")
            return
        }
        try await capture("stream")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('Also keep the failure message.');return true})()")
        try await capture("composer-working")
        _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
        try await capture("narrow-stream")
        let caretCount = try await webviewJS(web, "document.querySelectorAll('.caret').length")
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
                _ = try await webviewJS(web, "fetch('\(route)',{method:'POST',body:JSON.stringify(\(json))}).then(async r=>{const v=await r.json();if(!r.ok)throw Error(v.error);return v})")
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
            try await post("/dialog", ["id": "input", "value": "0.32.0"])
            try await webviewUntil(web, "document.querySelector('.dialog textarea')&&document.querySelector('.run>.line .spin')&&document.querySelector('.run>.line')?.textContent.includes('release')")
            try await capture("dialog-editor")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.dialog textarea').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',ctrlKey:true,bubbles:true,cancelable:true}));return true})()")
            try await webviewUntil(web, "!document.querySelector('.dialog')")
        }
        func controlsScenario() async throws {
            try await advance()
            try await webviewUntil(web, "document.querySelectorAll('#queue .q').length===3")
            try await capture("queue")
            try await capture("narrow-queue")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#queue button').click();return true})()")
            try await webviewUntil(web, "!document.querySelector('#queue .q')&&window.composer.text().includes('release notes')")
            _ = try await webviewJS(web, "(()=>{window.composer.setText('');return true})()")
            try await advance()
            try await webviewUntil(web, "!document.querySelector('.user')")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#model').click();return true})()")
            try await webviewUntil(web, "!document.querySelector('#picker').hidden&&document.querySelectorAll('#picker .row').length===5")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));return true})()")
            try await capture("picker-model")
            try await capture("narrow-picker-model")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));document.querySelector('#thinking').click();return true})()")
            try await webviewUntil(web, "document.querySelector('#picker .ph')?.textContent==='Thinking'")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true,cancelable:true}));return true})()")
            try await capture("picker-thinking")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#picker').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return true})()")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.toast.info')&&document.querySelectorAll('.status .ext').length===2")
            try await capture("toast-info")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.toast.warning')")
            try await capture("toast-warn")
            try await capture("narrow-toast-warn")
            try await advance()
            try await webviewUntil(web, "document.querySelector('.toast.error')")
            try await capture("toast-error")
            _ = try await webviewJS(web, "(()=>{document.querySelector('.toast')?.click();return true})()")
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
        case .transcript, .feed, .completion, .markdown, .media, .attachments, .userMarkdown, .preview, .lightbox: break
        case .dialogs: try await dialogScenario()
        case .controls: try await controlsScenario()
        case .exit: try await exitScenario()
        }
    }
}
