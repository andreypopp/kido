import AppKit
import TmuxControl

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
        window.title = SessionModel().title
        window.contentMinSize = Sidebar.minSize
        sidebar.frame = window.contentView!.bounds
        sidebar.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(sidebar)
        sidebar.view.send = { [weak self] in self?.send($0, then: $1) }
        menus.send = { [weak self] in self?.send($0) }
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

    private func send(_ commands: [Command], then done: (@MainActor @Sendable ([Reply]?) -> Void)? = nil) {
        guard case .connected(let connection) = link else { return done?(nil) ?? () }
        connection.send(commands, then: done)
    }

    private func down(_ title: String, _ detail: String, button: String?) {
        banner.show(title, detail, button: button)
        sidebar.view.offline(title)
    }

    @objc private func start() {
        switch link {
        case .locating, .connected: return
        case .redialing(let item): item.cancel()
        case .down: break
        }
        link = .locating
        down("Connecting to the kido server…", "", button: nil)
        Task {
            do throws(Failure) {
                dial(try await Server.locate(), backoff: 0.1)
            } catch {
                link = .down
                down("Kido could not reach the kido server", error.message, button: action)
            }
        }
    }

    private var action: String { Server.fixed == nil ? "Start kido server" : "Reconnect" }

    private func dial(_ server: Server, backoff: TimeInterval) {
        let view = SessionView(runtime: runtime)
        view.frame = sidebar.content.bounds
        view.autoresizingMask = [.width, .height]
        do {
            let connection = try Connection(
                server: server, view: view,
                onChange: { [weak self] in self?.changed(view, $0) },
                onClose: { [weak self] in self?.closed(server, view, $0, backoff: backoff) })
            link = .connected(connection)
            feed = Feed(
                socket: server.socket, locate: connection.locateFeed, query: { [weak self] in self?.sidebar.view.query ?? "" },
                onChange: { [weak self] in self?.sidebar.view.update($0) })
        } catch {
            link = .down
            down("Kido could not run \(server.tmux)", error.localizedDescription, button: action)
        }
    }

    private func changed(_ view: SessionView, _ model: SessionModel) {
        window.title = model.title
        menus.update(model)
        if view.superview == nil {
            session?.removeFromSuperview()
            session = view
            view.frame = sidebar.content.bounds
            sidebar.content.addSubview(view, positioned: .below, relativeTo: banner)
            banner.isHidden = true
        }
        view.show(model.window)
    }

    private func closed(_ server: Server, _ view: SessionView, _ exit: Exit, backoff: TimeInterval) {
        menus.update(SessionModel())
        feed?.stop()
        feed = nil
        window.title = SessionModel().title
        let reason: String?
        switch exit {
        case .detached(let detached):
            link = .down
            return down("Detached from the kido server", detached, button: "Reconnect")
        case .ended(let ended):
            reason = ended
        }
        let dropped = view === session
        let detail = reason ?? (dropped ? nil : "No kido server at \(server.socket).")
        down(
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
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        view.items = [
            item("Toggle Sidebar", #selector(toggleSidebar), "\\", .command),
            item("Focus Sidebar", #selector(focusSidebar), "s", [.command, .control]),
            .separator(),
            item("Next Needing Attention", #selector(nextAttention), "n", [.command, .control]),
            item("Previous Needing Attention", #selector(previousAttention), "N", [.command, .control]),
            item("Next Window in Sidebar", #selector(nextWindow), "j", [.command, .control]),
            item("Previous Window in Sidebar", #selector(previousWindow), "k", [.command, .control]),
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

    @objc private func nextAttention() { sidebar.view.nextAttention(1) }
    @objc private func previousAttention() { sidebar.view.nextAttention(-1) }
    @objc private func nextWindow() { switchWindow(next: true) }
    @objc private func previousWindow() { switchWindow(next: false) }

    private func switchWindow(next: Bool) {
        sidebar.view.failed(nil)
        feed?.switchWindow(next: next) { [weak self] in self?.sidebar.view.failed($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let background = ProcessInfo.processInfo.environment["KIDO_APP_BACKGROUND"] == "1"
let debugging = ProcessInfo.processInfo.environment["KIDO_APP_DEBUG"] == "1"

func debug(_ line: @autoclosure () -> String) {
    if debugging { FileHandle.standardError.write(Data("kido-app \(line())\n".utf8)) }
}

func milliseconds(since start: DispatchTime) -> String {
    String(format: "%.1fms", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(background ? .accessory : .regular)
NSApplication.shared.run()
