import AppKit
import KoModel
import SidebarFeed
import PaneGeometry

struct PaletteEntry {
    enum ID: Equatable {
        case pane(Snapshot.Position), host(String), command(Int), connectTyped, clearRecent, theme(String), themeUse(Int)
        case runtime(RuntimeKey), hostRuntime, runtimeOpen(Int), runtimeDown
    }
    let id: ID
    var order = 0
    let title: String
    let detail: String
    var shortcut = ""
    var status: SidebarRow.Status?
    var symbol: String?
    var theme: ThemeRow?
    var radio: Bool { if case .themeUse = id { true } else { false } }
    // A runtime row has its swatch in the icon slot, its detail at the right, and a failed link's message in red, cut
    // at 300pt. A row of the runtime step has its detail after the title and the return key when selected.
    var swatch: RuntimeMark?
    var detailAtRight: Bool { switch id { case .hostRuntime, .runtime: true; default: false } }
    var inline: Bool { switch id { case .runtimeOpen, .runtimeDown: true; default: false } }
    var cutDetail: String? { swatch?.failure }
    var failed: Bool { cutDetail != nil }
    var agent = false
    var promptable = false
    var check: @MainActor () -> String? = { nil }
    enum Operation {
        case run(@MainActor () -> Void), enter(PaletteMode), connectTyped(String), clearRecent, themeChoose, themeUse
    }
    let operation: Operation

    @MainActor static func panes(_ owner: WindowOwner) -> [PaletteEntry] {
        guard owner.canNavigate, let snapshot = owner.snapshot else { return [] }
        let instance = snapshot.serverInstance
        let host = if case .remote(let destination) = owner.host { [destination] } else { [String]() }
        let resolve: @MainActor (SidebarRow) -> WindowOwner? = { [weak owner] row in
            guard let owner, owner.canNavigate, owner.snapshot?.serverInstance == instance,
                  sidebarRows(owner.snapshot).contains(where: { $0.id == row.id }) else { return nil }
            return owner
        }
        let reachable = Set(snapshot.promptPanes.filter(\.agent).map(\.pane))
        var session = ""
        return sidebarRows(owner.snapshot).compactMap { row in
            if case .header = row.id { session = row.title }
            guard let target = row.topLevel else { return nil }
            return PaletteEntry(id: .pane(target), title: row.title, detail: (host + [session]).joined(separator: " › "), status: row.status, agent: row.agent, promptable: reachable.contains(target.pane), check: { resolve(row) == nil ? "That pane is gone" : nil }, operation: .run { let owner = resolve(row); owner?.reveal(); owner?.perform(.jump(target)) })
        }
    }

    // `Host` when the pane in focus runs in a runtime, then one row for each runtime of the server.
    @MainActor static func runtimes(_ owner: WindowOwner) -> [PaletteEntry] {
        guard owner.canNavigate else { return [] }
        let host: [PaletteEntry] = owner.focusedRuntime == nil ? [] : [
            PaletteEntry(id: .hostRuntime, title: "Host", detail: "this Mac", symbol: "desktopcomputer", operation: .enter(.runtime(nil)))
        ]
        return host + owner.runtimes.map { runtime in
            let mark = RuntimeMark.known(runtime, routed: false)
            let detail = ["\(runtime.kind.rawValue)", runtime.state.stateWord, runtime.state.failure].compactMap { $0 }.joined(separator: " · ")
            return PaletteEntry(id: .runtime(runtime.key), title: "Runtime: " + owner.runtimeLabel(runtime.key), detail: detail, swatch: mark, operation: .enter(.runtime(mark)))
        }
    }

    // The ways to open a pane in a runtime. The splits need a live pane in focus, as the split commands do.
    @MainActor static func runtimeStep(_ mark: RuntimeMark?, owner: WindowOwner?, responder: NSResponder?) -> [PaletteEntry] {
        guard let owner, owner.canNavigate else { return [] }
        let target: NewPaneRuntime = mark.map { .named($0.name) } ?? .host
        var rows = [PaletteEntry(id: .runtimeOpen(0), title: "New Window", detail: "in session " + (owner.snapshot.flatMap { s in s.sessions.first { $0.id == s.client.session } }?.name ?? ""),
                                 check: { [weak owner] in owner?.canNavigate == true ? nil : "Not available now" },
                                 operation: .run { [weak owner] in owner?.newWindow(in: nil, target) })]
        if let pane = livePane(owner, responder) {
            for (index, (title, detail, side)) in [("Split Right", "beside the focused pane", Side.right), ("Split Down", "below the focused pane", Side.down)].enumerated() {
                rows.append(PaletteEntry(id: .runtimeOpen(index + 1), title: title, detail: detail,
                                         check: { [weak owner, weak pane] in owner?.canNavigate == true && pane?.window === owner?.window ? nil : "Not available now" },
                                         operation: .run { [weak owner, weak pane] in
                    guard let owner, let pane else { return }
                    owner.paneCommand(.split(side), pane.pane, target)
                }))
            }
        }
        if let mark, owner.canShutDownRuntime(mark.key) {
            rows.append(PaletteEntry(id: .runtimeDown, title: "Shut Down Runtime", detail: mark.name,
                                     check: { [weak owner] in owner?.canShutDownRuntime(mark.key) == true ? nil : "Not available now" },
                                     operation: .run { [weak owner] in owner?.shutDownRuntime(mark.key) }))
        }
        return rows
    }

