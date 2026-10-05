import AppKit
import TmuxControl
import SidebarFeed

@MainActor final class WindowOwner: NSObject, NSWindowDelegate {
    let runtime: GhosttyRuntime
    let host: Host
    let ended = DispatchGroup()
    private(set) var alive = true
    private(set) var generation = 0
    private var task: Task<Void, Never>?
    private var drain: Drain?
    private var initial: DispatchWorkItem?
    private(set) var ssh: SSH?
    private var identity: String? { didSet { sidebar.tabs.needsLayout = true; sidebar.tabs.needsDisplay = true } }
    var menuChanged: () -> Void = {}
    var onClose: () -> Void = {}
    private(set) var window: NSWindow!
    private var banner: Banner!
    private var session: SessionView?
    private var link = Link.down { didSet { sidebar.tabs.needsDisplay = true } }
    let sidebar = Sidebar()
    private var feed: Feed?
    private var model = SessionModel()
    private var snapshot: Snapshot?
    private var navigationModel = SessionModel()
    private(set) var preparedAlert: (alert: NSAlert, respond: (NSApplication.ModalResponse) -> Void)?

    private enum Attempt {
        case discover
        case attach(Endpoint)
        case confirm(Endpoint)
    }

    private enum Link {
        case down
        case locating(Attempt, TimeInterval)
        case mismatch(Endpoint)
        case changed
        case connected(Connection, Endpoint, TimeInterval)
        case redialing(DispatchWorkItem, Attempt, TimeInterval)
    }

