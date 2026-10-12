import AppIntents
import AppKit
import SidebarFeed

struct ConnectRemoteHost: AppIntent {
    static let title: LocalizedStringResource = "Connect to Remote Host in Kido"
    static let openAppWhenRun = true
    @Parameter(title: "Host") var host: String
    static var parameterSummary: some ParameterSummary { Summary("Connect to \(\.$host)") }

    @MainActor func perform() async throws -> some IntentResult {
        let destination = try Host(host.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let app = NSApp.delegate as? AppDelegate else { throw Failure(message: "Kido is not ready") }
        app.routes.connect(destination)
        return .result()
    }
}

struct RemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectRemoteHost(), phrases: ["Connect to remote host in \(.applicationName)"],
                    shortTitle: "Connect to Remote Host", systemImageName: "network")
    }
}

@MainActor final class WindowRoutes {
    private let preferences: UserDefaults?
    private(set) var recent: RecentHosts
    init(preferences: UserDefaults? = background ? nil : .standard) {
        self.preferences = preferences
        recent = preferences?.data(forKey: "recentHosts").flatMap { try? JSONDecoder().decode(RecentHosts.self, from: $0) } ?? RecentHosts()
    }
    func clearRecent() { recent.clear(); saveRecent() }
    private func saveRecent() { preferences?.set(try? JSONEncoder().encode(recent), forKey: "recentHosts") }
    private var queued: [(Host, WindowOwner.DialCause)] = []
    private var open: ((Host, WindowOwner.DialCause) -> Void)?
    private var ordinaryAllowed = true
    func connect(_ host: Host, cause: WindowOwner.DialCause = .remoteRequest) {
        if case .remote(let alias) = host { recent.add(alias, at: Date()); saveRecent() }
        if let open {
            ordinaryAllowed = true
            open(host, cause)
        } else { queued.append((host, cause)) }
    }
    func ordinaryOpen(cause: WindowOwner.DialCause = .launch) {
        if ordinaryAllowed && queued.isEmpty { connect(.local, cause: cause) }
    }
    func ready(isDefaultLaunch: Bool, _ open: @escaping (Host, WindowOwner.DialCause) -> Void) {
        self.open = open
        let requests = queued.filter { isDefaultLaunch || $0.0 != .local }
        ordinaryAllowed = isDefaultLaunch || !requests.isEmpty
        queued = []
        requests.forEach { open($0.0, $0.1) }
    }
}

