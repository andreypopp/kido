import GhosttyKit
import KoClient
import KoModel
import XCTest
@testable import Kido

final class Recorder {
    var events: [KoEvent] = []
    var view: [KoViewEvent] = []
    var restored: [(UInt64, ghostty_snapshot_restore_result_e)] {
        view.compactMap { if case .restored(let generation, let result) = $0 { return (generation, result) } else { return nil } }
    }
}

@MainActor class KoTestCase: XCTestCase {
    func ko(_ arguments: [String], dir: String, output: Bool = false) throws -> Process {
        let process = Process()
        if output { process.standardOutput = Pipe() }
        process.executableURL = URL(fileURLWithPath: tools.ko)
        let split = arguments.firstIndex(of: "--") ?? arguments.endIndex
        process.arguments = Array(arguments[..<split]) + ["--server", dir] + arguments[split...]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": dir]
        try process.run()
        return process
    }

    func run(_ arguments: [String], dir: String) throws {
        let process = try ko(arguments, dir: dir)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    func wait(_ description: String, within seconds: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() >= deadline { return XCTFail("Timed out: \(description)") }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    func put(_ layout: String, dir: String) throws {
        try run(layoutPut(layout, dir: dir), dir: dir)
    }

    func stateDir() throws -> String {
        var template = Array("/tmp/ko-kp-XXXXXX".utf8CString)
        return String(cString: try XCTUnwrap(mkdtemp(&template)))
    }

    func server() throws -> String {
        let dir = try stateDir()
        let process = try ko(["server"], dir: dir)
        addTeardownBlock {
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }
        addTeardownBlock { @MainActor in
            try? self.run(["kill-server"], dir: dir)
            if process.isRunning { process.terminate() }
        }
        wait("the server socket") { FileManager.default.fileExists(atPath: dir + "/socket") }
        return dir
    }

    // Runs a blocking call off the main queue while the main run loop goes on.
    func offMain<T: Sendable>(_ description: String, _ work: @escaping @Sendable () throws -> T) throws -> T {
        let done = Latch()
        nonisolated(unsafe) var result: Result<T, Error>?
        DispatchQueue.global(qos: .userInteractive).async {
            result = Result { try work() }
            done.set()
        }
        wait(description) { done.isSet }
        return try XCTUnwrap(result).get()
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
    func connect(_ dir: String, hello: KoHello = KoHello(), panes: Int = 1, sink: @escaping (KoEvent) -> Void) throws -> KoClient {
        let connection = try KoClient(socket: dir + "/socket", hello: hello, sink: sink)
        addTeardownBlock { @MainActor in connection.close() }
        wait("the model with \(panes) panes") { (try? connection.model())?.panes.count == panes }
        return connection
    }

    func connect(_ dir: String, _ recorder: Recorder, panes: Int = 1) throws -> KoClient {
        try connect(dir, panes: panes) { recorder.events.append($0) }
    }


}
