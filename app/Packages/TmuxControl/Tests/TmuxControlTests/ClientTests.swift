import Foundation
import Testing
@testable import TmuxControl

let tmux = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    .map { URL(fileURLWithPath: String($0)).appendingPathComponent("kido-tmux") }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }

final class Recorder<Item>: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Item] = []
    private var status: Int32?

    func add(_ e: Item) { lock.withLock { events.append(e) } }
    func close(_ s: Int32) { lock.withLock { status = s } }

    func wait<T>(_ what: String, _ probe: ([Item], Int32?) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let found = lock.withLock({ probe(events, status) }) { return found }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TimedOut(what: what)
    }
}

struct TimedOut: Error { let what: String }

@discardableResult
func server(_ tmux: URL, _ socket: String, _ args: String...) throws -> Int32 {
    let p = try Process.run(tmux, arguments: ["-S", socket, "-f", "/dev/null"] + args)
    p.waitUntilExit()
    return p.terminationStatus
}

@Test(.enabled(if: tmux != nil), .timeLimit(.minutes(1)))
func liveClient() async throws {
    let tmux = try #require(tmux)
    let socket = "/tmp/tc-\(getpid()).sock"
    #expect(try server(tmux, socket, "new-session", "-d", "-s", "t", "-x", "80", "-y", "24", "/bin/sh") == 0)
    defer {
        _ = try? server(tmux, socket, "kill-server")
        try? FileManager.default.removeItem(atPath: socket)
    }
    let seen = Recorder<Event>()
    let client = Client(tmux: tmux, socket: socket, session: "t", pauseAfter: 5)
    try client.start(onEvent: seen.add, onClose: seen.close)
    _ = try await seen.wait("attach") { e, _ in e.contains(.sessionChanged(SessionID(number: 0), "t")) ? () : nil }

    let odd = "a b;$HOME ~ \"q\" \\ #{x} ✓\ttab"
    #expect(try await client.run(Command("set-option", "-g", "@odd", odd)) == .success([]))
    #expect(try await client.run(Command("show-options", "-gv", "@odd")) == .success([odd]))
    #expect(try await client.run(Command("no-such-command")) == .failure(["parse error: unknown command: no-such-command"]))
    let unparsed = Reply.failure(["parse error: unknown command: no-such-command"])
    #expect(try await client.run([Command("list-sessions"), Command("no-such-command")]) == [unparsed])
    #expect(try await client.run(Command("show-options", "-gv", "@odd")) == .success([odd]))

    for failing in 0..<3 {
        let line = (0..<3).map {
            $0 == failing ? Command("select-pane", "-t", PaneID(number: 999)) : Command("display-message", "-p", "\($0)")
        }
        let replies = Recorder<[Reply]?>()
        client.send(line, then: replies.add)
        client.send([Command("display-message", "-p", "next")], then: replies.add)
        let got = try await replies.wait("failure at \(failing)") { r, _ in r.count == 2 ? r : nil }
        #expect(got[0] == (0..<failing).map { .success(["\($0)"]) } + [.failure(["can't find pane: %999"])])
        #expect(got[1] == [.success(["next"])])
    }

    let pane = PaneID(number: 0)
    for c in Command.sendKeys(pane, Array("echo 'hi there'\r".utf8), chunk: 4) {
        #expect(try await client.run(c) == .success([]))
    }
    _ = try await seen.wait("output") { e, _ in output(e, pane).contains("hi there\r\n") ? () : nil }

    let replies = try await client.run([
        Command("capture-pane", "-p", "-t", pane), Command("list-panes", "-t", pane, "-F", "#{pane_id}"),
    ])
    #expect(replies.count == 2)
    guard case .success(let screen) = replies[0] else { Issue.record("capture failed"); return }
    #expect(screen.contains("hi there"))
    #expect(replies[1] == .success(["%0"]))

    #expect(try await client.run(Command("send-keys", "-t", pane, "printf '\\033]0;x'; sleep 5", "Enter")) == .success([]))
    _ = try await seen.wait("unterminated osc") { e, _ in output(e, pane).contains("\u{1B}]0;x") ? () : nil }
    let pending = try await client.run(Command("capture-pane", "-p", "-P", "-C", "-t", pane))
    guard case .success(let lines) = pending, lines.count == 1 else { Issue.record("pending: \(pending)"); return }
    #expect(decodeOctal(ArraySlice(lines[0].utf8)).starts(with: Array("\u{1B}]0;x".utf8)))

    var dropped: Client? = Client(tmux: tmux, socket: socket, session: "t", pauseAfter: 5)
    let gone = Recorder<Event>()
    try dropped?.start(onEvent: gone.add, onClose: gone.close)
    _ = try await gone.wait("second attach") { e, _ in e.isEmpty ? nil : () }
    dropped = nil
    #expect(try await gone.wait("dropped client exits") { _, s in s } == 0)

    let closing = Client(tmux: tmux, socket: socket, session: "t", pauseAfter: 5)
    let orphans = Recorder<[Reply]?>()
    try closing.start(onEvent: { _ in }, onClose: orphans.close)
    closing.send([Command("list-sessions")], then: orphans.add)
    closing.close()
    closing.send([Command("list-sessions")], then: orphans.add)
    #expect(try await orphans.wait("closed client exits") { r, s in s.map { (r, $0) } } == ([nil, nil], 0))

    #expect(try await client.run(Command("rename-window", "-t", WindowID(number: 0), "new name")) == .success([]))
    _ = try await seen.wait("rename") { e, _ in e.contains(.windowRenamed(WindowID(number: 0), .linked, "new name")) ? () : nil }

    _ = try? await client.run(Command("kill-server"))
    let status = try await seen.wait("close") { _, s in s }
    #expect(status == 0)
    _ = try await seen.wait("exit") { e, _ in e.last == .exit(reason: nil) ? () : nil }
    await #expect(throws: Client.Closed.self) { try await client.run(Command("list-sessions")) }
}
