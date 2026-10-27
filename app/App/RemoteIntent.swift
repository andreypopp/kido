import AppIntents
import AppKit
import SidebarFeed

struct ConnectRemoteHost: AppIntent {
    static let title: LocalizedStringResource = "Connect to Remote Host in Kido"
    static let openAppWhenRun = true
    @Parameter(title: "Host") var host: String
    static var parameterSummary: some ParameterSummary { Summary("Connect to \(\.$host)") }

    @MainActor func perform() async throws -> some IntentResult {
        let destination = try Host(host.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let app = NSApp.delegate as? AppDelegate else { throw Failure(message: "Kido is not ready") }
        app.routes.connect(destination)
        return .result()
    }
}

struct RemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectRemoteHost(), phrases: ["Connect to remote host in \(.applicationName)"],
                    shortTitle: "Connect to Remote Host", systemImageName: "network")
    }
}

@MainActor final class WindowRoutes {
    private let preferences: UserDefaults?
    private(set) var recent: RecentHosts
    let accents: HostAccents
    init(preferences: UserDefaults? = background ? nil : .standard) {
        self.preferences = preferences
        accents = HostAccents(preferences: preferences)
        recent = preferences?.data(forKey: "recentHosts").flatMap { try? JSONDecoder().decode(RecentHosts.self, from: $0) } ?? RecentHosts()
    }
    func clearRecent() { recent.clear(); saveRecent() }
    private func saveRecent() { preferences?.set(try? JSONEncoder().encode(recent), forKey: "recentHosts") }
    private var queued: [(Host, WindowOwner.DialCause)] = []
    private var open: ((Host, WindowOwner.DialCause) -> Void)?
    private var ordinaryAllowed = true
    func connect(_ host: Host, cause: WindowOwner.DialCause = .remoteRequest, accent: Accent? = nil) {
        if case .remote(let alias) = host { recent.add(alias, at: Date()); saveRecent() }
        accents.assign(host, chosen: accent)
        if let open {
            ordinaryAllowed = true
            open(host, cause)
        } else { queued.append((host, cause)) }
    }
    func ordinaryOpen(cause: WindowOwner.DialCause = .launch) {
        if ordinaryAllowed && queued.isEmpty { connect(.local, cause: cause) }
    }
    func ready(isDefaultLaunch: Bool, _ open: @escaping (Host, WindowOwner.DialCause) -> Void) {
        self.open = open
        let requests = queued.filter { host, cause in
            if case .newWindow = cause { return true }
            return isDefaultLaunch || host != .local
        }
        ordinaryAllowed = isDefaultLaunch || !requests.isEmpty
        queued = []
        requests.forEach { open($0.0, $0.1) }
    }
}
