import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var window: NSWindow!
    private var banner: Banner!
    private var session: SessionView?
    private var link = Link.down
    private let menus = SessionMenus()
    private let sidebar = Sidebar()
    private var feed: Feed?

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
        window.contentMinSize = Sidebar.minSize
        sidebar.frame = window.contentView!.bounds
        sidebar.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(sidebar)
        sidebar.view.send = { [weak self] commands in
            if case .connected(let connection) = self?.link { connection.send(commands) }
        }
        sidebar.view.filter = { [weak self] in self?.feed?.filter($0) }
        sidebar.view.leave = { [weak self] in self?.session?.focusActive() }
        banner = Banner(target: self, action: #selector(start))
        banner.frame = sidebar.content.bounds
        sidebar.content.addSubview(banner)
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
            let connection = try Connection(
                server: server, view: view,
                onChange: { [weak self] in self?.changed(view, $0) },
                onClose: { [weak self] in self?.closed(server, view, $0, backoff: backoff) })
            link = .connected(connection)
            locateFeed(connection, socket: server.socket)
        } catch {
            link = .down
            banner.show("Kido could not run \(server.tmux)", error.localizedDescription, button: action)
        }
    }

    private func locateFeed(_ connection: Connection, socket: String) {
        connection.locateFeed { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, case .connected(let current) = link, current === connection else { return }
                switch result {
                case .failure(let failure):
                    sidebar.view.update(.failed(failure.message))
                case .success(let located):
                    feed = Feed(
                        kido: located.kido, socket: socket, client: located.client,
                        onChange: { [weak self] in self?.sidebar.view.update($0) })
                }
            }
        }
    }

    private func changed(_ view: SessionView, _ model: SessionModel) {
        window.title = model.title
        menus.update(model)
        guard view.superview == nil else { return }
        session?.removeFromSuperview()
        session = view
        view.frame = sidebar.content.bounds
        view.autoresizingMask = [.width, .height]
        sidebar.content.addSubview(view, positioned: .below, relativeTo: banner)
        banner.isHidden = true
        if case .connected(let connection) = link { menus.connection = connection }
    }

    private func closed(_ server: Server, _ view: SessionView, _ reason: String?, backoff: TimeInterval) {
        menus.connection = nil
        menus.update(SessionModel())
        feed?.stop()
        feed = nil
        sidebar.view.update(.starting)
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
        let view = NSMenu(title: "View")
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = tag
            return item
        }
        view.items = [
            item("Toggle Sidebar", #selector(toggleSidebar), "\\", .command),
            item("Focus Sidebar", #selector(focusSidebar), "s", [.command, .control]),
            .separator(),
            item("Next Needing Attention", #selector(attention(_:)), "n", [.command, .control], tag: 1),
            item("Previous Needing Attention", #selector(attention(_:)), "N", [.command, .control], tag: -1),
            item("Next Window in Sidebar", #selector(switchWindow(_:)), "j", [.command, .control], tag: 1),
            item("Previous Window in Sidebar", #selector(switchWindow(_:)), "k", [.command, .control], tag: 0),
        ]
        let bar = NSMenu()
        for menu in [app, view, menus.window, menus.session] {
            bar.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        bar.insertItem(PaneCommand.menu, at: 2)
        return bar
    }

    @objc private func toggleSidebar() {
        sidebar.toggle()
    }

    @objc private func focusSidebar() {
        if sidebar.isCollapsed { sidebar.toggle() }
        sidebar.view.focus()
    }

    @objc private func attention(_ sender: NSMenuItem) {
        sidebar.view.nextAttention(sender.tag)
    }

    @objc private func switchWindow(_ sender: NSMenuItem) {
        sidebar.view.failed(nil)
        feed?.switchWindow(next: sender.tag == 1) { [weak self] in self?.sidebar.view.failed($0) }
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
