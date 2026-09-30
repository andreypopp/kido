import Foundation
import SidebarFeed

// The %-quoting `Launch.conf_command` writes around a path that contains a
// space; the value otherwise reaches show-options unquoted (lib/launch.ml).
func unquoteSideStatusCommand(_ raw: String) -> String {
    raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 ? String(raw.dropFirst().dropLast()) : raw
}

final class Feed: @unchecked Sendable {
    enum Status: Equatable {
        case starting
        case running(Snapshot?)
        case failed(String)
    }

    private let socket: String
    private var client: String
    private let kido: String
    private let queue = DispatchQueue(label: "Feed.reader")
    private var process: Process?
    private var input: FileHandle?
    private var generation = 0
    private var restartWork: DispatchWorkItem?
    private var backoff: TimeInterval = 0.1
    @MainActor private(set) var status: Status = .starting { didSet { onChange(status) } }
    @MainActor private let onChange: (Status) -> Void

    @MainActor init(kido: String, socket: String, client: String, onChange: @escaping (Status) -> Void) {
        self.kido = kido
        self.socket = socket
        self.client = client
        self.onChange = onChange
        start()
    }

    @MainActor func reconnect(client: String) {
        self.client = client
        backoff = 0.1
        stop()
        start()
    }

    @MainActor func stop() {
        restartWork?.cancel()
        restartWork = nil
        generation += 1
        try? input?.close()
        input = nil
        process = nil
    }

    func filter(_ text: String) {
        queue.async { [weak self] in
            guard let input = self?.input else { return }
            try? input.write(contentsOf: Data((text.isEmpty ? "filter\n" : "filter \(text)\n").utf8))
        }
    }

    @MainActor func switchWindow(next: Bool, failed: @escaping @MainActor (String) -> Void) {
        let process = Process(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: kido)
        process.arguments = ["switch-window", next ? "next" : "prev", "--client", client, "--socket", socket]
        process.environment = Self.environment
        process.standardError = stderr
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { failed(message.isEmpty ? "kido switch-window exited \(process.terminationStatus)" : message) }
        }
        do { try process.run() } catch { failed("could not run \(kido): \(error.localizedDescription)") }
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            key != "TMUX" && key != "TMUX_PANE" && !key.hasPrefix("KIDO_AGENT_")
        }
    }

    @MainActor private func start() {
        status = .starting
        generation += 1
        let generation = generation
        let fake = ProcessInfo.processInfo.environment["KIDO_APP_FEED"]
        let path = fake ?? kido
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = fake == nil ? ["sidebar-feed", "--socket", socket, "--client", client] : []
        process.environment = Self.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        let writeEnd = stdin.fileHandleForWriting
        input = writeEnd
        _ = fcntl(writeEnd.fileDescriptor, F_SETNOSIGPIPE, 1)

        nonisolated(unsafe) var stderrTail = Data()
        // waitUntilExit can miss the exit off the main thread (Client.start).
        let ended = DispatchGroup()
        ended.enter()
        process.terminationHandler = { _ in ended.leave() }
        do {
            try process.run()
        } catch {
            status = .failed("could not run \(path): \(error.localizedDescription)")
            ended.leave()
            return
        }
        DispatchQueue.global().async(group: ended) { stderrTail = stderr.fileHandleForReading.readDataToEndOfFile() }
        readLines(stdout.fileHandleForReading, queue: queue, group: ended) { [weak self] line in
            let last = try? JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.status = .running(last)
            }
        }
        ended.notify(queue: .main) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.process = nil
            writeEnd.closeFile()
            self.input = nil
            let tail = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            self.status = .failed(tail.isEmpty ? "kido sidebar-feed exited" : tail)
            self.backoff = min(self.backoff * 2, 8)
            let item = DispatchWorkItem { [weak self] in self?.start() }
            self.restartWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + self.backoff, execute: item)
        }
    }
}

// A DispatchSource read source over the pipe's fd, split into lines; entered
// into `group` so `ended.notify` runs only after the last line is delivered.
private func readLines(
    _ handle: FileHandle, queue: DispatchQueue, group: DispatchGroup, _ onLine: @escaping (String) -> Void
) {
    group.enter()
    let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
    var buffer = Data()
    source.setEventHandler {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let n = Foundation.read(handle.fileDescriptor, &chunk, chunk.count)
        if n > 0 {
            buffer.append(contentsOf: chunk[..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                onLine(String(decoding: buffer[..<newline], as: UTF8.self))
                buffer.removeSubrange(...newline)
            }
            return
        }
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        source.cancel()
        group.leave()
    }
    source.resume()
}
