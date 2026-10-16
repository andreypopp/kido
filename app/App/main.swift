import AppKit
import TmuxControl
import SidebarFeed

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime?
    private(set) var owners: [WindowOwner] = []
    private let menus = SessionMenus()
    private var signals: [DispatchSourceSignal] = []
    private var trigger: String?
    let routes = WindowRoutes()
    private var ordinaryLaunchEvent = true
    private var pendingJumps: [Host: (target: NoticeTarget, deadline: Date)] = [:]

    #if KIDO_VISUAL
    init(runtime: GhosttyRuntime? = nil) {
        self.runtime = runtime
        super.init()
    }
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
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

    var current: WindowOwner? { owners.first { $0.alive && $0.window === NSApp.keyWindow } ?? (background ? owners.first(where: \.alive) : nil) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        NSApp.applicationIconImage = NSImage(named: "AppIcon")
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
        self.runtime = runtime
        NSApp.mainMenu = mainMenu()
        menus.send = { [weak self] in self?.current?.perform($0) }
        runtime.onConfigChange = { [weak self] in self?.owners.filter(\.alive).forEach { $0.updateAppearance() } }
        runtime.onColorSchemeChange = { [weak self] in self?.owners.filter(\.alive).forEach { $0.updateColorScheme() } }
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
        let owner = WindowOwner(host: host, runtime: runtime, start: start, cause: cause)
        owners.append(owner)
        owner.snapshotReceived = { [weak self, weak owner] in
            guard let self, let owner, let snapshot = owner.snapshot, snapshot.error == nil,
                  let pending = pendingJumps[host] else { return }
            if pending.deadline <= Date() || snapshot.serverInstance != pending.target.instance {
                pendingJumps.removeValue(forKey: host)
            } else if sidebarRows(snapshot).contains(where: { $0.target?.pane == pending.target.position.pane }) {
                pendingJumps.removeValue(forKey: host)
                route(pending.target)
            }
        }
        owner.onClose = { [weak self, weak owner] in
            self?.updateMenu()
            owner?.ended.notify(queue: .main) { [weak self, weak owner] in self?.owners.removeAll { $0 === owner } }
        }
        owner.menuChanged = { [weak self, weak owner] in
            guard let self, current === owner else { return }
            updateMenu()
        }
        updateMenu()
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
            if !background {
                NSApp.activate(ignoringOtherApps: true)
                owner.window.deminiaturize(nil)
                owner.window.makeKeyAndOrderFront(nil)
            }
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

    private func updateMenu() {
        menus.update(current?.navigation ?? SessionModel())
        let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        for item in view?.items.prefix(2) ?? [].prefix(2) { item.target = current?.sidebar }
        view?.items.first?.title = current?.sidebar.isCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
    }

    func applicationDidResignActive(_ notification: Notification) { Notifier.shared.attendanceChanged() }

    func applicationDidBecomeActive(_ notification: Notification) {
        Notifier.shared.attendanceChanged()
        do throws(Failure) { try tools.validate() } catch { owners.forEach { $0.bundleChanged(error) } }
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
        ]
        for item in view.items.prefix(2) { item.target = current?.sidebar }
        let file = NSMenu(title: "File")
        let newWindow = item("New Window", #selector(PaneView.runCommand(_:)), "t", .command)
        newWindow.representedObject = PaneCommand.newWindow
        file.items = [item("New Session", #selector(newSession), "n", .command), newWindow,
                      .separator(), item("New Local Window", #selector(newLocalWindow), "", []),
                      item("Connect to Remote Host…", #selector(connectRemoteHost), "", [])]
        for entry in file.items.suffix(2) { entry.target = self }
        let find = NSMenu(title: "Find")
        find.items = [
            item("Find…", #selector(PaneView.showFind(_:)), "f", .command),
            item("Find Next", #selector(PaneView.findNext(_:)), "g", .command),
            item("Find Previous", #selector(PaneView.findPrevious(_:)), "g", [.command, .shift]),
        ]
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        edit.addItem(item("Copy Mode", #selector(PaneView.toggleCopyMode(_:)), "c", [.command, .shift]))
        edit.addItem(item("Reset Clipboard and Upload Permissions", #selector(resetClipboardPermissions), "", []))
        let bar = NSMenu()
        for menu in [app, file, edit, view, menus.window, menus.session] {
            bar.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
        }
        bar.insertItem(PaneCommand.menu, at: 2)
        return bar
    }


    @objc private func resetClipboardPermissions() {
        WindowOwner.resetClipboardPermissions(owners)
    }

    @objc func newLocalWindow() { routes.ordinaryOpen(cause: .newWindow) }
    @objc private func connectRemoteHost() { RemoteHostDialog(routes: routes).show(on: NSApp.keyWindow) }

    @objc private func newSession() { current?.newSession() }
    @objc private func quitItem() { quit("the Quit menu item") }
    func quit(_ reason: String) { trigger = reason; NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        note("quitting: \(trigger ?? "NSApp.terminate")")
        Notifier.shared.withdrawAll()
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

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(background ? .accessory : .regular)
NSApplication.shared.run()
