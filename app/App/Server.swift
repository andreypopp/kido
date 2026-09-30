import Foundation

struct Server: Decodable {
    struct Failure: Error {
        let message: String
    }

    let tmux: String
    let socket: String

    static var fixed: Server? {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env["KIDO_APP_SOCKET"], let tmux = env["KIDO_APP_TMUX"] else { return nil }
        return Server(tmux: tmux, socket: socket)
    }

    static func locate() throws -> Server {
        if let fixed { return fixed }
        guard let kido = kido(ProcessInfo.processInfo.environment) else {
            throw Failure(message: "kido is neither on the login shell's PATH nor at /opt/homebrew/bin/kido")
        }
        let (status, out, err) = try run(kido, ["server"])
        guard status == 0 else { throw Failure(message: err.isEmpty ? "kido server exited \(status)" : err) }
        guard let server = try? JSONDecoder().decode(Server.self, from: Data(out.utf8)) else {
            throw Failure(message: "kido server printed \(out.isEmpty ? "nothing" : out)")
        }
        return server
    }

    private static func kido(_ env: [String: String]) -> String? {
        if let kido = env["KIDO_APP_KIDO"] { return kido }
        if case (0, let out, _)? = try? run("/bin/zsh", ["-lc", "command -v kido"]),
           let path = out.split(separator: "\n").last, path.hasPrefix("/") {
            return String(path)
        }
        let brew = "/opt/homebrew/bin/kido"
        return FileManager.default.isExecutableFile(atPath: brew) ? brew : nil
    }

    private static func run(_ path: String, _ args: [String]) throws -> (Int32, String, String) {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = out
        process.standardError = err
        // Client.start: waitUntilExit can miss the exit off the main thread.
        let ended = DispatchGroup()
        ended.enter()
        process.terminationHandler = { _ in ended.leave() }
        do { try process.run() } catch { throw Failure(message: "could not run \(path): \(error.localizedDescription)") }
        nonisolated(unsafe) var stdout = Data(), stderr = Data()
        DispatchQueue.global().async(group: ended) { stdout = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: ended) { stderr = err.fileHandleForReading.readDataToEndOfFile() }
        guard ended.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            throw Failure(message: "\(path) \(args.joined(separator: " ")) did not finish in 10 seconds")
        }
        let text = { (d: Data) in String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (process.terminationStatus, text(stdout), text(stderr))
    }
}
