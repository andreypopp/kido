import Foundation
import TmuxControl
import SidebarFeed

struct BundledTools: Sendable {
    let prefix: String
    let build: String?
    let environment: [String: String]
    let serverDir: String
    var kido: String { prefix + "/bin/kido" }
    var tmux: String { prefix + "/bin/kido-tmux" }

    init(resources: URL, environment: [String: String]) {
        prefix = resources.appendingPathComponent("kido").path
        build = try? String(contentsOfFile: prefix + "/BUILD-ID", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var env = environment.filter { key, _ in
            key != "TMUX" && key != "TMUX_PANE" && key != "KIDO_TMUX" && key != "KIDO_STATE_DIR" && !key.hasPrefix("KIDO_AGENT_")
        }
        // tmux's CLIENT_UTF8 preserves the control-mode format delimiters.
        if !["LC_ALL", "LC_CTYPE", "LANG"].contains(where: { env[$0]?.uppercased().contains("UTF-8") == true || env[$0]?.uppercased().contains("UTF8") == true }) {
            let locale = Locale.current
            let name = "\(locale.language.languageCode?.identifier ?? "en")_\(locale.region?.identifier ?? "US").UTF-8"
            env["LANG"] = FileManager.default.fileExists(atPath: "/usr/share/locale/" + name) ? name : "en_US.UTF-8"
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let state = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state"
        #if KIDO_VISUAL || KIDO_STRESS
        serverDir = environment["KIDO_APP_SERVER"] ?? URL(fileURLWithPath: state).appendingPathComponent("kido-app").standardizedFileURL.path
        #else
        serverDir = URL(fileURLWithPath: state).appendingPathComponent("kido-app").standardizedFileURL.path
        #endif
        self.environment = env
    }

    func validate() throws(Failure) {
        guard let build, !build.isEmpty else { throw Failure(message: "The app's bundled kido build ID is missing") }
        guard let current = try? String(contentsOfFile: prefix + "/BUILD-ID", encoding: .utf8),
            current.trimmingCharacters(in: .whitespacesAndNewlines) == build
        else { throw Failure(message: "Kido.app changed on disk. Relaunch the app before reconnecting or restarting its server.") }
    }
}

struct Endpoint: Sendable {
    let server: Server
    let kido: String
    var directory: String { String(server.socket.dropLast("/socket".count)) }
}

struct Server: Decodable, Sendable {
    let tmux: String
    let socket: String
    let protocolVersion: RPCVersion?
    var binaryProtocol: RPCVersion = .required
    private enum CodingKeys: String, CodingKey { case tmux, socket; case protocolVersion = "server"; case binaryProtocol = "protocol" }

    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static var fixed: Server? {
        #if KIDO_VISUAL || KIDO_STRESS
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["KIDO_APP_SERVER"], let tmux = env["KIDO_APP_TMUX"] else { return nil }
        return Server(tmux: tmux, socket: URL(fileURLWithPath: dir).appendingPathComponent("socket").path, protocolVersion: .required)
        #else
        return nil
        #endif
    }

    @MainActor static func locate(prepare: (([String]) -> Launch)? = nil, drain: Drain? = nil) async throws(Failure) -> Endpoint {
        try tools.validate()
        if prepare == nil, let fixed { return Endpoint(server: fixed, kido: tools.kido) }
        let kido: String, directory: String
        if let prepare {
            let script = "kido=$(command -v kido) || { printf '%s\\n' 'Remote kido is missing from the noninteractive SSH PATH. Install kido, or add its bin directory to PATH for noninteractive SSH in ~/.zshenv (zsh); do not print startup text.' >&2; exit 127; }; printf '%s\\n' \"$kido\" \"${XDG_STATE_HOME:-$HOME/.local/state}/kido-app\""
            let probe = try await Child.run(prepare(["/bin/sh", "-c", script]), drain: drain)
            guard probe.status == 0 else {
                let message = probe.err.isEmpty ? "Remote discovery exited \(probe.status)" : probe.err
                throw probe.status == 255 ? Failure.ssh(message) : Failure(message: message)
            }
            let paths = probe.out.components(separatedBy: "\n")
            guard paths.count == 2, paths.allSatisfy(validPath) else { throw Failure(message: "Remote discovery returned invalid absolute paths: \(probe.out)") }
            kido = paths[0]
            directory = paths[1]
        } else {
            kido = tools.kido
            directory = tools.serverDir
        }
        let args = [kido, "server", "--server", directory]
        let launch = prepare?(["/usr/bin/env", "SSH_AUTH_SOCK=" + directory + "/agent.sock"] + args) ?? Launch(kido, Array(args.dropFirst()), environment: tools.environment)
        let result = try await Child.run(launch.path, launch.arguments, env: launch.environment,
            cwd: prepare == nil ? tools.environment["HOME"] ?? NSHomeDirectory() : nil, deadline: prepare == nil ? 10 : 20, drain: drain)
        guard result.status == 0 else {
            let message = result.err.isEmpty ? "kido server exited \(result.status)" : result.err
            throw prepare != nil && result.status == 255 ? Failure.ssh(message) : Failure(message: message)
        }
        guard let server = try? JSONDecoder().decode(Server.self, from: Data(result.out.utf8)),
              validPath(server.tmux), validPath(server.socket), server.socket.hasSuffix("/socket"),
              validPath(String(server.socket.dropLast("/socket".count))), prepare != nil || server.tmux == tools.tmux else {
            throw Failure(message: "kido server returned an invalid endpoint: \(result.out)")
        }
        return Endpoint(server: server, kido: kido)
    }

    func restart(drain: Drain? = nil) async throws(Failure) {
        try tools.validate()
        let current = try await Self.locate(drain: drain).server
        guard current.socket == socket, current.protocolVersion == protocolVersion else {
            throw Failure(message: "The server changed. Reconnect before restarting it.")
        }
        let (killed, _, err) = try await Child.run(tools.tmux, ["-S", socket, "kill-server"], env: tools.environment, drain: drain)
        guard killed == 0 else { throw Failure(message: err.isEmpty ? "Could not stop the app server" : err) }
    }
}
