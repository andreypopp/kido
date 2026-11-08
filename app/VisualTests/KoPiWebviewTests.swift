import AppKit
import WebKit
import XCTest
@testable import Kido

extension VisualTests {
    func testKoPiWebviewLightAndDark() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shim = tools.prefix + "/share/ko/bin/ko-pi"
        let piBin = root.appendingPathComponent("share/pi/node_modules/.bin").path
        guard FileManager.default.isExecutableFile(atPath: piBin + "/pi") else {
            XCTFail("Pinned pi is missing; run npm install in share/pi")
            return
        }
        let path = [piBin, tools.prefix + "/bin", "/opt/homebrew/bin", ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        let home = directory.appendingPathComponent("pi-home")
        let agent = home.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try #"{"quietStartup":true,"checkForUpdates":false,"defaultProvider":"anthropic","defaultModel":"claude-sonnet-4-5"}"#.write(to: agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let fixture = directory.appendingPathComponent("transcript.jsonl")
        let stamp = "2026-11-05T12:00:00.000Z"
        var entries: [[String: Any]] = [["type": "session", "version": 3, "id": "3d690cb0-7e12-446b-91ae-685caea746fe", "timestamp": stamp, "cwd": home.path]]
        func entry(_ type: String, _ fields: [String: Any]) {
            let index = entries.count
            entries.append(fields.merging(["type": type, "id": "entry-\(index)", "parentId": index == 1 ? NSNull() : "entry-\(index - 1)" as Any, "timestamp": stamp]) { _, new in new })
        }
        entry("session_info", ["name": "HTML transcript"])
        entry("model_change", ["provider": "anthropic", "modelId": "claude-sonnet-4-5"])
        entry("message", ["message": ["role": "user", "content": [["type": "text", "text": "Show the implementation and check the result."]], "timestamp": 1793880000000]])
        let usage: [String: Any] = ["input": 10, "output": 20, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 30, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]
        entry("message", ["message": ["role": "assistant", "api": "anthropic-messages", "provider": "anthropic", "model": "claude-sonnet-4-5", "usage": usage, "stopReason": "toolUse", "timestamp": 1793880000001, "content": [
            ["type": "text", "text": "## A small, clear change\n\nThe page keeps **your conversation** in view, with `streaming` updates.\n\n- Safe text rendering\n- One result beside each tool call\n\n```typescript\nconst page = await fetch('/events');\n```"],
            ["type": "thinking", "thinking": "Check the stream and keep tool results with their calls."],
            ["type": "toolCall", "id": "read-1", "name": "read", "arguments": ["path": "src/page.ts"]],
            ["type": "toolCall", "id": "test-1", "name": "bash", "arguments": ["command": "make check"]]
        ]]])
        entry("message", ["message": ["role": "toolResult", "toolCallId": "read-1", "toolName": "read", "content": [["type": "text", "text": "export const ready = true;"]], "isError": false, "timestamp": 1793880000002]])
        entry("message", ["message": ["role": "toolResult", "toolCallId": "test-1", "toolName": "bash", "content": [["type": "text", "text": "Check failed: missing fixture"]], "isError": true, "timestamp": 1793880000003]])
        entry("custom_message", ["customType": "ko-pi.notice", "display": true, "details": ["from": "builder"], "content": "The page is ready for review."])
        let data = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try data.write(to: fixture, atomically: true, encoding: .utf8)
        try await start(height: 1040, pane: "cd \(SSH.quote(home.path)); export HOME=\(SSH.quote(home.path)) PI_CODING_AGENT_DIR=\(SSH.quote(agent.path)) PATH=\(SSH.quote(path)); exec \(SSH.quote(shim)) --webview --offline --no-extensions --no-mcp --no-skills --no-prompt-templates --no-themes --no-context-files --session \(SSH.quote(fixture.path))")
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await wait("real ko-pi webview page", within: 20) { (pane.webviewView?.visualDocuments ?? 0) > 0 }
        let screen = pane.webviewView == nil ? try await ko(["api", "/panes/pane_1/screen"], dir: directory.path) : ""
        let web = try XCTUnwrap(pane.webviewView?.browser, screen)
        try await webviewUntil(web, "document.querySelector('.notice')&&document.querySelector('#status').textContent==='Ready'")
        let ready = try await webviewJS(web, "document.querySelector('#items').innerText")
        XCTAssertTrue(ready.contains("A small, clear change"), ready)
        XCTAssertTrue(ready.lowercased().contains("builder"), ready)
        let fonts = try await webviewJS(web, "({theme:window.ko.theme['--ko-font-family'],code:getComputedStyle(document.querySelector('pre')).fontFamily,tool:getComputedStyle(document.querySelector('.tool summary')).fontFamily})")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fonts.utf8)) as? [String: String])
        XCTAssertEqual(values["code"], values["theme"])
        XCTAssertEqual(values["tool"], values["theme"])
        XCTAssertTrue(values["theme"]?.contains("monospace") == true)
        let toolState = try await webviewJS(web, "[...document.querySelectorAll('.tool')].map(d=>d.open)")
        XCTAssertEqual(toolState, "[false,true]")
        _ = try await webviewJS(web, "(()=>{document.querySelector('#scroll').scrollTop=0;return true})()")
        try await webviewSnapshot(pane, "light")
        try await darken()
        pane.webviewView?.updateTheme()
        try await webviewUntil(web, "getComputedStyle(document.body).getPropertyValue('--ko-appearance').trim()==='dark'")
        try await webviewSnapshot(pane, "dark")
        XCTAssertEqual(pane.webviewView?.visualDocuments, 1)
    }
}
