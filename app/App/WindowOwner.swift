import AppKit
import TmuxControl
import SidebarFeed

class OwnerWindow: NSWindow {
    var focusChanged: (NSResponder?, NSResponder?) -> Void = { _, _ in }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let old = firstResponder
        let accepted = super.makeFirstResponder(responder)
        if accepted, old !== firstResponder { focusChanged(old, firstResponder) }
        return accepted
    }
}

private class AlertEscape: NSView {
    var button: NSButton?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == "\u{1b}", event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        button?.performClick(nil)
        return true
    }
}

@MainActor final class WindowOwner: NSObject, NSWindowDelegate {
    let runtime: GhosttyRuntime
    let host: Host
    let ownerID = String(UUID().uuidString.prefix(8))
    enum DialCause {
        case launch, newWindow, reopen, remoteRequest, reconnect, serverRestart
        case redial(String)
        var label: String {
            switch self {
            case .launch: "launch"
            case .newWindow: "new window"
            case .reopen: "reopen"
            case .remoteRequest: "remote request"
            case .reconnect: "reconnect"
            case .serverRestart: "server restart"
            case .redial(let reason): "redial after \(reason)"
            }
        }
    }
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
    private enum Target { case pane(Snapshot.Position), window(SessionID, WindowID) }
    private var focusTarget: Target?
    private var intent = 0
    private var activating: Int?
    private var completing = false
    var request: (RPCRequest, @escaping @MainActor @Sendable (Result<RPCEvent.Reply.Value, Failure>) -> Void) -> Void = { $1(.failure(.terminal("the RPC feed is not ready"))) }
    private(set) var preparedAlert: (alert: NSAlert, respond: (NSApplication.ModalResponse) -> Void)?

    private static let localServerRestarted = Notification.Name("KidoLocalServerRestarted")

    @objc private func localServerRestarted(_ notification: Notification) {
        guard alive, host == .local, case .mismatch(let endpoint) = link,
              notification.object as? String == endpoint.server.socket else { return }
        begin(.serverRestart)
    }

    private enum Attempt {
        case discover
        case attach(Endpoint)
        case check(Endpoint)
    }

    private enum Link {
        case down
        case locating(Attempt, TimeInterval)
        case mismatch(Endpoint)
        case changed
        case connected(Connection, Endpoint, TimeInterval)
        case redialing(DispatchWorkItem, Attempt, TimeInterval)
    }

