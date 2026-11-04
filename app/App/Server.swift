import Foundation

struct BundledTools: Sendable {
    let prefix: String
    let build: String?
    let serverDir: String
    let ko: String
    var environment: [String: String] { ProcessInfo.processInfo.environment }

    init(resources: URL, environment: [String: String]) {
        prefix = resources.appendingPathComponent("ko").resolvingSymlinksInPath().path
        ko = prefix + "/bin/ko"
        build = try? String(contentsOfFile: prefix + "/BUILD-ID", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // ko_client_launch starts the server with the environment of this process.
        for key in environment.keys where ["KO_PANE", "KO_SOCKET", "KO_PANE_TOKEN", "KO_RUN_ID"].contains(key) || key.hasPrefix("KO_AGENT_") {
            unsetenv(key)
        }
        if !["LC_ALL", "LC_CTYPE", "LANG"].contains(where: { environment[$0]?.uppercased().contains("UTF-8") == true || environment[$0]?.uppercased().contains("UTF8") == true }) {
            let locale = Locale.current
            let name = "\(locale.language.languageCode?.identifier ?? "en")_\(locale.region?.identifier ?? "US").UTF-8"
            setenv("LANG", FileManager.default.fileExists(atPath: "/usr/share/locale/" + name) ? name : "en_US.UTF-8", 1)
        }
        #if KIDO_VISUAL || KIDO_STRESS
        serverDir = environment["KIDO_APP_SERVER"] ?? KoClient.defaultDir()
        #else
        serverDir = KoClient.defaultDir()
        #endif
    }

    func validate() throws(Failure) {
        guard let build, !build.isEmpty else { throw Failure(message: "The app's bundled ko build ID is missing") }
        guard let current = try? String(contentsOfFile: prefix + "/BUILD-ID", encoding: .utf8),
            current.trimmingCharacters(in: .whitespacesAndNewlines) == build
        else { throw Failure(message: "Kido.app changed on disk. Relaunch the app before reconnecting or restarting its server.") }
    }
}

enum KoServer {
    // Both calls block until the server started or ended, so they run off the main thread.
    static func launch(dir: String) async throws(Failure) -> String {
        try tools.validate()
        let executable = tools.ko
        do { return try await Task.detached { try KoClient.launch(dir: dir, executable: executable) }.value } catch {
            throw Failure(message: "\(error)")
        }
    }

    static func stop(dir: String) async throws(Failure) {
        do { try await Task.detached { try KoClient.stopServer(dir: dir) }.value } catch {
            throw Failure(message: "\(error)")
        }
    }
}
