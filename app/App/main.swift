import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var window: NSWindow!
    private var connection: Connection!
    private let menus = SessionMenus()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime() else { fatalError("libghostty failed to initialise") }
        self.runtime = runtime
        let view = SessionView(runtime: runtime)
        NSApp.mainMenu = mainMenu()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Kido"
        window.contentView = view
        window.center()
        if !background {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        Task {
            do {
                let server = try await Task.detached { try Server.locate() }.value
                connection = try Connection(server: server, view: view) { model in
                    self.window.title = model.title
                    self.menus.update(model)
                }
                menus.connection = connection
            } catch {
                let alert = NSAlert()
                alert.messageText = "Kido could not reach the kido server"
                alert.informativeText = (error as? Server.Failure)?.message ?? "\(error)"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor private func mainMenu() -> NSMenu {
        let app = NSMenu(title: "Kido")
        app.items = [
            NSMenuItem(title: "Hide Kido", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            .separator(),
            NSMenuItem(title: "Quit Kido", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        let bar = NSMenu()
        for menu in [app, menus.window, menus.session] {
            bar.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        bar.insertItem(PaneCommand.menu, at: 1)
        return bar
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// A test launch must never take the user's focus: it neither activates nor
// shows its window.
let background = ProcessInfo.processInfo.environment["KIDO_APP_BACKGROUND"] == "1"
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(background ? .accessory : .regular)
NSApplication.shared.run()