@MainActor final class RemoteHostDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 306), styleMask: [.titled], backing: .buffered, defer: false)
    let field = NSTextField(string: "")
    let table = NSTableView()
    let error = NSTextField(wrappingLabelWithString: "")
    let clear = NSButton(title: "Clear Recent", target: nil, action: nil)
    private let routes: WindowRoutes
    private var retained: RemoteHostDialog?
    init(routes: WindowRoutes) {
        self.routes = routes
        super.init()
        sheet.isReleasedWhenClosed = false
        let content = sheet.contentView!
        func label(_ text: String, _ frame: NSRect, size: CGFloat = 11, bold: Bool = false) {
            let view = NSTextField(labelWithString: text)
            view.font = .systemFont(ofSize: size, weight: bold ? .bold : .regular)
            view.textColor = bold || text == "Host:" ? .labelColor : .secondaryLabelColor
            view.alignment = text == "Host:" ? .right : .left
            view.frame = frame
            content.addSubview(view)
        }
        label("Connect to Remote Host", NSRect(x: 20, y: 270, width: 400, height: 16), size: 13, bold: true)
        label("Opens a new window attached to the host's kido server over SSH.", NSRect(x: 20, y: 250, width: 400, height: 14))
        label("Host:", NSRect(x: 20, y: 216, width: 52, height: 20), size: 13)
        field.frame = NSRect(x: 80, y: 214, width: 340, height: 24)
        field.placeholderString = "user@hostname or SSH alias"
        field.setAccessibilityLabel("Host")
        content.addSubview(field)
        label("Uses your SSH configuration, keys and known hosts.", NSRect(x: 80, y: 196, width: 340, height: 14))
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 52, width: 400, height: 132))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: .init("host"))
        column.title = "Recent"
        column.width = 400
        column.headerCell.font = .systemFont(ofSize: 11, weight: .semibold)
        table.addTableColumn(column)
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        table.frame = NSRect(x: 0, y: 0, width: 400, height: 132)
        table.autoresizingMask = .width
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectRecent)
        scroll.documentView = table
        content.addSubview(scroll)
        error.frame = NSRect(x: 20, y: 52, width: 400, height: 24)
        error.isHidden = true
        error.font = .systemFont(ofSize: 11)
        error.textColor = .systemRed
        content.addSubview(error)
        clear.frame = NSRect(x: 20, y: 12, width: 110, height: 28)
        clear.target = self
        clear.action = #selector(clearRecent)
        content.addSubview(clear)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 240, y: 12, width: 80, height: 28)
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)
        let connect = NSButton(title: "Connect", target: self, action: #selector(connect))
        connect.frame = NSRect(x: 325, y: 12, width: 95, height: 28)
        connect.keyEquivalent = "\r"
        content.addSubview(connect)
        for button in [clear, cancel, connect] { button.bezelStyle = .rounded }
        sheet.defaultButtonCell = connect.cell as? NSButtonCell
        sheet.initialFirstResponder = field
        reload()
    }
    private func reload() { table.reloadData(); clear.isEnabled = !routes.recent.isEmpty }
    @objc func clearRecent() { routes.clearRecent(); reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { max(1, routes.recent.entries.count) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !routes.recent.isEmpty }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("recentHost")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = id
        cell.subviews.forEach { $0.removeFromSuperview() }
        let entry = routes.recent.entries.indices.contains(row) ? routes.recent.entries[row] : nil
        let title = NSTextField(labelWithString: entry?.host ?? "No recent hosts")
        title.font = .systemFont(ofSize: 12)
        title.frame = NSRect(x: 8, y: 4, width: entry == nil ? 380 : 280, height: 16)
        title.alignment = entry == nil ? .center : .left
        cell.textField = title; cell.addSubview(title)
        if let entry {
            let time = NSTextField(labelWithString: routes.recent.relativeTime(entry, now: Date()))
            time.font = .systemFont(ofSize: 10)
            time.textColor = .secondaryLabelColor
            time.alignment = .right
            time.frame = NSRect(x: 290, y: 4, width: 90, height: 16)
            cell.addSubview(time)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard routes.recent.entries.indices.contains(table.selectedRow) else { return }
        field.stringValue = routes.recent.entries[table.selectedRow].host
    }
    func handle(_ response: NSApplication.ModalResponse) -> Bool {
        guard response == .alertFirstButtonReturn else { return true }
        do throws(Failure) {
            routes.connect(try Host(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)))
            return true
        } catch {
            self.error.stringValue = error.message
            if self.error.isHidden {
                self.error.isHidden = false
                sheet.setContentSize(NSSize(width: 440, height: 338))
                sheet.contentView?.subviews.filter { !($0 is NSButton) && $0 !== self.error }.forEach { $0.frame.origin.y += 32 }
            }
            return false
        }
    }
    @objc private func connectRecent() {
        guard routes.recent.entries.indices.contains(table.selectedRow) else { return }
        field.stringValue = routes.recent.entries[table.selectedRow].host
        connect()
    }
    @objc func connect() { if handle(.alertFirstButtonReturn) { finish(.alertFirstButtonReturn) } }
    @objc func cancel() { finish(.alertSecondButtonReturn) }
    private func finish(_ response: NSApplication.ModalResponse) {
        if let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: response) }
        else { sheet.orderOut(nil) }
        retained = nil
    }
    func show(on window: NSWindow?) {
        retained = self
        if let window { window.beginSheet(sheet) { [self] _ in sheet.orderOut(nil); retained = nil } }
        else if !background { sheet.makeKeyAndOrderFront(nil) }
    }
}
