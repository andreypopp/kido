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
    let notificationID = UUID().uuidString
    var feedFresh = true
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
    private(set) var identity: String? { didSet { sidebar.tabs.needsLayout = true; sidebar.tabs.needsDisplay = true } }
    var menuChanged: () -> Void = {}
    var onClose: () -> Void = {}
    var snapshotReceived: () -> Void = {}
    private(set) var window: NSWindow!
    private var banner: Banner!
    private var session: SessionView?
    private var link = Link.down { didSet { sidebar.tabs.needsDisplay = true } }
    let sidebar = Sidebar()
    let reorder = Reorder()
    private var feed: Feed?
    private var controlModel = SessionModel()
    private struct Hold {
        let token: Int, intent: Int, generation: Int, instance: ServerInstance, session: SessionID, window: WindowID
    }
    private var held: Hold?
    private var model: SessionModel {
        var model = controlModel
        if let held, holds(held) { model.window = held.window }
        return model
    }
    private(set) var snapshot: Snapshot?
    private var navigationModel = SessionModel()
    private enum Target { case pane(Snapshot.Position), window(SessionID, WindowID) }
    private var focusTarget: Target?
    private var intent = 0
    private var activating: Int?
    private var completing = false
    var request: (RPCRequest, @escaping @MainActor @Sendable (Result<RPCEvent.Reply.Value, Failure>) -> Void) -> Void = { $1(.failure(.terminal("the RPC feed is not ready"))) }
    private(set) var preparedAlert: (alert: NSAlert, respond: (NSApplication.ModalResponse) -> Void)?

    private static let localServerRestarted = Notification.Name("KidoLocalServerRestarted")
    private static let seenChanged = Notification.Name("KidoSeenChanged")
    private static var seenByHost: [Host: SeenRecord] = [:]
    private(set) lazy var seen: SeenRecord = {
        let record = Self.seenByHost[host] ?? SeenRecord()
        Self.seenByHost[host] = record
        return record
    }()

    var attended: Bool {
        var attended = NSApp.isActive && window.isKeyWindow && !window.isMiniaturized && window.occlusionState.contains(.visible)
        #if KIDO_VISUAL || KIDO_STRESS
        attended = testAttended ?? attended
        #endif
        return attended
    }

    private func observeSeen() -> Bool {
        guard let snapshot else { return false }
        var next = seen.value
        next.observe(snapshot, attended: attended)
        guard next != seen.value else { return false }
        seen.value = next
        NotificationCenter.default.post(name: Self.seenChanged, object: seen, userInfo: ["by": self])
        return true
    }

    @objc private func attend() {
        if observeSeen() { refreshSeen() }
        Notifier.shared.update(host: host)
    }

    @objc private func seenChanged(_ notification: Notification) {
        if notification.userInfo?["by"] as? WindowOwner !== self { refreshSeen() }
    }

    private func refreshSeen() {
        sidebar.list.refresh()
        updateTabs()
    }

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

    private let openBrowser: (URL) -> Void

    func openLink(_ text: String) {
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
        openBrowser(url)
    }

    init(host: Host, runtime: GhosttyRuntime, start: Bool = true, cause: DialCause = .launch, openBrowser: @escaping (URL) -> Void = { if !background { NSWorkspace.shared.open($0) } }) {
        self.openBrowser = openBrowser
        self.host = host
        self.runtime = runtime
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(localServerRestarted(_:)), name: Self.localServerRestarted, object: nil)
        sidebar.list.seen = seen
        NotificationCenter.default.addObserver(self, selector: #selector(seenChanged(_:)), name: Self.seenChanged, object: seen)
        NotificationCenter.default.addObserver(self, selector: #selector(attend), name: NSApplication.didBecomeActiveNotification, object: nil)
        window = AppWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.delegate = self
        Notifier.shared.register(self)
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
        sidebar.list.renameSession = { [weak self] id, name, done in
            guard let self else { return done("The control client is not ready.") }
            send([Command("rename-session", "-t", id, "--", name)]) { replies in
                guard let reply = replies?.first else { return done("The control client is not ready.") }
                if case .failure(let lines) = reply { done(lines.joined(separator: "\n")) }
                else { done(nil) }
            }
        }
        sidebar.list.reorder = reorder
        sidebar.tabs.reorder = reorder
        sidebar.list.move = { [weak self] in self?.submit($0) }
        sidebar.tabs.move = sidebar.list.move
        sidebar.tabs.select = { [weak self] in self?.selectWindow($0) }
        sidebar.tabs.close = { [weak self] tab in self?.confirmClose(.window(tab.id), name: tab.name) }
        sidebar.tabs.addWindow.invoke = { [weak self] in
            guard let self, let window = model.window else { return }
            perform(.newWindow(window))
        }
        sidebar.list.closePane = { [weak self] row in
            guard let pane = row.target?.pane else { return }
            self?.confirmClose(.pane(pane), name: row.title)
        }
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
        if start { begin(cause) }
    }

    func updateAppearance() {
        let background = runtime.background
        window.backgroundColor = background
        for view in [sidebar.terminalHost, sidebar.content] {
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
                if !endpoint.server.compatible { return protocolMismatch(endpoint) }
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

    static func mismatchAlert(host: Host, server: ServerStamp?, binary: RPCVersion) -> NSAlert {
        let alert = NSAlert()
        let local = host == .local
        if !binary.compatible {
            let newer = binary.major > RPCVersion.required.major || binary.major == RPCVersion.required.major && binary.minor > RPCVersion.required.minor
            alert.messageText = newer ? (local ? "This server needs a newer Kido.app" : "Update Kido.app to connect") : (local ? "Update Kido.app" : "Update kido on \(host.label)")
            alert.informativeText = "This app needs kido RPC \(RPCVersion.required). \(local ? "The bundled kido" : "kido on " + host.label) speaks \(binary)."
            alert.informativeText += newer ? " Update Kido.app, then reconnect." : (local ? " Reinstall or update Kido.app." : " Upgrade kido there, then reconnect.")
        } else {
            alert.messageText = local ? "Restart the local kido server" : "Restart kido on \(host.label)"
            alert.informativeText = "This server was started by a different kido build or config\(server == nil ? " (or is unstamped)" : ""). Restart it, then reconnect."
        }
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
        let alert = Self.mismatchAlert(host: host, server: endpoint.server.stamp, binary: endpoint.server.binaryProtocol)
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
        for owner in owners {
            owner.clipboardPermission = [:]
            owner.uploadPermission = .ask
            owner.clipboardPrompt?.pane.finishClipboard(false)
            owner.releaseUploadPrompt()
        }
    }

    private var clipboardPrompt: (pane: PaneView, alert: NSAlert, scope: ClipboardConsent.Capability)?

    func requestClipboard(_ pane: PaneView, _ scope: ClipboardConsent.Capability) {
        if clipboardPermission[scope] == .deny { return pane.finishClipboard(false) }
        if clipboardPermission[scope] == .allow || Self.clipboardConsent.allows(host, scope) { return pane.finishClipboard(true) }
        guard !pane.isHiddenOrHasHiddenAncestor, window.isVisible,
              preparedAlert == nil, window.attachedSheet == nil,
              Self.clipboardConsent.askingHosts.insert(scope.rawValue + " " + host.clipboardKey).inserted else { return pane.finishClipboard(false) }
        let alert = NSAlert()
        alert.messageText = scope == .rich
            ? "Allow applications on “\(host.label)” to read images, HTML and file lists from your Mac clipboard?"
            : "Allow applications on “\(host.label)” to read your Mac clipboard?"
        alert.informativeText = "This also permits applications reached through SSH inside its panes."
        for title in ["Allow for this connection", "Always allow", "Deny"] { alert.addButton(withTitle: title) }
        clipboardPrompt = (pane, alert, scope)
        pane.expireClipboard()
        prepareAlert(alert) { [weak self, weak pane] response in
            guard let self, let pane, clipboardPrompt?.pane === pane, clipboardPrompt?.alert === alert else { return }
            guard pane.clipboardOnTime else { return pane.finishClipboard(false) }
            let granted = response == .alertFirstButtonReturn || response == .alertSecondButtonReturn
            if granted { clipboardPermission[scope] = .allow }
            if response == .alertThirdButtonReturn { clipboardPermission[scope] = .deny }
            if response == .alertSecondButtonReturn { Self.clipboardConsent.allowAlways(host, scope) }
            pane.finishClipboard(granted)
        }
    }

    func releaseClipboard(_ pane: PaneView) {
        guard let prompt = clipboardPrompt, prompt.pane === pane else { return }
        clipboardPrompt = nil
        Self.clipboardConsent.askingHosts.remove(prompt.scope.rawValue + " " + host.clipboardKey)
        cancelClipboardAlert(prompt.alert)
    }

    enum ClipboardPermission { case ask, allow, deny }
    var clipboardPermission: [ClipboardConsent.Capability: ClipboardPermission] = [:]
    var uploadPermission = ClipboardPermission.ask
    private var uploadPrompt: NSAlert?
    private var uploads: [String: (pane: PaneView, task: Task<Void, Never>)] = [:]

    private var uploadBase: String? {
        #if KIDO_VISUAL || KIDO_STRESS
        if let testUploadBase { return testUploadBase }
        #endif
        if case .connected(_, let endpoint, _) = link { return endpoint.directory }
        return nil
    }

    func sshDestination(_ pane: PaneView) -> String? {
        guard host == .local else { return nil }
        func find(_ nodes: [SidebarFeed.Node]) -> String? {
            for node in nodes {
                if case .item(let item) = node, item.pane == pane.pane { return if case .live(.ssh(let destination, _)) = item.lifecycle { destination.description } else { nil } }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        return find(snapshot?.sessions.flatMap(\.nodes) ?? [])
    }

    func upload(_ planned: Result<Upload, Failure>, to pane: PaneView) {
        let plan: Upload
        do { plan = try planned.get() } catch { return notice("Kido did not upload", error.message) }
        if let destination = sshDestination(pane) { return uploadOverSSH(plan, destination, to: pane) }
        if host == .local, let paths = plan.originals { return insert(paths, into: pane) }
        guard let base = uploadBase else { return notice("Kido did not upload", "\(host.label) is not connected.") }
        guard admitsUpload() else { return }
        if host == .local || uploadPermission == .allow || Self.clipboardConsent.allows(host, .upload) { return transfer(plan, base: base, to: pane) }
        if uploadPermission == .deny { return notice("Kido did not upload", "Uploads to “\(host.label)” are denied for this connection.") }
        askUpload(plan, to: host.label, "Kido copies them to \(base)/drops on \(identity ?? host.label) and pastes their paths. Files are kept for about 7 days.",
                  ["Allow for this connection", "Always allow", "Deny"]) { [weak self, weak pane] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn { Self.clipboardConsent.allowAlways(host, .upload) }
            uploadPermission = response == .alertFirstButtonReturn || response == .alertSecondButtonReturn ? .allow : .deny
            guard uploadPermission == .allow, let pane else { return }
            transfer(plan, base: base, to: pane)
        }
    }

    private func uploadOverSSH(_ plan: Upload, _ destination: String, to pane: PaneView, confirmed: [String]? = nil) {
        guard admitsUpload() else { return }
        let id = UUID().uuidString.lowercased(), instance = snapshot?.serverInstance
        uploads[id] = (pane, Task {})
        send([Command("show-options", "-p", "-v", "-t", pane.pane, "@kido_ssh_args")]) { [weak self, weak pane] replies in
            guard let self, let pane, uploads.removeValue(forKey: id) != nil else { return }
            guard case .success(let lines)? = replies?.first, let recorded = try? JSONDecoder().decode([String].self, from: Data(lines.joined(separator: "\n").utf8)),
                  let target = recorded.last, sshDestination(pane) == destination, snapshot?.serverInstance == instance else {
                return notice("Kido did not upload", confirmed == nil ? "Kido can't tell where this ssh session connects; nothing was uploaded."
                              : "The ssh session in this pane changed after you confirmed; nothing was uploaded.")
            }
            guard let confirmed else {
                return askUpload(plan, to: target, "The program in this pane runs over ssh on \(target) (\(destination)). Nested ssh sessions are not detected.",
                                 ["Upload", "Cancel"]) { [weak self, weak pane] response in
                    guard let self, response == .alertFirstButtonReturn, let pane else { return }
                    uploadOverSSH(plan, destination, to: pane, confirmed: recorded)
                }
            }
            guard recorded == confirmed else { return notice("Kido did not upload", "The ssh session in this pane changed after you confirmed; nothing was uploaded.") }
            var base = ""
            #if KIDO_VISUAL || KIDO_STRESS
            base = testUploadBase ?? ""
            #endif
            transfer(plan, base: base, to: pane, over: recorded)
        }
    }

    private func askUpload(_ plan: Upload, to label: String, _ detail: String, _ buttons: [String], then answered: @escaping (NSApplication.ModalResponse) -> Void) {
        guard window.isVisible, preparedAlert == nil, window.attachedSheet == nil,
              Self.clipboardConsent.askingHosts.insert("upload " + host.clipboardKey).inserted else {
            return note("\(host.label): upload refused while another prompt is open")
        }
        let alert = NSAlert()
        let files = plan.sources.count == 1 ? "1 file" : "\(plan.sources.count) files"
        alert.messageText = "Upload \(files) (\(String(format: "%.1f", Double(plan.size) / 1_048_576)) MiB) to “\(label)”?"
        alert.informativeText = detail
        for title in buttons { alert.addButton(withTitle: title) }
        uploadPrompt = alert
        let generation = generation
        prepareAlert(alert) { [weak self] response in
            guard let self, uploadPrompt === alert else { return }
            releaseUploadPrompt()
            if accepts(generation) { answered(response) }
        }
    }

    func uploadImage(_ raw: Data?, to pane: PaneView) {
        prepareUpload(to: pane) { _ throws(Failure) in try await Upload(image: raw) }
    }

    func uploadPromises(_ receivers: [NSFilePromiseReceiver], to pane: PaneView) {
        prepareUpload(to: pane) { id throws(Failure) in try await Upload.promised(receivers, id: id) }
    }

    private func prepareUpload(to pane: PaneView, _ prepare: @escaping @MainActor (String) async throws(Failure) -> Upload) {
        guard !pane.disposed, pane.acceptingInput, admitsUpload() else { return }
        let id = UUID().uuidString.lowercased(), generation = generation
        uploads[id] = (pane, Task { [weak self] in
            let planned: Result<Upload, Failure>
            do throws(Failure) { planned = .success(try await prepare(id)) } catch { planned = .failure(error) }
            guard let self, accepts(generation), uploads.removeValue(forKey: id) != nil, !pane.disposed, pane.acceptingInput else { return }
            upload(planned, to: pane)
        })
    }

    private func admitsUpload() -> Bool {
        guard uploads.count >= 2 else { return true }
        notice("Kido did not upload", "An upload is running. Wait for it to finish, or press Escape in its pane to cancel it.")
        return false
    }

    private func releaseUploadPrompt() {
        guard let alert = uploadPrompt else { return }
        uploadPrompt = nil
        Self.clipboardConsent.askingHosts.remove("upload " + host.clipboardKey)
        cancelClipboardAlert(alert)
    }

    private func transfer(_ plan: Upload, base: String, to pane: PaneView, over recorded: [String]? = nil) {
        let id = UUID().uuidString.lowercased(), generation = generation, drain = drain, arguments = plan.arguments(base: base, id: id)
        let label = recorded?.last ?? host.label
        let launch: Launch? = if let recorded { SSH.recorded(recorded, arguments) }
            else if host == .local { Launch(arguments[0], Array(arguments.dropFirst()), environment: tools.environment) } else { ssh?.upload(arguments) }
        guard let launch else { return notice("Kido did not upload", "\(host.label) is not connected.") }
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result: Result<(status: Int32, out: String, err: String), Failure>
            do throws(Failure) { result = .success(try await Child.run(launch, deadline: 60 + Double(plan.size >> 20), drain: drain, input: plan.send)) }
            catch { result = .failure(error) }
            guard let self, accepts(generation), uploads.removeValue(forKey: id) != nil else { return }
            switch result {
            case .failure(let error): notice("Upload to \(label) failed", error.message)
            case .success(let run) where run.status != 0 || !(base.isEmpty ? run.out.hasPrefix("/") && run.out.hasSuffix("/drops/" + id) : run.out == base + "/drops/" + id):
                notice("Upload to \(label) failed", run.err.isEmpty ? "The upload exited \(run.status)." : run.err)
            case .success(let run): insert(plan.sources.map { run.out + "/" + $0.name }, into: pane)
            }
        }
        uploads[id] = (pane, task)
    }

    func uploading(_ pane: PaneView) -> Bool { uploads.values.contains { $0.pane === pane } }

    func cancelUploads(_ pane: PaneView) -> Bool {
        let running = uploads.filter { $0.value.pane === pane }
        running.forEach { uploads[$0.key] = nil; $0.value.task.cancel() }
        Upload.cancelPromises(Array(running.keys))
        return !running.isEmpty
    }

    private func insert(_ paths: [String], into pane: PaneView) {
        guard let text = Upload.text(paths) else {
            return notice("Kido did not paste the path", "A path contains control characters. The files are in \(paths.first.map { ($0 as NSString).deletingLastPathComponent } ?? "").")
        }
        guard !pane.disposed, pane.acceptingInput else { return notice("The pane closed before the upload finished", text) }
        guard pane.copyMode == nil else { return notice("Kido did not paste the path", text) }
        pane.paste(text)
    }

    private func notice(_ title: String, _ detail: String) {
        note("\(host.label): \(title): \(detail)")
        guard alive, preparedAlert == nil, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        prepareAlert(alert) { _ in }
    }

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
        view.reorder = reorder
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
            connection.closePane = { [weak self] pane in
                guard let self, accepts(generation) else { return }
                let name = sidebarRows(snapshot).first { $0.target?.pane == pane }?.title ?? pane.description
                confirmClose(.pane(pane), name: name)
            }
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
                openLink(text)
            }
            link = .connected(connection, endpoint, backoff)
            Notifier.shared.connected()
            session?.close()
            session = view
            feedFresh = true
            feed = Feed(
                serverDir: endpoint.directory, locate: connection.locateFeed, drain: drain,
                prepare: { [transport = ssh] args in transport?.launch([endpoint.kido] + args) ?? Launch(endpoint.kido, args, environment: tools.environment) },
                onChange: { [weak self] status in
                    guard let self, accepts(generation) else { return }
                    if case .invalidBundle(let error) = status { return self.bundleChanged(error) }
                    if case .protocolMismatch(let stamp, let expected, let binary) = status {
                        return self.protocolMismatch(Endpoint(server: Server(tmux: server.tmux, socket: server.socket, stamp: stamp, expected: expected ?? server.expected, binaryProtocol: binary), kido: endpoint.kido))
                    }
                    self.received(status)
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

    private func received(_ status: Feed.Status) {
        switch status {
        case .starting, .restarting: feedFresh = true
        case .running(let snapshot):
            self.snapshot = snapshot
            reorder.state.observe(snapshot)
            endHold()
            _ = observeSeen()
            Notifier.shared.update(host: host, snapshotOwner: self)
            snapshotReceived()
        default: break
        }
        if case .running(let snapshot) = status {
            let projected = reorder.state.project(snapshot)
            sidebar.list.update(.running(projected))
            updateTabs(projected)
        } else { sidebar.list.update(status) }
        ready()
    }

    #if KIDO_VISUAL || KIDO_STRESS
    var stressState: (SessionModel, SessionModel, SessionView?, Connection?, Snapshot?) {
        if case .connected(let connection, _, _) = link { return (model, navigationModel, session, connection, snapshot) }
        return (model, navigationModel, session, nil, snapshot)
    }
    #endif

    private func updateTabs(_ projected: Snapshot?? = nil) {
        let next = model.navigation(projected ?? snapshot.map(reorder.state.project), activePanes: session?.windows.compactMapValues(\.active) ?? [:], seen: seen.value)
        if sidebar.tabs.entries != next.tabs { sidebar.tabs.entries = next.tabs }
        sidebar.tabs.scope = next.model.session.map { .init(session: $0, generation: generation, instance: snapshot?.serverInstance) }
        if navigationModel != next.model {
            navigationModel = next.model
            menuChanged()
        }
    }

    private func changed(_ view: SessionView, _ model: SessionModel) {
        controlModel = model
        present(view)
    }

    private func present(_ view: SessionView) {
        if let held, !holds(held) { self.held = nil }
        let model = model
        window.title = host == .local ? model.title : "\(identity ?? host.label) / \(model.title)"
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
        endHold()
    }

    func confirmClose(_ target: CloseTarget, name: String) {
        guard preparedAlert == nil, window.attachedSheet == nil else { return }
        supersedeIntent()
        let generation = generation
        let command: Command = switch target {
        case .pane(let id): Command("kill-pane", "-t", id)
        case .window(let id): Command("kill-window", "-t", id)
        }
        let scope = closeScope(snapshot, target: target)
        let commands = scope.descendants.map { Command("kill-window", "-t", $0) } + [command]
        let close = { [weak self] in
            guard let self, accepts(generation) else { return }
            send(commands) { [weak self] replies in
                guard let failure = replies?.compactMap({ reply -> String? in
                    if case .failure(let lines) = reply { return lines.joined(separator: "\n") }; return nil
                }).first, let self else { return }
                let alert = NSAlert()
                alert.messageText = "Pane command failed"
                alert.informativeText = failure
                prepareAlert(alert) { _ in }
            }
        }
        guard scope.running else { close(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(name)”?"
        alert.informativeText = switch target {
        case .pane: "A process is still running in this pane. Closing the pane will end it."
        case .window: "Processes are still running in this window. Closing the window will end them."
        }
        alert.addButton(withTitle: "Close").keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        prepareAlert(alert) { response in if response == .alertFirstButtonReturn { close() } }
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
                sidebar.list.leave()
            case .success(.switched(let target)):
                guard let target else { return }
                focusTarget = .window(target.session, target.window)
                sidebar.list.leave()
            case .success(.released): sidebar.list.leave()
            default: break
            }
        }
        self.request(request, done)
    }

    private func submit(_ move: ReorderMove) {
        guard let snapshot, let token = reorder.state.submit(move, to: snapshot) else {
            let reason = snapshot == nil ? "no snapshot" : reorder.state.pending != nil ? "another reorder is pending"
                : snapshot?.reordered(move) == nil ? "stale ids" : "no change"
            return debug("reorder \(move) not sent: \(reason)")
        }
        debug("reorder \(move) sent")
        supersedeIntent()
        if case .window(let session, _, _, _) = move, session == model.session, let current = model.window {
            held = Hold(token: token, intent: intent, generation: generation, instance: snapshot.serverInstance, session: session, window: current)
        }
        sidebar.list.failed(nil)
        showOrder()
        DispatchQueue.main.asyncAfter(deadline: .now() + (host == .local ? 2 : 5)) { [weak self] in
            self?.endHold(token)
            if self?.reorder.state.pending?.token == token { debug("reorder \(move) timed out") }
            self?.settleOrder { $0.expire(token) }
        }
        request(.reorder(move)) { [weak self] result in
            // The reply travels on the feed; the move's own window-change notifications travel on the control
            // stream. A control round trip after the reply proves those notifications were consumed.
            if let self, let held, held.token == token, holds(held) { send([Command("display-message", "-p", "")]) { [weak self] _ in self?.endHold(token) } }
            let error: String? = if case .failure(let error) = result { error.message } else { nil }
            debug("reorder \(move) reply \(error ?? "reordered")")
            self?.settleOrder { $0.complete(token, error: error) }
        }
    }

    private func holds(_ held: Hold) -> Bool {
        held.intent == intent && held.generation == generation && held.instance == snapshot?.serverInstance
            && controlModel.session == held.session && controlModel.windows.contains { $0.id == held.window }
    }

    private func endHold(_ token: Int? = nil) {
        guard let held, held.token == token || !holds(held) else { return }
        self.held = nil
        if let session { present(session) }
    }

    private func settleOrder(_ change: (inout ReorderState) -> String?) {
        let before = reorder.state
        let error = change(&reorder.state)
        guard reorder.state != before else { return }
        if let error { sidebar.list.failed(error) }
        showOrder()
    }

    private func showOrder() {
        let projected = snapshot.map(reorder.state.project)
        sidebar.list.show(projected)
        sidebar.tabs.animated { updateTabs(projected) }
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
        clipboardPermission = [:]
        uploadPermission = .ask
        uploads.values.forEach { $0.task.cancel() }
        Upload.cancelPromises(Array(uploads.keys))
        uploads = [:]
        releaseUploadPrompt()
        preparedAlert = nil
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
        task?.cancel()
        task = nil
        initial?.cancel()
        initial = nil
        if case .redialing(let work, _, _) = link { work.cancel() }
        reorder.state.reset()
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
            controlModel = SessionModel()
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
        Notifier.shared.forget(self)
        invalidate(cause: .windowClosed)
        link = .down
        sidebar.dismissFloating()
        window.delegate = nil
        onClose()
    }
    func windowDidBecomeKey(_ notification: Notification) { supersedeIntent(); menuChanged(); attend() }
    func windowDidResignKey(_ notification: Notification) { supersedeIntent(); attend() }
    func windowDidMiniaturize(_ notification: Notification) { attend() }
    func windowDidDeminiaturize(_ notification: Notification) { attend() }
    func windowDidChangeOcclusionState(_ notification: Notification) { presentAlert(); attend() }
    func updateColorScheme() { session?.updateColorScheme() }
    var navigation: SessionModel { navigationModel }

    #if KIDO_VISUAL || KIDO_STRESS
    var testRemoteEnvironment: [String: String]?
    var testSSHConfiguration: String?
    var testIdentity: String { identity ?? host.label }
    var testEndpoint: Endpoint?
    var testUploadBase: String?
    var testBanner: Banner { banner }
    var testSession: SessionView? { session }
    var testConnection: Connection? { if case .connected(let connection, _, _) = link { connection } else { nil } }
    var testAttended: Bool? { didSet { attend() } }
    func testReceive(_ snapshot: Snapshot) { received(.running(snapshot)) }
    #endif
}
