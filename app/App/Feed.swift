import Foundation
import SidebarFeed

// The %-quoting `Launch.conf_command` writes around a path that contains a
// space; the value otherwise reaches show-options unquoted (lib/launch.ml).
func unquoteSideStatusCommand(_ raw: String) -> String {
    raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 ? String(raw.dropFirst().dropLast()) : raw
}

final class Feed: @unchecked Sendable {
    typealias Location = (kido: String, client: String)
    typealias Locate = (@escaping @Sendable (Result<Location, Server.Failure>) -> Void) -> Void

    enum Status {
        case starting
        case running(Snapshot?)
        case restarting(String)
    }

    private let socket: String
    private let locate: Locate
    @MainActor private let query: () -> String
    private let reader = DispatchQueue(label: "Feed.reader")
    private let writer = DispatchQueue(label: "Feed.writer")
    @MainActor private var located: Location?
    @MainActor private var process: Process?
    @MainActor private var input: FileHandle?
    @MainActor private var generation = 0
    @MainActor private var restartWork: DispatchWorkItem?
    @MainActor private var backoff: TimeInterval = 0.1
    @MainActor private(set) var status: Status = .starting { didSet { onChange(status) } }
    @MainActor private let onChange: (Status) -> Void

    @MainActor init(
        socket: String, locate: @escaping Locate, query: @escaping () -> String, onChange: @escaping (Status) -> Void
    ) {
        self.socket = socket
        self.locate = locate
        self.query = query
        self.onChange = onChange
        start()
    }

    @MainActor func stop() {
        restartWork?.cancel()
        restartWork = nil
        generation += 1
        process = nil
        closeInput()
    }

    @MainActor private func closeInput() {
        guard let input else { return }
        self.input = nil
        writer.async { try? input.close() }
    }

    @MainActor func filter(_ text: String) {
        guard let input else { return }
        writer.async { try? input.write(contentsOf: Data((text.isEmpty ? "filter\n" : "filter \(text)\n").utf8)) }
    }

    @MainActor func switchWindow(next: Bool, failed: @escaping @MainActor (String) -> Void) {
        guard let (kido, client) = located else { return failed("the sidebar feed has not found kido yet") }
        let process = Process(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: kido)
        process.arguments = ["switch-window", next ? "next" : "prev", "--client", client, "--socket", socket]
        process.environment = Self.environment
        process.standardError = stderr
        let ended = DispatchGroup()
        ended.enter()
        process.terminationHandler = { _ in ended.leave() }
        do { try process.run() } catch { return failed("could not run \(kido): \(error.localizedDescription)") }
        nonisolated(unsafe) var message = Data()
        DispatchQueue.global().async(group: ended) { message = stderr.fileHandleForReading.readDataToEndOfFile() }
        ended.notify(queue: .main) {
            guard process.terminationStatus != 0 else { return }
            let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            failed(text.isEmpty ? "kido switch-window exited \(process.terminationStatus)" : text)
        }
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
        locate { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                switch result {
                case .failure(let failure): self.restart(failure.message)
                case .success(let location): self.launch(location, generation)
                }
            }
        }
    }

    @MainActor private func launch(_ location: Location, _ generation: Int) {
        located = location
        let (kido, client) = location
        let fake = ProcessInfo.processInfo.environment["KIDO_APP_FEED"]
        let path = fake ?? kido
        guard !path.isEmpty else { return restart("the server's side-status-command is empty") }
        guard path.hasPrefix("/") else { return restart("the server's side-status-command \(path) is not an absolute path") }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = fake == nil ? ["sidebar-feed", "--socket", socket, "--client", client] : []
        process.environment = Self.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        nonisolated(unsafe) var stderrTail = Data()
        // waitUntilExit can miss the exit off the main thread (Client.start).
        let ended = DispatchGroup()
        ended.enter()
        process.terminationHandler = { _ in ended.leave() }
        do { try process.run() } catch { return restart("could not run \(path): \(error.localizedDescription)") }
        self.process = process
        input = stdin.fileHandleForWriting
        filter(query())
        DispatchQueue.global().async(group: ended) { stderrTail = stderr.fileHandleForReading.readDataToEndOfFile() }
        readLines(stdout.fileHandleForReading, queue: reader, group: ended) { [weak self] line in
            let last = try? JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                if last != nil { self.backoff = 0.1 }
                self.status = .running(last)
            }
        }
        ended.notify(queue: .main) { [weak self] in
            guard let self, self.generation == generation else { return }
            let tail = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            restart(tail.isEmpty ? "kido sidebar-feed exited" : tail)
        }
    }

    @MainActor private func restart(_ reason: String) {
        process = nil
        closeInput()
        status = .restarting(reason)
        backoff = min(backoff * 2, 8)
        let item = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: item)
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
