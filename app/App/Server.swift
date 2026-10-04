import Foundation

struct BundledTools: Sendable {
    let prefix: String
    let build: String?
    let environment: [String: String]
    var kido: String { prefix + "/bin/kido" }
    var tmux: String { prefix + "/bin/kido-tmux" }

    init(resources: URL, environment: [String: String]) {
        prefix = resources.appendingPathComponent("kido").path
        build = try? String(contentsOfFile: prefix + "/BUILD-ID", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var env = environment.filter { key, _ in
            key != "TMUX" && key != "TMUX_PANE" && key != "KIDO_TMUX" && !key.hasPrefix("KIDO_AGENT_")
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let state = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state"
        env["KIDO_STATE_DIR"] = URL(fileURLWithPath: state).appendingPathComponent("kido-app").standardizedFileURL.path
        self.environment = env
    }

    func validate() throws(Failure) {
        guard let build, !build.isEmpty else { throw Failure(message: "The app's bundled kido build ID is missing") }
        guard let current = try? String(contentsOfFile: prefix + "/BUILD-ID", encoding: .utf8),
            current.trimmingCharacters(in: .whitespacesAndNewlines) == build
        else { throw Failure(message: "Kido.app changed on disk. Relaunch the app before reconnecting or restarting its server.") }
    }
}

struct Server: Decodable, Sendable {
    let tmux: String
    let socket: String
    let build: String?

    static var fixed: Server? {
        #if KIDO_VISUAL || KIDO_STRESS
        let env = ProcessInfo.processInfo.environment
        guard let socket = env["KIDO_APP_SOCKET"], let tmux = env["KIDO_APP_TMUX"] else { return nil }
        return Server(tmux: tmux, socket: socket, build: nil)
        #else
        return nil
        #endif
    }

    static func locate() async throws(Failure) -> Server {
        try tools.validate()
        if let fixed { return fixed }
        let (status, out, err) = try await Child.run(tools.kido, ["server", "--socket-name", "kido-app"], env: tools.environment)
        guard status == 0 else { throw Failure(message: err.isEmpty ? "kido server exited \(status)" : err) }
        guard let server = try? JSONDecoder().decode(Server.self, from: Data(out.utf8)), server.tmux == tools.tmux else {
            throw Failure(message: "kido server returned an invalid bundled server: \(out)")
        }
        return server
    }

    func restart() async throws(Failure) {
        try tools.validate()
        let current = try await Self.locate()
        guard current.socket == socket, current.build == build else {
            throw Failure(message: "The server changed. Reconnect before restarting it.")
        }
        let (killed, _, err) = try await Child.run(tools.tmux, ["-S", socket, "kill-server"], env: tools.environment)
        guard killed == 0 else { throw Failure(message: err.isEmpty ? "Could not stop the app server" : err) }
    }
}
