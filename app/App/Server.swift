import Foundation

struct Server: Decodable {
    struct Failure: Error {
        let message: String
    }

    let tmux: String
    let socket: String

    static func locate() throws -> Server {
        let env = ProcessInfo.processInfo.environment
        if let socket = env["KIDO_APP_SOCKET"], let tmux = env["KIDO_APP_TMUX"] {
            return Server(tmux: tmux, socket: socket)
        }
        guard let kido = kido(env) else { throw Failure(message: "kido not found") }
        let (status, out, err) = try run(kido, ["server"])
        guard status == 0 else { throw Failure(message: err.isEmpty ? "kido server exited \(status)" : err) }
        return try JSONDecoder().decode(Server.self, from: Data(out.utf8))
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
        try process.run()
        nonisolated(unsafe) var stdout = Data(), stderr = Data()
        let drained = DispatchGroup()
        DispatchQueue.global().async(group: drained) { stdout = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: drained) { stderr = err.fileHandleForReading.readDataToEndOfFile() }
        guard drained.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            throw Failure(message: "\(path) \(args.joined(separator: " ")) did not finish in 10 seconds")
        }
        process.waitUntilExit()
        let text = { (d: Data) in String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (process.terminationStatus, text(stdout), text(stderr))
    }
}
