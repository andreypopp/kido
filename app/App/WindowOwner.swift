import AppKit
import KoClient
import KoModel
import PaneGeometry
import SidebarFeed

extension NSScreen {
    var displayID: UInt32? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}

class OwnerWindow: NSWindow {
    var allowsPaneInput: Bool { isKeyWindow || (NSApp.delegate as? AppDelegate)?.palettePanel == nil }
    override func sendEvent(_ event: NSEvent) {
        if !allowsPaneInput, [.keyDown, .keyUp, .flagsChanged].contains(event.type) { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        allowsPaneInput && super.performKeyEquivalent(with: event)
    }

    var focusChanged: (NSResponder?, NSResponder?) -> Void = { _, _ in }
    private(set) var isInputWindow = true
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didBecomeKeyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didResignKeyNotification, object: self)
    }
    @objc private func keyChanged(_ note: Notification) {
        isInputWindow = note.name == NSWindow.didBecomeKeyNotification
        focusChanged(firstResponder, firstResponder)
    }
    private var nested = 0
    // Ending a field editor's session first makes the window itself first
    // responder, through this method.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let old = firstResponder, owner = PaneView.owner(old)
        nested += 1
        let accepted = super.makeFirstResponder(responder)
        nested -= 1
        guard accepted, old !== firstResponder else { return accepted }
        if nested == 0, let owner, owner !== PaneView.owner(firstResponder) { owner.endCopy() }
        focusChanged(old, firstResponder)
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
    #if KIDO_VISUAL
    static var welcomeTimeout: TimeInterval = 20
    static var visualPreparedUploads = 0
    #else
    static let welcomeTimeout: TimeInterval = 20
    #endif
    let runtime: GhosttyRuntime
    let host: Host
    private let preferences: UserDefaults?
    private var frames: WindowFrames { WindowFrames(preferences: preferences, serverDir: serverDir) }
    private var frameSave: DispatchWorkItem?
    private var changingFullScreen = false
    let ownerID = String(UUID().uuidString.prefix(8))
    let notificationID = UUID().uuidString
    var feedFresh = true
    enum DialCause {
        case launch, newWindow, newSession, reopen, remoteRequest, reconnect, serverRestart
        var label: String {
            switch self {
            case .launch: "launch"
            case .newWindow: "new window"
            case .newSession: "new session"
            case .reopen: "reopen"
            case .remoteRequest: "remote request"
            case .reconnect: "reconnect"
            case .serverRestart: "server restart"
            }
        }
    }
    let ended = DispatchGroup()
    private(set) var alive = true
    private(set) var generation = 0
    private var task: Task<Void, Never>?
    private var recovering: Task<Void, Never>?
    private var attachStart: ContinuousClock.Instant?
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
    // What `receive` makes of the core's model, set in one place.
    private struct Received {
        var ko: KoModel?
        var model = SessionModel()
        var snapshot: Snapshot?
    }
    private var received = Received()
    private var model: SessionModel { received.model }
    private var koModel: KoModel? { received.ko }
    var snapshot: Snapshot? { received.snapshot }
    private var editor: LayoutEditor?
    private var welcomed = false
    private var selectedFirst = false
    private var receiving = false
    private var needsRestart: Bool {
        switch link {
        case .mismatch, .refused: true
        default: false
        }
    }
    var canNavigate: Bool { alive && !needsRestart && snapshot != nil }
    private var pendingNewSession = false
    private var pendingInitialSession = false
    private var navigationModel = SessionModel()
    private enum Target { case pane(Snapshot.Position), window(SessionID, WindowID) }
    private var focusTarget: Target?
    private var intent = 0
    private var activating: Int?
    private var awaitingSelect = false
    private(set) var preparedAlert: (alert: NSAlert, respond: (NSApplication.ModalResponse) -> Void)?

    private static let localServerRestarted = Notification.Name("KidoLocalServerRestarted")

    var attended: Bool {
        var attended = NSApp.isActive && window.isKeyWindow && !window.isMiniaturized && window.occlusionState.contains(.visible)
        #if KIDO_VISUAL || KIDO_STRESS
        attended = testAttended ?? attended
        #endif
        return attended
    }

    var shownPanes: [PaneID] {
        (session?.windows.values.first { !$0.isHidden }?.panes ?? []).filter { !$0.isHidden }.map(\.pane)
    }

    private var presentedPanes: [PaneID] = []
    private var observed: Notifier.Seen?

    // The server's focus: the window is key in the active app and a pane of the shown window has
    // the keyboard. The sidebar, a palette and a sheet take it away.
    private var reportedFocus: Bool?
    private func reportFocus() {
        guard case .connected(let client) = link else { return }
        let pane = window.firstResponder.flatMap(PaneView.owner)
        let focused = NSApp.isActive && window.isKeyWindow && window.attachedSheet == nil
            && pane.map { view in session?.windows.values.contains { !$0.isHidden && view.isDescendant(of: $0) } == true } == true
        guard focused != reportedFocus else { return }
        reportedFocus = focused
        try? client.focus(focused)
    }

    @objc private func attend() {
        reportFocus()
        Notifier.shared.observeSeen(host: host)
        Notifier.shared.update(host: host)
    }

    // Tells the core what the attended windows of the host show, when that changed.
    func observeSeen() {
        guard case .connected(let client) = link else { return }
        let seen = Notifier.shared.seen(host: host)
        guard seen != observed else { return }
        observed = seen
        try? client.observe(seen.shown, attending: seen.attending)
    }

    @objc private func localServerRestarted(_ notification: Notification) {
        guard alive, host == .local, needsRestart, notification.object as? String == serverDir else { return }
        begin(.serverRestart)
    }

    private enum Link {
        case down
        case refused
        case starting
        case mismatch(code: ko_code, server: KoVersion, own: KoVersion)
        case changed
        case connected(KoClient)
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

    init(host: Host, runtime: GhosttyRuntime, start: Bool = true, cause: DialCause = .launch, preferences: UserDefaults? = background ? nil : .standard, openBrowser: @escaping (URL) -> Void = { if !background { NSWorkspace.shared.open($0) } }) {
        self.preferences = preferences
        self.openBrowser = openBrowser
        self.host = host
        if case .newSession = cause { pendingNewSession = true }
        self.runtime = runtime
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(localServerRestarted(_:)), name: Self.localServerRestarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(attend), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(attend), name: NSApplication.didResignActiveNotification, object: nil)
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
        sidebar.list.navigate = { [weak self] in self?.perform($0) }
        sidebar.list.onIntent = { [weak self] in self?.supersedeIntent() }
        sidebar.list.commandTarget = { [weak self] in self?.session?.activePane }
        sidebar.list.newSession = { [weak self] in self?.newSession() }
        sidebar.list.newWindow = { [weak self] session in self?.newWindow(in: session) }
        sidebar.list.renameSession = { [weak self] id, name, done in
            guard let self else { return done("The client is not ready.") }
            renameSession(id, name, done: done)
        }
        sidebar.list.reorder = reorder
        sidebar.tabs.reorder = reorder
        sidebar.list.move = { [weak self] in self?.submit($0) }
        sidebar.tabs.move = sidebar.list.move
        sidebar.tabs.select = { [weak self] in self?.selectWindow($0) }
        sidebar.tabs.close = { [weak self] tab in self?.confirmClose(.window(tab.id), name: tab.name) }
        sidebar.tabs.addWindow.invoke = { [weak self] in self?.newWindow() }
        sidebar.list.closePane = { [weak self] row in
            guard let pane = row.target?.pane else { return }
            self?.confirmClose(.pane(pane), name: row.title)
        }
        sidebar.focusTerminal = { [weak self] in self?.focusSelected() }
        (window as? OwnerWindow)?.focusChanged = { [weak self] old, next in
            guard let self else { return }
            sidebar.updateFocusEdge()
            session?.windows.values.filter { !$0.isHidden }.forEach { $0.updateFocusTreatment() }
            reportFocus()
            if old === next { return }
            if let pane = next as? PaneView, model.window.flatMap({ session?.windows[$0]?.active }) == pane.pane,
               old == nil || old is PaneView || old === window { return }
            supersedeIntent()
        }
        banner = Banner(background: runtime.background, target: self, action: #selector(WindowOwner.start))
        banner.frame = sidebar.content.bounds
        sidebar.content.addSubview(banner)
        sidebar.configBanner.reveal = { [weak self] in
            guard let error = self?.runtime.configError else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: error.path)])
        }
        window.center()
        if let main = NSScreen.main?.visibleFrame {
            let open = NSApp.windows.compactMap { other -> CGRect? in
                guard let owner = other.delegate as? WindowOwner, owner !== self,
                      owner.alive, owner.host == host,
                      !other.styleMask.contains(.fullScreen), !other.isMiniaturized else { return nil }
                return other.frame
            }
            window.setFrame(WindowFrames.place(saved: frames.frame(for: host), centered: window.frame,
                                               screens: NSScreen.screens.map(\.visibleFrame), main: main, open: open), display: false)
        }
        if !background {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        menuChanged()
        if start { begin(cause) }
    }

    func updateAppearance() {
        let background = runtime.background
        window.backgroundColor = runtime.unfocusedPaper
        sidebar.terminalHost.wantsLayer = true
        sidebar.terminalHost.layer?.backgroundColor = runtime.unfocusedPaper.cgColor
        sidebar.content.wantsLayer = true
        sidebar.content.layer?.backgroundColor = background.cgColor
        banner?.background = background
        sidebar.configBanner.background = background
        let dark = background.isDark
        let theme = (background: background, appearance: NSAppearance(named: dark ? .darkAqua : .aqua))
        window.appearance = theme.appearance
        sidebar.updateAppearance(runtime: runtime)
        session?.updateBackground()
        showConfigError()
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposedOptions.subtracting(.autoHideToolbar)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        saveFrame()
        changingFullScreen = true
    }
    func windowWillExitFullScreen(_ notification: Notification) { changingFullScreen = true }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { changingFullScreen = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { changingFullScreen = false }
    func windowWillMiniaturize(_ notification: Notification) { saveFrame() }
    func windowDidEnterFullScreen(_ notification: Notification) { changingFullScreen = false; updateAppearance() }
    func windowDidExitFullScreen(_ notification: Notification) { changingFullScreen = false; updateAppearance() }

    private func saveFrame() {
        frameSave?.cancel()
        frameSave = nil
        guard alive, !changingFullScreen, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        frames.save(window.frame, for: host)
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }

    private func scheduleFrameSave() {
        frameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrame() }
        frameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func down(_ title: String, _ detail: String, button: String?, action: Selector = #selector(WindowOwner.start)) {
        guard alive else { return }
        sidebar.list.leave()
        sidebar.showConfigError(nil)
        banner.show(title, detail, button: button, action: action)
        sidebar.list.offline(title)
    }

    func showConfigError() {
        guard welcomed, case .connected = link, preparedAlert == nil else { return }
        sidebar.showConfigError(runtime.configError.map { (runtime.abbreviate($0.path) + " has an error", $0.problem.detail) })
    }

    @objc func start() {
        guard case .connected = link else { return begin(.reconnect) }
        if welcomed, koModel?.layout.layout.sessions.isEmpty == true { return newSession() }
        guard host == .local else {
            invalidate()
            link = .down
            return connect(cause: .reconnect)
        }
        startServer()
    }

    private func startServer() {
        let generation = generation
        down("Starting the ko server…", "", button: nil)
        task = Task {
            guard accepts(generation) else { return }
            do throws(Failure) {
                _ = try await KoServer.launch(dir: serverDir)
                guard accepts(generation), !welcomed else { return }
                down("Disconnected from \(host.label)", "Reconnecting…", button: "Start")
            } catch {
                guard accepts(generation), !welcomed else { return }
                down("Could not start the ko server", error.message, button: "Start")
            }
        }
    }

    private var serverDir: String {
        #if KIDO_VISUAL || KIDO_STRESS
        if let testServerDir { return testServerDir }
        #endif
        return tools.serverDir
    }

    private func begin(_ cause: DialCause) {
        guard alive else { return }
        switch link {
        case .starting, .connected, .changed: return
        case .mismatch, .refused, .down: break
        }
        invalidate(keepingSnapshot: needsRestart)
        connect(cause: cause)
    }

    private func markAttach(_ step: String) {
        guard Timing.enabled, let start = attachStart else { return }
        Timing.emit(["t": "attach", "host": host.label, "step": step, "ms": Timing.milliseconds(since: start)])
        if step == "first-layout" { attachStart = nil }
    }

    private func connect(cause: DialCause) {
        attachStart = .now
        let generation = generation
        link = .starting
        down("Connecting to \(host.label)…", "", button: nil)
        if case .remote(let alias) = host { return connectRemote(alias, cause: cause) }
        task = Task { [self] in
            guard accepts(generation) else { return }
            do throws(Failure) {
                let socket = try await KoServer.launch(dir: serverDir)
                guard accepts(generation) else { return }
                dial(socket, cause: cause)
            } catch {
                guard accepts(generation) else { return }
                link = .down
                down("Kido could not start the ko server", error.message, button: "Start")
            }
        }
    }

    private func connectRemote(_ alias: String, cause: DialCause) {
        let generation = generation
        task = Task { [self] in
            let session: SSH
            do throws(Failure) { session = try SSH(alias) } catch { return remoteFailed(.ssh(error)) }
            ssh = session
            session.mark = { [weak self] step in self?.markAttach(step) }
            #if KIDO_VISUAL || KIDO_STRESS
            session.testConfiguration = ProcessInfo.processInfo.environment["KIDO_APP_SSH_CONFIG"]
            testSSH?(session)
            #endif
            let closing = Drain()
            drain = closing
            do throws(RemoteFailure) {
                let opened = try await session.open(drain: closing) { [weak self] failure in self?.masterLost(failure, generation: generation) }
                guard accepts(generation) else { return }
                identity = opened.identity
                dial(opened.socket, cause: cause)
            } catch {
                guard accepts(generation) else { return }
                remoteFailed(error)
            }
        }
    }

    private func remoteFailed(_ failure: RemoteFailure) {
        if case .mismatch(let code, let server) = failure { return protocolMismatch(code: code, server: server, own: KoClient.version) }
        link = .down
        let text = failure.banner(host.label)
        down(text.title, text.detail, button: "Reconnect")
    }

    private func masterLost(_ failure: Failure, generation: Int) {
        guard accepts(generation), recovering == nil, case .connected = link, let ssh, let drain else { return }
        var detail = failure.message
        recovering = Task { [self] in
            var delay: TimeInterval = 1
            while accepts(generation), !Task.isCancelled {
                down("Disconnected from \(host.label)", detail + "\nReconnecting…", button: "Reconnect")
                do throws(Failure) {
                    try await ssh.recover(drain: drain)
                    guard accepts(generation) else { return }
                    if ssh.master?.process.isRunning == true { return recovering = nil }
                    detail = "The SSH connection to \(host.label) ended again."
                } catch {
                    guard accepts(generation) else { return }
                    detail = error.message
                    if case .terminal = error {
                        invalidate()
                        link = .down
                        return down("Kido could not reach \(host.label)", error.message, button: "Reconnect")
                    }
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    static let restartTitle = "Restart Server"
    static let restartWarning = "Restarting ends all sessions and panes on this local ko server. Running commands and agents will stop. Other clients attached to this server will disconnect."

    static func mismatchAlert(host: Host, code: ko_code, server: KoVersion, own: KoVersion, serverDir: String) -> NSAlert {
        let alert = NSAlert()
        let local = host == .local
        let builds = "The server is build \(server.build); this app is build \(own.build)."
        let command = "ko kill-server" + (local ? " --server '\(serverDir.replacingOccurrences(of: "'", with: "'\"'\"'"))'" : "")
        let protocols = "This app speaks ko protocol \(own.protocolVersion). The server speaks \(server.protocolVersion)."
        let revisions = "This app runs terminal revision \(own.vt.prefix(9)); the server runs \(server.vt.prefix(9))."
        if local {
            let detail = code == KO_ERR_PROTOCOL_MISMATCH ? protocols : "This app runs terminal revision \(own.vt.prefix(9)). The server runs \(server.vt.prefix(9))."
            alert.messageText = "Restart the local ko server"
            alert.informativeText = "The running server is a different version and must be restarted to upgrade. \(detail) \(builds)"
                + "\n\n" + restartWarning
        } else if code == KO_ERR_PROTOCOL_MISMATCH, let major = server.major, let ours = own.major, major > ours {
            alert.messageText = "Update Kido.app to connect to \(host.label)"
            alert.informativeText = "The server speaks ko protocol \(server.protocolVersion); this app speaks \(own.protocolVersion). Update Kido.app on this Mac. \(builds)"
        } else if code == KO_ERR_PROTOCOL_MISMATCH {
            alert.messageText = "Update ko on \(host.label)"
            alert.informativeText = "\(protocols) Update ko on the host, then reconnect. \(builds)"
        } else {
            alert.messageText = "Kido.app and ko on \(host.label) are from different releases"
            alert.informativeText = "\(revisions) Install the ko release of this Kido.app on the host, or update Kido.app. \(builds)"
        }
        if !local {
            alert.informativeText += "\n\nOn \(host.label), stop the server with the command below, then run ko server. All sessions and panes on that server will end."
        }
        alert.addButton(withTitle: local ? restartTitle : "Reconnect").hasDestructiveAction = local
        alert.addButton(withTitle: "Close").keyEquivalent = "\u{1b}"
        alert.buttons[0].keyEquivalent = ""
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        alert.window.initialFirstResponder = alert.buttons[1]
        let escape = AlertEscape()
        escape.button = alert.buttons[1]
        let field = NSTextField(wrappingLabelWithString: command)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.preferredMaxLayoutWidth = 420
        escape.frame = NSRect(x: 0, y: 0, width: 420, height: field.fittingSize.height)
        field.frame = escape.bounds
        field.autoresizingMask = [.width, .height]
        escape.addSubview(field)
        alert.accessoryView = escape
        return alert
    }

    private func protocolMismatch(code: ko_code, server: KoVersion, own: KoVersion) {
        invalidate(keepingSnapshot: true)
        link = .mismatch(code: code, server: server, own: own)
        down("Disconnected from \(host.label)", "", button: "Reconnect")
        let alert = Self.mismatchAlert(host: host, code: code, server: server, own: own, serverDir: serverDir)
        let generation = generation
        prepareAlert(alert) { [weak self] response in
            guard let self, accepts(generation) else { return }
            guard response == .alertFirstButtonReturn else { banner.isHidden = false; return }
            if host != .local { return start() }
            restartServer()
        }
    }

    @objc func restartServer() {
        guard host == .local else { return }
        invalidate(keepingSnapshot: true)
        link = .starting
        down("Restarting the ko server…", "", button: nil)
        let generation = generation
        task = Task {
            do throws(Failure) {
                try await KoServer.stop(dir: serverDir)
                guard accepts(generation) else { return }
                NotificationCenter.default.post(name: Self.localServerRestarted, object: serverDir)
                link = .down
                begin(.serverRestart)
            } catch {
                guard accepts(generation) else { return }
                link = .down
                down("Could not restart the ko server", error.message, button: "Reconnect")
            }
        }
    }

    func refused(_ message: String) {
        invalidate(keepingSnapshot: true)
        link = .refused
        down("The ko server refused the connection", message + (host == .local ? "\n\n" + Self.restartWarning : ""), button: host == .local ? Self.restartTitle : "Reconnect", action: host == .local ? #selector(restartServer) : #selector(start))
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
              Self.clipboardConsent.askingHosts.insert("read " + host.clipboardKey).inserted else { return pane.finishClipboard(false) }
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
        Self.clipboardConsent.askingHosts.remove("read " + host.clipboardKey)
        cancelClipboardAlert(prompt.alert)
    }

    func writeClipboard(_ contents: [KoClipboardContent]) {
        guard runtime.clipboard.write == .allow, let items = PasteboardMIME.items(contents),
              !items.isEmpty else { return }
        _ = runtime.store(items)
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
        if case .connected = link { return "" }
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
        askUpload(plan, to: host.label, "Kido copies them to \(base.isEmpty ? "~/.local/state/\(Upload.stateName)" : base)/drops on \(identity ?? host.label) and pastes their paths. Files are kept for about 7 days.",
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
        let refusal = confirmed == nil ? "Kido can't tell where this ssh session connects; nothing was uploaded."
            : "The ssh session in this pane changed after you confirmed; nothing was uploaded."
        guard case .array(let values)? = koModel?.pane(pane.pane)?.vars["ssh.args"] else {
            return notice("Kido did not upload", refusal)
        }
        let recorded: [String] = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
        guard let target = recorded.last, sshDestination(pane) == destination else { return notice("Kido did not upload", refusal) }
        guard let confirmed else {
            return askUpload(plan, to: target, "The program in this pane runs over ssh on \(target) (\(destination)). Nested ssh sessions are not detected.",
                             ["Upload", "Cancel"]) { [weak self, weak pane] response in
                guard let self, response == .alertFirstButtonReturn, let pane else { return }
                uploadOverSSH(plan, destination, to: pane, confirmed: recorded)
            }
        }
        guard recorded == confirmed else { return notice("Kido did not upload", refusal) }
        var base = ""
        #if KIDO_VISUAL || KIDO_STRESS
        base = testUploadBase ?? ""
        #endif
        transfer(plan, base: base, to: pane, over: recorded)
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
            #if KIDO_VISUAL
            defer { WindowOwner.visualPreparedUploads += 1 }
            #endif
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
            let result: Result<Child.Finished, Failure>
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
        invalidate()
        link = .changed
        down("Relaunch Kido.app", error.message, button: nil)
    }

    private func dial(_ socket: String, cause: DialCause) {
        let generation = generation
        do throws(Failure) { try tools.validate() } catch { return bundleChanged(error) }
        note("dialing \(socket) (\(cause.label.replacingOccurrences(of: "\n", with: "; "))) [owner \(ownerID)]")
        let view = makeSessionView()
        do {
            let hello = KoHello(name: ownerID, sizesWindows: true)
            let client = try KoClient(socket: socket, hello: hello, fetches: host.imageFetches) { [weak self] event in
                guard let self, accepts(generation) else { return }
                handle(event)
            }
            link = .connected(client)
            reportedFocus = nil
            view.client = client
            makeEditor { try client.edit($0) }
            observed = nil
            Notifier.shared.connected()
            session?.close()
            session = view
            welcomed = false
            selectedFirst = false
            feedFresh = true
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, accepts(generation) else { return }
                failed("The ko server did not welcome the app within \(Int(Self.welcomeTimeout)) seconds")
            }
            initial = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.welcomeTimeout, execute: timeout)
        } catch {
            note("could not connect to \(socket): \(error)")
            link = .down
            down("Kido could not reach \(host.label)", "\(error)", button: host == .local ? "Start" : "Reconnect")
        }
    }

    private func makeSessionView() -> SessionView {
        let generation = generation
        let view = SessionView(runtime: runtime)
        view.host = host
        if case .connected(let client) = link { view.client = client }
        view.sidebarFocused = { [weak sidebar] in sidebar?.list.containsFocus == true }
        view.reorder = reorder
        view.edit = { [weak self] edit, key in self?.editor?.submit(edit, key: key) }
        view.editing = { [weak self] in self?.editor?.holding == true }
        view.selectPane = { [weak self] pane in
            guard let self, accepts(generation), case .connected(let client) = link else { return }
            try? client.select(KO_SELECT_PANE, pane)
        }
        view.paneCommand = { [weak self] command, pane in
            guard let self, accepts(generation) else { return }
            paneCommand(command, pane)
        }
        view.sizeClient = { [weak self] cols, rows, cell in
            guard let self, accepts(generation), case .connected(let client) = link else { return }
            debug("client-size-send \(cols)x\(rows)")
            try? client.size(cols: cols, rows: rows, cell: cell)
        }
        view.canPrompt = { [weak self] in self?.canPrompt == true }
        view.onPrompt = { [weak self] pane, quote in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.openPrompt(owner: self, pane: pane, quote: quote)
        }
        view.onPaneChange = { [weak self] in
            guard let self, accepts(generation) else { return }
            updateTabs()
            if focusTarget != nil { focusSelected() }
        }
        view.frame = sidebar.content.bounds
        view.autoresizingMask = [.width, .height]
        return view
    }

    private func failed(_ message: String) {
        guard alive else { return }
        invalidate()
        link = .down
        down("Kido could not reach \(host.label)", message, button: "Start")
    }

    private func handle(_ event: KoEvent) {
        guard case .connected = link else { return }
        switch event {
        case .welcome(let id, let fresh):
            #if KIDO_STRESS
            note("stress client \(id)")
            #endif
            initial?.cancel()
            initial = nil
            if fresh {
                pendingInitialSession = host == .local
                feedFresh = true
                selectedFirst = false
                // The new server's revisions start again, so an edit held for the old one never settles.
                if let editor { makeEditor(editor.perform) }
                reorder.state.reset()
                if welcomed { resetSession() }
            }
            welcomed = true
            markAttach("welcome")
            ready()
            if !fresh { session?.retryImages() }
            observeSeen()
        case .layout(let revision):
            receiveSoon()
            editor?.layoutChanged(revision: Int(revision))
        case .model:
            receiveSoon()
        case .selected(let session, let window, let pane):
            receiveSoon()
            guard awaitingSelect else { return }
            awaitingSelect = false
            if let session, let window {
                focusTarget = pane.map { .pane(.init(session: session, window: window, pane: $0)) } ?? .window(session, window)
                activating = nil
                sidebar.list.leave()
            }
        case .failed(let code, let message):
            if code == KO_ERR_REFUSED { return refused(message) }
            welcomed = false
            guard recovering == nil else { return }
            if host == .local, code == KO_ERR_NO_SERVER { return startServer() }
            down("Disconnected from \(host.label)", (code == KO_ERR_NO_SERVER ? "The connection to \(host.label) is down." : message) + "\nReconnecting…", button: host == .local ? "Start" : "Reconnect")
        case .mismatch(let code, let server, let own):
            protocolMismatch(code: code, server: server, own: own)
        case .clipboardWrite(_, let contents):
            writeClipboard(contents)
        case .clipboardRead(let read):
            guard let pane = session?.pane(read.pane) else {
                if case .connected(let client) = link { client.answerClipboard(id: read.id, contents: nil) }
                return
            }
            pane.receiveClipboardRead(read)
        }
    }

    private func makeEditor(_ perform: @escaping @Sendable (KoSchema.Edit) throws -> KoSchema.Edited) {
        let editor = LayoutEditor(perform: perform)
        editor.onFailure = { [weak self] in self?.sidebar.list.failed($0) }
        editor.onSettled = { [weak self] in
            self?.session?.editsSettled()
            self?.settleOrder { $0.settled(); return nil }
        }
        self.editor = editor
    }

    private func resetSession() {
        let view = makeSessionView()
        session?.close()
        session = view
        received = Received()
        sidebar.list.offline("Connecting…")
        present(view)
    }

    // The model is read once a main-queue turn, after the events of that turn.
    private func receiveSoon() {
        guard !receiving else { return }
        receiving = true
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, receiving else { return }
            receiving = false
            guard accepts(generation), case .connected(let client) = link else { return }
            receive(client)
        }
    }

    private func receive(_ client: KoClient) {
        let ko: KoModel
        do { ko = try client.model() } catch {
            return note("unreadable model: \(error)")
        }
        if ko.selection.session == nil, !selectedFirst, let first = ko.layout.layout.sessions.first {
            selectedFirst = true
            try? client.select(KO_SELECT_SESSION, first.id)
        }
        let model = SessionModel(ko)
        let marks = ko.runtimeMarks
        received = Received(ko: ko, model: model, snapshot: Snapshot(model: ko, marks: marks))
        if pendingInitialSession {
            pendingInitialSession = false
            if ko.layout.layout.sessions.isEmpty && !pendingNewSession {
                create(.ensureSession(.init(name: "session", new: .init(cwd: .absPath(NSHomeDirectory())))))
            }
        }
        if pendingNewSession {
            pendingNewSession = false
            newSession()
        }
        session?.update(model.session.flatMap { ko.layout.layout.session($0) }?.windows ?? [],
                        alive: Set(ko.layout.layout.windows.map(\.id)), selected: ko.selection.pane, marks: marks)
        guard let snapshot else {
            sidebar.list.offline("No sessions")
            if let session { present(session) } else { updateTabs() }
            return down("No sessions", "", button: "Start")
        }
        adopt(snapshot)
        #if KIDO_STRESS
        stressModelReceived?()
        #endif
    }

    private func adopt(_ snapshot: Snapshot) {
        markAttach("first-layout")
        reorder.state.observe(snapshot)
        // The core reads a pane's status after its listing: a live pane without one is not known yet,
        // and the notification baseline waits for it.
        if koModel?.panes.contains(where: { $0.dead == nil && $0.status == nil }) != true {
            Notifier.shared.update(host: host, snapshotOwner: self)
        }
        let projected = reorder.state.project(snapshot)
        sidebar.list.update(projected)
        if let session { present(session, projected: projected) } else { updateTabs(projected) }
        menuChanged()
        snapshotReceived()
    }

    #if KIDO_VISUAL || KIDO_STRESS
    var stressState: (SessionModel, SessionModel, SessionView?, Snapshot?) { (model, navigationModel, session, snapshot) }
    var stressModel: KoModel? { koModel }
    var stressModelReceived: (() -> Void)?
    func stressEdit(_ edit: KoSchema.Edit) { editor?.submit(edit) }
    func stressDelete(_ pane: PaneID) {
        guard case .connected(let client) = link else { return }
        DispatchQueue.global(qos: .utility).async { try? client.delete(KO_DELETE_PANE, pane) }
    }
    #endif

    private func updateTabs(_ projected: Snapshot?? = nil) {
        let next = model.navigation(projected ?? snapshot.map(reorder.state.project), activePanes: session?.windows.compactMapValues(\.active) ?? [:])
        if sidebar.tabs.entries != next.tabs { sidebar.tabs.entries = next.tabs }
        sidebar.tabs.scope = next.model.session.map { .init(session: $0, generation: generation, instance: snapshot?.serverInstance) }
        if navigationModel != next.model {
            navigationModel = next.model
            menuChanged()
        }
    }

    private func present(_ view: SessionView, projected: Snapshot?? = nil) {
        window.title = host == .local ? model.title : "\(identity ?? host.label) / \(model.title)"
        if model.session == nil { received.snapshot = nil }
        updateTabs(projected)
        if view.superview == nil {
            session?.removeFromSuperview()
            session = view
            view.frame = sidebar.content.bounds
            sidebar.content.addSubview(view, positioned: .below, relativeTo: banner)
        }
        view.show(model.window)
        if focusTarget != nil { focusSelected() }
        let shown = shownPanes
        if shown != presentedPanes {
            presentedPanes = shown
            DispatchQueue.main.async { [weak self] in self.map { Notifier.shared.observeSeen(host: $0.host) } }
        }
        ready()
    }

    var canPrompt: Bool {
        guard let session = currentSession else { return false }
        return snapshot?.promptPanes.contains { $0.session == session.id && $0.agent } == true
    }

    func windowName(_ id: WindowID) -> String { session?.windowName(id) ?? id.description }

    func promptDelivered(pane: PaneID) { session?.pane(pane)?.promptDelivered() }

    func promptSource(session: SessionID, window: WindowID, pane: PaneID, quote: String?, preselect: PaneID? = nil) -> PromptSource? {
        guard let snapshot else { return nil }
        return PromptSource(owner: self, instance: snapshot.serverInstance, session: session, window: window, pane: pane,
                            windowName: windowName(window), quote: quote, preselect: preselect)
    }

    // The runtimes that the server offers, and the runtime of the pane in focus.
    var runtimes: [KoSchema.ClientRuntime] {
        #if KIDO_VISUAL
        if let testRuntimes { return testRuntimes.list }
        #endif
        return koModel?.runtimes ?? []
    }

    // The runtime of the pane that this client selected: the host has none.
    var focusedRuntime: String? {
        #if KIDO_VISUAL
        if let testRuntimes { return testRuntimes.focused }
        #endif
        return koModel.flatMap { model in model.current.flatMap { model.pane($0.pane)?.runtime } }
    }

    var currentSession: SessionNodes? {
        snapshot?.sessions.first { $0.id == navigation.session }
    }

    private var currentWindow: (id: WindowID, name: String)? {
        navigation.windows.first { $0.id == navigation.window }.map { ($0.id, $0.name) }
    }

    func closeCurrentWindow() {
        if let window = currentWindow { confirmClose(.window(window.id), name: window.name) }
    }

    func closeCurrentSession() {
        if let session = currentSession { confirmClose(.session(session.id), name: session.name) }
    }

    // An edit that makes a session or a window selects it.
    private func create(_ edit: KoSchema.Edit, done: ((String?) -> Void)? = nil) {
        guard let editor, case .connected(let client) = link else {
            done?("\(host.label) is not connected.")
            return sidebar.list.failed("\(host.label) is not connected.")
        }
        let generation = generation
        editor.submit(edit) { [weak self] result in
            guard let self, accepts(generation) else { return }
            switch result {
            case .success(let edited):
                done?(nil)
                try? client.select(made: edited.created)
            case .failure(let error): done?("\(error)")
            }
        }
    }

    func renameSession(_ id: SessionID, _ name: String, done: @escaping (String?) -> Void) {
        create(.renameSession(KoSchema.EditRenameSession(name: name, session: id)), done: done)
    }

    func createSession(_ name: String, done: @escaping (String?) -> Void) {
        guard let koModel else { return create(.addSession(.init(name: name, new: .init(cwd: .absPath(NSHomeDirectory())))), done: done) }
        create(koModel.newSession(name), done: done)
    }

    @objc func newSession() {
        let names = Set(koModel?.layout.layout.sessions.map(\.name) ?? [])
        let name = (1...).lazy.map { $0 == 1 ? "session" : "session \($0)" }.first { !names.contains($0) }!
        createSession(name) { [weak self] error in if let error { self?.sidebar.list.failed(error) } }
    }

    func newWindow(in target: SessionID? = nil, _ runtime: NewPaneRuntime = .inherit) {
        guard let id = target ?? model.session, let edit = koModel?.newWindow(in: id, after: model.window, runtime) else { return }
        create(edit)
    }

    enum PromptRequest: Equatable {
        case resolve(from: PaneID)
        case send(from: PaneID, to: PaneID, text: String)
    }
    enum PromptReply: Equatable {
        case candidates([KoSchema.Candidate])
        case sent
    }

    // A prompt call of the core, off the main queue; the result arrives on main while this
    // connection lasts.
    func prompt(_ request: PromptRequest, done: @escaping @MainActor (Result<PromptReply, Error>) -> Void) {
        #if KIDO_VISUAL
        if let testPrompt { return testPrompt(request, done) }
        #endif
        guard case .connected(let client) = link else { return done(.failure(KoError(code: KO_ERR_NO_SERVER, detail: "\(host.label) is not connected"))) }
        let generation = generation
        Task {
            let result = await Task.detached { () -> Result<PromptReply, Error> in
                Result {
                    switch request {
                    case .resolve(let caller): return PromptReply.candidates(try client.promptCandidates(from: caller))
                    case .send(let caller, let target, let text):
                        try client.prompt(from: caller, to: target, text)
                        return PromptReply.sent
                    }
                }
            }.value
            if accepts(generation) { done(result) }
        }
    }

    func paneCommand(_ command: PaneCommand, _ pane: PaneID, _ runtime: NewPaneRuntime = .inherit) {
        switch command {
        case .close:
            let name = sidebarRows(snapshot).first { $0.target?.pane == pane }?.title ?? pane.description
            return confirmClose(.pane(pane), name: name)
        case .window(let step): return selectWindow(step)
        case .newWindow: return newWindow(in: nil, runtime)
        default: break
        }
        guard let koModel, let window = koModel.layout.layout.locate(pane)?.window,
              let action = command.action(pane, in: window, new: koModel.newPane(from: pane, runtime), cell: session?.cell ?? .zero) else { return }
        switch action {
        case .edit(let edit):
            editor?.submit(edit) { [weak self] result in
                guard case .success(let edited) = result, let pane = selectedPane(by: edit, edited) else { return }
                self?.session?.selectPane(pane)
            }
        case .select(let target): session?.selectPane(target)
        }
    }

    func selectWindow(_ step: WindowStep) {
        if let navigation = navigationModel.select(step) { perform(navigation) }
    }

    func supersedeIntent() {
        intent += 1
        focusTarget = nil
        awaitingSelect = false
    }

    func canShutDownRuntime(_ name: String) -> Bool {
        guard canNavigate, let runtime = runtimes.first(where: { $0.name == name }) else { return false }
        switch runtime.state { case .starting, .up: return true; case .down, .failed: return false }
    }

    func runtimePaneCount(_ name: String) -> Int {
        koModel?.panes.filter { $0.runtime == name && $0.dead == nil }.count ?? 0
    }

    @objc func shutDownRuntimeItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        shutDownRuntime(name)
    }

    func shutDownRuntime(_ name: String) {
        guard canShutDownRuntime(name) else { return }
        let count = runtimePaneCount(name)
        let warning = count == 1 ? "1 pane runs in this runtime. Shutting it down ends the pane."
            : "\(count) panes run in this runtime. Shutting it down ends them."
        confirmCommand("Shut Down", title: "Shut down “\(name)”?", warning: count > 0 ? warning : nil, failure: "Runtime command failed") {
            try $0.runtimeDown(name)
        }
    }

    func confirmClose(_ target: CloseTarget, name: String) {
        let warning = switch target {
        case .pane: "A program is still running in this pane. Closing the pane will end it."
        case .window: "Programs are still running in this window. Closing the window will end them."
        case .session: "Programs are still running in this session. Closing the session will end them."
        }
        confirmCommand("Close", title: "Close “\(name)”?", warning: closeScope(snapshot, target: target).ask ? warning : nil, failure: "Pane command failed") { client in
            switch target {
            case .pane(let id): try client.delete(KO_DELETE_PANE, id)
            case .window(let id): try client.delete(KO_DELETE_WINDOW, id)
            case .session(let id): try client.delete(KO_DELETE_SESSION, id)
            }
        }
    }

    private func confirmCommand(_ verb: String, title: String, warning: String?, failure: String, send: @escaping @Sendable (KoClient) throws -> Void) {
        guard preparedAlert == nil, window.attachedSheet == nil, let instance = snapshot?.serverInstance else { return }
        supersedeIntent()
        let generation = generation
        let perform = { [weak self] in
            guard let self, accepts(generation), welcomed, snapshot?.serverInstance == instance, case .connected(let client) = link else { return }
            Task { [weak self] in
                do { try await Task.detached { try send(client) }.value } catch {
                    self?.notice(failure, failureText(error))
                }
            }
        }
        guard let warning else { perform(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = warning
        alert.addButton(withTitle: verb).keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        prepareAlert(alert) { response in if response == .alertFirstButtonReturn { perform() } }
    }

    func reveal() {
        guard !background else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func perform(_ navigation: Navigation) {
        if case .jump(let target) = navigation {
            guard activating != intent else { return }
            sidebar.list.select(target)
        }
        supersedeIntent()
        sidebar.list.failed(nil)
        if case .releaseSideFocus = navigation { return sidebar.list.leave() }
        guard case .connected(let client) = link else { return sidebar.list.failed("\(host.label) is not connected.") }
        do {
            switch navigation {
            case .jump(let target):
                activating = intent
                awaitingSelect = true
                // A pane that the zoom hides is shown: the jump ends the zoom.
                if let window = koModel?.layout.layout.window(target.window),
                   let zoom = window.zoom, zoom != target.pane {
                    editor?.submit(.zoom(KoSchema.EditZoom(pane: nil, window: window.id)))
                }
                try client.select(KO_SELECT_PANE, target.pane)
            case .selectWindow(_, let window):
                awaitingSelect = true
                try client.select(KO_SELECT_WINDOW, window)
            case .selectSession(let session):
                awaitingSelect = true
                try client.select(KO_SELECT_SESSION, session)
            case .switchSession(let next):
                awaitingSelect = true
                try client.switchOver(KO_OVER_SESSION, next ? KO_DIRECTION_NEXT : KO_DIRECTION_PREVIOUS)
            case .switchWindow(let next):
                guard let current = model.window, let layout = koModel?.layout.layout,
                      let window = adjacentWindow(snapshot.map(reorder.state.project), surviving: layout.survivingWindows, from: current, next: next) else { return }
                awaitingSelect = true
                try client.select(KO_SELECT_WINDOW, window)
            case .releaseSideFocus: break
            }
        } catch {
            awaitingSelect = false
            activating = nil
            sidebar.list.failed("\(error)")
        }
    }

    private func submit(_ move: ReorderMove) {
        guard let snapshot, let editor, let edit = snapshot.reorderEdit(move), let token = reorder.state.submit(move, to: snapshot) else { return }
        supersedeIntent()
        sidebar.list.failed(nil)
        showOrder()
        editor.submit(edit) { [weak self] result in
            let error: String? = if case .failure(let error) = result { failureText(error) } else { nil }
            self?.settleOrder { $0.complete(token, error: error) }
        }
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

    func focusSelected() {
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


    private func ready() {
        guard welcomed, model.session != nil, case .connected = link else { return }
        banner.isHidden = true
        showConfigError()
    }

    func accepts(_ token: Int) -> Bool {
        alive && generation == token
    }

    private func invalidate(keepingSnapshot: Bool = false) {
        focusTarget = nil
        awaitingSelect = false
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
        recovering?.cancel()
        recovering = nil
        initial?.cancel()
        initial = nil
        reorder.state.reset()
        editor = nil
        if case .connected(let client) = link { client.close() }
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
            received = Received()
            updateTabs()
        }
        window.title = host == .local ? "Local" : identity ?? host.label
    }

    func close() {
        if alive { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard alive else { return }
        saveFrame()
        alive = false
        Notifier.shared.forget(self)
        invalidate()
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
    func reloadConfig(font: Float?) { session?.reloadConfig(font: font) }
    func updateColorScheme() { session?.updateColorScheme() }
    var navigation: SessionModel { navigationModel }

    #if KIDO_VISUAL || KIDO_STRESS
    var testServerDir: String?
    // The runtimes of an owner without a server, and the runtime of its selected pane.
    var testRuntimes: (list: [KoSchema.ClientRuntime], focused: String?)?
    var testSSH: ((SSH) -> Void)?
    var testUploadBase: String?
    var testBanner: Banner { banner }
    var testSession: SessionView? { session }
    var testModel: KoModel? { koModel }
    var testPrompt: ((PromptRequest, @escaping @MainActor (Result<PromptReply, Error>) -> Void) -> Void)?
    // An editor whose answers the test gives, for an owner without a server.
    func testEditor(_ perform: @escaping @Sendable (KoSchema.Edit) throws -> KoSchema.Edited) { makeEditor(perform) }
    var testEditing: Bool { editor?.holding == true }
    var testClient: KoClient? { if case .connected(let client) = link { client } else { nil } }
    var testAttended: Bool? { didSet { attend() } }
    func testReceive(_ snapshot: Snapshot) {
        if receiving, case .connected(let client) = link {
            receiving = false
            receive(client)
        }
        received.snapshot = snapshot
        adopt(snapshot)
    }
    #endif
}
