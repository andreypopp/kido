import AppKit
import SidebarFeed
import TmuxControl

struct PaletteEntry {
    enum ID: Equatable {
        case session(Host, SessionID), pane(Host, Snapshot.Position), host(String), command(Int), connectTyped, clearRecent
    }
    let id: ID
    var order = 0
    let title: String
    let detail: String
    var shortcut = ""
    var status: SidebarRow.Status?
    var symbol: String?
    var agent = false
    var promptable = false
    var check: @MainActor () -> String? = { nil }
    enum Operation {
        case run(@MainActor () -> Void), enter(PaletteMode), connectTyped(String), clearRecent
    }
    let operation: Operation

    @MainActor static func sessions(_ owner: WindowOwner, app: AppDelegate) -> [PaletteEntry] {
        guard owner.canNavigate, let snapshot = owner.snapshot else { return [] }
        let instance = snapshot.serverInstance
        let host = if case .remote(let destination) = owner.host { [destination] } else { [String]() }
        let destination = owner.host
        let resolve: @MainActor (SidebarRow) -> WindowOwner? = { [weak app] row in
            app?.owners.first {
                $0.canNavigate && $0.host == destination && $0.snapshot?.serverInstance == instance
                    && sidebarRows($0.snapshot).contains { $0.id == row.id }
            }
        }
        func go(_ row: SidebarRow, _ request: RPCRequest) -> @MainActor () -> Void {
            { let owner = resolve(row); owner?.reveal(); owner?.perform(request) }
        }
        func check(_ row: SidebarRow) -> @MainActor () -> String? {
            { resolve(row) == nil ? "That pane is gone" : nil }
        }
        let reachable = Set(snapshot.promptPanes.filter(\.agent).map(\.pane))
        var session = ""
        return sidebarRows(owner.snapshot, seen: owner.seen.value).compactMap { row in
            if case .header(let id) = row.id {
                session = row.title
                return PaletteEntry(id: .session(owner.host, id), title: row.title, detail: host.joined(), symbol: "square.stack", check: check(row), operation: .run(go(row, .selectSession(id))))
            }
            guard let target = row.target else { return nil }
            return PaletteEntry(id: .pane(owner.host, target), title: row.title, detail: (host + [session]).joined(separator: " › "), status: row.status, agent: row.agent, promptable: reachable.contains(target.pane), check: check(row), operation: .run(go(row, .jump(target))))
        }
    }

    private enum Scope { case always, window, pane }

