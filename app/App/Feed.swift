import Foundation
import SidebarFeed

final class Feed: @unchecked Sendable {
    typealias Location = (kido: String, client: String)
    typealias Locate = (@escaping @Sendable (Result<Location, Failure>) -> Void) -> Void

    enum Status {
        case starting
        case running(Snapshot)
        case unreadable
        case restarting(String)
    }

    private let socket: String
    private let locate: Locate
    @MainActor private let query: () -> String
    private let reader = DispatchQueue(label: "Feed.reader")
    private let writer = DispatchQueue(label: "Feed.writer")
    @MainActor private var located: Location?
    @MainActor private var input: FileHandle?
    @MainActor private var generation = 0
    @MainActor private var restartWork: DispatchWorkItem?
    @MainActor private var backoff: TimeInterval = 0.1
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

    @MainActor func switchWindow(next: Bool, completed: @escaping @MainActor (String?) -> Void) {
        guard let (kido, client) = located else { return completed("the sidebar feed has not found kido yet") }
        let args = ["switch-window", next ? "next" : "prev", "--client", client, "--socket", socket]
        Task {
            do throws(Failure) {
                let (status, _, err) = try await Child.run(kido, args, env: Self.environment)
                completed(status == 0 ? nil : err.isEmpty ? "kido switch-window exited \(status)" : err)
            } catch {
                completed(error.message)
            }
        }
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            key != "TMUX" && key != "TMUX_PANE" && !key.hasPrefix("KIDO_AGENT_")
        }
    }

    @MainActor private func start() {
        onChange(.starting)
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
        let stdin = Pipe(), stdout = Pipe()
        let child: Child
        do throws(Failure) {
            child = try Child(
                path, fake == nil ? ["sidebar-feed", "--socket", socket, "--client", client] : [], env: Self.environment,
                stdin: stdin, stdout: stdout)
        } catch {
            return restart(error.message)
        }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = stdin.fileHandleForWriting
        filter(query())
        let output = stdout.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: output, queue: reader)
        nonisolated(unsafe) var buffer = Data()
        nonisolated(unsafe) var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let decoder = JSONDecoder()
        child.ended.enter()
        source.setEventHandler { @Sendable [weak self] in
            let n = Foundation.read(output, &chunk, chunk.count)
            guard n > 0 else {
                if n < 0, errno == EAGAIN || errno == EINTR { return }
                source.cancel()
                return child.ended.leave()
            }
            buffer.append(contentsOf: chunk[..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let last = try? decoder.decode(Snapshot.self, from: buffer[..<newline])
                buffer.removeSubrange(...newline)
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    guard let last else { return self.onChange(.unreadable) }
                    self.backoff = 0.1
                    self.onChange(.running(last))
                }
            }
        }
        source.resume()
        child.ended.notify(queue: .main) { [weak self] in
            guard let self, self.generation == generation else { return }
            restart(child.stderr.isEmpty ? "kido sidebar-feed exited" : child.stderr)
        }
    }

    @MainActor private func restart(_ reason: String) {
        closeInput()
        onChange(.restarting(reason))
        let item = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: item)
        backoff = min(backoff * 2, 8)
    }
}
