import AppKit
import GhosttyKit
import TmuxControl

final class Connection: @unchecked Sendable {
    private let client: Client
    private final class PaneFeed: @unchecked Sendable {
        enum History {
            case syncing(UUID)
            case complete
            case more(gap: Int)
            case limited(history: Int)
            case fetching(UUID)
        }
        let view: PaneView
        var history: History = .syncing(UUID())
        enum Search {
            case scanning(token: UUID, matches: [Int])
            case stale(since: DispatchTime, restart: DispatchWorkItem?)
        }
        var search: Search?
        var metadataDirty = false
        var initialHistory = 0
        init(_ view: PaneView) { self.view = view }
    }
    private var panes: [PaneID: PaneFeed]? = [:]
    private var reasons: [String] = []
    private var detached: String?
    @MainActor private var retiring: [ObjectIdentifier: PaneView] = [:]
    @MainActor private var freeing: [PaneView] = []
    @MainActor private weak var view: SessionView?
    @MainActor private var sizing: DispatchWorkItem?
    @MainActor private(set) var model = SessionModel() {
        didSet { onChange(model) }
    }
    @MainActor private let onChange: (SessionModel) -> Void
    @MainActor private let onClose: (Exit) -> Void

    @MainActor init(
        server: Server, view: SessionView, onChange: @escaping (SessionModel) -> Void,
        onClose: @escaping (Exit) -> Void
    ) throws {
        self.view = view
        self.onChange = onChange
        self.onClose = onClose
        client = Client(tmux: URL(fileURLWithPath: server.tmux), socket: server.socket, session: nil, pauseAfter: 5)
        view.connection = self
        try client.start(
            onEvent: { [weak self] in self?.handle($0) },
            onClose: { [weak self] status, stderr in self?.closed(status, stderr) })
    }

    @MainActor func attach(_ pane: PaneView, synced: (@Sendable () -> Void)? = nil) {
        client.queue.async {
            guard self.panes != nil else { return DispatchQueue.main.async { _ = pane } }
            self.panes?[pane.pane] = PaneFeed(pane)
        }
        pane.onScroll = { [weak self, weak pane] in
            guard let pane else { return }
            self?.scroll(pane.pane)
        }
        pane.onScrollSettled = { [weak self, id = pane.pane] in
            guard let self else { return }
            self.client.queue.async {
                guard let feed = self.panes?[id], feed.search == nil else { return }
                let position = feed.view.scrollPosition()
                let history: Int
                switch feed.history {
                case .syncing, .fetching: return
                case .complete: history = position.history
                case .more(let gap): history = position.history + gap
                case .limited(let total): history = total
                }
                let removed = feed.view.trimHistory(keeping: feed.initialHistory)
                guard removed > 0 else { return }
                let gap = max(0, history - feed.view.scrollPosition().history)
                feed.history = gap > 0 ? .more(gap: gap) : .complete
                self.publish(feed, history: history)
            }
        }
        pane.onLoadMore = { [weak self, id = pane.pane] in
            guard let self else { return }
            self.client.queue.async {
                guard let feed = self.panes?[id], case .limited(let history) = feed.history else { return }
                ghostty_surface_raise_scrollback_limit(feed.view.surface)
                feed.history = .more(gap: max(0, history - feed.view.scrollPosition().history))
                self.scroll(id)
            }
        }
        pane.onSearch = { [weak self, weak pane] query, token in
            guard let pane else { return }
            self?.search(pane.pane, query: query, token: token)
        }
        sync(pane.pane, synced: synced)
    }

    @MainActor func detach(_ pane: PaneView) {
        let id = pane.pane, key = ObjectIdentifier(pane)
        retiring[key] = pane
        client.queue.async {
            if self.panes?[id].map { ObjectIdentifier($0.view) } == key { self.panes?[id] = nil }
            DispatchQueue.main.async {
                guard let pane = self.retiring.removeValue(forKey: key) else { return }
                self.freeing.append(pane)
                if self.freeing.count == 1 { self.free() }
            }
        }
    }

