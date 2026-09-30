import Foundation

public final class Client: @unchecked Sendable {
    public struct Closed: Error {}

    private typealias Pending = (count: Int, replies: [Reply], done: @Sendable ([Reply]?) -> Void)

    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let writer = DispatchQueue(label: "TmuxControl.writer")
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var closed = false
    private var parser = Parser()

    public init(tmux: URL, socket: String, session: String?, pauseAfter: Int) {
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = tmux
        process.arguments = ["-S", socket, "-C", "attach-session"] + (session.map { ["-t", $0] } ?? [])
            + ["-f", "pause-after=\(pauseAfter),new-layouts"]
        process.standardInput = stdin
        process.standardOutput = stdout
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    deinit {
        close()
    }

    public func start(
        onEvent: @escaping @Sendable (Event) -> Void, onClose: @escaping @Sendable (Int32) -> Void
    ) throws {
        try process.run()
        output.readabilityHandler = { [weak self, process] h in
            let data = h.availableData
            guard data.isEmpty else {
                self?.read(data, onEvent)
                return
            }
            h.readabilityHandler = nil
            self?.close()
            process.waitUntilExit()
            onClose(process.terminationStatus)
        }
    }

    public func close() {
        let orphans = lock.withLock {
            guard !closed else { return [Pending]() }
            closed = true
            writer.async { [input] in try? input.close() }
            defer { pending = [] }
            return pending
        }
        orphans.forEach { $0.done(nil) }
    }

    private func read(_ data: Data, _ onEvent: (Event) -> Void) {
        parser.feed(data) { event in
            if case .block(let reply, .control) = event, let done = complete(reply) {
                done()
            } else {
                onEvent(event)
            }
        }
    }

    // A failed command makes tmux drop the rest of its line (cmdq_remove_group
    // in cmd-queue.c), so a failure is the line's last reply.
    private func complete(_ reply: Reply) -> (() -> Void)? {
        lock.withLock {
            guard !pending.isEmpty else { return nil }
            pending[0].replies.append(reply)
            if case .success = reply, pending[0].replies.count < pending[0].count { return {} }
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
            writer.async { [weak self, input] in
                do { try input.write(contentsOf: line) } catch { self?.close() }
            }
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
}
