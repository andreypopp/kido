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

@MainActor final class RemoteHostDialog: NSObject {
    let alert = NSAlert()
    let field = NSTextField(string: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let routes: WindowRoutes

    init(routes: WindowRoutes) {
        self.routes = routes
        super.init()
        alert.messageText = "Connect to Remote Host"
        alert.informativeText = "user@host or SSH alias"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        field.frame = NSRect(x: 0, y: 46, width: 320, height: 24)
        field.placeholderString = "user@host or SSH alias"
        field.setAccessibilityLabel("user@host or SSH alias")
        error.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
        error.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        error.textColor = .systemRed
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 70))
        accessory.addSubview(field)
        accessory.addSubview(error)
        alert.accessoryView = accessory
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(connect)
    }

    func handle(_ response: NSApplication.ModalResponse) -> Bool {
        guard response == .alertFirstButtonReturn else { return true }
        do throws(Failure) {
            routes.connect(try Host(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)))
            return true
        } catch {
            self.error.stringValue = error.message
            return false
        }
    }

    @objc private func connect() {
        guard handle(.alertFirstButtonReturn) else { return }
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn) }
        else { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
    }

    func show(on window: NSWindow?) {
        alert.window.initialFirstResponder = field
        if let window {
            alert.beginSheetModal(for: window) { _ in self.alert.window.orderOut(nil) }
        } else {
            alert.runModal()
        }
    }
}