    // Freeing a surface takes milliseconds on main, and hundreds of them when
    // it was created moments earlier, so surfaces are freed one per turn, each
    // at least a second old.
    @MainActor private func free() {
        guard let next = freeing.first else { return }
        DispatchQueue.main.asyncAfter(deadline: max(.now() + 0.005, next.born + 1)) {
            let start = DispatchTime.now(), pane = self.freeing.removeFirst().pane
            debug("freed \(pane) in \(milliseconds(since: start)), \(self.freeing.count) to free")
            self.free()
        }
    }

    func send(_ commands: [Command], then done: (@MainActor @Sendable ([Reply]?) -> Void)? = nil) {
        client.send(commands) { replies in
            if let done { DispatchQueue.main.async { done(replies) } }
        }
    }

    func locateFeed(_ done: @escaping @Sendable (Result<Feed.Location, Failure>) -> Void) {
        client.send([Command("show-options", "-gv", "side-status-command"), Command("display-message", "-p", "#{client_name}")]) {
            replies in
            guard let replies, replies.count == 2, case .success(let command) = replies[0], let raw = command.first,
                case .success(let name) = replies[1], let client = name.first
            else { return done(.failure(Failure(message: "could not read side-status-command or the client name"))) }
            // `Launch.conf_command` double-quotes a path that contains a space
            // or a tab, and show-options prints the quotes back (lib/launch.ml).
            let quoted = raw.count >= 2 && raw.hasPrefix("\"") && raw.hasSuffix("\"")
            done(.success((kido: quoted ? String(raw.dropFirst().dropLast()) : raw, client: client)))
        }
    }

    func sendKeys(_ pane: PaneID, _ bytes: Data) {
        for keys in Command.sendKeys(pane, bytes) { send([keys]) }
    }

    @MainActor func resize(cols: Int, rows: Int) {
        sizing?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.send([Command("refresh-client", "-C", "\(cols)x\(rows)")]) }
        sizing = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func handle(_ event: Event) {
        switch event {
        case .output(let p, let bytes), .extendedOutput(let p, _, let bytes):
            if let feed = panes?[p] {
                feed.metadataDirty = true
                invalidateSearch(feed, restart: true)
                feed.view.feed(Data(bytes))
            }
        case .pause(let p):
            let resume = Command("refresh-client", "-A", "\(p):continue")
            if panes?[p] == nil { send([resume]) } else { sync(p, first: [resume]) }
        case .layoutChange(let window, let layout, let visible, _):
            DispatchQueue.main.sync { self.view?.windows[window]?.update(layout, visible) }
        case .windowPaneChanged(let window, let pane):
            DispatchQueue.main.async { self.view?.windows[window]?.focus(pane) }
        case .sessionWindowChanged(let s, let window):
            DispatchQueue.main.async {
                if s == self.model.session { self.model.window = window }
            }
        case .sessionChanged:
            reasons = []
            refresh()
        case .sessionsChanged, .sessionRenamed, .windowAdd(_, .linked), .windowClose,
            .windowRenamed(_, .linked, _):
            refresh()
        case .exit(.detached(let reason)):
            detached = reason
        case .exit(.ended(let reason?)):
            reasons.append(reason)
        case .block(.failure(let lines), .other):
            reasons += lines
        default:
            break
        }
    }

    private func refresh() {
        let commands = [
            Command("list-sessions", "-F", SessionListing.format), Command("display-message", "-p", "#{session_id}"),
            Command("list-windows", "-F", WindowListing.format), Command("list-windows", "-a", "-F", "#{window_id}"),
        ]
        client.send(commands) { [weak self] replies in
            guard let replies else { return }
            guard replies.count == 4, case .success(let sessions) = replies[0], case .success(let current) = replies[1],
                let session = current.first.flatMap(SessionID.init), case .success(let windows) = replies[2],
                case .success(let all) = replies[3]
            else { return self?.report("could not list the session's windows: \(replies)") ?? () }
            let listing = windows.compactMap(WindowListing.init)
            DispatchQueue.main.sync {
                guard let self else { return }
                self.view?.update(listing, alive: Set(all.compactMap(WindowID.init)))
                self.model = SessionModel(
                    sessions: sessions.compactMap(SessionListing.init), session: session,
                    windows: listing.map { .init(id: $0.id, name: $0.name) }, window: listing.first(where: \.active)?.id)
            }
        }
    }

