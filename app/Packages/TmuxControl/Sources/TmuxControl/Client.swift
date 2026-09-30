import Foundation

public enum Session: Sendable {
    case attach(String?)
    case create(String?)
}

public final class Client: @unchecked Sendable {
    public struct Closed: Error {}

    private typealias Pending = (count: Int, replies: [Reply], done: @Sendable ([Reply]?) -> Void)

    private let process = Process()
    private let input: FileHandle
    private let writer = DispatchQueue(label: "TmuxControl.writer")
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var closed = false
    private var parser = Parser()

    public init(
        tmux: URL, socket: String, session: Session, pauseAfter: Int,
        onEvent: @escaping @Sendable (Event) -> Void, onClose: @escaping @Sendable (Int32) -> Void
    ) throws {
        let (command, target): (String, [String]) =
            switch session {
            case .attach(let s): ("attach-session", s.map { ["-t", $0] } ?? [])
            case .create(let s): ("new-session", s.map { ["-s", $0] } ?? [])
            }
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = tmux
        process.arguments = ["-S", socket, "-C", command] + target + ["-f", "pause-after=\(pauseAfter),new-layouts"]
        process.standardInput = stdin
        process.standardOutput = stdout
        input = stdin.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        stdout.fileHandleForReading.readabilityHandler = { [self] h in
            let data = h.availableData
            guard data.isEmpty else {
                return parser.feed(data) { event in
                    if case .block(let reply, .control) = event, let done = complete(reply) {
                        done()
                    } else {
                        onEvent(event)
                    }
                }
            }
            h.readabilityHandler = nil
            process.waitUntilExit()
            let orphans = lock.withLock {
                closed = true
                defer { pending = [] }
                return pending
            }
            orphans.forEach { $0.done(nil) }
            onClose(process.terminationStatus)
        }
        try process.run()
    }

    private func complete(_ reply: Reply) -> (() -> Void)? {
        lock.withLock {
            guard !pending.isEmpty else { return nil }
            // tmux answers a line that fails to parse with one block, whatever its command count.
            if case .failure(let lines) = reply, lines.first?.hasPrefix("parse error: ") == true {
                pending[0].replies = Array(repeating: reply, count: pending[0].count)
            } else {
                pending[0].replies.append(reply)
            }
            guard pending[0].replies.count == pending[0].count else { return {} }
            let p = pending.removeFirst()
            return { p.done(p.replies) }
        }
    }

    public func send(_ commands: [Command], then done: @escaping @Sendable ([Reply]?) -> Void) {
        guard !commands.isEmpty else { return done([]) }
        let line = Data((commands.map(\.line).joined(separator: " ; ") + "\n").utf8)
        let accepted = lock.withLock {
            guard !closed else { return false }
            pending.append((commands.count, [], done))
            writer.async { [input] in try? input.write(contentsOf: line) }
            return true
        }
        if !accepted { done(nil) }
    }

    public func run(_ commands: [Command]) async throws -> [Reply] {
        try await withCheckedThrowingContinuation { k in
            send(commands) { replies in
                if let replies { k.resume(returning: replies) } else { k.resume(throwing: Closed()) }
            }
        }
    }

    public func run(_ command: Command) async throws -> Reply {
        try await run([command])[0]
    }

    public func detach() {
        writer.async { [input] in try? input.close() }
    }
}
