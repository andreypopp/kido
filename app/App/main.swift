import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var window: NSWindow!
    private var banner: Banner!
    private var session: SessionView?
    private var link = Link.down
    private let menus = SessionMenus()

    private enum Link {
        case down
        case locating
        case connected(Connection)
        case redialing(DispatchWorkItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime() else { fatalError("libghostty failed to initialise") }
        self.runtime = runtime
        NSApp.mainMenu = mainMenu()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Kido"
        banner = Banner(target: self, action: #selector(start))
        banner.frame = window.contentView!.bounds
        window.contentView!.addSubview(banner)
        window.center()
        if !background {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        start()
    }

    @objc private func start() {
        switch link {
        case .locating, .connected: return
        case .redialing(let item): item.cancel()
        case .down: break
        }
        link = .locating
        banner.show("Connecting to the kido server…", "", button: nil)
        Task {
            do {
                dial(try await Task.detached { try Server.locate() }.value, backoff: 0.1)
            } catch {
                link = .down
                banner.show(
                    "Kido could not reach the kido server",
                    (error as? Server.Failure)?.message ?? error.localizedDescription, button: action)
            }
        }
    }

    private var action: String { Server.fixed == nil ? "Start kido server" : "Reconnect" }

    private func dial(_ server: Server, backoff: TimeInterval) {
        let view = SessionView(runtime: runtime)
        do {
            link = .connected(try Connection(
                server: server, view: view,
                onChange: { [weak self] in self?.changed(view, $0) },
                onClose: { [weak self] in self?.closed(server, view, $0, backoff: backoff) }))
        } catch {
            link = .down
            banner.show("Kido could not run \(server.tmux)", error.localizedDescription, button: action)
        }
    }

    private func changed(_ view: SessionView, _ model: SessionModel) {
        window.title = model.title
        menus.update(model)
        guard view.superview == nil else { return }
        session?.removeFromSuperview()
        session = view
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view, positioned: .below, relativeTo: banner)
        banner.isHidden = true
        if case .connected(let connection) = link { menus.connection = connection }
    }

    private func closed(_ server: Server, _ view: SessionView, _ reason: String?, backoff: TimeInterval) {
        menus.connection = nil
        menus.update(SessionModel())
        window.title = "Kido"
        let dropped = view === session
        let detail = reason ?? (dropped ? nil : "No kido server at \(server.socket).")
        banner.show(
            session == nil ? "Kido could not reach the kido server" : "Disconnected from the kido server",
            (detail.map { "\($0)\n" } ?? "") + "Reconnecting…", button: action)
        let next = dropped ? 0.1 : min(backoff * 2, 2)
        let item = DispatchWorkItem { [weak self] in self?.dial(server, backoff: next) }
        link = .redialing(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + next, execute: item)
    }

    private func mainMenu() -> NSMenu {
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
