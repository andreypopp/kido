import Foundation

public final class Client: @unchecked Sendable {
    public let queue = DispatchQueue(label: "TmuxControl.reader")

    private enum Boundary { case count(Int), marker(String) }
    private typealias Pending = (boundary: Boundary, replies: [Reply], done: @Sendable ([Reply]?) -> Void)

    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle
    private let writer = DispatchQueue(label: "TmuxControl.writer")
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var closed = false
    private var parser = Parser()

    public init(tmux: URL, socket: String, session: String?, pauseAfter: Int) {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = tmux
        process.arguments = ["-S", socket, "-N", "-C", "attach-session"] + (session.map { ["-t", $0] } ?? [])
            + ["-f", "pause-after=\(pauseAfter),new-layouts,no-detach-on-destroy"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    deinit {
        close()
    }

    public func start(
        onEvent: @escaping @Sendable (Event) -> Void, onClose: @escaping @Sendable (Int32, String) -> Void
    ) throws {
        // waitUntilExit spins the calling thread's run loop and can miss the
        // exit when called from a dispatch queue, blocking forever.
        let ended = DispatchGroup()
        ended.enter()
        ended.enter()
        ended.enter()
        process.terminationHandler = { _ in ended.leave() }
        try process.run()
        nonisolated(unsafe) var stderr = Data()
        DispatchQueue.global().async { [errors] in
            stderr = errors.readDataToEndOfFile()
            ended.leave()
        }
        ended.notify(queue: queue) { [process] in
            onClose(
                process.terminationStatus,
                String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
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

    // Nested commands inherit CMDQ_STATE_CONTROL (cmd-if-shell.c), so their
    // blocks have the same flag as direct replies. A separate marker line
    // survives cmdq_remove_group's removal of a failed command's line.
    private func complete(_ reply: Reply) -> (() -> Void)? {
        lock.withLock {
            guard !pending.isEmpty else { return nil }
            switch pending[0].boundary {
            case .marker(let marker):
                if reply != .success([marker]) { pending[0].replies.append(reply); return {} }
            case .count(let count):
                pending[0].replies.append(reply)
                if case .success = reply, pending[0].replies.count < count { return {} }
            }
            let p = pending.removeFirst()
            return { p.done(p.replies) }
        }
    }

    public func send(_ commands: [Command], then done: @escaping @Sendable ([Reply]?) -> Void) {
        guard !commands.isEmpty else { return queue.async { done([]) } }
        let nested = commands.contains { ["if-shell", "run-shell", "source-file"].contains(String($0.line.prefix { $0 != " " })) }
        let marker = nested ? UUID().uuidString : nil
        var text = commands.map(\.line).joined(separator: " ; ") + "\n"
        if let marker { text += Command("display-message", "-p", marker).line + "\n" }
        let line = Data(text.utf8)
        let accepted = lock.withLock {
            guard !closed else { return false }
            pending.append((marker.map(Boundary.marker) ?? .count(commands.count), [], done))
            writer.async { [weak self, input] in
                do { try input.write(contentsOf: line) } catch { self?.close() }
            }
            return true
        }
        if !accepted { queue.async { done(nil) } }
    }
}
