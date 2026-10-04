import AppKit
import TmuxControl
import SidebarFeed

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var window: NSWindow!
    private var banner: Banner!
    private var session: SessionView?
    private var link = Link.down
    private let menus = SessionMenus()
    let sidebar = Sidebar()
    private var feed: Feed?
    private var model = SessionModel()
    private var snapshot: Snapshot?
    private var navigationModel = SessionModel()
    private var trigger: String?
    private var signals: [DispatchSourceSignal] = []

    private enum Link {
        case down
        case locating
        case mismatch(Server)
        case changed
        case connected(Connection)
        case redialing(DispatchWorkItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = NSImage(named: "AppIcon")
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler {
                note("quitting: \(String(cString: strsignal(signal)))")
                Darwin.signal(signal, SIG_DFL)
                raise(signal)
            }
            source.resume()
            signals.append(source)
        }
        guard let runtime = GhosttyRuntime() else { fatalError("libghostty failed to initialise") }
        self.runtime = runtime
        NSApp.mainMenu = mainMenu()
        window = AppWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = SessionModel().title
        window.collectionBehavior = .fullScreenPrimary
        window.contentMinSize = Sidebar.minSize
        let width = background ? 292 : UserDefaults.standard.object(forKey: "nativeSidebarWidth") as? Double ?? 292
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        updateAppearance()
        runtime.onConfigChange = { [weak self] in self?.updateAppearance() }
        runtime.onColorSchemeChange = { [weak self] in self?.session?.updateColorScheme() }
        window.contentViewController = sidebar
        let toolbar = NSToolbar(identifier: "KidoSidebar")
        toolbar.delegate = sidebar
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 900, height: 560))
        window.contentView?.layoutSubtreeIfNeeded()
        sidebar.splitView.setPosition(max(200, min(360, width)), ofDividerAt: 0)
        if !background { sidebar.isCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed") }
        sidebar.changed = { [weak self] in self?.updateSidebarMenu() }
        sidebar.list.send = { [weak self] in self?.send($0, then: $1) }
        sidebar.list.newSession = { [weak self] in self?.newSession() }
        sidebar.list.newWindow = { [weak self] in self?.create(Command("new-window", "-d", "-P", "-F", "#{session_id}:#{window_id}.#{pane_id}", "-t", $0, "-c", "#{pane_current_path}")) }
        menus.send = { [weak self] in self?.send($0) }
        sidebar.tabs.select = { [weak self] step in
            guard let self, let command = navigationModel.select(step) else { return }
            send([command])
        }
        sidebar.list.filter = { [weak self] in self?.feed?.filter($0) }
        sidebar.focusTerminal = { [weak self] in self?.session?.focusActive() }
        banner = Banner(target: self, action: #selector(start), connectAction: #selector(connectAnyway))
        banner.frame = sidebar.content.bounds
        sidebar.content.addSubview(banner)
        window.center()
        if !background {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        updateSidebarMenu()
        start()
        #if KIDO_STRESS
        Stress(window: window, send: { [weak self] in self?.send($0) }, reconnect: { [weak self] in self?.start() }).run()
        #endif
    }

    private func updateAppearance() {
        window.backgroundColor = runtime.background
        let rgb = runtime.background.usingColorSpace(.deviceRGB) ?? .black
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        let luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        window.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
        session?.updateBackground()
    }

    private func send(_ commands: [Command], then done: (@MainActor @Sendable ([Reply]?) -> Void)? = nil) {
        guard case .connected(let connection) = link else { return done?(nil) ?? () }
        connection.send(commands, then: done)
    }

    func down(_ title: String, _ detail: String, button: String?, connect: Bool = false) {
        sidebar.list.leave()
        banner.show(title, detail, button: button, connect: connect)
        sidebar.list.offline(title)
    }

    @objc private func start() {
        switch link {
        case .locating, .connected, .changed: return
        case .mismatch(let server):
            let alert = NSAlert()
            alert.messageText = "This server was started by a different kido. Restarting ends all its sessions and panes."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.confirmedRestart(server, response)
            }
            return
        case .redialing(let item): item.cancel()
        case .down: break
        }
        link = .locating
        down("Connecting to the kido server…", "", button: nil)
        Task {
            do throws(Failure) {
                let server = try await Server.locate()
                if Server.fixed == nil, server.build != tools.build {
                    link = .mismatch(server)
                    note("server build mismatch: \(server.build ?? "missing")")
                    down("This app server was started by a different kido", "Restart the kido-app server to use this bundle.", button: "Restart", connect: true)
                    return
                }
                dial(server, backoff: 0.1)
            } catch {
                note("could not locate the kido server: \(error.message)")
                link = .down
                down("Kido could not reach the kido server", error.message, button: action)
            }
        }
    }

    @objc private func connectAnyway() {
        guard case .mismatch(let server) = link else { return }
        dial(server, backoff: 0.1)
    }

    private func confirmedRestart(_ server: Server, _ response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn else { return }
        link = .locating
        Task {
            do throws(Failure) {
                try await server.restart()
                link = .down
                start()
            } catch {
                link = .down
                down("Could not restart the app server", error.message, button: "Reconnect")
            }
        }
    }

    private var action: String { Server.fixed == nil ? "Start app server" : "Reconnect" }

    func applicationDidBecomeActive(_ notification: Notification) {
        do throws(Failure) { try tools.validate() } catch { bundleChanged(error) }
    }

    private func bundleChanged(_ error: Failure) {
        if case .redialing(let item) = link { item.cancel() }
        let connection: Connection?
        if case .connected(let current) = link { connection = current } else { connection = nil }
        link = .changed
        feed?.stop()
        feed = nil
        connection?.gridFailed()
        down("Relaunch Kido.app", error.message, button: nil)
    }

    private func dial(_ server: Server, backoff: TimeInterval) {
        do throws(Failure) { try tools.validate() } catch { return bundleChanged(error) }
        note("dialing \(server.socket)")
        let view = SessionView(runtime: runtime)
        view.frame = sidebar.content.bounds
        view.autoresizingMask = [.width, .height]
        do {
            let connection = try Connection(
                server: server, view: view,
                onChange: { [weak self] in self?.changed(view, $0) },
                onDiagnostic: { [weak self] in self?.banner.show($0, "", button: nil) },
                onClose: { [weak self] in self?.closed(server, view, $0, backoff: backoff) })
            connection.navigationModel = { [weak self] in self?.navigationModel ?? SessionModel() }
            link = .connected(connection)
            feed = Feed(
                socket: server.socket, locate: connection.locateFeed, query: { [weak self] in self?.sidebar.list.query ?? "" },
                onChange: { [weak self] status in
                    if case .invalidBundle(let error) = status { return self?.bundleChanged(error) ?? () }
                    self?.sidebar.list.update(status)
                    if case .running(let snapshot) = status, self?.sidebar.list.query.isEmpty == true, snapshot.filter.isEmpty {
                        self?.snapshot = snapshot
                        self?.updateTabs()
                    }
                })
        } catch {
            note("could not run \(server.tmux): \(error.localizedDescription)")
            link = .down
            down("Kido could not run \(server.tmux)", error.localizedDescription, button: action)
        }
    }

    private func updateTabs() {
        let next = model.navigation(snapshot)
        sidebar.tabs.entries = next.tabs
        if navigationModel != next.model {
            navigationModel = next.model
            menus.update(navigationModel)
        }
    }

    private func changed(_ view: SessionView, _ model: SessionModel) {
        window.title = model.title
        self.model = model
        if model.session == nil { snapshot = nil }
        updateTabs()
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
        guard case .connected = link else { return }
        view.subviews.compactMap { $0 as? WindowView }.forEach { $0.cancelDrag() }
        model = SessionModel()
        snapshot = nil
        updateTabs()
        feed?.stop()
        feed = nil
        window.title = SessionModel().title
        let reason: String?
        switch exit {
        case .detached(let detached):
            note("staying detached")
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
        note("redialing in \(next)s")
        let item = DispatchWorkItem { [weak self] in self?.dial(server, backoff: next) }
        link = .redialing(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + next, execute: item)
    }

    private func mainMenu() -> NSMenu {
        let app = NSMenu(title: "Kido")
        app.items = [
            NSMenuItem(title: "Hide Kido", action: #selector(NSApplication.hide(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit Kido", action: #selector(quitItem), keyEquivalent: "q"),
        ]
        let view = NSMenu(title: "View")
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        view.items = [
            item("Hide Sidebar", #selector(Sidebar.toggleSidebar(_:)), "S", [.command, .shift]),
            item("Focus Sidebar", #selector(Sidebar.focusSidebar(_:)), "s", .command),
            .separator(),
            item("Next Needing Attention", #selector(nextAttention), "n", [.command, .control]),
            item("Previous Needing Attention", #selector(previousAttention), "N", [.command, .control]),
            item("Next Window in Sidebar", #selector(nextWindow), "j", [.command, .control]),
            item("Previous Window in Sidebar", #selector(previousWindow), "k", [.command, .control]),
        ]
        for item in view.items.prefix(2) { item.target = sidebar }
        let file = NSMenu(title: "File")
        file.items = [item("New Session", #selector(newSession), "N", [.command, .shift])]
        let find = NSMenu(title: "Find")
        find.items = [
            item("Find…", #selector(PaneView.showFind(_:)), "f", .command),
            item("Find Next", #selector(PaneView.findNext(_:)), "g", .command),
            item("Find Previous", #selector(PaneView.findPrevious(_:)), "g", [.command, .shift]),
        ]
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        let bar = NSMenu()
        for menu in [app, file, edit, view, menus.window, menus.session] {
            bar.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        bar.insertItem(PaneCommand.menu, at: 2)
        return bar
    }

    @objc private func newSession() {
        let home = tools.environment["HOME"] ?? NSHomeDirectory()
        guard case .connected(let connection) = link, let window = connection.model.window else {
            return create(Command("new-session", "-d", "-P", "-F", "#{session_id}:#{window_id}.#{pane_id}", "-c", home))
        }
        send([Command("display-message", "-p", "-t", window, "#{pane_current_path}")]) { [weak self] replies in
            guard case .success(let lines)? = replies?.first, let cwd = lines.first, !cwd.isEmpty else { return }
            self?.create(Command("new-session", "-d", "-P", "-F", "#{session_id}:#{window_id}.#{pane_id}", "-c", cwd))
        }
    }

    private func create(_ command: Command) {
        sidebar.list.failed(nil)
        send([command]) { [weak self] replies in
            guard let self else { return }
            guard case .success(let lines)? = replies?.first, let target = lines.first else {
                if case .failure(let lines)? = replies?.first { sidebar.list.failed(lines.joined(separator: "\n")) }
                else { sidebar.list.failed("The connection closed before creation completed") }
                return
            }
            send([Command("switch-client", "-t", target)]) { [weak self] replies in
                guard let self else { return }
                if case .success? = replies?.first { session?.focusActive() }
                else if case .failure(let lines)? = replies?.first { sidebar.list.failed(lines.joined(separator: "\n")) }
                else { sidebar.list.failed("The connection closed before selection completed") }
            }
        }
    }

    private func updateSidebarMenu() {
        NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu?.items.first?.title = sidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
    }

    @objc private func nextAttention() { sidebar.list.nextAttention(1) }
    @objc private func previousAttention() { sidebar.list.nextAttention(-1) }
    @objc private func nextWindow() { switchWindow(next: true) }
    @objc private func previousWindow() { switchWindow(next: false) }

    private func switchWindow(next: Bool) {
        sidebar.list.failed(nil)
        guard case .connected(let connection) = link else { return }
        feed?.switchWindow(next: next) { [weak self] target, error in
            guard let self, case .connected(let current) = link, current === connection else { return }
            if let error { return sidebar.list.failed(error) }
            sidebar.list.completedNavigation(to: target)
        }
    }

    @objc private func quitItem() { quit("the Quit menu item") }

    func quit(_ trigger: String) {
        self.trigger = trigger
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        trigger = "the last window closed"
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let pid = event?.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        note("quitting: \(trigger ?? pid.map { "a quit Apple Event from pid \($0)" } ?? "NSApp.terminate")")
        return .terminateNow
    }
}

let tools = BundledTools(resources: Bundle.main.resourceURL!, environment: ProcessInfo.processInfo.environment)
#if DEBUG || KIDO_VISUAL || KIDO_STRESS
let background = ProcessInfo.processInfo.environment["KIDO_APP_BACKGROUND"] == "1"
#else
let background = false
#endif
#if KIDO_VISUAL || KIDO_STRESS
let debugging = ProcessInfo.processInfo.environment["KIDO_APP_DEBUG"] == "1"
#else
let debugging = false
#endif

func note(_ line: String) {
    FileHandle.standardError.write(Data("kido-app \(line)\n".utf8))
}

func debug(_ line: @autoclosure () -> String) {
    if debugging { note(line()) }
}

func milliseconds(since start: DispatchTime) -> String {
    String(format: "%.1fms", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(background ? .accessory : .regular)
NSApplication.shared.run()