    init(host: Host, runtime: GhosttyRuntime, start: Bool = true) {
        self.host = host
        self.runtime = runtime
        super.init()
        window = AppWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = host.label
        window.collectionBehavior = .fullScreenPrimary
        window.contentMinSize = Sidebar.minSize
        let width = background ? 292 : UserDefaults.standard.object(forKey: "nativeSidebarWidth") as? Double ?? 292
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        updateAppearance()
        window.contentViewController = sidebar
        sidebar.tabs.hostLabel = { [weak self] in
            guard let self, case .remote(let alias) = self.host else { return nil }
            return (self.identity ?? alias, alias, { if case .connected = self.link { return true }; return false }())
        }
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
        sidebar.changed = { [weak self] in self?.menuChanged() }
        sidebar.list.send = { [weak self] in self?.send($0, then: $1) }
        sidebar.list.newSession = { [weak self] in self?.newSession() }
        sidebar.list.newWindow = { [weak self] in self?.create(Command("new-window", "-d", "-P", "-F", "#{session_id}:#{window_id}.#{pane_id}", "-t", $0, "-c", "#{pane_current_path}")) }
        sidebar.tabs.select = { [weak self] step in
            guard let self, let command = navigationModel.select(step) else { return }
            send([command])
        }
        sidebar.list.filter = { [weak self] in self?.feed?.filter($0) }
        sidebar.focusTerminal = { [weak self] in self?.session?.focusActive() }
        banner = Banner(background: runtime.background, target: self, action: #selector(WindowOwner.start))
        banner.frame = sidebar.content.bounds
        sidebar.content.addSubview(banner)
        window.center()
        if !background {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        menuChanged()
        if start { self.start() }
    }

    func updateAppearance() {
        let background = runtime.background
        window.backgroundColor = background
        for view in [sidebar.view, sidebar.content] {
            view.wantsLayer = true
            view.layer?.backgroundColor = background.cgColor
        }
        banner?.background = background
        let rgb = background.usingColorSpace(.deviceRGB) ?? .black
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        let luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        window.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
        session?.updateBackground()
    }

    func send(_ commands: [Command], then done: (@MainActor @Sendable ([Reply]?) -> Void)? = nil) {
        guard case .connected(let connection, _, _) = link else { return done?(nil) ?? () }
        let generation = generation
        connection.send(commands) { [weak self] replies in
            guard let self, accepts(generation) else { return }
            done?(replies)
        }
    }

    func down(_ title: String, _ detail: String, button: String?) {
        guard alive else { return }
        sidebar.list.leave()
        banner.show(title, detail, button: button)
        sidebar.list.offline(title)
    }

    @objc func start() {
        guard alive else { return }
        switch link {
        case .locating, .connected, .changed: return
        case .mismatch: break
        case .redialing(let item, _, _): item.cancel()
        case .down: break
        }
        if case .mismatch = link { invalidate(keepingSnapshot: true) }
        else { invalidate() }
        connect(.discover, backoff: 0.1)
    }

    private func connect(_ attempt: Attempt, backoff: TimeInterval) {
        let generation = generation, drain = Drain()
        self.drain = drain
        ended.enter()
        drain.ended.notify(queue: .global()) { @Sendable [ended] in ended.leave() }
        link = .locating(attempt, backoff)
        down("Connecting to \(host.label)…", "", button: nil)
        task = Task { [self] in
            guard accepts(generation) else { return }
            do throws(Failure) {
                try await openTransport(generation)
                guard accepts(generation) else { return }
                let endpoint: Endpoint
                switch attempt {
                case .attach(let remembered): return dial(remembered, backoff: backoff)
                case .confirm(let remembered): endpoint = remembered
                case .discover:
                    #if KIDO_VISUAL || KIDO_STRESS
                    if let testEndpoint { endpoint = testEndpoint }
                    else { endpoint = try await Server.locate(prepare: ssh.map { transport in { transport.launch($0) } }, drain: drain) }
                    #else
                    endpoint = try await Server.locate(prepare: ssh.map { transport in { transport.launch($0) } }, drain: drain)
                    #endif
                }
                guard accepts(generation) else { return }
                if endpoint.server.protocolVersion?.compatible != true { return protocolMismatch(endpoint) }
                dial(endpoint, backoff: backoff)
            } catch { failed(generation, error) }
        }
    }

    private func failed(_ token: Int, _ error: Failure) {
        guard alive, generation == token else { return }
        let attempt: Attempt, backoff: TimeInterval
        switch link {
        case .locating(let pending, let delay), .redialing(_, let pending, let delay): attempt = pending; backoff = delay
        case .connected(_, let endpoint, let delay): attempt = .attach(endpoint); backoff = initial == nil ? 0.05 : delay
        case .mismatch(let endpoint): attempt = .confirm(endpoint); backoff = 0.1
        case .down, .changed: return
        }
        invalidate()
        switch error {
        case .terminal:
            link = .down
            down("Kido could not reach \(host.label)", error.message, button: "Reconnect")
        case .transport:
            let next = min(backoff * 2, 2), generation = generation
            down("Disconnected from \(host.label)", error.message + "\nReconnecting…", button: "Reconnect")
            let item = DispatchWorkItem { [weak self] in
                guard let self, accepts(generation) else { return }
                connect(attempt, backoff: next)
            }
            link = .redialing(item, attempt, next)
            DispatchQueue.main.asyncAfter(deadline: .now() + next, execute: item)
        }
    }

    static func mismatchAlert(host: Host, server: RPCVersion?, binary: RPCVersion?) -> NSAlert {
        let alert = NSAlert()
        let local = host == .local, newer = max(server?.major ?? 0, binary?.major ?? 0) > RPCVersion.required.major
        let upgraded = !newer && binary?.compatible == true
        if newer {
            alert.messageText = local ? "This server needs a newer Kido.app" : "Update Kido.app to connect"
            alert.informativeText = local
                ? "This local server was started by a newer Kido.app. Update the app, or restart the server using this bundle. Restarting ends all its sessions and panes."
                : "The server on \(host.label) is newer than this app supports. Update Kido.app, then reconnect."
            if !local, let binary, binary.major > (server?.major ?? 0) {
                alert.informativeText = "kido on \(host.label) is newer than this app supports, but its running server still uses the older version. Update Kido.app, then restart that server and reconnect."
            }
        } else if !local && upgraded {
            alert.messageText = "Restart kido on \(host.label)"
            alert.informativeText = "kido was updated on the host, but its running server still uses the older version. Restart that server, then reconnect."
        } else {
            alert.messageText = local ? "Restart the local kido server" : "Update kido on \(host.label)"
            alert.informativeText = local
                ? "This server was started by an older kido. Restart it to use the kido bundled with this app."
                : "The host is running an older kido server that this app cannot connect to. Upgrade kido on the host and restart its server, then reconnect."
        }
        alert.informativeText += "\n\nCompatibility: this app needs protocol \(RPCVersion.required) or later within major \(RPCVersion.required.major). Server: \(server.map(String.init(describing:)) ?? "unstamped (older kido)")."
        if !local && (upgraded || newer && binary != server), let binary { alert.informativeText += " Host binary: \(binary)." }
        alert.informativeText += " Protocol numbers are not Kido.app release numbers."
        alert.addButton(withTitle: local ? "Restart…" : "Reconnect")
        alert.addButton(withTitle: "Close").keyEquivalent = "\u{1b}"
        return alert
    }

    private func protocolMismatch(_ endpoint: Endpoint) {
        invalidate(keepingSnapshot: true)
        link = .mismatch(endpoint)
        down("Disconnected from \(host.label)", "", button: "Reconnect")
        mismatchSheet(endpoint)
    }

    private func mismatchSheet(_ endpoint: Endpoint) {
        let alert = Self.mismatchAlert(host: host, server: endpoint.server.protocolVersion, binary: endpoint.server.binaryProtocol)
        let generation = generation
        prepareAlert(alert) { [weak self] response in
            guard let self, accepts(generation) else { return }
            guard response == .alertFirstButtonReturn else { banner.isHidden = false; return }
            if host != .local { return start() }
            let confirmation = NSAlert()
            confirmation.messageText = "Restart the local server?"
            confirmation.informativeText = "Restarting ends all sessions and panes on this local kido-app server. Running commands and agents will stop. Other clients attached to this server will disconnect."
            confirmation.addButton(withTitle: "Cancel")
            confirmation.addButton(withTitle: "Restart").hasDestructiveAction = true
            confirmation.buttons[0].keyEquivalent = "\u{1b}"
            confirmation.window.defaultButtonCell = confirmation.buttons[0].cell as? NSButtonCell
            confirmation.window.initialFirstResponder = confirmation.buttons[0]
            prepareAlert(confirmation) { [weak self] response in
                guard let self, accepts(generation) else { return }
                guard response == .alertSecondButtonReturn else { return mismatchSheet(endpoint) }
                link = .locating(.confirm(Endpoint(server: endpoint.server, kido: tools.kido)), 0.1)
                task = Task {
                    guard accepts(generation) else { return }
                    do throws(Failure) {
                        try await endpoint.server.restart(drain: drain)
                        guard accepts(generation) else { return }
                        link = .down
                        start()
                    } catch {
                        guard accepts(generation) else { return }
                        link = .down
                        down("Could not restart the app server", error.message, button: "Reconnect")
                    }
                }
            }
        }
    }

    enum ClipboardPermission { case ask, allow, deny }
    var clipboardPermission = ClipboardPermission.ask

    func cancelClipboardAlert(_ alert: NSAlert) {
        guard preparedAlert?.alert === alert else { return }
        preparedAlert = nil
        if window.attachedSheet === alert.window { window.endSheet(alert.window, returnCode: .abort) }
    }

    func prepareAlert(_ alert: NSAlert, respond: @escaping (NSApplication.ModalResponse) -> Void) {
        preparedAlert = (alert, respond)
        banner.isHidden = true
        presentAlert()
    }

    private func presentAlert() {
        guard alive, window.isVisible, window.attachedSheet == nil, let preparedAlert else { return }
        let alert = preparedAlert.alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, self.preparedAlert?.alert === alert else { return }
            respondToAlert(response)
        }
    }

    func respondToAlert(_ response: NSApplication.ModalResponse) {
        let pending = preparedAlert
        preparedAlert = nil
        if let alert = pending?.alert, window.attachedSheet === alert.window { window.endSheet(alert.window, returnCode: response) }
        pending?.respond(response)
    }

    func bundleChanged(_ error: Failure) {
        guard alive else { return }
        invalidate()
        link = .changed
        down("Relaunch Kido.app", error.message, button: nil)
    }

    private func dial(_ endpoint: Endpoint, backoff: TimeInterval) {
        let server = endpoint.server, generation = generation
        do throws(Failure) { try tools.validate() } catch { return bundleChanged(error) }
        note("dialing \(server.socket)")
        let view = SessionView(runtime: runtime)
        view.onPaneChange = { [weak self] in
            guard let self, accepts(generation) else { return }
            updateTabs()
        }
        view.frame = sidebar.content.bounds
        view.autoresizingMask = [.width, .height]
        do {
            let connection = try Connection(
                server: server, view: view, launch: ssh.map { $0.launch([server.tmux] + Launch.attach(server.tmux, socket: server.socket).arguments) }, host: host, drain: drain,
                onChange: { [weak self] model in guard let self, accepts(generation) else { return }; changed(view, model) },
                onDiagnostic: { [weak self] message in guard let self, accepts(generation) else { return }; banner.show(message, "", button: nil) },
                onClose: { [weak self] exit in guard let self, alive, self.generation == generation else { return }; closed(view, exit) })
            connection.navigationModel = { [weak self] in self?.navigationModel ?? SessionModel() }
            connection.onURL = { [weak self] text in
                guard let self, accepts(generation) else { return }
                guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    let message = "Remote file paths and non-HTTP links cannot be opened locally: \(text)"
                    note("\(host.label): \(message)")
                    if !background {
                        let alert = NSAlert()
                        alert.messageText = "Unsupported remote link"
                        alert.informativeText = message
                        alert.beginSheetModal(for: window) { _ in }
                    }
                    return
                }
                if !background { NSWorkspace.shared.open(url) }
            }
            link = .connected(connection, endpoint, backoff)
            session?.close()
            session = view
            feed = Feed(
                serverDir: endpoint.directory, locate: connection.locateFeed, query: { [weak self] in self?.sidebar.list.query ?? "" }, drain: drain,
                prepare: { [transport = ssh] args in transport?.launch([endpoint.kido] + args) ?? Launch(endpoint.kido, args, environment: tools.environment) },
                onChange: { [weak self] status in
                    guard let self, accepts(generation) else { return }
                    if case .invalidBundle(let error) = status { return self.bundleChanged(error) }
                    if case .protocolMismatch(let version, let binary) = status {
                        return self.protocolMismatch(Endpoint(server: Server(tmux: server.tmux, socket: server.socket, protocolVersion: version, binaryProtocol: binary ?? server.binaryProtocol), kido: endpoint.kido))
                    }
                    self.sidebar.list.update(status)
                    if case .running(let snapshot) = status, self.sidebar.list.query.isEmpty, snapshot.filter.isEmpty {
                        self.snapshot = snapshot
                        self.updateTabs()
                    }
                    self.ready()
                })
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, accepts(generation) else { return }
                closed(view, .ended("Control topology and sidebar snapshot did not arrive within 20 seconds"))
            }
            initial = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        } catch {
            note("could not run \(server.tmux): \(error.localizedDescription)")
            failed(generation, .transport(error.localizedDescription))
        }
    }

    #if KIDO_VISUAL || KIDO_STRESS
    var stressState: (SessionModel, SessionModel, SessionView?, Connection?, Snapshot?) {
        if case .connected(let connection, _, _) = link { return (model, navigationModel, session, connection, snapshot) }
        return (model, navigationModel, session, nil, snapshot)
    }
    #endif

    private func updateTabs() {
        let next = model.navigation(snapshot, activePanes: session?.windows.compactMapValues(\.active) ?? [:])
        sidebar.tabs.entries = next.tabs
        if navigationModel != next.model {
            navigationModel = next.model
            menuChanged()
        }
    }

    private func changed(_ view: SessionView, _ model: SessionModel) {
        window.title = host == .local ? model.title : "\(identity ?? host.label) / \(model.title)"
        self.model = model
        if model.session == nil { snapshot = nil }
        updateTabs()
        if view.superview == nil {
            session?.removeFromSuperview()
            session = view
            view.frame = sidebar.content.bounds
            sidebar.content.addSubview(view, positioned: .below, relativeTo: banner)
        }
        view.show(model.window)
        ready()
    }

    private func closed(_ view: SessionView, _ exit: Exit) {
        guard view === session else { return }
        switch exit {
        case .detached(let detached):
            invalidate()
            link = .down
            down("Detached from the kido server", detached, button: "Reconnect")
        case .ended(let reason): failed(generation, .transport(reason ?? "Control connection ended"))
        }
    }

    @objc func newSession() {
        let home = tools.environment["HOME"] ?? NSHomeDirectory()
        guard case .connected(let connection, _, _) = link, let window = connection.model.window else {
            var words = ["new-session", "-d", "-P", "-F", "#{session_id}:#{window_id}.#{pane_id}"]
            if host == .local { words += ["-c", home] }
            return create(Command(words: words))
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

    @objc func nextAttention() { sidebar.list.nextAttention(1) }
    @objc func previousAttention() { sidebar.list.nextAttention(-1) }
    @objc func nextWindow() { switchWindow(next: true) }
    @objc func previousWindow() { switchWindow(next: false) }

    private func switchWindow(next: Bool) {
        sidebar.list.failed(nil)
        guard case .connected(let connection, _, _) = link else { return }
        feed?.switchWindow(next: next) { [weak self] target, error in
            guard let self, case .connected(let current, _, _) = link, current === connection else { return }
            if let error { return sidebar.list.failed(error) }
            sidebar.list.completedNavigation(to: target)
        }
    }

    private func openTransport(_ token: Int) async throws(Failure) {
        guard case .remote(let destination) = host else { return }
        let transport = try SSH(destination)
        ssh = transport
        ended.enter()
        transport.ended.notify(queue: .global()) { @Sendable [ended] in ended.leave() }
        #if KIDO_VISUAL || KIDO_STRESS
        if let testRemoteEnvironment { transport.testEnvironment(testRemoteEnvironment) }
        transport.testConfiguration = testSSHConfiguration
        #endif
        let resolved = try await transport.start(drain: drain) { [weak self] error in self?.failed(token, error) }
        guard accepts(token) else { return }
        identity = resolved
    }

    private func ready() {
        guard initial != nil, model.session != nil, case .running? = feed?.status else { return }
        initial?.cancel()
        initial = nil
        banner.isHidden = true
    }

    func accepts(_ token: Int) -> Bool {
        guard alive, generation == token else { return false }
        switch link {
        case .connected:
            return host == .local || ssh?.master?.process.isRunning == true
        default: return true
        }
    }

    private func invalidate(keepingSnapshot: Bool = false) {
        generation += 1
        clipboardPermission = .ask
        preparedAlert = nil
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
        task?.cancel()
        task = nil
        initial?.cancel()
        initial = nil
        if case .redialing(let work, _, _) = link { work.cancel() }
        feed?.stop()
        feed = nil
        if case .connected(let connection, _, _) = link { connection.close(keepingView: keepingSnapshot) }
        if !keepingSnapshot {
            session?.close()
            session = nil
        }
        let closing = drain
        drain = nil
        closing?.close()
        ssh?.stop(after: closing)
        ssh = nil
        if !keepingSnapshot {
            model = SessionModel()
            snapshot = nil
            updateTabs()
        }
        window.title = host == .local ? "Local" : identity ?? host.label
    }

    func close() {
        if alive { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard alive else { return }
        alive = false
        invalidate()
        link = .down
        sidebar.dismissFloating()
        window.delegate = nil
        onClose()
    }
    func windowDidBecomeKey(_ notification: Notification) { menuChanged() }
    func windowDidChangeOcclusionState(_ notification: Notification) { presentAlert() }
    func updateColorScheme() { session?.updateColorScheme() }
    var navigation: SessionModel { navigationModel }

    #if KIDO_VISUAL || KIDO_STRESS
    var testRemoteEnvironment: [String: String]?
    var testSSHConfiguration: String?
    var testIdentity: String { identity ?? host.label }
    var testEndpoint: Endpoint?
    var testBanner: Banner { banner }
    var testSession: SessionView? { session }
    var testConnection: Connection? { if case .connected(let connection, _, _) = link { connection } else { nil } }
    #endif
}
