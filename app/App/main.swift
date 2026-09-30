import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var window: NSWindow!
    private var connection: Connection!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime() else { fatalError("libghostty failed to initialise") }
        self.runtime = runtime
        let view = WindowView(runtime: runtime)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Kido"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do {
                let server = try await Task.detached { try Server.locate() }.value
                connection = try Connection(server: server, view: view)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Kido could not reach the kido server"
                alert.informativeText = (error as? Server.Failure)?.message ?? "\(error)"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
