import Foundation
import SidebarFeed
import TmuxControl

final class Feed: @unchecked Sendable {
    typealias Location = String
    typealias Locate = (@escaping @Sendable (Result<Location, Failure>) -> Void) -> Void

    enum Status {
        case starting
        case invalidBundle(Failure)
        case protocolMismatch(server: RPCVersion?, binary: RPCVersion?)
        case running(Snapshot)
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
    private var pending: [Int: @MainActor @Sendable ((session: SessionID, window: WindowID)?, String?) -> Void] = [:]
    private var requestID = 0
    @MainActor private let query: () -> String
    private let reader = DispatchQueue(label: "Feed.reader")
    private let writer = DispatchQueue(label: "Feed.writer")
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
        failPending()
    }

    @MainActor private func closeInput() {
        guard let input else { return }
        self.input = nil
        writer.async { try? input.close() }
    }

    @MainActor func filter(_ text: String) {
        guard let input else { return }
        writer.async { try? input.write(contentsOf: try JSONSerialization.data(withJSONObject: ["filter": text]) + Data([10])) }
    }

    @MainActor func switchWindow(next: Bool, completed: @escaping @MainActor @Sendable ((session: SessionID, window: WindowID)?, String?) -> Void) {
        guard let input, case .running = status else { return completed(nil, "the RPC feed is not ready") }
        do throws(Failure) { try tools.validate() } catch {
            publish(.invalidBundle(error))
            return completed(nil, error.message)
        }
        reader.async { [self] in
            requestID += 1
            let id = requestID
            pending[id] = completed
            writer.async {
                do {
                    try input.write(contentsOf: try JSONSerialization.data(withJSONObject: ["id": id, "switch-window": ["direction": next ? "next" : "prev"]]) + Data([10]))
                } catch {
                    self.reader.async {
                        let callback = self.pending.removeValue(forKey: id)
                        DispatchQueue.main.async { callback?(nil, "Could not write RPC request") }
                    }
                }
            }
        }
    }

    private func failPending() {
        reader.async { [self] in
            let callbacks = Array(pending.values)
            pending.removeAll()
            DispatchQueue.main.async { callbacks.forEach { $0(nil, "RPC connection ended before the request completed") } }
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
            let launch = fake == nil ? prepare(["rpc", "--server", serverDir, "--client", client]) : Launch(path, [], environment: tools.environment)
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
        nonisolated(unsafe) var greeted = false
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
                let event = try? decoder.decode(RPCEvent.self, from: buffer[..<newline])
                buffer.removeSubrange(...newline)
                let first = !greeted
                greeted = true
                if case .reply(let reply) = event, !first {
                    let callback = self?.pending.removeValue(forKey: reply.id)
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else {
                            return callback?(nil, "RPC connection changed before the reply arrived") ?? ()
                        }
                        callback?(reply.switched.map { ($0.session, $0.window) }, reply.error)
                    }
                    continue
                }
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    guard let event else { return self.restart("Unreadable RPC event") }
                    if first {
                        guard case .hello(let hello) = event else { return self.restart("RPC did not send a hello first") }
                        let version: RPCVersion?, binary: RPCVersion?
                        switch hello {
                        case .accepted(let protocolVersion):
                            guard !protocolVersion.compatible else { return }
                            version = protocolVersion
                            binary = protocolVersion
                        case .rejected(let executable, let server): version = server; binary = executable
                        }
                        self.stop()
                        return self.publish(.protocolMismatch(server: version, binary: binary))
                    }
                    switch event {
                    case .snapshot(let snapshot):
                        self.backoff = 0.1
                        self.publish(.running(snapshot))
                    case .error: self.stop(); self.publish(.protocolMismatch(server: nil, binary: nil))
                    case .hello, .reply: self.restart("Unexpected RPC event")
                    }
                }
            }
        }
        source.resume()
        child.ended.notify(queue: .main) { [weak self] in
            guard let self, self.generation == generation else { return }
            restart(child.stderr.isEmpty ? "kido rpc exited" : child.stderr)
        }
    }

    @MainActor private func restart(_ reason: String) {
        generation += 1
        failPending()
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