    // %output queued before a reply is written ahead of its %begin
    // (control.c), and the reply is completed on the reader queue, so output
    // fed before the restore is wiped by it and output after it is not in it.
    func sync(_ pane: PaneID, first: [Command] = [], synced: (@Sendable () -> Void)? = nil, chunk: Int = 5000) {
        client.queue.async {
            guard let feed = self.panes?[pane] else { return synced?() ?? () }
            let token = UUID()
            feed.history = .syncing(token)
            self.invalidateSearch(feed, restart: false)
            feed.view.clearScrollTarget()
            DispatchQueue.main.async { [weak view = feed.view] in view?.resetScroll() }
            let epoch = feed.view.historyEpoch
            self.client.send(first + PaneSync.commands(pane, chunk: chunk)) { [weak self, weak feed] replies in
                guard let self, let feed, self.panes?[pane] === feed, feed.view.historyEpoch == epoch,
                      case .syncing(let current) = feed.history, current == token, let replies else { return synced?() ?? () }
                switch PaneSync.restore(replies.dropFirst(first.count)) {
                case .expand(let history):
                    self.sync(pane, synced: synced, chunk: min(history, chunk * 2))
                    return
                case .snapshot(let data, let history):
                    feed.view.feed(data)
                    let position = feed.view.scrollPosition()
                    feed.metadataDirty = false
                    feed.initialHistory = position.history
                    if let anchor = feed.view.resizeAnchor {
                        self.restoreAnchor(pane, feed, anchor: anchor, token: token, epoch: epoch, history: history, captured: chunk, synced: synced)
                        return
                    }
                    feed.history = history > position.history ? .more(gap: history - position.history) : .complete
                    self.publish(feed, history: history)
                    DispatchQueue.main.async { [weak view = feed.view] in view?.find?.search() }
                case nil:
                    feed.view.feed(Self.notice("could not capture \(pane): \(replies)"))
                }
                synced?()
            }
        }
    }

    private func restoreAnchor(_ pane: PaneID, _ feed: PaneFeed, anchor: ScrollAnchor, token: UUID,
                               epoch: Int, history: Int, captured: Int, end: Int? = nil, chunk: Int = 5000,
                               synced: (@Sendable () -> Void)?) {
        client.send(SearchCapture.commands(pane, end: end, chunk: chunk)) { [weak self, weak feed] replies in
            guard let self, let feed, self.panes?[pane] === feed, feed.view.historyEpoch == epoch,
                  case .syncing(let current) = feed.history, current == token else { return synced?() ?? () }
            let distance: Int
            switch replies.flatMap({ anchor.locate($0, end: end) }) {
            case .next(let remaining, let next):
                if next == end {
                    self.restoreAnchor(pane, feed, anchor: anchor, token: token, epoch: epoch, history: history, captured: captured, end: end,
                                       chunk: min(history + 1, chunk * 2), synced: synced)
                } else {
                    self.restoreAnchor(pane, feed, anchor: remaining, token: token, epoch: epoch, history: history, captured: captured, end: next, synced: synced)
                }
                return
            case .found(let row): distance = row
            case nil: distance = min(history, max(1, anchor.lines))
            }
            let loaded = feed.view.scrollPosition()
            if distance > loaded.history, captured < history {
                self.sync(pane, synced: synced, chunk: min(history, max(captured * 2, distance + loaded.rows)))
                return
            }
            let position = feed.view.scrollPosition(distance: distance)
            feed.history = history > position.history ? .more(gap: history - position.history) : .complete
            feed.view.resizeAnchor = nil
            self.publish(feed, history: history)
            DispatchQueue.main.async { [weak view = feed.view] in
                view?.requestScroll(distance)
                view?.find?.search()
            }
            synced?()
        }
    }

