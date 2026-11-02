import GhosttyKit
import KoClient
import XCTest

final class Recorder {
    var events: [KoEvent] = []
    var view: [KoViewEvent] = []
    var restored: [(UInt64, ghostty_snapshot_restore_result_e)] {
        view.compactMap { if case .restored(let generation, let result) = $0 { return (generation, result) } else { return nil } }
    }
}

@MainActor class KoTestCase: XCTestCase {
    func ko(_ arguments: [String], dir: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["KO_BIN"], "KO_BIN"))
        process.arguments = arguments + ["--server", dir]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": dir]
        try process.run()
        return process
    }

    func run(_ arguments: [String], dir: String) throws {
        let process = try ko(arguments, dir: dir)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    func wait(_ description: String, within seconds: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() >= deadline { return XCTFail("Timed out: \(description)") }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    func put(_ layout: String, dir: String) throws {
        let draft = dir + "/draft.json"
        try layout.write(toFile: draft, atomically: true, encoding: .utf8)
        try run(["api", "-X", "PUT", "--input", draft, "/layout"], dir: dir)
    }

    func server() throws -> String {
        var template = Array("/tmp/ko-kp-XXXXXX".utf8CString)
        let dir = String(cString: try XCTUnwrap(mkdtemp(&template)))
        let process = try ko(["server"], dir: dir)
        addTeardownBlock {
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }
        addTeardownBlock { @MainActor in try? self.run(["kill-server"], dir: dir) }
        wait("the server socket") { FileManager.default.fileExists(atPath: dir + "/socket") }
        return dir
    }

    func mainQueueDrained() {
        let drained = expectation(description: "the main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 10)
    }

    // A server whose one session has a window for each entry of `windows`, with that many
    // panes in a row; every pane runs `argv`.
    func serverWithWindows(_ windows: [Int], argv: [String] = ["/bin/sleep", "60"]) throws -> String {
        let dir = try server()
        let command = try String(decoding: JSONSerialization.data(withJSONObject: argv), as: UTF8.self)
        let pane = #"{"pane":{"new":{"command":{"type":"argv","argv":\#(command)}}}}"#
        let tree = { (count: Int) in
            count == 1 ? pane : #"{"split":"h","children":[\#(Array(repeating: pane, count: count).joined(separator: ","))]}"#
        }
        let list = windows.map { #"{"name":"w","tree":\#(tree($0))}"# }.joined(separator: ",")
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"s","windows":[\#(list)]}]}}"#, dir: dir)
        return dir
    }

    // A server with one pane that runs `script` under sh.
    func serverWithPane(_ script: String) throws -> String {
        try serverWithWindows([1], argv: ["/bin/sh", "-c", script])
    }

    // Connects and waits until the model holds `panes` panes.
    func connect(_ dir: String, hello: ko_hello = ko_hello(cols: 80, rows: 24, focused: false, sizes_windows: false), panes: Int = 1, sink: @escaping (KoEvent) -> Void) throws -> KoConnection {
        let connection = try KoConnection(socket: dir + "/socket", hello: hello, sink: sink)
        addTeardownBlock { @MainActor in connection.close() }
        wait("the model with \(panes) panes") { (try? connection.model()["panes"] as? [Any])?.count == panes }
        return connection
    }

    func connect(_ dir: String, _ recorder: Recorder, panes: Int = 1) throws -> KoConnection {
        try connect(dir, panes: panes) { recorder.events.append($0) }
    }

    // The windows of a model, as its layout document has them.
    nonisolated static func windows(_ model: [String: Any]) -> [[String: Any]] {
        let layout = (model["layout"] as? [String: Any])?["layout"] as? [String: Any]
        return (layout?["sessions"] as? [[String: Any]] ?? []).flatMap { $0["windows"] as? [[String: Any]] ?? [] }
    }
}