    private enum Scope { case always, window, pane }

    @MainActor static func commands(_ menu: NSMenu, owner: WindowOwner?, responder: NSResponder?, path: [String] = []) -> [PaletteEntry] {
        return menu.items.flatMap { item -> [PaletteEntry] in
            if let submenu = item.submenu { return commands(submenu, owner: owner, responder: responder, path: path + [item.title].filter { !$0.isEmpty }) }
            guard let action = item.action, let (order, scope) = commandOrder(item), !item.isHidden else { return [] }
            let available = switch scope { case .always: true; case .window: owner != nil; case .pane: livePane(owner, responder) != nil }
            guard available, enabled(item, owner: owner, responder: responder) else { return [] }
            let operation: Operation
            var title = item.title
            if action == #selector(AppDelegate.connectRemoteHost) { operation = .enter(.connect) }
            else if action == #selector(AppDelegate.newSession), let owner {
                title = "New Session…"
                if let instance = owner.snapshot?.serverInstance { operation = .enter(.sessionName(owner, instance, .create)) }
                else { operation = .run {} }
            }
            else if action == #selector(AppDelegate.showThemes) { operation = .enter(.theme(.pick)) }
            else if action == #selector(SessionMenus.renameItem), let owner, let session = owner.currentSession, let instance = owner.snapshot?.serverInstance {
                operation = .enter(.sessionName(owner, instance, .rename(session.id, original: session.name)))
            } else if action == #selector(PaneView.promptSelectionItem(_:)), let owner, let pane = livePane(owner, responder),
                      let position = owner.projection.placements[pane.pane]?.position,
                      let source = owner.promptSource(position, quote: pane.selectionQuote) {
                operation = .enter(.prompt(source))
            } else { operation = .run { NSApp.sendAction(action, to: item.target, from: item) } }
            return [PaletteEntry(id: .command(order), order: order, title: title, detail: path.joined(separator: " › "), shortcut: shortcut(item),
                                 check: { [weak owner] in
                if action == #selector(AppDelegate.newSession), let owner, owner.snapshot == nil { return "Not available now" }
                if scope == .pane, livePane(owner, owner?.window.firstResponder) == nil { return "Not available now" }
                return enabled(item, owner: owner, responder: owner?.window.firstResponder) ? nil : "Not available now"
            }, operation: operation)]
        }.sorted { $0.order < $1.order }
    }

    @MainActor private static func livePane(_ owner: WindowOwner?, _ responder: NSResponder?) -> PaneView? {
        guard let owner, owner.canNavigate, let pane = PaneView.owner(responder),
              pane.window === owner.window, !pane.isHiddenOrHasHiddenAncestor else { return nil }
        return pane
    }

    @MainActor private static func enabled(_ item: NSMenuItem, owner: WindowOwner?, responder: NSResponder?) -> Bool {
        guard item.menu?.autoenablesItems != false else { return item.isEnabled }
        var target: Any? = item.target
        if target == nil, let action = item.action {
            var next = responder
            while let candidate = next {
                if candidate.responds(to: action) { target = candidate; break }
                next = candidate.nextResponder
            }
            if target == nil, let pane = PaneView.owner(responder), pane.responds(to: action) { target = pane }
            if target == nil, let owner, owner.responds(to: action) { target = owner }
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
        case #selector(WindowOwner.navigateHistoryBack(_:)): (5, .window)
        case #selector(WindowOwner.navigateHistoryForward(_:)): (6, .window)
        case #selector(PaneView.runCommand(_:)):
            switch item.representedObject as? PaneCommand {
            case .newWindow: (3, .pane)
            case .split(.right): (7, .pane)
            case .split(.down): (8, .pane)
            case .close: (9, .pane)
            case .zoom: (10, .pane)
            case .float: (11, .pane)
            default: nil
            }
        case #selector(AppDelegate.connectLocalHost): (12, .always)
        case #selector(AppDelegate.connectRemoteHost): (13, .always)
        case #selector(Sidebar.toggleSidebar(_:)): (14, .window)
        case #selector(Sidebar.focusSidebar(_:)): (15, .window)
        case NSSelectorFromString("toggleFullScreen:"): (16, .window)
        case #selector(PaneView.showFind(_:)): (17, .pane)
        case #selector(PaneView.toggleCopyMode(_:)): (18, .pane)
        case #selector(PaneView.promptSelectionItem(_:)): (19, .pane)
        case #selector(AppDelegate.resetClipboardPermissions): (20, .window)
        case #selector(AppDelegate.showThemes): (21, .always)
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
        return (owner.map { PaletteEntry.panes($0) + PaletteEntry.runtimes($0) } ?? [])
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
