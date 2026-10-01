import AppKit
import TmuxControl

final class Connection: @unchecked Sendable {
    private let client: Client
    private final class PaneFeed: @unchecked Sendable {
        enum History {
            case syncing(UUID)
            case complete
            case more(gap: Int)
            case limited
            case alternate
            case fetching(UUID)
        }
        let view: PaneView
        var history: History = .syncing(UUID())
        var search: (token: UUID, matches: [Int])?
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
            panes?[p]?.view.feed(Data(bytes))
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
            feed.view.clearScrollTarget()
            DispatchQueue.main.async { [weak view = feed.view] in view?.resetScroll() }
            self.client.send(first + PaneSync.commands(pane, chunk: chunk)) { [weak self, weak feed] replies in
                guard let self, let feed, self.panes?[pane] === feed,
                      case .syncing(let current) = feed.history, current == token, let replies else { return synced?() ?? () }
                switch PaneSync.restore(replies.dropFirst(first.count)) {
                case .expand(let history):
                    self.sync(pane, synced: synced, chunk: min(history, chunk * 2))
                    return
                case .snapshot(let data, let history):
                    feed.view.feed(data)
                    let position = feed.view.scrollPosition()
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

    private func search(_ pane: PaneID, query: String, token: UUID) {
        client.queue.async {
            guard let feed = self.panes?[pane] else { return }
            feed.search = (token, [])
            guard !query.isEmpty else { return }
            self.searchChunk(pane, feed, query: query, token: token, end: nil)
        }
    }

    private func searchChunk(_ pane: PaneID, _ feed: PaneFeed, query: String, token: UUID,
                             end: Int?, chunk: Int = 5000) {
        client.send(SearchCapture.commands(pane, end: end, chunk: chunk)) { [weak self, weak feed] replies in
            guard let self, let feed, self.panes?[pane] === feed, feed.search?.token == token else { return }
            guard let replies else { return }
            let identity = ObjectIdentifier(feed)
            DispatchQueue.global(qos: .userInitiated).async {
                let capture = SearchCapture(replies, query: query)
                self.client.queue.async {
                    guard let feed = self.panes?[pane], ObjectIdentifier(feed) == identity,
                          feed.search?.token == token else { return }
                    guard let capture else {
                        return DispatchQueue.main.async { [weak view = feed.view] in view?.find?.failed(token) }
                    }
                    if let next = capture.next {
                        if next == end || (end == nil && next >= -1 && capture.distances.isEmpty) {
                            self.searchChunk(pane, feed, query: query, token: token, end: end,
                                             chunk: min(capture.history + 1, chunk * 2))
                        } else {
                            feed.search?.matches.append(contentsOf: capture.distances)
                            self.searchChunk(pane, feed, query: query, token: token, end: next)
                        }
                    } else {
                        feed.search?.matches.append(contentsOf: capture.distances)
                        let all = feed.search?.matches ?? []
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
            case .more(let gap) where destination >= position.history - position.rows:
                self.publish(feed, history: position.history + gap)
                let token = UUID()
                feed.history = .fetching(token)
                self.fetch(pane, feed, token: token, chunk: min(5000, gap))
            default:
                let limited = if case .limited = feed.history { true } else { false }
                let token = UUID()
                feed.history = .fetching(token)
                self.client.send([Command("display-message", "-p", "-t", pane, "#{history_size} #{alternate_on}")]) {
                    [weak self, weak feed] replies in
                    guard let self, let feed, self.panes?[pane] === feed,
                          case .fetching(let current) = feed.history, current == token else { return }
                    guard let replies, case .success(let lines) = replies.first,
                          let values = lines.first?.split(separator: " ").compactMap({ Int($0) }), values.count == 2 else {
                        feed.history = .complete
                        return
                    }
                    let history = values[0], position = feed.view.scrollPosition()
                    if values[1] != 0 {
                        feed.history = .alternate
                        return self.publish(feed, history: 0, alternate: true)
                    }
                    feed.history = limited ? .limited : (history > position.history ? .more(gap: history - position.history) : .complete)
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
            guard let capture = HistoryCapture(replies, loaded: position.history) else {
                feed.history = .limited
                return
            }
            if capture.alternate {
                feed.history = .alternate
                return self.publish(feed, history: 0, alternate: true)
            }
            if let destination = feed.view.scrollTarget, destination < position.history - position.rows {
                feed.history = capture.history > position.history ? .more(gap: capture.history - position.history) : .complete
                self.publish(feed, history: capture.history)
                self.scroll(pane)
                return
            }
            if capture.rows == 0 && capture.history > position.history && chunk < capture.history {
                return self.fetch(pane, feed, token: token, chunk: min(capture.history, chunk * 2))
            }
            let added = capture.rows == 0 ? 0 : feed.view.prepend(Data(capture.text.utf8), epoch: epoch)
            let loaded = feed.view.scrollPosition().history
            feed.history = added == 0 && capture.history > loaded ? .limited
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
