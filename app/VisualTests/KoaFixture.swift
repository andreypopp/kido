import Foundation
import XCTest
@testable import Kido

// koa hosts the pi that is installed on PATH. A visual test gives it a private agent directory that points to
// one fake provider (share/koa/koa-fake-provider.ts), session files that share/koa/testdata/visual-seed.ts wrote,
// and the extension share/koa/testdata/visual-ext.ts, whose command /vstep runs one step of the test's timeline.
@MainActor final class KoaProvider {
    private(set) var baseUrl = ""
    private let child: Child
    private let input: Pipe

    static func start(_ test: VisualTestCase, directory: URL, script: [[String: Any]], models: [[String: Any]] = [], settings: [String: Any] = [:], extensionModels: Bool = false) async throws -> KoaProvider {
        let scriptFile = directory.appendingPathComponent("provider-script.json")
        try JSONSerialization.data(withJSONObject: script).write(to: scriptFile)
        let output = Pipe(), input = Pipe()
        let json = { (value: Any) in String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
        let errors = directory.appendingPathComponent("provider.stderr")
        let child = try Child("/bin/sh", ["-c", "exec \"$@\" 2>\"$0\"", errors.path, "/usr/bin/env", "node", test.checkoutRoot.appendingPathComponent("share/koa/koa-fake-provider.ts").path, "@" + scriptFile.path, directory.appendingPathComponent("agent").path, try json(settings), try json(models)] + (extensionModels ? ["extension"] : []), env: ["PATH": koaPath(test)], stdin: input, stdout: output)
        let provider = KoaProvider(child: child, input: input)
        test.addTeardownBlock { @MainActor in provider.stop() }
        nonisolated(unsafe) var seen = ""
        let ready = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                var line = Data()
                while !line.contains(10), case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty { line.append(chunk) }
                seen = String(decoding: line, as: UTF8.self)
                done.resume(returning: line.contains(10))
            }
        }
        if !ready { await child.finished() }
        provider.baseUrl = ((try? JSONSerialization.jsonObject(with: Data(seen.utf8)) as? [String: String])?["baseUrl"]) ?? ""
        XCTAssertTrue(ready, "the fake provider did not become ready (exit \(child.process.terminationStatus), reason \(child.process.terminationReason.rawValue), stdout \(seen)): \((try? String(contentsOf: errors, encoding: .utf8)) ?? "no stderr file") PATH=\(koaPath(test))")
        return provider
    }

    private init(child: Child, input: Pipe) { self.child = child; self.input = input }

    func release(_ gate: String) { try? input.fileHandleForWriting.write(contentsOf: Data("release \(gate)\n".utf8)) }

    func stop() {
        try? input.fileHandleForWriting.close()
        child.stop()
    }
}

@MainActor func koaPath(_ test: VisualTestCase) -> String {
    [test.checkoutRoot.appendingPathComponent("share/koa/node_modules/.bin").path, tools.prefix + "/bin", "/opt/homebrew/bin", ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
}

// Writes the sessions with pi's own SessionManager. The result holds the file of each session by name and the leaf entry of each branch by label.
@MainActor func koaSeed(_ test: VisualTestCase, directory: URL, cwd: URL, sessions: [[String: Any]]) async throws -> (paths: [String: String], ids: [String: String]) {
    let specFile = directory.appendingPathComponent("seed.json")
    try JSONSerialization.data(withJSONObject: ["cwd": cwd.path, "dir": directory.appendingPathComponent("home/sessions").path, "sessions": sessions]).write(to: specFile)
    let result = try await Child.run("/usr/bin/env", ["node", test.checkoutRoot.appendingPathComponent("share/koa/testdata/visual-seed.ts").path, specFile.path], env: ["PATH": koaPath(test)], cwd: test.checkoutRoot.appendingPathComponent("share/koa").path)
    XCTAssertEqual(result.status, 0, result.err)
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: [String: String]])
    return (try XCTUnwrap(parsed["paths"]), try XCTUnwrap(parsed["ids"]))
}

// The shell command that starts koa in a pane. `visual` is the steps file of visual-ext.ts.
@MainActor func koaShell(_ test: VisualTestCase, directory: URL, home: URL, session: String?, visual: URL?, extensionFile: String = "visual-ext.ts", cwd: URL, exec: Bool = true, nodeOptions: String? = nil, resources: Bool = false, env: [String: String] = [:], args: [String] = [], stderr: URL? = nil) -> String {
    var variables: [String: String] = [
        "HOME": home.path, "PATH": koaPath(test), "PI_CODING_AGENT_DIR": directory.appendingPathComponent("agent").path,
        "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1",
    ]
    if let visual { variables["KOA_VISUAL"] = visual.path }
    if let nodeOptions { variables["NODE_OPTIONS"] = nodeOptions }
    variables.merge(env) { _, new in new }
    let exports = variables.sorted { $0.key < $1.key }.map { "\($0.key)=\(SSH.quote($0.value))" }.joined(separator: " ")
    var arguments = ["--no-extensions", "--extension", test.checkoutRoot.appendingPathComponent("share/koa/testdata/" + extensionFile).path, "--no-context-files", "--session-dir", directory.appendingPathComponent("home/sessions").path]
    if !resources { arguments += ["--no-skills", "--no-prompt-templates"] }
    if let session { arguments += ["--session", session] } else { arguments += ["--session-id", "00000000-0000-7000-8000-0000000000ff"] }
    arguments += args
    return "cd \(SSH.quote(cwd.path)); export \(exports); \(exec ? "exec " : "")\(SSH.quote(tools.prefix + "/share/ko/bin/koa")) \(arguments.map(SSH.quote).joined(separator: " "))" + (stderr.map { " 2>\(SSH.quote($0.path))" } ?? "")
}

// A message of a seeded session. `at` is a millisecond timestamp.
func koaItem(_ message: [String: Any]) -> [String: Any] { ["kind": "message", "message": message] }

// One advance of a test's timeline. `step` runs a command of visual-ext.ts, `switchTo` opens a seeded session
// like the session picker does, `release` opens a gate of the provider, and `touch` creates a gate file of the fake `make`.
enum KoaAdvance {
    case step(String), switchTo(String), release(String), touch(String), shown(String), working, idle
}

nonisolated(unsafe) let koaModels: [[String: Any]] = [
    ["provider": "anthropic", "id": "claude-opus-5-5", "contextWindow": 200000],
    ["provider": "anthropic", "id": "claude-sonnet-5-5", "contextWindow": 200000],
    ["provider": "claude-bridge", "id": "claude-fable-5-1", "contextWindow": 200000],
    ["provider": "openai-codex", "id": "gpt-6.1-sol", "contextWindow": 200000],
    ["provider": "openai-codex", "id": "gpt-6-astra", "contextWindow": 200000],
]

// `make` and `git` of the tests: they print the text of the test's file for their number, then wait for the gate file or for a signal.
let koaFakeProgram = """
#!/bin/sh
d="$KOA_FAKE_DIR"
n=1; while ! mkdir "$d/$(basename "$0").run.$n" 2>/dev/null; do n=$((n+1)); done
cat "$d/$(basename "$0").live.$n" 2>/dev/null
if [ -e "$d/$(basename "$0").hold.$n" ]; then exec sleep 3600; fi
while [ ! -e "$d/$(basename "$0").gate.$n" ]; do sleep 0.05; done
cat "$d/$(basename "$0").done.$n" 2>/dev/null
"""
