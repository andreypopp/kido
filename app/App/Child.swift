import Foundation
import TmuxControl

enum Failure: Error {
    case terminal(String)
    case transport(String)

    init(message: String) { self = .terminal(message) }
    var message: String { switch self { case .terminal(let text), .transport(let text): text } }

    static func ssh(_ reason: String) -> Failure {
        let text = reason.lowercased()
        if ["permission denied", "host key verification failed", "remote host identification has changed", "bad configuration", "bad owner or permissions", "authentication failed"].contains(where: text.contains) {
            return .terminal(reason + "\nEstablish host trust and unlock authentication in Terminal, then Reconnect. Password and host-key prompts are not supported in Kido.")
        }
        return .transport(reason)
    }
}

final class Child: @unchecked Sendable {
    let process = Process()
    let ended = DispatchGroup()
    private(set) var stderr = ""
    private let lock = NSLock()
    private var stopping = false

    init(_ path: String, _ args: [String], env: [String: String]? = nil, cwd: String? = nil, stdin: Pipe? = nil, stdout: Pipe, drain: Drain? = nil) throws(Failure) {
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { process.environment = env }
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = err
        try drain?.enter()
        ended.enter()
        process.terminationHandler = { [ended, drain] _ in drain?.ended.leave(); ended.leave() }
        do { try process.run() } catch {
            drain?.ended.leave()
            ended.leave()
            throw Failure(message: "could not run \(path): \(error.localizedDescription)")
        }
        DispatchQueue.global().async(group: ended) {
            var data = Data()
            while let chunk = try? err.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 16384 { data.removeFirst(data.count - 16384) }
            }
            self.stderr = Self.text(data)
        }
    }

    func stop() {
        guard lock.withLock({ if stopping { return false }; stopping = true; return true }) else { return }
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    static func run(_ launch: Launch, deadline: TimeInterval = 10, drain: Drain? = nil) async throws(Failure) -> (status: Int32, out: String, err: String) {
        try await run(launch.path, launch.arguments, env: launch.environment, deadline: deadline, drain: drain)
    }

    static func run(
        _ path: String, _ args: [String], env: [String: String]? = nil, cwd: String? = nil, deadline: TimeInterval = 10, drain: Drain? = nil
    ) async throws(Failure) -> (status: Int32, out: String, err: String) {
        guard !Task.isCancelled else { throw Failure(message: "Connection cancelled") }
        let out = Pipe()
        let child = try Child(path, args, env: env, cwd: cwd, stdout: out, drain: drain)
        nonisolated(unsafe) var stdout = Data()
        DispatchQueue.global().async(group: child.ended) { stdout = out.fileHandleForReading.readDataToEndOfFile() }
        let finished = await withTaskCancellationHandler {
            await withCheckedContinuation { finished in
                DispatchQueue.global().async { finished.resume(returning: child.ended.wait(timeout: .now() + deadline) == .success) }
            }
        } onCancel: { child.stop() }
        guard finished, !Task.isCancelled else {
            child.stop()
            throw Failure.transport("\(path) did not finish within \(Int(deadline)) seconds (or was cancelled)")
        }
        return (child.process.terminationStatus, text(stdout), child.stderr)
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
