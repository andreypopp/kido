import Foundation
import SidebarFeed
import TmuxControl

final class Feed: @unchecked Sendable {
    typealias Location = String
    typealias Locate = (@escaping @Sendable (Result<Location, Failure>) -> Void) -> Void

    enum Status {
        case starting
        case invalidBundle(Failure)
        case running(Snapshot)
        case unreadable
        case restarting(String)
    }

    #if KIDO_VISUAL || KIDO_STRESS
    @MainActor var testKido: String?
    #endif

    private let serverDir: String
    private let drain: Drain?
    private let locate: Locate
    @MainActor private let prepare: ([String]) -> Launch
    @MainActor private var child: Child?
    @MainActor private var commands: [UUID: Task<Void, Never>] = [:]
    @MainActor private let query: () -> String
    private let reader = DispatchQueue(label: "Feed.reader")
    private let writer = DispatchQueue(label: "Feed.writer")
    @MainActor private var located: Location?
    @MainActor private var input: FileHandle?
    @MainActor private var generation = 0
    @MainActor private var restartWork: DispatchWorkItem?
    @MainActor private var backoff: TimeInterval = 0.1
    @MainActor private let onChange: (Status) -> Void
    @MainActor private(set) var status: Status = .starting

    @MainActor private func publish(_ status: Status) { self.status = status; onChange(status) }

    @MainActor init(
        serverDir: String, locate: @escaping Locate, query: @escaping () -> String, drain: Drain? = nil,
        prepare: @escaping ([String]) -> Launch = { Launch(tools.kido, $0, environment: tools.environment) }, onChange: @escaping (Status) -> Void
    ) {
        self.serverDir = serverDir
        self.drain = drain
        self.locate = locate
        self.prepare = prepare
        self.query = query
        self.onChange = onChange
        start()
    }

    @MainActor func stop() {
        restartWork?.cancel()
        restartWork = nil
        generation += 1
        closeInput()
        child?.stop()
        child = nil
        commands.values.forEach { $0.cancel() }
        commands = [:]
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

    @MainActor func switchWindow(next: Bool, completed: @escaping @MainActor ((session: SessionID, window: WindowID)?, String?) -> Void) {
        guard let client = located else { return completed(nil, "the sidebar feed has not found its client yet") }
        let args = ["switch-window", next ? "next" : "prev", "--client", client, "--server", serverDir]
        do throws(Failure) { try tools.validate() } catch {
            publish(.invalidBundle(error))
            return completed(nil, error.message)
        }
        let generation = generation, id = UUID()
        commands[id] = Task {
            defer { commands[id] = nil }
            do throws(Failure) {
                #if KIDO_VISUAL || KIDO_STRESS
                let kido = testKido ?? tools.kido
                #else
                let kido = tools.kido
                #endif
                let launch = kido == tools.kido ? prepare(args) : Launch(kido, args, environment: tools.environment)
                let (status, out, err) = try await Child.run(launch, drain: drain)
                guard self.generation == generation else { return }
                guard status == 0 else { return completed(nil, err.isEmpty ? "kido switch-window exited \(status)" : err) }
                if out.isEmpty { return completed(nil, nil) }
                let ids = out.split(separator: " ").map(String.init)
                guard ids.count == 2, let session = SessionID(ids[0]), let window = WindowID(ids[1]) else {
                    return completed(nil, "kido switch-window returned an invalid target: \(out)")
                }
                completed((session, window), nil)
            } catch {
                guard self.generation == generation else { return }
                completed(nil, error.message)
            }
        }
    }

    @MainActor private func start() {
        publish(.starting)
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
        let client = location
        #if KIDO_VISUAL || KIDO_STRESS
        let fake = testKido ?? ProcessInfo.processInfo.environment["KIDO_APP_FEED"]
        #else
        let fake: String? = nil
        #endif
        let path = fake ?? tools.kido
        do throws(Failure) { try tools.validate() } catch { return publish(.invalidBundle(error)) }
        let stdin = Pipe(), stdout = Pipe()
        let child: Child
        do throws(Failure) {
            let launch = fake == nil ? prepare(["sidebar-feed", "--server", serverDir, "--client", client]) : Launch(path, [], environment: tools.environment)
            child = try Child(launch.path, launch.arguments, env: launch.environment, stdin: stdin, stdout: stdout, drain: drain)
            self.child = child
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
                    guard let last else { return self.publish(.unreadable) }
                    self.backoff = 0.1
                    self.publish(.running(last))
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
        generation += 1
        located = nil
        closeInput()
        child?.stop()
        child = nil
        publish(.restarting(reason))
        let item = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: item)
        backoff = min(backoff * 2, 8)
    }
}
