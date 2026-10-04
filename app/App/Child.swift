import Foundation

struct Failure: Error {
    let message: String
}

final class Child: @unchecked Sendable {
    let process = Process()
    let ended = DispatchGroup()
    private(set) var stderr = ""

    init(_ path: String, _ args: [String], env: [String: String]? = nil, cwd: String? = nil, stdin: Pipe? = nil, stdout: Pipe) throws(Failure) {
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { process.environment = env }
        if let stdin { process.standardInput = stdin }
        process.standardOutput = stdout
        process.standardError = err
        ended.enter()
        process.terminationHandler = { [ended] _ in ended.leave() }
        do { try process.run() } catch { throw Failure(message: "could not run \(path): \(error.localizedDescription)") }
        DispatchQueue.global().async(group: ended) { self.stderr = Self.text(err.fileHandleForReading.readDataToEndOfFile()) }
    }

    static func run(
        _ path: String, _ args: [String], env: [String: String]? = nil, cwd: String? = nil, deadline: TimeInterval = 10
    ) async throws(Failure) -> (status: Int32, out: String, err: String) {
        let out = Pipe()
        let child = try Child(path, args, env: env, cwd: cwd, stdout: out)
        nonisolated(unsafe) var stdout = Data()
        DispatchQueue.global().async(group: child.ended) { stdout = out.fileHandleForReading.readDataToEndOfFile() }
        let finished = await withCheckedContinuation { finished in
            DispatchQueue.global().async { finished.resume(returning: child.ended.wait(timeout: .now() + deadline) == .success) }
        }
        guard finished else {
            child.process.terminate()
            throw Failure(message: "\(path) \(args.joined(separator: " ")) did not finish in \(Int(deadline)) seconds")
        }
        return (child.process.terminationStatus, text(stdout), child.stderr)
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
