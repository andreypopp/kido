import AppIntents
import AppKit

struct ConnectRemoteHost: AppIntent {
    static let title: LocalizedStringResource = "Connect to Remote Host in Kido"
    static let openAppWhenRun = true
    @Parameter(title: "Host") var host: String
    static var parameterSummary: some ParameterSummary { Summary("Connect to \(\.$host)") }

    @MainActor func perform() async throws -> some IntentResult {
        let destination = try Host(host)
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
    private var queued: [Host] = []
    private var open: ((Host) -> Void)?
    func connect(_ host: Host) {
        if let open { open(host) } else { queued.append(host) }
    }
    func ordinaryOpen() { if queued.isEmpty { connect(.local) } }
    func ready(_ open: @escaping (Host) -> Void) {
        self.open = open
        let requests = queued
        queued = []
        requests.forEach(open)
    }
}