    private func invalidateSearch(_ feed: PaneFeed, restart: Bool) {
        let since: DispatchTime
        switch feed.search {
        case .scanning:
            since = .now()
            DispatchQueue.main.async { [weak view = feed.view] in view?.find?.invalidate() }
        case .stale(let start, let work): since = start; work?.cancel()
        case nil: return
        }
        feed.search = .stale(since: since, restart: nil)
        guard restart else { return }
        if case .syncing = feed.history { return }
        let work = DispatchWorkItem { [weak feed] in
            guard let feed, case .stale = feed.search else { return }
            DispatchQueue.main.async { [weak view = feed.view] in view?.find?.search() }
        }
        feed.search = .stale(since: since, restart: work)
        client.queue.asyncAfter(deadline: min(.now() + 0.3, since + 2), execute: work)
    }

    private func search(_ pane: PaneID, query: String, token: UUID) {
        client.queue.async {
            guard let feed = self.panes?[pane] else { return }
            if case .stale(_, let work) = feed.search { work?.cancel() }
            feed.search = query.isEmpty ? nil : .scanning(token: token, matches: [])
            guard !query.isEmpty else { return }
            if case .syncing = feed.history { return self.invalidateSearch(feed, restart: false) }
            self.searchChunk(pane, feed, query: query, token: token, end: nil)
        }
    }

    private func searchChunk(_ pane: PaneID, _ feed: PaneFeed, query: String, token: UUID,
                             end: Int?, chunk: Int = 5000) {
        client.send(SearchCapture.commands(pane, end: end, chunk: chunk)) { [weak self, weak feed] replies in
            guard let self, let feed, self.panes?[pane] === feed,
                  case .scanning(let current, _) = feed.search, current == token else { return }
            guard let replies else { return }
            let identity = ObjectIdentifier(feed)
            DispatchQueue.global(qos: .userInitiated).async {
                let capture = SearchCapture(replies, query: query)
                self.client.queue.async {
                    guard let feed = self.panes?[pane], ObjectIdentifier(feed) == identity,
                          case .scanning(let current, let matches) = feed.search, current == token else { return }
                    guard let capture else {
                        return DispatchQueue.main.async { [weak view = feed.view] in view?.find?.failed(token) }
                    }
                    if let next = capture.next {
                        if next == end || (end == nil && next >= -1 && capture.distances.isEmpty) {
                            self.searchChunk(pane, feed, query: query, token: token, end: end,
                                             chunk: min(capture.history + 1, chunk * 2))
                        } else {
                            feed.search = .scanning(token: token, matches: matches + capture.distances)
                            self.searchChunk(pane, feed, query: query, token: token, end: next)
                        }
                    } else {
                        let all = matches + capture.distances
                        feed.search = .scanning(token: token, matches: all)
                        DispatchQueue.main.async { [weak view = feed.view] in view?.find?.finished(all, token: token) }
                    }
                }
            }
        }
    }

    private func scroll(_ pane: PaneID) {
        client.queue.async {
            guard let feed = self.panes?[pane] else { return }
            let position = feed.view.scrollPosition()
            let destination = feed.view.scrollTarget ?? (position.history - position.offset)
            switch feed.history {
            case .syncing, .fetching: return
            case .limited(let history) where !feed.metadataDirty:
                self.publish(feed, history: history)
                return
            case .more(let gap) where destination >= position.history - position.rows:
                self.publish(feed, history: position.history + gap)
                let token = UUID()
                feed.history = .fetching(token)
                self.fetch(pane, feed, token: token, chunk: min(5000, gap))
            default:
                guard feed.metadataDirty else { return }
                let limited = if case .limited = feed.history { true } else { false }
                feed.metadataDirty = false
                let token = UUID()
                feed.history = .fetching(token)
                self.client.send([Command("display-message", "-p", "-t", pane, "#{history_size} #{alternate_on}")]) {
                    [weak self, weak feed] replies in
                    guard let self, let feed, self.panes?[pane] === feed,
                          case .fetching(let current) = feed.history, current == token else { return }
                    guard let metadata = HistoryMetadata(replies?.first) else {
                        feed.history = .complete
                        return
                    }
                    let history = metadata.history, position = feed.view.scrollPosition()
                    if metadata.alternate {
                        feed.history = .complete
                        return self.publish(feed, history: 0, alternate: true)
                    }
                    feed.history = limited ? .limited(history: history) : (history > position.history ? .more(gap: history - position.history) : .complete)
                    self.publish(feed, history: history)
                    let destination = feed.view.scrollTarget ?? (position.history - position.offset)
                    if !limited && history > position.history && destination >= position.history - position.rows { self.scroll(pane) }
                }
            }
        }
    }

