import AppIntents
import AppKit

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
    private var queued: [Host] = []
    private var open: ((Host) -> Void)?
    private var ordinaryAllowed = true
    func connect(_ host: Host) {
        if let open {
            ordinaryAllowed = true
            open(host)
        } else { queued.append(host) }
    }
    func ordinaryOpen() {
        if ordinaryAllowed && queued.isEmpty { connect(.local) }
    }
    func ready(isDefaultLaunch: Bool, _ open: @escaping (Host) -> Void) {
        self.open = open
        let requests = queued.filter { isDefaultLaunch || $0 != .local }
        ordinaryAllowed = isDefaultLaunch || !requests.isEmpty
        queued = []
        requests.forEach(open)
    }
}

@MainActor final class RemoteHostDialog {
    let alert = NSAlert()
    let field = NSTextField(string: "")
    private let routes: WindowRoutes

    init(routes: WindowRoutes) {
        self.routes = routes
        alert.messageText = "Connect to Remote Host"
        alert.informativeText = "user@host or SSH alias"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.placeholderString = "user@host or SSH alias"
        field.setAccessibilityLabel("user@host or SSH alias")
        alert.accessoryView = field
    }

    func handle(_ response: NSApplication.ModalResponse) -> Bool {
        guard response == .alertFirstButtonReturn else { return true }
        do throws(Failure) {
            routes.connect(try Host(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)))
            return true
        } catch {
            alert.informativeText = "user@host or SSH alias\n" + error.message
            return false
        }
    }

    func show(on window: NSWindow?) {
        alert.window.initialFirstResponder = field
        if let window {
            alert.beginSheetModal(for: window) { response in
                if !self.handle(response) { self.show(on: window) }
            }
        } else {
            while !handle(alert.runModal()) {}
        }
    }
}
