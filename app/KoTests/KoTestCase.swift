import GhosttyKit
import KoClient
import KoClientKit
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
    private var serverProcesses: [String: [Process]] = [:]
    func ko(_ arguments: [String], dir: String, output: Bool = false, environment: [String: String] = [:], cwd: URL? = nil) throws -> Process {
        let process = Process()
        if output { process.standardOutput = Pipe() }
        process.currentDirectoryURL = cwd
        process.executableURL = URL(fileURLWithPath: tools.ko)
        let split = arguments.firstIndex(of: "--") ?? arguments.endIndex
        process.arguments = Array(arguments[..<split]) + ["--server", dir] + arguments[split...]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": dir].merging(environment) { $1 }
        try process.run()
        return process
    }

    // The standard output of a ko command that ended with status 0.
    func output(_ arguments: [String], dir: String) throws -> String {
        let process = try ko(arguments, dir: dir, output: true)
        let data = (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return String(decoding: data, as: UTF8.self)
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

    func createPane(_ request: String, dir: String) throws -> String {
        let input = dir + "/pane-request.json"
        try request.write(toFile: input, atomically: true, encoding: .utf8)
        let reply = try output(["api", "-X", "POST", "--input", input, "/panes"], dir: dir)
        return try XCTUnwrap(JSONDecoder().decode([String: String].self, from: Data(reply.utf8))["pane"])
    }

    func put(_ layout: String, dir: String) throws {
        try run(layoutPut(layout, dir: dir), dir: dir)
    }

    func stateDir() throws -> String {
        var template = Array("/tmp/ko-kp-XXXXXX".utf8CString)
        let dir = String(cString: try XCTUnwrap(mkdtemp(&template)))
        let suite = try XCTUnwrap(ProcessInfo.processInfo.environment["KIDO_APP_SERVER"])
        let manifest = suite + "/test-dirs"
        if !FileManager.default.fileExists(atPath: manifest) { FileManager.default.createFile(atPath: manifest, contents: nil) }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: manifest))
        try file.seekToEnd()
        try file.write(contentsOf: Data((dir + "\n").utf8))
        try file.close()
        addTeardownBlock { @MainActor in
            await KoServer.finishLaunches(dir: dir)
            _ = try? await Task.detached { try KoClient.stopServer(dir: dir) }.value
            for process in self.serverProcesses.removeValue(forKey: dir) ?? [] {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            self.wait("the server socket has no listener") { !serverHasListener(dir) }
            try? FileManager.default.removeItem(atPath: dir)
        }
        return dir
    }

    func mismatchServer() throws -> String {
        let dir = try stateDir()
        let checkout = try XCTUnwrap(ProcessInfo.processInfo.environment["KO_CHECKOUT"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: checkout + "/target/debug/ko-fake")
        process.arguments = ["mismatch-server", dir]
        try process.run()
        serverProcesses[dir, default: []].append(process)
        wait("incompatible server socket") { FileManager.default.fileExists(atPath: dir + "/socket") || !process.isRunning }
        XCTAssertTrue(process.isRunning)
        return dir
    }

    func server(at path: String? = nil, environment: [String: String] = [:], cwd: URL? = nil) throws -> String {
        let dir = try path ?? stateDir()
        let process = try ko(["server"], dir: dir, environment: environment, cwd: cwd)
        serverProcesses[dir, default: []].append(process)
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
    func serverWithWindows(_ windows: [Int], argv: [String] = ["/bin/sleep", "60"], at path: String? = nil) throws -> String {
        let dir = try server(at: path)
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
    func serverWithPane(_ script: String, at path: String? = nil) throws -> String {
        try serverWithWindows([1], argv: ["/bin/sh", "-c", script], at: path)
    }

    // Connects and waits until the model holds `panes` panes.
    func connect(_ dir: String, hello: KoHello = KoHello(), panes: Int = 1, sink: @escaping (KoEvent) -> Void) throws -> KoClient {
        let connection = try KoClient.connect(socket: dir + "/socket", hello: hello, sink: sink)
        addTeardownBlock { @MainActor in connection.close() }
        wait("the model with \(panes) panes") { (try? connection.model())?.panes.count == panes }
        return connection
    }

    func connect(_ dir: String, _ recorder: Recorder, panes: Int = 1) throws -> KoClient {
        try connect(dir, panes: panes) { recorder.events.append($0) }
    }


}

func serverHasListener(_ dir: String) -> Bool {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return true }
    defer { close(descriptor) }
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return true }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = (dir + "/socket").utf8CString
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return true }
    withUnsafeMutableBytes(of: &address.sun_path) { target in
        path.withUnsafeBytes { target.copyMemory(from: $0) }
    }
    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    return result == 0 || (errno != ECONNREFUSED && errno != ENOENT)
}

// Runs a program to its end within `deadline` seconds and returns its status and standard output.
func runTool(_ path: String, _ arguments: [String], env: [String: String], deadline: TimeInterval = 10) throws -> (status: Int32, out: String) {
    let process = Process(), out = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = env
    process.standardOutput = out
    let ended = DispatchGroup()
    ended.enter()
    process.terminationHandler = { _ in ended.leave() }
    try process.run()
    nonisolated(unsafe) var data = Data()
    let read = DispatchGroup()
    DispatchQueue.global().async(group: read) { data = out.fileHandleForReading.readDataToEndOfFile() }
    if ended.wait(timeout: .now() + deadline) == .timedOut {
        process.terminate()
        XCTFail("\(path) did not end within \(Int(deadline)) seconds")
    }
    _ = read.wait(timeout: .now() + 2)
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