    init(host: Host, runtime: GhosttyRuntime, start: Bool = true, cause: DialCause = .launch) {
        self.host = host
        self.runtime = runtime
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(localServerRestarted(_:)), name: Self.localServerRestarted, object: nil)
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
        request = { [weak self] request, done in
            guard let feed = self?.feed else { return done(.failure(.terminal("the RPC feed is not ready"))) }
            feed.request(request, completed: done)
        }
        sidebar.list.navigate = { [weak self] in self?.perform($0) }
        sidebar.list.onIntent = { [weak self] in self?.supersedeIntent() }
        sidebar.list.newSession = { [weak self] in self?.newSession() }
        sidebar.list.newWindow = { [weak self] session in
            guard let self, let window = model.sessions.first(where: { $0.id == session })?.window else { return }
            perform(.newWindow(window))
        }
        sidebar.tabs.select = { [weak self] in self?.selectWindow($0) }
        sidebar.focusTerminal = { [weak self] in self?.focusSelected() }
        (window as? OwnerWindow)?.focusChanged = { [weak self] old, next in
            guard let self else { return }
            if let pane = next as? PaneView, model.window.flatMap({ session?.windows[$0]?.active }) == pane.pane,
               old == nil || old is PaneView || old === window { return }
            supersedeIntent()
        }
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
        for view in [sidebar.view, sidebar.terminalHost, sidebar.content] {
            view.wantsLayer = true
            view.layer?.backgroundColor = background.cgColor
        }
        banner?.background = background
        let rgb = background.usingColorSpace(.deviceRGB) ?? .black
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        let luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        let theme = (background: background, appearance: NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua))
        window.appearance = theme.appearance
        sidebar.tabs.theme = theme
        session?.updateBackground()
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposedOptions.subtracting(.autoHideToolbar)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateAppearance() }
    func windowDidExitFullScreen(_ notification: Notification) { updateAppearance() }

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

    @objc func start() { begin(.reconnect) }

    private func begin(_ cause: DialCause) {
        guard alive else { return }
        switch link {
        case .locating, .connected, .changed: return
        case .mismatch: break
        case .redialing(let item, _, _): item.cancel()
        case .down: break
        }
        let closeCause: Connection.CloseCause = if case .serverRestart = cause { .serverRestart } else { .reconnect }
        if case .mismatch = link { invalidate(cause: closeCause, keepingSnapshot: true) }
        else { invalidate(cause: closeCause) }
        connect(.discover, backoff: 0.1, cause: cause)
    }

    private func connect(_ attempt: Attempt, backoff: TimeInterval, cause: DialCause) {
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
                case .attach(let remembered): return dial(remembered, backoff: backoff, cause: cause)
                case .check(let remembered): endpoint = remembered
                case .discover:
                    #if KIDO_VISUAL || KIDO_STRESS
                    if let testEndpoint { endpoint = testEndpoint }
                    else { endpoint = try await Server.locate(prepare: ssh.map { transport in { transport.launch($0) } }, drain: drain) }
                    #else
                    endpoint = try await Server.locate(prepare: ssh.map { transport in { transport.launch($0) } }, drain: drain)
                    #endif
                }
                guard accepts(generation) else { return }
                if endpoint.server.protocolVersion?.compatible != true || !endpoint.server.binaryProtocol.compatible { return protocolMismatch(endpoint) }
                dial(endpoint, backoff: backoff, cause: cause)
            } catch { failed(generation, error) }
        }
    }

    private func failed(_ token: Int, _ error: Failure, cause: Connection.CloseCause? = nil) {
        guard alive, generation == token else { return }
        let attempt: Attempt, backoff: TimeInterval
        switch link {
        case .locating(let pending, let delay), .redialing(_, let pending, let delay): attempt = pending; backoff = delay
        case .connected(_, let endpoint, let delay): attempt = .attach(endpoint); backoff = initial == nil ? 0.05 : delay
        case .mismatch(let endpoint): attempt = .check(endpoint); backoff = 0.1
        case .down, .changed: return
        }
        invalidate(cause: cause ?? .failure(error.message))
        switch error {
        case .terminal:
            link = .down
            down("Kido could not reach \(host.label)", error.message, button: "Reconnect")
        case .transport:
            let next = min(backoff * 2, 2), generation = generation
            down("Disconnected from \(host.label)", error.message + "\nReconnecting…", button: "Reconnect")
            let item = DispatchWorkItem { [weak self] in
                guard let self, accepts(generation) else { return }
                connect(attempt, backoff: next, cause: .redial(cause?.label ?? error.message))
            }
            link = .redialing(item, attempt, next)
            DispatchQueue.main.asyncAfter(deadline: .now() + next, execute: item)
        }
    }

    static func mismatchAlert(host: Host, server: RPCVersion?, binary: RPCVersion?) -> NSAlert {
        let alert = NSAlert()
        let local = host == .local
        func newerThanRequired(_ version: RPCVersion?) -> Bool {
            guard let version else { return false }
            return version.major > RPCVersion.required.major || version.major == RPCVersion.required.major && version.minor > RPCVersion.required.minor
        }
        let newer = newerThanRequired(server) || newerThanRequired(binary)
        let upgraded = !newer && binary?.compatible == true
        if newer {
            alert.messageText = local ? "This server needs a newer Kido.app" : "Update Kido.app to connect"
            alert.informativeText = local
                ? "This local server was started by a newer Kido.app. Update the app, or restart the server using this bundle. Restarting ends all its sessions and panes."
                : "The server on \(host.label) is newer than this app supports. Update Kido.app, then reconnect."
            if !local, let binary, newerThanRequired(binary), !newerThanRequired(server) {
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
        alert.informativeText += "\n\nCompatibility: this app needs exactly protocol \(RPCVersion.required). Server: \(server.map(String.init(describing:)) ?? "unstamped (older kido)")."
        if !local && (upgraded || newer && binary != server), let binary { alert.informativeText += " Host binary: \(binary)." }
        alert.informativeText += " Protocol numbers are not Kido.app release numbers."
        if local {
            alert.informativeText += "\n\nRestarting ends all sessions and panes on this local kido-app server. Running commands and agents will stop. Other clients attached to this server will disconnect."
        }
        alert.addButton(withTitle: local ? "Restart" : "Reconnect").hasDestructiveAction = local
        alert.addButton(withTitle: "Close").keyEquivalent = "\u{1b}"
        if local {
            alert.buttons[0].keyEquivalent = ""
            alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
            alert.window.initialFirstResponder = alert.buttons[1]
            let escape = AlertEscape()
            escape.button = alert.buttons[1]
            alert.accessoryView = escape
        }
        return alert
    }

    private func protocolMismatch(_ endpoint: Endpoint) {
        invalidate(cause: .protocolMismatch, keepingSnapshot: true)
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
            link = .locating(.check(endpoint), 0.1)
            task = Task {
                guard accepts(generation) else { return }
                do throws(Failure) {
                    try await endpoint.server.restart(drain: drain)
                    guard accepts(generation) else { return }
                    NotificationCenter.default.post(name: Self.localServerRestarted, object: endpoint.server.socket)
                    link = .down
                    begin(.serverRestart)
                } catch {
                    guard accepts(generation) else { return }
                    link = .down
                    down("Could not restart the app server", error.message, button: "Reconnect")
                }
            }
        }
    }

    #if KIDO_VISUAL || KIDO_STRESS
    static let clipboardConsent = ClipboardConsent()
    #else
    static let clipboardConsent = ClipboardConsent(grants: background ? nil : .standard)
    #endif
    static func resetClipboardPermissions(_ owners: [WindowOwner]) {
        clipboardConsent.reset()
        owners.forEach { $0.clipboardPermission = .ask }
    }

    private var clipboardPrompt: (pane: PaneView, alert: NSAlert)?

    func requestClipboard(_ pane: PaneView) {
        if clipboardPermission == .deny { return pane.finishClipboard(false) }
        if clipboardPermission == .allow || Self.clipboardConsent.allows(host) { return pane.finishClipboard(true) }
        guard !pane.isHiddenOrHasHiddenAncestor, window.isVisible,
              preparedAlert == nil, window.attachedSheet == nil,
              Self.clipboardConsent.askingHosts.insert(host.clipboardKey).inserted else { return pane.finishClipboard(false) }
        let alert = NSAlert()
        alert.messageText = "Allow applications on “\(host.label)” to read your Mac clipboard?"
        alert.informativeText = "This also permits applications reached through SSH inside its panes."
        for title in ["Allow for this connection", "Always allow", "Deny"] { alert.addButton(withTitle: title) }
        clipboardPrompt = (pane, alert)
        pane.expireClipboard()
        prepareAlert(alert) { [weak self, weak pane] response in
            guard let self, let pane, clipboardPrompt?.pane === pane, clipboardPrompt?.alert === alert else { return }
            guard pane.clipboardOnTime else { return pane.finishClipboard(false) }
            let granted = response == .alertFirstButtonReturn || response == .alertSecondButtonReturn
            if granted { clipboardPermission = .allow }
            if response == .alertThirdButtonReturn { clipboardPermission = .deny }
            if response == .alertSecondButtonReturn { Self.clipboardConsent.allowAlways(host) }
            pane.finishClipboard(granted)
        }
    }

    func releaseClipboard(_ pane: PaneView) {
        guard let prompt = clipboardPrompt, prompt.pane === pane else { return }
        clipboardPrompt = nil
        Self.clipboardConsent.askingHosts.remove(host.clipboardKey)
        cancelClipboardAlert(prompt.alert)
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
        invalidate(cause: .bundleChanged)
        link = .changed
        down("Relaunch Kido.app", error.message, button: nil)
    }

    private func dial(_ endpoint: Endpoint, backoff: TimeInterval, cause: DialCause) {
        let server = endpoint.server, generation = generation
        do throws(Failure) { try tools.validate() } catch { return bundleChanged(error) }
        note("dialing \(server.socket) (\(cause.label.replacingOccurrences(of: "\n", with: "; "))) [owner \(ownerID)]")
        let view = SessionView(runtime: runtime)
        view.onPaneChange = { [weak self] in
            guard let self, accepts(generation) else { return }
            updateTabs()
            if focusTarget != nil { focusSelected() }
        }
        view.frame = sidebar.content.bounds
        view.autoresizingMask = [.width, .height]
        do {
            let connection = try Connection(
                server: server, view: view, launch: ssh.map { $0.launch([server.tmux] + Launch.attach(server.tmux, socket: server.socket).arguments, control: endpoint) }, host: host, drain: drain, ownerID: ownerID,
                onChange: { [weak self] model in guard let self, accepts(generation) else { return }; changed(view, model) },
                onDiagnostic: { [weak self] message in guard let self, accepts(generation) else { return }; banner.show(message, "", button: nil) },
                onClose: { [weak self] exit, cause in guard let self, alive, self.generation == generation else { return }; closed(view, exit, cause: cause) })
            connection.userFocus = { [weak self] in self?.supersedeIntent() }
            connection.navigate = { [weak self] command in
                guard let self, accepts(generation) else { return }
                switch command {
                case .newWindow: if let window = model.window { perform(.newWindow(window)) }
                case .window(let step): selectWindow(step)
                default: break
                }
            }
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
                serverDir: endpoint.directory, locate: connection.locateFeed, drain: drain,
                prepare: { [transport = ssh] args in transport?.launch([endpoint.kido] + args) ?? Launch(endpoint.kido, args, environment: tools.environment) },
                onChange: { [weak self] status in
                    guard let self, accepts(generation) else { return }
                    if case .invalidBundle(let error) = status { return self.bundleChanged(error) }
                    if case .protocolMismatch(let version, let binary) = status {
                        return self.protocolMismatch(Endpoint(server: Server(tmux: server.tmux, socket: server.socket, protocolVersion: version, binaryProtocol: binary ?? server.binaryProtocol), kido: endpoint.kido))
                    }
                    self.sidebar.list.update(status)
                    if case .running(let snapshot) = status {
                        self.snapshot = snapshot
                        self.updateTabs()
                    }
                    self.ready()
                })
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, accepts(generation) else { return }
                closed(view, .ended("Control topology and sidebar snapshot did not arrive within 20 seconds"), cause: .readinessTimeout)
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
        if sidebar.tabs.entries != next.tabs { sidebar.tabs.entries = next.tabs }
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
        if focusTarget != nil { focusSelected() }
        ready()
    }

    private func closed(_ view: SessionView, _ exit: Exit, cause: Connection.CloseCause? = nil) {
        guard view === session else { return }
        switch exit {
        case .detached(let detached):
            invalidate(cause: nil)
            link = .down
            down("Detached from the kido server", detached, button: "Reconnect")
        case .ended(let reason): failed(generation, .transport(reason ?? "Control connection ended"), cause: cause)
        }
    }

    @objc func newSession() { perform(.newSession) }

    func selectWindow(_ step: WindowStep) {
        if let request = navigationModel.select(step) { perform(request) }
    }

    func supersedeIntent() {
        guard !completing else { return }
        intent += 1
        focusTarget = nil
    }

    func perform(_ request: RPCRequest) {
        if case .jump(let target) = request {
            guard activating != intent else { return }
            sidebar.list.select(target)
        }
        supersedeIntent()
        let revision = intent
        if case .jump = request { activating = revision }
        sidebar.list.failed(nil)
        let done: @MainActor @Sendable (Result<RPCEvent.Reply.Value, Failure>) -> Void = { [weak self] result in
            guard let self else { return }
            if activating == revision { activating = nil }
            guard intent == revision else { return }
            completing = true
            defer { completing = false }
            switch result {
            case .failure(let error): sidebar.list.failed(error.message)
            case .success(.jumped(let target)), .success(.selected(let target)), .success(.created(let target)):
                focusTarget = .pane(target)
                sidebar.list.completedActivation()
            case .success(.switched(let target)):
                guard let target else { return }
                focusTarget = .window(target.session, target.window)
                sidebar.list.completedActivation()
            case .success(.released): sidebar.list.leave()
            default: break
            }
        }
        self.request(request, done)
    }

    private func focusSelected() {
        if let target = focusTarget {
            switch target {
            case .pane(let position):
                guard model.session == position.session, model.window == position.window,
                      session?.windows[position.window]?.active == position.pane else { return }
            case .window(let s, let w):
                guard model.session == s, model.window == w, session?.windows[w]?.active != nil else { return }
            }
            focusTarget = nil
        }
        session?.focusActive()
    }

    @objc func nextAttention() { sidebar.list.nextAttention(1) }
    @objc func previousAttention() { sidebar.list.nextAttention(-1) }

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

    private func invalidate(cause: Connection.CloseCause?, keepingSnapshot: Bool = false) {
        focusTarget = nil
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
        if case .connected(let connection, _, _) = link { connection.close(cause: cause, keepingView: keepingSnapshot) }
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

    func close(cause: Connection.CloseCause = .windowClosed) {
        if alive {
            if case .connected(let connection, _, _) = link { connection.recordCloseCause(cause) }
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard alive else { return }
        alive = false
        invalidate(cause: .windowClosed)
        link = .down
        sidebar.dismissFloating()
        window.delegate = nil
        onClose()
    }
    func windowDidBecomeKey(_ notification: Notification) { supersedeIntent(); menuChanged() }
    func windowDidResignKey(_ notification: Notification) { supersedeIntent() }
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
