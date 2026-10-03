import Foundation

struct Server: Decodable {
    let tmux: String
    let socket: String

    static var fixed: Server? {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env["KIDO_APP_SOCKET"], let tmux = env["KIDO_APP_TMUX"] else { return nil }
        return Server(tmux: tmux, socket: socket)
    }

    static func locate() async throws(Failure) -> Server {
        if let fixed { return fixed }
        guard let kido = await kido(ProcessInfo.processInfo.environment) else {
            throw Failure(message: "kido is neither on the login shell's PATH nor at /opt/homebrew/bin/kido")
        }
        let (status, out, err) = try await Child.run(kido, ["server"])
        guard status == 0 else { throw Failure(message: err.isEmpty ? "kido server exited \(status)" : err) }
        guard let server = try? JSONDecoder().decode(Server.self, from: Data(out.utf8)) else {
            throw Failure(message: "kido server printed \(out.isEmpty ? "nothing" : out)")
        }
        return server
    }

    private static func kido(_ env: [String: String]) async -> String? {
        if let kido = env["KIDO_APP_KIDO"] { return kido }
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }.flatMap { $0.isEmpty ? nil : $0 }
            ?? env["SHELL"] ?? "/bin/zsh"
        if case (0, let out, _)? = try? await Child.run(shell, ["-lc", "command -v kido"]),
            let path = out.split(separator: "\n").last, path.hasPrefix("/")
        {
            return String(path)
        }
        let brew = "/opt/homebrew/bin/kido"
        return FileManager.default.isExecutableFile(atPath: brew) ? brew : nil
    }
}