    private func fetch(_ pane: PaneID, _ feed: PaneFeed, token: UUID, chunk: Int = 5000) {
        let position = feed.view.scrollPosition(), epoch = feed.view.historyEpoch
        client.send(HistoryCapture.commands(pane, loaded: position.history, chunk: chunk)) { [weak self, weak feed] replies in
            guard let self, let feed, self.panes?[pane] === feed,
                  case .fetching(let current) = feed.history, current == token,
                  feed.view.historyEpoch == epoch, let replies else { return }
            let position = feed.view.scrollPosition()
            feed.metadataDirty = false
            if let destination = feed.view.scrollTarget, destination < position.history - position.rows,
               let metadata = HistoryMetadata(replies.first) {
                feed.history = metadata.history > position.history ? .more(gap: metadata.history - position.history) : .complete
                self.publish(feed, history: metadata.history, alternate: metadata.alternate)
                return
            }
            guard let capture = HistoryCapture(replies, loaded: position.history) else {
                feed.history = .limited(history: HistoryMetadata(replies.first)?.history ?? position.history)
                return
            }
            if capture.alternate {
                feed.history = .complete
                return self.publish(feed, history: 0, alternate: true)
            }
            if capture.rows == 0 && capture.history > position.history && chunk < capture.history {
                return self.fetch(pane, feed, token: token, chunk: min(capture.history, chunk * 2))
            }
            let added = capture.rows == 0 ? 0 : feed.view.prepend(Data(capture.text.utf8), epoch: epoch)
            let loaded = feed.view.scrollPosition().history
            feed.history = added == 0 && capture.history > loaded ? .limited(history: capture.history)
                : (capture.history > loaded ? .more(gap: capture.history - loaded) : .complete)
            self.publish(feed, history: capture.history)
            if feed.view.scrollTarget != nil {
                self.scroll(pane)
            }
        }
    }

    private func publish(_ feed: PaneFeed, history: Int, alternate: Bool = false) {
        let position = feed.view.scrollPosition(distance: feed.view.scrollTarget)
        let limited = if case .limited = feed.history { true } else { false }
        DispatchQueue.main.async { [weak view = feed.view] in
            view?.updateScroller(history: history, position: position, alternate: alternate, limited: limited)
            view?.find?.loaded(position, limited: limited)
        }
    }

    private func closed(_ status: Int32, _ stderr: String) {
        let gone = panes, reason = (reasons + [stderr]).filter { !$0.isEmpty }.joined(separator: "\n")
        let exit = detached.map(Exit.detached) ?? .ended(reason.isEmpty ? nil : reason)
        let why = switch exit {
        case .detached(let reason): "detached: \(reason)"
        case .ended(let reason): "ended: \(reason ?? "no reason given")"
        }
        note("connection closed, tmux exited \(status), \(why.replacingOccurrences(of: "\n", with: "; "))")
        panes = nil
        DispatchQueue.main.async { withExtendedLifetime(gone) { self.onClose(exit) } }
    }

    private func report(_ message: String) {
        panes?.values.forEach { $0.view.feed(Self.notice(message)) }
    }

    private static func notice(_ message: String) -> Data {
        Data("\r\n\u{1B}[m[kido: \(message)]".utf8)
    }
}
