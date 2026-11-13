import AppKit
import Foundation
import XCTest
@testable import Kido

// koa hosts the pi that is installed on PATH. A test gives it a private agent directory that points to
// one fake provider (share/koa/koa-fake-provider.ts); the extension share/koa/testdata/visual-ext.ts registers its models.
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

// The shell command that starts koa in a pane. `visual` is the models file of visual-ext.ts.
@MainActor func koaShell(_ test: VisualTestCase, directory: URL, home: URL, session: String?, visual: URL?, extensionFile: String = "visual-ext.ts", cwd: URL, exec: Bool = true, env: [String: String] = [:], args: [String] = [], stderr: URL? = nil) -> String {
    var variables: [String: String] = [
        "HOME": home.path, "PATH": koaPath(test), "PI_CODING_AGENT_DIR": directory.appendingPathComponent("agent").path,
        "PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1",
    ]
    if let visual { variables["KOA_VISUAL"] = visual.path }
    variables.merge(env) { _, new in new }
    let exports = variables.sorted { $0.key < $1.key }.map { "\($0.key)=\(SSH.quote($0.value))" }.joined(separator: " ")
    var arguments = ["--no-extensions", "--extension", test.checkoutRoot.appendingPathComponent("share/koa/testdata/" + extensionFile).path, "--no-context-files", "--session-dir", directory.appendingPathComponent("home/sessions").path]
    arguments += ["--no-skills", "--no-prompt-templates"]
    if let session { arguments += ["--session", session] } else { arguments += ["--session-id", "00000000-0000-7000-8000-0000000000ff"] }
    arguments += args
    return "cd \(SSH.quote(cwd.path)); export \(exports); \(exec ? "exec " : "")\(SSH.quote(tools.prefix + "/share/ko/bin/koa")) \(arguments.map(SSH.quote).joined(separator: " "))" + (stderr.map { " 2>\(SSH.quote($0.path))" } ?? "")
}

nonisolated(unsafe) let koaModels: [[String: Any]] = [
    ["provider": "anthropic", "id": "claude-opus-5-5", "contextWindow": 200000],
    ["provider": "anthropic", "id": "claude-sonnet-5-5", "contextWindow": 200000],
    ["provider": "claude-bridge", "id": "claude-fable-5-1", "contextWindow": 200000],
    ["provider": "openai-codex", "id": "gpt-6.1-sol", "contextWindow": 200000],
    ["provider": "openai-codex", "id": "gpt-6-astra", "contextWindow": 200000],
]


@MainActor func koaContentSize(window: NSWindow, width: CGFloat, height: CGFloat) {
    let chrome = window.frame.height - window.contentLayoutRect.height
    window.setContentSize(NSSize(width: width, height: height + chrome))
}