    @MainActor static func commands(_ menu: NSMenu, owner: WindowOwner?, responder: NSResponder?, path: [String] = []) -> [PaletteEntry] {
        return menu.items.flatMap { item -> [PaletteEntry] in
            if let submenu = item.submenu { return commands(submenu, owner: owner, responder: responder, path: path + [item.title].filter { !$0.isEmpty }) }
            guard let action = item.action, let (order, scope) = commandOrder(item), !item.isHidden else { return [] }
            let available = switch scope { case .always: true; case .window: owner != nil; case .pane: livePane(owner, responder) != nil }
            guard available, enabled(item, responder: responder) else { return [] }
            let operation: Operation
            if action == #selector(AppDelegate.connectRemoteHost) { operation = .enter(.connect) }
            else if action == #selector(SessionMenus.renameItem), let owner, let session = owner.currentSession, let instance = owner.snapshot?.serverInstance {
                operation = .enter(.rename(owner, instance, session.id, original: session.name))
            } else if action == #selector(PaneView.promptSelectionItem(_:)), let owner, let pane = livePane(owner, responder),
                      let session = owner.currentSession, let window = pane.windowID,
                      let source = owner.promptSource(session: session.id, window: window, pane: pane.pane, quote: pane.selectionQuote) {
                operation = .enter(.prompt(source))
            } else { operation = .run { NSApp.sendAction(action, to: item.target, from: item) } }
            return [PaletteEntry(id: .command(order), order: order, title: item.title, detail: path.joined(separator: " › "), shortcut: shortcut(item),
                                 check: { [weak owner] in
                if scope == .pane, livePane(owner, owner?.window.firstResponder) == nil { return "Not available now" }
                return enabled(item, responder: owner?.window.firstResponder) ? nil : "Not available now"
            }, operation: operation)]
        }.sorted { $0.order < $1.order }
    }

    @MainActor private static func livePane(_ owner: WindowOwner?, _ responder: NSResponder?) -> PaneView? {
        guard let owner, owner.canNavigate, let pane = PaneView.owner(responder),
              pane.window === owner.window, !pane.isHiddenOrHasHiddenAncestor else { return nil }
        return pane
    }

    @MainActor private static func enabled(_ item: NSMenuItem, responder: NSResponder?) -> Bool {
        guard item.menu?.autoenablesItems != false else { return item.isEnabled }
        var target: Any? = item.target
        if target == nil, let action = item.action {
            var next = responder
            while let candidate = next {
                if candidate.responds(to: action) { target = candidate; break }
                next = candidate.nextResponder
            }
            if target == nil, let pane = PaneView.owner(responder), pane.responds(to: action) { target = pane }
            if target == nil { target = NSApp.target(forAction: action, to: nil, from: item) }
        }
        if let pane = target as? PaneView { return pane.canPerformMenuItem(item) }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return target != nil
    }

    private static func commandOrder(_ item: NSMenuItem) -> (Int, Scope)? {
        switch item.action {
        case #selector(AppDelegate.newSession): (0, .always)
        case #selector(SessionMenus.renameItem): (1, .window)
        case #selector(SessionMenus.closeItem): (2, .window)
        case #selector(AppDelegate.closeWindow): (4, .window)
        case #selector(PaneView.runCommand(_:)):
            switch item.representedObject as? PaneCommand {
            case .newWindow: (3, .pane)
            case .split(.right): (5, .pane)
            case .split(.down): (6, .pane)
            case .close: (7, .pane)
            case .zoom: (8, .pane)
            default: nil
            }
        case #selector(AppDelegate.connectRemoteHost): (9, .always)
        case #selector(Sidebar.toggleSidebar(_:)): (10, .window)
        case #selector(Sidebar.focusSidebar(_:)): (11, .window)
        case NSSelectorFromString("toggleFullScreen:"): (12, .window)
        case #selector(PaneView.showFind(_:)): (13, .pane)
        case #selector(PaneView.toggleCopyMode(_:)): (14, .pane)
        case #selector(PaneView.promptSelectionItem(_:)): (15, .pane)
        case #selector(AppDelegate.resetClipboardPermissions): (16, .window)
        default: nil
        }
    }

    private static let keys: [String: String] = [
        String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
        String(UnicodeScalar(NSRightArrowFunctionKey)!): "→", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓", "\r": "↩", " ": "Space",
    ]

    private static func shortcut(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var modifiers = item.keyEquivalentModifierMask
        if key != key.lowercased() { modifiers.insert(.shift) }
        let glyphs: [(NSEvent.ModifierFlags, String)] = [(.function, "fn "), (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + (keys[key] ?? key.uppercased())
    }

    static func ranked(_ entries: [PaletteEntry], query: String) -> [(entry: PaletteEntry, offsets: [[Int]])] {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == ">" || $0 == "›" })
        guard !words.isEmpty else { return entries.map { ($0, [[], []]) } }
        return entries.enumerated().compactMap { index, entry -> (score: Int, index: Int, entry: PaletteEntry, offsets: [[Int]])? in
            fuzzyMatch(words: words, fields: [entry.title, entry.detail]).map { ($0.score, index, entry, $0.offsets) }
        }
        .sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
        .map { ($0.entry, $0.offsets) }
    }
}

extension AppDelegate {
    func paletteEntries(owner: WindowOwner?, responder: NSResponder?) -> [PaletteEntry] {
        let open = owners.filter(\.alive)
        let hosts = routes.recent.entries.map(\.host).filter { alias in !open.contains { $0.host == .remote(alias) } }
        return (open.filter { $0 === owner } + open.filter { $0 !== owner }).flatMap { PaletteEntry.sessions($0, app: self) }
            + hosts.map { hostEntry($0, detail: "Connect") }
            + (NSApp.mainMenu.map { PaletteEntry.commands($0, owner: owner, responder: responder) } ?? [])
    }
    private func hostEntry(_ host: String, detail: String = "", shortcut: String = "") -> PaletteEntry {
        PaletteEntry(id: .host(host), title: host, detail: detail, shortcut: shortcut, symbol: "globe",
                     operation: .run { [routes] in routes.connect(.remote(host)) })
    }

    func connectEntries(query: String, invalid: Bool) -> [(entry: PaletteEntry, offsets: [[Int]])] {
        var result: [(PaletteEntry, [[Int]])] = []
        if !query.isEmpty, !invalid {
            result.append((PaletteEntry(id: .connectTyped, title: "Connect to " + query, detail: "", shortcut: "↩", symbol: "globe", operation: .connectTyped(query)), [[], []]))
        }
        let now = Date()
        result += routes.recent.entries.compactMap { recent -> (PaletteEntry, [[Int]])? in
            guard let offsets = query.isEmpty ? [] : fuzzyMatch(query, recent.host)?.offsets else { return nil }
            return (hostEntry(recent.host, shortcut: relativeTime(recent.date, now: now)), [offsets, []])
        }
        if query.isEmpty, !routes.recent.isEmpty {
            result.append((PaletteEntry(id: .clearRecent, title: "Clear Recent Hosts", detail: "", operation: .clearRecent), [[], []]))
        }
        return result
    }

}

@MainActor private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    return formatter
}()

@MainActor private func relativeTime(_ date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "Just now" }
    if seconds < 3600 { return "\(seconds / 60) m ago" }
    if seconds < 86400 { return "\(seconds / 3600) h ago" }
    let days = seconds / 86400
    return relativeFormatter.localizedString(from: days < 7 ? DateComponents(day: -days) : DateComponents(weekOfMonth: -(days / 7)))
}
