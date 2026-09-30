import Foundation

public final class Client: @unchecked Sendable {
    public let queue = DispatchQueue(label: "TmuxControl.reader")

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
        // waitUntilExit spins the calling thread's run loop and can miss the
        // exit when called from a dispatch queue, blocking forever.
        let ended = DispatchGroup()
        ended.enter()
        ended.enter()
        process.terminationHandler = { _ in ended.leave() }
        try process.run()
        ended.notify(queue: queue) { [process] in onClose(process.terminationStatus) }
        let source = DispatchSource.makeReadSource(fileDescriptor: output.fileDescriptor, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        source.setEventHandler { [weak self, output] in
            let n = Foundation.read(output.fileDescriptor, &buffer, buffer.count)
            if n > 0 { return self?.read(buffer[..<n], onEvent) ?? () }
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            source.cancel()
            self?.close()
            ended.leave()
        }
        source.resume()
    }

    public func close() {
        let orphans = lock.withLock {
            guard !closed else { return [Pending]() }
            closed = true
            writer.async { [input] in try? input.close() }
            defer { pending = [] }
            return pending
        }
        queue.async { orphans.forEach { $0.done(nil) } }
    }

    private func read(_ data: ArraySlice<UInt8>, _ onEvent: (Event) -> Void) {
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
        guard !commands.isEmpty else { return queue.async { done([]) } }
        let line = Data((commands.map(\.line).joined(separator: " ; ") + "\n").utf8)
        let accepted = lock.withLock {
            guard !closed else { return false }
            pending.append((commands.count, [], done))
            writer.async { [weak self, input] in
                do { try input.write(contentsOf: line) } catch { self?.close() }
            }
            return true
        }
        if !accepted { queue.async { done(nil) } }
    }
}
