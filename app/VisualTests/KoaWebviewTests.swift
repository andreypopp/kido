import AppKit
import WebKit
import XCTest
@testable import Kido

extension VisualTests {
    private enum KoaScenario { case transcript, dialogs, controls, exit }
    func testKoaWebviewMockupStates() async throws {
        try await koaWebview(width: 980, height: 560, captures: ["stream", "lines", "details"])
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

    private func koaWebview(width: CGFloat, height: CGFloat, scenario: KoaScenario = .transcript, captures: Set<String>) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fake = root.appendingPathComponent("share/koa/koa-fake-pi.ts").path
        let script = directory.appendingPathComponent("koa-script.jsonl")
        let sessionFile = directory.appendingPathComponent("session.jsonl")
        let home = directory.appendingPathComponent("home")
        let cwd = home.appendingPathComponent("Workspace/kido")
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let git = bin.appendingPathComponent("git")
        try "#!/bin/sh\ncase \"$*\" in 'symbolic-ref --short HEAD') echo main;; 'status --porcelain --untracked-files=no') echo ' M ko_server/src/sweep.rs';; *) exit 1;; esac\n".write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: git.path)
        try JSONSerialization.data(withJSONObject: ["cwd": cwd.path]).write(to: sessionFile)
        let stamp = Int(try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 14, minute: 32))).timeIntervalSince1970 * 1000)
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
            steps.append(["type": "wait", "command": "extension_ui_response", "events": [["type": "compaction_end"]]])
            steps.append(["type": "respond", "command": "get_messages", "data": ["messages": []]])
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
        try steps.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        let path = [bin.path, tools.prefix + "/bin", "/opt/homebrew/bin", ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let clock = directory.appendingPathComponent("clock.mjs")
        let now = directory.appendingPathComponent("now")
        try String(stamp).write(to: now, atomically: true, encoding: .utf8)
        let nowJSON = String(decoding: try JSONSerialization.data(withJSONObject: now.path, options: .fragmentsAllowed), as: UTF8.self)
        try "import {readFileSync} from 'node:fs'; Date.now = () => Number(readFileSync(\(nowJSON), 'utf8'));".write(to: clock, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("koa.stderr")
        try await start(width: width, height: height, pane: "export HOME=\(SSH.quote(home.path)) PATH=\(SSH.quote(path)) KOA_FAKE_SCRIPT=\(SSH.quote(script.path)) NODE_OPTIONS=\(SSH.quote("--import " + clock.path)); exec \(SSH.quote(tools.prefix + "/share/ko/bin/koa")) --pi \(SSH.quote(fake)) 2>\(SSH.quote(output.path))")
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await wait("koa webview", within: 20) { (pane.webviewView?.visualDocuments ?? 0) > 0 }
        let diagnostics = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let web = try XCTUnwrap(pane.webviewView?.browser, diagnostics)
        func capture(_ name: String) async throws {
            guard captures.contains(name) else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            pane.webviewView?.layoutSubtreeIfNeeded()
            _ = try await webviewJS(web, "(()=>{if(!document.querySelector('.dialog')&&!document.querySelector('#exited:not([hidden])')&&document.querySelector('#picker').hidden)document.querySelector('#prompt').focus();const scroll=document.querySelector('#scroll');scroll.scrollTop=scroll.scrollHeight;return true})()")
            try await webviewUntil(web, "(()=>{const scroll=document.querySelector('#scroll');return scroll.scrollHeight-scroll.scrollTop-scroll.clientHeight<1})()")
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
            _ = try await webviewJS(web, "fetch('/prompt',{method:'POST',body:JSON.stringify({text:'next',mode:'prompt'})}).then(async r=>{const result=await r.json();if(!r.ok)throw Error(result.error||'Prompt failed');return result})")
        }
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#model').textContent==='claude-opus-5-5'")
        _ = try await webviewJS(web, "(()=>{const NativeDate=Date;window.Date=class extends NativeDate{constructor(...args){super(...(args.length?args:[\(stamp + 12000)]))}static now(){return \(stamp + 12000)}};const style=document.createElement('style');style.textContent='.caret,.spin,.field.working::after{animation:none!important}.field.working::after{visibility:hidden!important}';document.head.append(style);return true})()")
        let idleSweep = try await webviewJS(web, "getComputedStyle(document.querySelector('#field'),'::after').content")
        XCTAssertEqual(idleSweep, "\"none\"")
        try await capture("idle")
        _ = try await webviewJS(web, "(()=>{const p=document.querySelector('#prompt');p.value='Three things, in order:\\n1. make the sweep keep a start failure for the linger grace\\n2. add the e2e test `sweep_keeps_a_start_failure` beside the linger test\\n3. then update docs/design.md, \"Window lifecycle\"\\n\\nDo not touch the cascade.';p.dispatchEvent(new Event('input'));return true})()")
        try await capture("composer-multi")
        _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt').value='';document.querySelector('#prompt').dispatchEvent(new Event('input'));return true})()")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#field').classList.contains('working')")
        let workingSweep = try await webviewJS(web, "getComputedStyle(document.querySelector('#field'),'::after').backgroundImage.includes('linear-gradient')&&getComputedStyle(document.querySelector('#field'),'::after').content!=='none'")
        XCTAssertEqual(workingSweep, "true")
        try await advance()
        try await webviewUntil(web, "document.querySelector('.caret')&&document.querySelector('table')")
        try await capture("stream")
        _ = try await webviewJS(web, "(()=>{const p=document.querySelector('#prompt');p.value='Also keep the failure message.';p.dispatchEvent(new Event('input'));return true})()")
        try await capture("composer-working")
        _ = try await webviewJS(web, "(()=>{const p=document.querySelector('#prompt');p.value='';p.dispatchEvent(new Event('input'));return true})()")
        let emptyHidden = try await webviewJS(web, "document.querySelector('#empty').hidden")
        XCTAssertEqual(emptyHidden, "true")
        try await capture("narrow-stream")
        let caretCount = try await webviewJS(web, "document.querySelectorAll('.caret').length")
        XCTAssertEqual(caretCount, "1")
        _ = try await webviewJS(web, "(()=>{window.savedUser=document.querySelector('.user .t');const range=document.createRange();range.setStart(savedUser.firstChild,0);range.setEnd(savedUser.firstChild,4);getSelection().removeAllRanges();getSelection().addRange(range);return true})()")
        try await advance()
        try await webviewUntil(web, "document.querySelector('#items').textContent.includes('earlier selection')")
        let stableSelection = try await webviewJS(web, "savedUser===document.querySelector('.user .t')&&getSelection().toString()==='Expl'")
        XCTAssertEqual(stableSelection, "true")
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
        try await webviewUntil(web, "document.querySelector('#items').textContent.includes('command failed')&&document.querySelector('#items').textContent.includes('aborted ·')")
        let openRuns = try await webviewJS(web, "document.querySelectorAll('.run.open').length")
        XCTAssertEqual(openRuns, "0")
        let collapsed = try await webviewJS(web, "document.querySelectorAll('.run.open').length===0")
        XCTAssertEqual(collapsed, "true")
        _ = try await webviewJS(web, "(()=>{const runs=[...document.querySelectorAll('.run')];runs.forEach(run=>run.querySelector('.line').click());runs[0].querySelectorAll('.step>.line')[1].click();return true})()")
        try await webviewUntil(web, "document.querySelector('.run').textContent.includes('2 steps · 1 command failed')&&document.querySelector('.run .step.open').textContent.includes('FAIL unit 40.2s')&&document.querySelectorAll('.run')[1].textContent.includes('aborted · 2 steps, you pressed Escape')")
        try await capture("error")
        XCTAssertEqual(pane.webviewView?.visualDocuments, 1)
        func dialogScenario() async throws {
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 8000);return true})()")
            func post(_ route: String, _ body: [String: Any] = [:]) async throws {
                let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
                _ = try await webviewJS(web, "fetch('\(route)',{method:'POST',body:JSON.stringify(\(json))}).then(async r=>{const v=await r.json();if(!r.ok)throw Error(v.error);return v})")
            }
            try await advance()
            try await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Which tap revision?'&&document.querySelector('.queued-next')")
            try await capture("dialog-select")
            try await post("/dialog", ["id": "select", "value": "0.31.1 · 20857320"])
            try await webviewUntil(web, "document.querySelector('.dialog .title')?.textContent==='Force-push main?'")
            try await capture("dialog-confirm")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 6000);return true})()")
            try await post("/dialog", ["id": "confirm", "confirmed": true])
            try await webviewUntil(web, "document.querySelector('.dialog input')")
            _ = try await webviewJS(web, "(()=>{Date.now=()=>\(stamp + 6000);document.querySelector('.dialog input').value='0.32.0';return true})()")
            try await webviewUntil(web, "document.querySelector('.dialog .count').textContent==='43s'")
            try await capture("dialog-input")
            try await post("/dialog", ["id": "input", "value": "0.32.0"])
            try await webviewUntil(web, "document.querySelector('.dialog textarea')")
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
            try await webviewUntil(web, "!document.querySelector('#queue .q')&&document.querySelector('#prompt').value.includes('release notes')")
            _ = try await webviewJS(web, "(()=>{document.querySelector('#prompt').value='';document.querySelector('#prompt').dispatchEvent(new Event('input'));return true})()")
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
        case .transcript: break
        case .dialogs: try await dialogScenario()
        case .controls: try await controlsScenario()
        case .exit: try await exitScenario()
        }
    }
}
