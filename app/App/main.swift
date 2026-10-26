import AppKit
import TmuxControl
import SidebarFeed

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var runtime: GhosttyRuntime?
    private(set) var owners: [WindowOwner] = []
    private let menus = SessionMenus()
    private var editMenu: NSMenu?
    private var signals: [DispatchSourceSignal] = []
    private var trigger: String?
    let routes: WindowRoutes

    override init() {
        routes = WindowRoutes()
        super.init()
    }
    private var ordinaryLaunchEvent = true
    private var pendingJumps: [Host: (target: NoticeTarget, deadline: Date)] = [:]
    private(set) var palettePanel: PalettePanel?
    var promptDrafts: [PromptDraft.Key: PromptDraft] = [:]
    private var pendingPrompt: PalettePrompt?
    private var paletteFocus: (owner: WindowOwner, responder: NSResponder?)?
    private var paletteObservers: [NSObjectProtocol] = []
    private var paletteBusy = false
    enum CloseReason { case dismiss, choice, moved }

    private func withPaletteBusy(_ body: () -> Void) {
        let saved = paletteBusy
        paletteBusy = true
        defer { paletteBusy = saved }
        body()
    }

    #if KIDO_VISUAL
    init(runtime: GhosttyRuntime? = nil, routes: WindowRoutes = WindowRoutes()) {
        self.runtime = runtime
        self.routes = routes
        super.init()
        if let runtime { configureRuntime(runtime) }
    }
    #endif

    private func configureRuntime(_ runtime: GhosttyRuntime) {
        self.runtime = runtime
        runtime.onConfigChange = { [weak self] in
            self?.owners.filter(\.alive).forEach { $0.updateColorScheme(); $0.updateAppearance() }
            self?.palettePanel?.palette.themeChanged()
        }
        runtime.onConfigReload = { [weak self] font in self?.owners.filter(\.alive).forEach { $0.reloadConfig(font: font) } }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Upload.sweepPromises(launch: true)
        if let notifications = Notifier.shared.poster as? SystemNotifications {
            notifications.click = { [weak self] in self?.route($0) }
            notifications.install()
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        ordinaryLaunchEvent = event.map { $0.eventClass == AEEventClass(kCoreEventClass) && $0.eventID == AEEventID(kAEOpenApplication) } ?? true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do throws(Failure) { routes.connect(try Host(url: url)) }
            catch { note(error.message) }
        }
    }

    var current: WindowOwner? { owners.first { $0.alive && $0.window === NSApp.keyWindow } ?? (background && palettePanel == nil ? owners.first(where: \.alive) : nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        NSApp.applicationIconImage = NSImage(named: "AppIcon")
        // AppKit marks a windowless app as terminated by TAL; no Dock reopen reached such a process (pid log, 2026-10-25).
        ProcessInfo.processInfo.disableAutomaticTermination("a Dock reopen with no window opens a Local window")
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler { [weak self] in self?.quit(String(cString: strsignal(signal))) }
            source.resume()
            signals.append(source)
        }
        #if KIDO_VISUAL || KIDO_STRESS
        let pasteboard = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        #else
        let pasteboard = NSPasteboard.general
        #endif
        guard let runtime = GhosttyRuntime(pasteboard: pasteboard) else { fatalError("libghostty failed to initialise") }
        configureRuntime(runtime)
        NSApp.mainMenu = mainMenu()
        routes.ready(isDefaultLaunch: isDefaultLaunch == true && ordinaryLaunchEvent) { [weak self] in _ = self?.open($0, cause: $1) }
        #if KIDO_VISUAL
        if ProcessInfo.processInfo.environment["KIDO_APP_QUIT_VERIFY"] == "1", let owner = owners.first ?? open(.local) {
            let deadline = Date().addingTimeInterval(15)
            @MainActor func ready() {
                if owner.testBanner.isHidden {
                    note("quit verification ready, offscreen=\(!NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible && !$0.isKeyWindow && !$0.isMainWindow })")
                } else if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ready() }
                }
            }
            ready()
        }
        #endif
        #if KIDO_STRESS
        if owners.isEmpty { routes.ordinaryOpen() }
        if let owner = owners.first {
            Stress(window: owner.window, send: { [weak owner] in owner?.send($0) }, reconnect: { [weak owner] in owner?.start() }).run()
        }
        #endif
    }

    @discardableResult func open(_ host: Host, start: Bool = true, cause: WindowOwner.DialCause = .launch) -> WindowOwner? {
        guard let runtime else { return nil }
        let owner = WindowOwner(host: host, runtime: runtime, accents: routes.accents, start: start, cause: cause)
        owners.append(owner)
        owner.snapshotReceived = { [weak self, weak owner] in
            guard let self else { return }
            defer { paletteStateChanged() }
            if let owner { prunePromptDrafts(owner) }
            guard let owner, let snapshot = owner.snapshot, snapshot.error == nil else { return }
            guard let pending = pendingJumps[host] else { return }
            if pending.deadline <= Date() || snapshot.serverInstance != pending.target.instance {
                pendingJumps.removeValue(forKey: host)
            } else if sidebarRows(snapshot).contains(where: { $0.target?.pane == pending.target.position.pane }) {
                pendingJumps.removeValue(forKey: host)
                route(pending.target)
            }
        }
        owner.onClose = { [weak self, weak owner] in
            if self?.paletteFocus?.owner === owner { self?.closePalette(.moved) }
            if let owner { self?.promptDrafts = self?.promptDrafts.filter { $0.key.host != owner.host } ?? [:] }
            self?.updateMenu(self?.current)
            self?.paletteStateChanged()
            owner?.ended.notify(queue: .main) { [weak self, weak owner] in self?.owners.removeAll { $0 === owner } }
        }
        owner.menuChanged = { [weak self, weak owner] in
            guard let self else { return }
            if current === owner { updateMenu(current) }
        }
        updateMenu(current)
        return owner
    }

    func route(_ target: NoticeTarget, now: Date = Date()) {
        let host: Host
        if target.host == "local" { host = .local }
        else if target.host.hasPrefix("ssh:") { host = .remote(String(target.host.dropFirst(4))) }
        else { return }
        let candidates = owners.filter { $0.alive && $0.host == host }
        let containing = candidates.filter {
            $0.snapshot?.serverInstance == target.instance && sidebarRows($0.snapshot).contains { $0.target?.pane == target.position.pane }
        }
        let inSession = containing.filter { $0.snapshot?.client.session == target.position.session }
        let owner = inSession.first { $0.window.isKeyWindow } ?? inSession.first
            ?? containing.first { $0.window.isKeyWindow } ?? containing.first
            ?? candidates.first { $0.window.isKeyWindow } ?? candidates.first
        if let owner {
            owner.reveal()
            owner.perform(.jump(target.position))
        } else {
            pendingJumps[host] = (target, now.addingTimeInterval(30))
            routes.connect(host, cause: host == .local ? .newWindow : .remoteRequest)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if !owners.contains(where: \.alive) { routes.ordinaryOpen() }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !owners.contains(where: \.alive) { routes.ordinaryOpen(cause: .reopen) }
        else if !background { owners.first(where: \.alive)?.window.makeKeyAndOrderFront(nil) }
        return false
    }

    func updateMenu(_ owner: WindowOwner?, responder: NSResponder? = nil) {
        menus.update(owner?.navigation ?? SessionModel())
        let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        for item in view?.items.prefix(2) ?? [].prefix(2) { item.target = owner?.sidebar }
        view?.items.first?.title = owner?.sidebar.isCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
        if let editMenu { updatePromptMenu(editMenu, responder: responder ?? owner?.window.firstResponder) }
    }

    func applicationDidResignActive(_ notification: Notification) { Notifier.shared.attendanceChanged() }

    func applicationDidBecomeActive(_ notification: Notification) {
        Notifier.shared.attendanceChanged()
        do throws(Failure) { try tools.validate() } catch { owners.forEach { $0.bundleChanged(error) } }
    }

    func mainMenu() -> NSMenu {
        menus.rename = { [weak self] in self?.renameSession() }
        menus.connectionColor = { [weak self] in self?.connectionColor() }
        menus.close = { [weak self] in self?.closeSession() }
        menus.send = { [weak self] in (self?.paletteFocus?.owner ?? self?.current)?.perform($0) }
        menus.canSend = { [weak self] in (self?.paletteFocus?.owner ?? self?.current) != nil }
        menus.update(current?.navigation ?? SessionModel())
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
            item("Command Palette…", #selector(togglePalette), "p", .command),
            item("Theme…", #selector(showThemes), "", []),
        ]
        for item in view.items.prefix(2) { item.target = current?.sidebar }
        let alternate = item("Command Palette…", #selector(togglePalette), "P", [.command, .shift])
        alternate.isAlternate = true
        alternate.isHidden = true
        alternate.allowsKeyEquivalentWhenHidden = true
        view.addItem(alternate)
        for item in view.items where item.action == #selector(togglePalette) || item.action == #selector(showThemes) { item.target = self }
        let file = NSMenu(title: "File")
        let newWindow = item("New Window", #selector(PaneView.runCommand(_:)), "t", .command)
        newWindow.representedObject = PaneCommand.newWindow
        file.items = [item("New Session", #selector(newSession), "n", .command), newWindow,
                      item("Close Window", #selector(closeWindow), "", []), .separator(),
                      item("Connect to Remote Host…", #selector(connectRemoteHost), "K", [.command, .shift])]
        for entry in file.items where entry.action != #selector(PaneView.runCommand(_:)) { entry.target = self }
        let find = NSMenu(title: "Find")
        find.items = [
            item("Find…", #selector(PaneView.showFind(_:)), "f", .command),
            item("Find Next", #selector(PaneView.findNext(_:)), "g", .command),
            item("Find Previous", #selector(PaneView.findPrevious(_:)), "g", [.command, .shift]),
        ]
        let edit = NSMenu(title: "Edit")
        edit.delegate = self
        editMenu = edit
        edit.items = [
            item("Undo", Selector(("undo:")), "z", .command),
            item("Redo", Selector(("redo:")), "Z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", .command),
            item("Copy", #selector(NSText.copy(_:)), "c", .command),
            item("Paste", #selector(NSText.paste(_:)), "v", .command),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "V", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:)), "", []),
            item("Select All", #selector(NSText.selectAll(_:)), "a", .command),
            .separator(),
        ]
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        edit.addItem(item("Prompt with Selection…", #selector(PaneView.promptSelectionItem(_:)), "o", .command))
        edit.addItem(item("Copy Mode", #selector(PaneView.toggleCopyMode(_:)), "c", [.command, .shift]))
        edit.addItem(item("Reset Clipboard and Upload Permissions", #selector(resetClipboardPermissions), "", []))
        let bar = NSMenu()
        for menu in [app, file, edit, view, menus.window, menus.session] {
            bar.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        bar.insertItem(PaneCommand.menu, at: 2)
        return bar
    }


    func updatePromptMenu(_ menu: NSMenu, responder: NSResponder?) {
        guard menu === editMenu,
              let item = menu.items.first(where: { $0.action == #selector(PaneView.promptSelectionItem(_:)) })
        else { return }
        let pane = PaneView.owner(responder)
        item.target = pane
        item.title = pane?.hasSelection == true ? "Prompt with Selection…" : "Prompt…"
        item.isEnabled = pane?.validateMenuItem(item) == true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updatePromptMenu(menu, responder: (current?.window ?? NSApp.keyWindow)?.firstResponder)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === editMenu else { return }
        menu.items.first { $0.action == #selector(PaneView.promptSelectionItem(_:)) }?.target = nil
    }

    @objc func resetClipboardPermissions() {
        WindowOwner.resetClipboardPermissions(owners)
    }

    @objc func connectRemoteHost() {
        if palettePanel == nil { togglePalette() }
        palettePanel?.palette.enter(.connect)
    }

    @objc func connectionColor() {
        guard let owner = paletteFocus?.owner ?? current else { return }
        if palettePanel == nil { togglePalette() }
        palettePanel?.palette.enter(.color(.connection(owner.host)))
    }

    private var customColorTarget: ColorTarget?
    private var colorPanelClosed: NSObjectProtocol?

    private func currentAccent(_ target: ColorTarget, _ palette: PaletteView) -> Accent {
        if case .connection(let host) = target { routes.accents.accent(for: host) } else { palette.selectedAccent }
    }

    private func customColor(_ target: ColorTarget, current: Accent) {
        customColorTarget = target
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = current.color(dark: runtime?.background.isDark ?? false)
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        colorPanelClosed = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endCustomColor() }
        }
        if !background { panel.orderFront(nil) }
    }

    private func endCustomColor() {
        customColorTarget = nil
        colorPanelClosed.map(NotificationCenter.default.removeObserver)
        colorPanelClosed = nil
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
    }

    @objc func colorPanelChanged(_ panel: NSColorPanel) {
        let accent = Accent(panel.color)
        switch customColorTarget {
        case .connection(let host): routes.accents.set(accent, for: host)
        case .newConnection: palettePanel?.palette.connectAccent = accent
        case nil: break
        }
    }

    @objc func renameSession() {
        guard let owner = paletteFocus?.owner ?? current, let session = owner.currentSession,
              let instance = owner.snapshot?.serverInstance else { return }
        if palettePanel == nil { togglePalette() }
        palettePanel?.palette.enter(.rename(owner, instance, session.id, original: session.name))
    }

    @objc func showThemes() {
        if palettePanel == nil { togglePalette() }
        palettePanel?.palette.enter(.theme(.pick))
    }

    @objc func closeWindow() { (paletteFocus?.owner ?? current)?.closeCurrentWindow() }
    @objc func closeSession() { (paletteFocus?.owner ?? current)?.closeCurrentSession() }

    @objc func newSession() {
        if let current { return current.newSession() }
        if let owner = owners.first(where: { $0.alive && $0.host == .local }) {
            owner.reveal()
            return owner.newSession()
        }
        routes.ordinaryOpen(cause: .newSession)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(closeWindow) || (paletteFocus?.owner ?? current) != nil
    }

    private func keepPromptDraft(_ owner: WindowOwner) -> (PromptDraft.Key) -> Bool {
        let current = PromptSource.current(in: owner)
        let paneExists = PromptSource.paneExists(in: owner)
        return { current($0.instance) && paneExists($0.pane) }
    }

    private func prunePromptDrafts(_ owner: WindowOwner) {
        guard !promptDrafts.isEmpty else { return }
        let keep = keepPromptDraft(owner)
        promptDrafts = promptDrafts.filter { key, _ in key.host != owner.host || keep(key) }
    }

    func paletteStateChanged() {
        if let pendingPrompt, !pendingPrompt.source.valid { self.pendingPrompt = nil }
        guard let panel = palettePanel, !paletteBusy else { return }
        if case .prompt(let source) = panel.palette.mode {
            guard source.current else { closePalette(.moved); return }
            panel.palette.prompt?.sourceChanged(gone: !source.paneExists)
            return
        }
        guard panel.palette.mode == .root else { return }
        withPaletteBusy {
            updateMenu(paletteFocus?.owner, responder: paletteFocus?.responder)
            panel.palette.refresh(paletteEntries(owner: paletteFocus?.owner, responder: paletteFocus?.responder))
        }
    }

    private func focusPalette(_ panel: PalettePanel) {
        let editor = panel.palette.prompt?.textView ?? panel.palette.field.currentEditor()
        let selection = panel.firstResponder === editor ? (editor as? NSTextView)?.selectedRange() : nil
        panel.makeKey()
        panel.makeFirstResponder(panel.palette.prompt?.textView ?? panel.palette.field)
        if let selection { (panel.firstResponder as? NSTextView)?.setSelectedRange(selection) }
        if let field = panel.palette.prompt?.textView { field.scrollRangeToVisible(field.selectedRange()) }
    }

    @objc func togglePalette() {
        pendingPrompt = nil
        if palettePanel != nil { return closePalette() }
        showPalette()
    }

    private func showPalette(_ prepared: PalettePrompt? = nil) {
        updateMenu(current, responder: current?.window.firstResponder)
        let entries = paletteEntries(owner: current, responder: current?.window.firstResponder)
        guard let runtime = current?.runtime ?? runtime else { return }
        paletteFocus = (prepared?.source.owner ?? current).map { ($0, $0.window.firstResponder) }
        let palette = PaletteView(runtime: runtime, entries: entries,
                                  accentFor: { [weak self] text, chosen in self?.effectiveAccent(text, chosen: chosen) ?? .system },
                                  swatch: { [weak self] in self?.swatch($0) ?? Chrome.accent })
        let panel = PalettePanel(palette: palette) { [weak self, weak palette] in
            guard let self, !paletteBusy else { return }
            guard customColorTarget == .newConnection else { return closePalette(.moved) }
            DispatchQueue.main.async { [weak self] in
                guard let self, palettePanel?.palette === palette, !(NSApp.keyWindow is NSColorPanel) else { return }
                closePalette(.moved)
            }
        }
        palettePanel = panel
        panel.toggle = { [weak self] in self?.closePalette() }
        panel.connect = { [weak self] in self?.connectRemoteHost() }
        panel.prompt = { [weak self, weak panel] in
            guard let self, let panel else { return }
            if let entry = panel.palette.selectedEntry, entry.promptable, case .pane(let host, let position) = entry.id,
               let owner = owners.first(where: { $0.host == host && $0.alive }),
               let source = owner.promptSource(session: position.session, window: position.window, pane: position.pane, quote: nil, preselect: position.pane) {
                panel.palette.enter(.prompt(source))
            } else if let pane = PaneView.owner(paletteFocus?.responder) {
                pane.openPrompt()
            }
        }
        panel.palette.makePrompt = { [weak self, weak panel] source in
            self?.resolvePrompt(source, panel: panel)
        }
        panel.palette.modeChanged = { [weak self] in self?.pendingPrompt = nil }
        panel.palette.dismiss = { [weak self] in self?.closePalette() }
        panel.palette.chooseEntry = { [weak self, weak panel] entry in
            guard let self, let panel else { return }
            performPalette(entry, panel: panel)
        }
        panel.palette.rootEntries = { [weak self] in
            guard let self else { return [] }
            updateMenu(paletteFocus?.owner, responder: paletteFocus?.responder)
            return paletteEntries(owner: paletteFocus?.owner, responder: paletteFocus?.responder)
        }
        panel.palette.modeEntries = { [weak self, weak panel] mode, query, invalid in
            guard let self, let palette = panel?.palette else { return [] }
            switch mode {
            case .color(let target):
                return colorEntries(target, current: currentAccent(target, palette), query: query)
            default: return connectEntries(query: query, invalid: invalid, chosen: palette.connectAccent)
            }
        }
        panel.palette.rename = { [weak self, weak panel] text in
            guard let self, let panel, self.palettePanel === panel,
                  case .rename(let owner, let instance, let id, let original) = panel.palette.mode else { return }
            let mode = panel.palette.mode
            guard owner.alive, owner.canNavigate, let snapshot = owner.snapshot, snapshot.serverInstance == instance,
                  snapshot.sessions.contains(where: { $0.id == id }) else {
                panel.palette.reject("That session is gone")
                return
            }
            switch SessionRename(text, session: id, original: original, sessions: snapshot.sessions) {
            case .revert: closePalette()
            case .reject(let message): panel.palette.reject(message)
            case .rename(let name):
                owner.renameSession(id, name) { [weak self, weak panel] error in
                    guard let self, let panel, self.palettePanel === panel, panel.palette.mode == mode else { return }
                    if let error { panel.palette.reject(error) }
                    else { self.closePalette() }
                }
            }
        }
        if let prepared { panel.palette.enter(.prompt(prepared.source), prompt: prepared) }
        panel.place(over: paletteFocus?.owner)
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didResignActiveNotification] {
            paletteObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak panel] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, self.palettePanel != nil, !self.paletteBusy else { return }
                    if window !== panel, !(window is NSColorPanel) { self.closePalette(.moved) }
                }
            })
        }
        withPaletteBusy {
            if !background { panel.makeKeyAndOrderFront(nil) }
            focusPalette(panel)
        }
    }

    private func performPalette(_ entry: PaletteEntry, panel: PalettePanel) {
        withPaletteBusy {
            restorePaletteFocus()
            if let error = entry.check() {
                panel.palette.reject(error)
                focusPalette(panel)
                return
            }
            switch entry.operation {
            case .run(let action): closePalette(.choice); action()
            case .enter(let mode): panel.palette.enter(mode); focusPalette(panel)
            case .connectTyped(let text):
                do throws(Failure) {
                    let host = try Host(text)
                    let accent = panel.palette.connectAccent
                    closePalette(.choice)
                    routes.connect(host, accent: accent)
                } catch { panel.palette.reject(error.message); focusPalette(panel) }
            case .themeChoose, .themeUse: break
            case .chooseColor(let accent):
                switch panel.palette.mode {
                case .color(.connection(let host)): routes.accents.set(accent, for: host); closePalette(.choice)
                default: panel.palette.connectAccent = accent; panel.palette.enter(.connect); focusPalette(panel)
                }
            case .customColor:
                guard case .color(let target) = panel.palette.mode else { break }
                let current = currentAccent(target, panel.palette)
                if case .connection = target { closePalette(.choice) } else { panel.palette.enter(.connect); focusPalette(panel) }
                customColor(target, current: current)
            case .clearRecent:
                routes.clearRecent()
                panel.palette.reloadMode()
                focusPalette(panel)
            }
        }
    }

    func closePalette(_ reason: CloseReason = .dismiss) {
        pendingPrompt = nil
        guard let panel = palettePanel else { return }
        withPaletteBusy {
            panel.palette.prompt?.storeDraft()
            if case .prompt(let source) = panel.palette.mode, !source.current {
                prunePromptDrafts(source.owner)
            }
            palettePanel = nil
            if customColorTarget == .newConnection {
                endCustomColor()
                NSColorPanel.shared.orderOut(nil)
            }
            paletteObservers.forEach { NotificationCenter.default.removeObserver($0) }
            paletteObservers = []
            let focus = paletteFocus
            paletteFocus = nil
            panel.palette.field.abortEditing()
            panel.close()
            if reason == .dismiss { restorePaletteFocus(focus) }
        }
    }

    func openPrompt(owner: WindowOwner, pane: PaneView, quote: String?) {
        guard let session = owner.currentSession, let window = pane.windowID,
              let source = owner.promptSource(session: session.id, window: window, pane: pane.pane, quote: quote) else { return }
        resolvePrompt(source, panel: palettePanel, responder: pane)
    }

    private func resolvePrompt(_ source: PromptSource, panel: PalettePanel?, responder: NSResponder? = nil) {
        guard pendingPrompt == nil else { return }
        let mode = panel?.palette.mode
        let prompt = PalettePrompt(source: source, runtime: source.owner.runtime)
        pendingPrompt = prompt
        prompt.load = { [weak self, weak prompt] key in
            guard let self else { return nil }
            if pendingPrompt === prompt { palettePanel?.palette.prompt?.storeDraft() }
            return promptDrafts[key]
        }
        prompt.save = { [weak self] key, draft in
            guard let self else { return }
            promptDrafts[key] = keepPromptDraft(source.owner)(key) ? draft : nil
        }
        prompt.dismiss = { [weak self] in self?.closePalette() }
        prompt.delivered = { [weak self] in
            self?.closePalette()
            source.owner.promptDelivered(pane: source.pane)
        }
        prompt.resolved = { [weak self, weak prompt, weak panel] in
            guard let self, let prompt, pendingPrompt === prompt else { return }
            pendingPrompt = nil
            guard source.valid, palettePanel === panel, panel?.palette.mode == mode else { return }
            if panel == nil { showPalette(prompt) }
            guard let destination = palettePanel else { return }
            if let responder { paletteFocus = (source.owner, responder) }
            prompt.active = { [weak self, weak destination] in
                guard let destination else { return false }
                return self?.palettePanel === destination && destination.palette.mode == .prompt(source)
            }
            prompt.resolved = {}
            if panel != nil { destination.palette.enter(.prompt(source), prompt: prompt) }
            focusPalette(destination)
        }
        prompt.resolve()
    }

    private func restorePaletteFocus(_ saved: (owner: WindowOwner, responder: NSResponder?)? = nil) {
        guard let focus = saved ?? paletteFocus, focus.owner.alive else { return }
        if !background { focus.owner.window.makeKeyAndOrderFront(nil) }
        if let view = focus.responder as? NSView, view.window === focus.owner.window {
            focus.owner.window.makeFirstResponder(view)
        } else { focus.owner.focusSelected() }
    }
    @objc private func quitItem() { quit("the Quit menu item") }
    func quit(_ reason: String) { trigger = reason; NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        note("quitting: \(trigger ?? "NSApp.terminate")")
        Notifier.shared.withdrawAll()
        Upload.sweepPromises()
        let stopped = DispatchGroup()
        for owner in owners {
            stopped.enter()
            owner.ended.notify(queue: .global()) { @Sendable in stopped.leave() }
        }
        owners.forEach { $0.close(cause: .quit) }
        owners = []
        stopped.notify(queue: .global()) { @Sendable in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    #if KIDO_VISUAL
                    if let files = ProcessInfo.processInfo.environment["KIDO_APP_QUIT_CHILDREN"] {
                        let pids = files.split(separator: "|").compactMap { try? String(contentsOfFile: String($0), encoding: .utf8) }.compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        note("quit drain completed, unreaped=\(pids.filter { kill($0, 0) == 0 })")
                    }
                    #endif
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }

    #if KIDO_STRESS
    var stressState: (SessionModel, SessionModel, SessionView?, Connection?, SidebarFeed.Snapshot?) { owners.first!.stressState }
    var stressGeneration: Int { owners.first!.generation }
    var stressOwner: WindowOwner { owners.first! }
    var sidebar: Sidebar { owners.first!.sidebar }
    #endif
}

let tools = BundledTools(resources: Bundle.main.resourceURL!, environment: ProcessInfo.processInfo.environment)
#if DEBUG || KIDO_VISUAL || KIDO_STRESS
let background = ProcessInfo.processInfo.environment["KIDO_APP_BACKGROUND"] == "1"
#else
let background = false
#endif
let debugging = ProcessInfo.processInfo.environment["KIDO_APP_DEBUG"] == "1"

func note(_ line: String) {
    FileHandle.standardError.write(Data("kido-app \(line)\n".utf8))
}

func debug(_ line: @autoclosure () -> String) {
    if debugging { note(line()) }
}

func milliseconds(since start: DispatchTime) -> String {
    String(format: "%.1fms", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
}

setenv("GHOSTTY_RESOURCES_DIR", Bundle.main.resourceURL!.appendingPathComponent("ghostty").path, 1)
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(background ? .prohibited : .regular)
NSApplication.shared.run()
