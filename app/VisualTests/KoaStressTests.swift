import AppKit
import Darwin
import KoClientKit
import WebKit
import KoClient
import KoModel
import XCTest
@testable import Kido

@MainActor final class KoaStressTests: VisualTestCase {
    private static var startingWebContent: Int?
    private static let visibleWorkloads: Set<Int> = [2, 6]
    private var dir = ""
    private var owner: WindowOwner!
    private var output: URL!
    private var visible: Bool { ProcessInfo.processInfo.environment["KOA_STRESS_VISIBLE"] == "1" }
    private var timing: String { visible ? "frame" : "applied" }
    private var path: String { [tools.prefix + "/bin", "/opt/homebrew/bin", ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":") }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["KOA_STRESS"] == "1" else { throw XCTSkip("Set KOA_STRESS=1 for the manual koa measurements") }
        try await super.setUp()
        guard let configured = ProcessInfo.processInfo.environment["KOA_STRESS_OUTPUT"], !configured.isEmpty else { throw NSError(domain: "KoaStress", code: 1, userInfo: [NSLocalizedDescriptionKey: "KOA_STRESS_OUTPUT must not be empty"]) }
        output = URL(fileURLWithPath: configured)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: output.appendingPathComponent("scripts/12.jsonl").path) {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            let generated = try await Child.run("/usr/bin/env", ["node", checkoutRoot.appendingPathComponent("share/koa/stress/workloads.ts").path, output.appendingPathComponent("scripts").path], env: env)
            XCTAssertEqual(generated.status, 0, generated.err)
        }
        let manifest = output.appendingPathComponent("kido-manifest.json")
        let selected = Set((ProcessInfo.processInfo.environment["KOA_STRESS_TESTS"] ?? "").split(separator: " ").map(String.init))
        let workloads = [(1, "testLongSession"), (2, "testFastTokens"), (6, "testManyPanes"), (7, "testHiddenShown"), (8, "testThemes"), (12, "testParentChildren")]
        let ids = workloads.compactMap { id, test -> Int? in
            let enabled = selected.isEmpty || selected.contains("KoaStressTests") || selected.contains("KoaStressTests/" + test)
            return enabled && (!visible || Self.visibleWorkloads.contains(id)) ? id : nil
        }
        try JSONSerialization.data(withJSONObject: ["target": "kido", "ids": ids]).write(to: manifest)
        dir = try koServerDir()
        let config = output.appendingPathComponent("kido-config.yaml").path
        try "app: {font: {size: 13}, webview: {keep_hidden: 0}}\n".write(toFile: config, atomically: true, encoding: .utf8)
        let board = NSPasteboard(name: .init("koa-stress-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config, pasteboard: board))
        owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = dir
        if visible {
            let screen = try XCTUnwrap(NSScreen.main)
            owner.window.setFrame(screen.visibleFrame.insetBy(dx: 16, dy: 16), display: false)
            let policy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            addTeardownBlock { @MainActor in NSApp.setActivationPolicy(policy) }
        } else {
            owner.window.setFrame(NSRect(x: -20000, y: -20000, width: 1200, height: 850), display: false)
        }
        PaneView.renderOffscreen = !visible
        addTeardownBlock { @MainActor [owner] in owner?.close(); board.releaseGlobally(); PaneView.renderOffscreen = false }
        _ = try await KoServer.launch(dir: dir)
    }

    private func prompt(_ web: WKWebView) async throws {
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'")
        let status = try await webviewJS(web, "fetch('/prompt',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text:'go',mode:'prompt',attachments:[]})}).then(r=>r.status)")
        XCTAssertEqual(status, "200")
    }

    private func complete(_ web: WKWebView, id: Int, deadline: Date) async throws {
        try await webviewUntil(web, "document.querySelector('#status').textContent==='idle'&&document.querySelector('#items').textContent.includes('STRESS DONE \(id)')", within: max(0.001, deadline.timeIntervalSinceNow))
        if id == 1 {
            let loaded = try await webviewJS(web, "document.querySelector('#items').textContent.includes('Paragraph 1998')")
            XCTAssertEqual(loaded, "true")
        } else {
            _ = try await webviewJS(web, "(()=>{if(document.querySelectorAll('#items .msg.assistant p').length<20000&&!document.querySelector('#older').hidden)document.querySelector('#older').click();return true})()")
            try await webviewUntil(web, "document.querySelectorAll('#items .msg.assistant p').length===20000&&Array.from(document.querySelectorAll('#items .msg.assistant p')).every(p=>p.textContent==='abcdefghijklmnopqr')", within: max(0.001, deadline.timeIntervalSinceNow))
        }
    }

    private func flushMetrics(_ browsers: [WKWebView]) async throws {
        let writes = browsers.map { browser in Task { @MainActor in try await self.webviewJS(browser, "window.koaMetrics.flush().then(()=>true)") } }
        for write in writes { let value = try await write.value; XCTAssertEqual(value, "true") }
    }

    private func memory() throws -> [String: Int] {
        let processes = try XCTUnwrap(WKProcessPool.perform(NSSelectorFromString("_webContentProcessInfo"))?.takeUnretainedValue() as? [NSObject])
        var footprints: [UInt64] = []
        for process in processes {
            let pid = try XCTUnwrap(process.value(forKey: "pid") as? NSNumber).int32Value
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if result != 0 {
                if errno == ESRCH { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            footprints.append(usage.ri_phys_footprint)
        }
        return ["footprintBytes": Int(footprints.reduce(0, +)), "maxFootprintBytes": Int(footprints.max() ?? 0), "processes": footprints.count]
    }

    private var panes: [PaneView] { owner.testSession?.windows.values.filter { !$0.isHidden }.flatMap(\.displayedPanes) ?? [] }

    private func summary(_ id: Int, started: Date, before: [String: Int], metrics: [String], status: Result<Void, Error>) throws {
        var value: [String: Any] = ["target": "kido", "visible": visible, "timing": timing, "id": id, "before": before, "after": try memory(), "metrics": metrics, "seconds": Date().timeIntervalSince(started)]
        switch status {
        case .success: value["status"] = "ok"
        case .failure(let error): value["status"] = "failed"; value["error"] = String(describing: error)
        }
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent("kido-\(id)-summary.json"))
    }

    private func measure(_ id: Int, count: Int = 1, hidden: Bool = false) async throws {
        if visible && !Self.visibleWorkloads.contains(id) { throw XCTSkip("Workload has no visible stress mode") }
        var started = Date()
        var before = try memory()
        if Self.startingWebContent == nil { Self.startingWebContent = before["processes"] }
        var metrics: [String] = []
        do {
            let settled = Date().addingTimeInterval(10)
            while before["processes"] != Self.startingWebContent {
                guard Date() < settled else { throw NSError(domain: "KoaStress", code: 2, userInfo: [NSLocalizedDescriptionKey: "baseline not settled"]) }
                try await Task.sleep(for: .milliseconds(100))
                before = try memory()
            }
            started = Date()
            let completionSeconds: TimeInterval = id == 6 && !visible ? 180 : 90
            let deadline = started.addingTimeInterval(completionSeconds)
            func command(_ index: Int) -> String {
                let file = output.appendingPathComponent("kido-\(id)-\(index).jsonl").path
                metrics.append(file)
                let script = output.appendingPathComponent("scripts/\(id).jsonl").path
                return "export PATH=\(SSH.quote(path)) KOA_FAKE_SCRIPT=\(SSH.quote(script)) KOA_FAKE_LOG=\(SSH.quote(output.appendingPathComponent("kido-\(id)-\(index)-rpc.jsonl").path)); exec \(SSH.quote(tools.prefix + "/share/ko/bin/koa")) --pi \(SSH.quote(checkoutRoot.appendingPathComponent("share/koa/koa-fake-pi.ts").path)) --metrics \(SSH.quote(file)) --metrics-mode \(timing) 2>\(SSH.quote(output.appendingPathComponent("kido-\(id)-\(index).stderr").path))"
            }
            let trees = (0..<count).map { koPane(command($0)) }
            let tree: String
            if visible && count == 8 {
                let rows = stride(from: 0, to: 8, by: 4).map { index in
                    #"{"split":"h","children":[\#(trees[index..<(index + 4)].joined(separator: ","))]}"#
                }
                tree = #"{"split":"v","children":[\#(rows.joined(separator: ","))]}"#
            } else {
                tree = count == 1 ? trees[0] : #"{"split":"h","children":[\#(trees.joined(separator: ","))]}"#
            }
            let windows = hidden ? #"[{"name":"koa","tree":\#(tree)},{"name":"other","tree":\#(koPane())}]"# : #"[{"name":"koa","tree":\#(tree)}]"#
            try await koPut(dir, #"[{"name":"stress","windows":\#(windows)}]"#)
            owner.start()
            if visible {
                owner.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            try await wait("koa stress pages", within: 30) { self.panes.count == count && self.panes.allSatisfy { ($0.webviewView?.visualDocuments ?? 0) > 0 } }
            if visible {
                for pane in panes {
                    let browser = try XCTUnwrap(pane.webviewView?.browser)
                    try await webviewUntil(browser, "document.visibilityState==='visible'&&!document.hidden", within: 5)
                }
            }
            for pane in panes { try await prompt(try XCTUnwrap(pane.webviewView?.browser)) }
            if id != 1 { try await webviewUntil(try XCTUnwrap(panes.first?.webviewView?.browser), "document.querySelector('#status').textContent.startsWith('working')") }
            if id == 12 {
                let parent = try XCTUnwrap(panes.first).pane
                let parentWindow = try XCTUnwrap(owner.testModel?.layout.layout.sessions.first?.windows.first).id
                for index in 1...6 {
                    let request: [String: Any] = ["parent": parent.description, "close": "on_exit", "command": ["type": "shell", "command": command(index)]]
                    let file = dir + "/child.json"
                    try JSONSerialization.data(withJSONObject: request).write(to: URL(fileURLWithPath: file))
                    let response = try await ko(["api", "-X", "POST", "--input", file, "/panes"], dir: dir)
                    let placement = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
                    let window = try XCTUnwrap(placement["window"] as? String), childPane = try XCTUnwrap(placement["pane"] as? String)
                    try await wait("child window") { self.owner.testModel?.layout.layout.sessions.first?.windows.contains { $0.id.description == window } == true }
                    let childWindow = try XCTUnwrap(owner.testModel?.layout.layout.sessions.first?.windows.first { $0.id.description == window }).id
                    try XCTUnwrap(owner.testClient).select(KO_SELECT_WINDOW, childWindow)
                    try await wait("child page") { self.panes.first?.pane.description == childPane && (self.panes.first?.webviewView?.visualDocuments ?? 0) > 0 }
                    try await prompt(try XCTUnwrap(panes.first?.webviewView?.browser))
                    try XCTUnwrap(owner.testClient).select(KO_SELECT_WINDOW, parentWindow)
                    try await wait("parent selected") { self.panes.first?.pane == parent && (self.panes.first?.webviewView?.visualDocuments ?? 0) > 0 }
                }
                try await wait("children released") { self.owner.testSession?.windows.values.filter { $0.isHidden }.flatMap(\.retainedPanes).allSatisfy { $0.webviewView == nil } == true }
                try JSONSerialization.data(withJSONObject: try memory()).write(to: output.appendingPathComponent("kido-12-hidden.json"))
                try await complete(try XCTUnwrap(panes.first?.webviewView?.browser), id: id, deadline: deadline)
                try await flushMetrics(try panes.map { try XCTUnwrap($0.webviewView?.browser) })
                let children = owner.testModel?.layout.layout.sessions.first?.windows.filter { $0.id != parentWindow } ?? []
                XCTAssertEqual(children.count, 6)
                for child in children {
                    try XCTUnwrap(owner.testClient).select(KO_SELECT_WINDOW, child.id)
                    try await wait("child catch-up") { self.owner.testModel?.selection.window == child.id && (self.panes.first?.webviewView?.visualDocuments ?? 0) > 0 }
                    try await complete(try XCTUnwrap(panes.first?.webviewView?.browser), id: id, deadline: deadline)
                    try await flushMetrics(try panes.map { try XCTUnwrap($0.webviewView?.browser) })
                }
                try XCTUnwrap(owner.testClient).select(KO_SELECT_WINDOW, parentWindow)
                try await wait("parent shown") { self.panes.first?.pane == parent && (self.panes.first?.webviewView?.visualDocuments ?? 0) > 0 }
            }
            if id == 8 {
                for index in 0..<50 {
                    owner.window.appearance = NSAppearance(named: index % 2 == 0 ? .darkAqua : .aqua)
                    owner.testSession?.updateWebview()
                    _ = try await webviewJS(try XCTUnwrap(panes.first?.webviewView?.browser), "document.documentElement.style.getPropertyValue('--ko-bg')")
                }
            }
            if hidden {
                let rows = try XCTUnwrap(owner.testModel?.layout.layout.sessions.first?.windows)
                try XCTUnwrap(owner.testClient).select(KO_SELECT_WINDOW, rows[1].id)
                try await wait("hidden koa page released") { self.owner.testSession?.windows[rows[0].id]?.retainedPanes.allSatisfy { $0.webviewView == nil } == true }
                let during = try memory()
                try XCTUnwrap(owner.testClient).select(KO_SELECT_WINDOW, rows[0].id)
                try await wait("koa page reloaded") { (self.panes.first?.webviewView?.visualDocuments ?? 0) > 0 }
                try JSONSerialization.data(withJSONObject: during).write(to: output.appendingPathComponent("kido-\(id)-hidden.json"))
            }
            for pane in panes {
                let browser = try XCTUnwrap(pane.webviewView?.browser)
                try await complete(browser, id: id, deadline: deadline)
                if id == 6 {
                    let snapshot = try await webviewJS(browser, """
                    (async()=>{
                      let before=Number.MAX_SAFE_INTEGER;const expected=[];
                      for(;;){
                        const page=await (await fetch('/items?before='+before)).json();
                        expected.unshift(...page.items);
                        if(!page.more)break;
                        before=page.items[0].seq;
                      }
                      return {actual:window.koaMetrics.items,expected,after:window.koaMetrics.after,cursor:expected.at(-1).seq};
                    })()
                    """)
                    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any])
                    XCTAssertEqual(try XCTUnwrap(result["actual"] as? NSArray), try XCTUnwrap(result["expected"] as? NSArray))
                    XCTAssertEqual(try XCTUnwrap(result["after"] as? Int), try XCTUnwrap(result["cursor"] as? Int))
                }
            }
            try await flushMetrics(try panes.map { try XCTUnwrap($0.webviewView?.browser) })
            for file in metrics {
                let records = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
                XCTAssertTrue(records.contains { (($0 as? [String: Any])?["samples"] as? [Any])?.isEmpty == false }, "No apply samples: \(file)")
            }
            if visible { XCTAssertTrue(owner.window.isVisible && owner.window.isKeyWindow) }
            else { XCTAssertFalse(owner.window.isVisible || owner.window.isKeyWindow || owner.window.isMainWindow) }
            try summary(id, started: started, before: before, metrics: metrics, status: .success(()))

        } catch {
            try summary(id, started: started, before: before, metrics: metrics, status: .failure(error))
            throw error
        }
    }

    func testLongSession() async throws { try await measure(1) }
    func testFastTokens() async throws { try await measure(2) }
    func testManyPanes() async throws { try await measure(6, count: 8) }
    func testHiddenShown() async throws { try await measure(7, hidden: true) }
    func testThemes() async throws { try await measure(8) }
    func testParentChildren() async throws { try await measure(12) }
}
