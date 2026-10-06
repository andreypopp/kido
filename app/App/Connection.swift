import AppKit
import GhosttyKit
import TmuxControl
#if KIDO_VISUAL
import os
#endif

final class Connection: @unchecked Sendable {
    private let client: Client
    #if KIDO_VISUAL
    private let metadataQueries = OSAllocatedUnfairLock(initialState: 0)
    var visualMetadataQueries: Int { metadataQueries.withLock { $0 } }
    #endif
    private final class PaneFeed: @unchecked Sendable {
        enum Boundary { case older, exhausted(epoch: Int), refused }
        final class RestoreRequest: @unchecked Sendable {
            let epoch: Int
            var completions: [@Sendable () -> Void]
            init(epoch: Int, synced: (@Sendable () -> Void)?) {
                self.epoch = epoch
                completions = synced.map { [$0] } ?? []
            }
        }
        enum History {
            case syncing(RestoreRequest)
            case settled(Boundary)
            case fetching(UUID)
        }
        let view: PaneView
        var history: History = .settled(.older)
        enum Search {
            case scanning(token: UUID, matches: [Int])
            case stale(since: DispatchTime, restart: DispatchWorkItem?)
        }
        var search: Search?
        var sampledTmuxHistoryRows = 0
        var outputEpoch = 0
        var goal: (distance: Int, token: UUID)?
        var preparingRestore = false
        var pendingRestore: (first: [Command], synced: (@Sendable () -> Void)?)?
        init(_ view: PaneView) { self.view = view }
        func completePendingRestore() {
            let pending = pendingRestore
            pendingRestore = nil
            pending?.synced?()
        }
    }
    private var panes: [PaneID: PaneFeed]? = [:]
    private var reasons: [String] = []
    private var detached: String?
    @MainActor private var retiring: [ObjectIdentifier: PaneView] = [:]
    @MainActor private var freeing: [PaneView] = []
    @MainActor private weak var view: SessionView?
    @MainActor private(set) var active = true
    let host: Host
    @MainActor var onURL: (String) -> Void = { _ in }
    @MainActor private var sizing: DispatchWorkItem?
    @MainActor private var desiredSize: String?
    @MainActor private var sentSize: String?
    @MainActor private var sizeInFlight = false
    @MainActor var navigationModel: () -> SessionModel = { SessionModel() }
    @MainActor private(set) var model = SessionModel() {
        didSet { onChange(model) }
    }
    @MainActor private let onChange: (SessionModel) -> Void
    @MainActor private let onClose: (Exit) -> Void
    @MainActor private let onDiagnostic: (String) -> Void

    @MainActor init(
        server: Server, view: SessionView, launch: Launch? = nil, host: Host = .local, drain: Drain? = nil, onChange: @escaping (SessionModel) -> Void,
        onDiagnostic: @escaping (String) -> Void, onClose: @escaping (Exit) -> Void
    ) throws {
        self.view = view
        self.host = host
        self.onChange = onChange
        self.onClose = onClose
        self.onDiagnostic = onDiagnostic
        client = Client(launch: launch ?? .attach(server.tmux, socket: server.socket))
        view.connection = self
        try drain?.enter()
        do {
            try client.start(
                onEvent: { [weak self] in self?.handle($0) },
                onClose: { [weak self] status, stderr in self?.closed(status, stderr) },
                onExit: { drain?.ended.leave() })
        } catch {
            drain?.ended.leave()
            throw error
        }
        client.send([Command("refresh-client", "-B", "windows::#{W:#{window_id}=#{window_index},}")]) { _ in }
    }

    @MainActor func openURL(_ text: String) {
        guard active else { return }
        onURL(text)
    }

    @MainActor func close(keepingView: Bool = false) {
        guard active else { return }
        active = false
        view?.invalidateClipboard()
        sizing?.cancel()
        sizing = nil
        if !keepingView { view?.close() }
        view?.connection = nil
        view = nil
        client.close()
        client.queue.async {
            let gone = self.teardown()
            DispatchQueue.main.async { withExtendedLifetime(gone) {} }
        }
    }

    @MainActor func attach(_ pane: PaneView, synced: (@Sendable () -> Void)? = nil) {
        guard active else { return }
        client.queue.async {
            guard self.panes != nil else { return DispatchQueue.main.async { _ = pane } }
            self.panes?[pane.pane] = PaneFeed(pane)
        }
        pane.onRestoreDrain = { [weak self, id = pane.pane] in
            guard let self else { return }
            self.client.queue.async {
                guard let feed = self.panes?[id], case .settled = feed.history, feed.pendingRestore != nil else { return }
                self.sync(id)
            }
        }
        pane.onScrollTop = { [weak self, id = pane.pane] in self?.load(id, metadataOnly: true) }
        pane.onLoadMore = { [weak self, id = pane.pane] in self?.load(id) }
        pane.onFindCoverage = { [weak self, id = pane.pane] distance, token in
            self?.load(id, goal: (distance, token))
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
            if let feed = self.panes?[id], ObjectIdentifier(feed.view) == key {
                self.panes?[id] = nil
                feed.completePendingRestore()
            }
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

    #if KIDO_VISUAL
    var visualCommands: [Command] = []
    #endif

    func send(_ commands: [Command], then done: (@MainActor @Sendable ([Reply]?) -> Void)? = nil) {
        #if KIDO_VISUAL
        visualCommands += commands
        #endif
        client.send(commands) { [weak self] replies in
            if let done { DispatchQueue.main.async { [weak self] in guard self?.active == true else { return }; done(replies) } }
        }
    }

    func locateFeed(_ done: @escaping @Sendable (Result<Feed.Location, Failure>) -> Void) {
        client.send([Command("display-message", "-p", "#{client_name}")]) { replies in
            guard case .success(let names)? = replies?.first, let client = names.first else {
                return done(.failure(Failure(message: "could not read the client name")))
            }
            done(.success(client))
        }
    }

    @MainActor func sendKeys(_ pane: PaneID, _ bytes: Data) {
        guard active else { return }
        for keys in Command.sendKeys(pane, bytes) { send([keys]) }
    }

    @MainActor func resize(cols: Int, rows: Int) {
        let size = "\(cols)x\(rows)"
        desiredSize = size == sentSize ? nil : size
        guard desiredSize != nil, sizing == nil, !sizeInFlight else { return }
        let item = DispatchWorkItem { [weak self] in self?.flushSize() }
        sizing = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: item)
    }

    @MainActor func flushSize() {
        sizing?.cancel()
        sizing = nil
        guard !sizeInFlight else { return }
        guard let size = desiredSize else {
            for window in view?.windows.values ?? [:].values {
                for pane in window.panes { pane.endResizeIntent() }
            }
            return
        }
        desiredSize = nil
        sentSize = size
        sizeInFlight = true
        debug("resize t=\(ProcessInfo.processInfo.systemUptime) client-size-send \(size)")
        send([Command("refresh-client", "-C", size)]) { [weak self] _ in
            guard let self else { return }
            debug("resize t=\(ProcessInfo.processInfo.systemUptime) client-size-reply \(size)")
            self.sizeInFlight = false
            self.flushSize()
        }
    }

    @MainActor func syncResize(_ pane: PaneID) -> Bool {
        guard !sizeInFlight, desiredSize == nil else { return false }
        sync(pane)
        return true
    }

    func gridFailed() { client.close() }

    private func handle(_ event: Event) {
        switch event {
        case .output(let p, let bytes), .extendedOutput(let p, _, let bytes):
            if let feed = panes?[p] {
                feed.outputEpoch += 1
                invalidateSearch(feed, restart: true)
                feed.view.feed(Data(bytes))
            }
        case .pause(let p):
            let resume = Command("refresh-client", "-A", "\(p):continue")
            if panes?[p] == nil { send([resume]) } else { sync(p, first: [resume]) }
        case .layoutChange(let window, let layout, let visible, _):
            debug("resize t=\(ProcessInfo.processInfo.systemUptime) layout-received window=\(window)")
            DispatchQueue.main.sync { self.view?.windows[window]?.update(layout, visible) }
        case .windowPaneChanged(let window, let pane):
            DispatchQueue.main.async { self.view?.windows[window]?.focus(pane) }
        case .sessionWindowChanged(let s, let window):
            DispatchQueue.main.async {
                if s == self.model.session { self.model.window = window }
            }
        case .unrecognized(let line) where line.hasPrefix("%subscription-changed windows "):
            refresh()
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
                guard let self, self.active else { return }
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
    func sync(_ pane: PaneID, first: [Command] = [], synced: (@Sendable () -> Void)? = nil) {
        client.queue.async { [self] in
            guard let feed = panes?[pane] else { return synced?() ?? () }
            feed.goal = nil
            if case .syncing(let request) = feed.history,
               request.epoch == feed.view.historyEpoch, first.isEmpty, feed.pendingRestore == nil {
                if let synced { request.completions.append(synced) }
                return
            }
            if let older = feed.pendingRestore {
                feed.pendingRestore = (older.first + first, { older.synced?(); synced?() })
            } else { feed.pendingRestore = (first, synced) }
            guard case .settled = feed.history, !feed.preparingRestore else { return }
            feed.preparingRestore = true
            DispatchQueue.main.async {
                let view = feed.view
                let deferred = (view.superview as? WindowView)?.defersRestore == true
                let epoch = view.historyEpoch
                if !deferred { view.resetScroll() }
                self.client.queue.async {
                    feed.preparingRestore = false
                    guard self.panes?[pane] === feed else {
                        feed.completePendingRestore()
                        return
                    }
                    guard !deferred else { return }
                    guard view.historyEpoch == epoch else { return self.sync(pane) }
                    guard case .settled = feed.history, let pending = feed.pendingRestore else { return }
                    feed.pendingRestore = nil
                    let request = PaneFeed.RestoreRequest(epoch: epoch, synced: pending.synced)
                    feed.history = .syncing(request)
                    self.invalidateSearch(feed, restart: false)
                    self.capture(pane, feed, request: request, first: pending.first)
                }
            }
        }
    }

    private func drain(_ pane: PaneID, _ feed: PaneFeed, retry: Bool = true) {
        if feed.pendingRestore != nil {
            sync(pane)
        } else if retry && feed.view.resizeDirty {
            DispatchQueue.main.async { [weak view = feed.view] in view?.syncResize() }
        }
    }

    private func capture(_ pane: PaneID, _ feed: PaneFeed, request: PaneFeed.RestoreRequest, first: [Command]) {
        let epoch = request.epoch
        debug("resize t=\(ProcessInfo.processInfo.systemUptime) capture-send pane=\(pane) chunk=\(historyChunkSize)")
        client.send(first + PaneSync.commands(pane)) { [weak self, weak feed] replies in
            debug("resize t=\(ProcessInfo.processInfo.systemUptime) capture-reply pane=\(pane)")
            guard let self, let feed, self.panes?[pane] === feed,
                  case .syncing(let current) = feed.history, current === request else { return request.completions.forEach { $0() } }
            var retry = true
            defer { request.completions.forEach { $0() }; self.drain(pane, feed, retry: retry) }
            guard feed.view.historyEpoch == epoch, let replies else {
                if !feed.view.resizeDirty { feed.view.markContentDirty(preserveAnchor: true) }
                feed.history = .settled(.older)
                return
            }
            if let snapshot = PaneSync.restore(replies.dropFirst(first.count)) {
                let (data, history) = (snapshot.data, snapshot.history)
                debug("resize t=\(ProcessInfo.processInfo.systemUptime) replay-start pane=\(pane) bytes=\(data.count)")
                guard feed.view.feed(data, kind: .snapshot, epoch: epoch) else {
                    if !feed.view.resizeDirty { feed.view.markContentDirty(preserveAnchor: true) }
                    feed.history = .settled(.older)
                    return
                }
                debug("resize t=\(ProcessInfo.processInfo.systemUptime) replay-done pane=\(pane)")
                guard feed.view.commitSnapshot(epoch: epoch) else {
                    if !feed.view.resizeDirty { feed.view.markContentDirty(preserveAnchor: true) }
                    feed.history = .settled(.older)
                    return
                }
                let position = feed.view.scrollPosition()
                let distance = feed.view.resizeAnchor?.locate(snapshot.anchorRows).flatMap { $0 <= position.retainedHistoryRows ? $0 : nil } ?? 0
                self.publish(feed, history: history, alternate: ghostty_surface_is_alternate_screen(feed.view.surface), insertionRefused: false)
                DispatchQueue.main.async { [weak view = feed.view] in
                    guard let view, view.historyEpoch == epoch else { return }
                    if view.resizeAnchor != nil { view.requestScroll(distance) }
                    view.resizeAnchor = nil
                    view.restored(epoch: epoch)
                    view.find?.search(navigate: false)
                }
            } else {
                retry = false
                feed.history = .settled(.older)
                DispatchQueue.main.async { [weak view = feed.view] in view?.restoreFailed(epoch: epoch) }
                self.report("could not capture \(pane): \(replies)")
            }
        }
    }

    private func invalidateSearch(_ feed: PaneFeed, restart: Bool) {
        feed.goal = nil
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
            feed.goal = nil
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
                          case .scanning(let current, var matches) = feed.search, current == token else { return }
                    guard let capture else {
                        return DispatchQueue.main.async { [weak view = feed.view] in view?.find?.failed(token) }
                    }
                    if let next = capture.next, next == end || (end == nil && next >= -1 && capture.distances.isEmpty) {
                        return self.searchChunk(pane, feed, query: query, token: token, end: end,
                                                chunk: min(capture.history + 1, chunk * 2))
                    }
                    feed.search = nil
                    matches.append(contentsOf: capture.distances)
                    feed.search = .scanning(token: token, matches: matches)
                    if let next = capture.next { self.searchChunk(pane, feed, query: query, token: token, end: next) }
                    else { DispatchQueue.main.async { [weak view = feed.view, matches] in view?.find?.finished(matches, token: token) } }
                }
            }
        }
    }

    private func load(_ pane: PaneID, goal: (Int, UUID)? = nil, metadataOnly: Bool = false) {
        client.queue.async { [self] in
            guard let feed = panes?[pane], !feed.view.resizeDirty else { return }
            if let goal {
                guard case .scanning(let token, _) = feed.search, token == goal.1 else { return }
                feed.goal = goal.0 > feed.view.scrollPosition().retainedHistoryRows ? goal : nil
                if feed.goal == nil { return }
            }
            guard case .settled(let availability) = feed.history else { return }
            if !metadataOnly, case .refused = availability { ghostty_surface_raise_scrollback_limit(feed.view.surface) }
            let token = UUID(), epoch = feed.view.historyEpoch
            feed.history = .fetching(token)
            #if KIDO_VISUAL
            metadataQueries.withLock { $0 += 1 }
            #endif
            client.send([Command("display-message", "-p", "-t", pane, "#{history_size} #{alternate_on}")]) {
                [weak self, weak feed] replies in
                guard let self, let feed, self.panes?[pane] === feed,
                      case .fetching(let current) = feed.history, current == token else { return }
                defer { if case .settled = feed.history { self.drain(pane, feed) } }
                guard feed.view.historyEpoch == epoch, !feed.view.resizeDirty,
                      let metadata = HistoryMetadata(replies?.first) else {
                    self.publish(feed, history: feed.sampledTmuxHistoryRows)
                    return
                }
                if self.repair(feed, metadata: metadata) {
                    self.publish(feed, history: metadata.history, alternate: metadata.alternate)
                    return
                }
                let position = feed.view.scrollPosition()
                if metadataOnly || metadata.alternate || metadata.history <= position.retainedHistoryRows {
                    self.publish(feed, history: metadata.history, alternate: metadata.alternate)
                    feed.goal = nil
                    return
                }
                feed.sampledTmuxHistoryRows = metadata.history
                self.fetch(pane, feed, token: token, chunk: min(historyChunkSize, metadata.history - position.retainedHistoryRows))
            }
        }
    }

    private func fetch(_ pane: PaneID, _ feed: PaneFeed, token: UUID, chunk: Int = historyChunkSize, retries: Int = 0) {
        let position = feed.view.scrollPosition(), epoch = feed.view.historyEpoch
        debug("resize t=\(ProcessInfo.processInfo.systemUptime) history-page-send pane=\(pane) loaded=\(position.retainedHistoryRows) chunk=\(chunk)")
        client.send(HistoryCapture.commands(pane, loaded: position.retainedHistoryRows, chunk: chunk)) { [weak self, weak feed] replies in
            guard let self, let feed, self.panes?[pane] === feed,
                  case .fetching(let current) = feed.history, current == token else { return }
            defer { if case .settled = feed.history { self.drain(pane, feed) } }
            guard feed.view.historyEpoch == epoch, !feed.view.resizeDirty, let replies else {
                self.publish(feed, history: feed.sampledTmuxHistoryRows)
                return
            }
            let position = feed.view.scrollPosition()
            guard let capture = HistoryCapture(replies, loaded: position.retainedHistoryRows) else {
                self.publish(feed, history: feed.sampledTmuxHistoryRows)
                self.failGoal(feed)
                self.report("could not load older history for \(pane)")
                return
            }
            if let metadata = HistoryMetadata(replies.first), self.repair(feed, metadata: metadata) {
                self.publish(feed, history: capture.history, alternate: capture.alternate)
                return
            }
            if capture.alternate { self.publish(feed, history: capture.history, alternate: true); return }
            if capture.rows == 0 && capture.history > position.retainedHistoryRows && chunk < capture.history - position.retainedHistoryRows {
                return self.fetch(pane, feed, token: token, chunk: min(capture.history - position.retainedHistoryRows, chunk * 2))
            }
            let added = capture.rows == 0 ? 0 : feed.view.prepend(Data(capture.text.utf8), epoch: epoch)
            guard feed.view.historyEpoch == epoch, !feed.view.resizeDirty else {
                self.publish(feed, history: feed.sampledTmuxHistoryRows)
                return
            }
            if capture.rows > 0 && added == 0, feed.goal != nil, retries < 16,
               feed.view.historyEpoch == epoch, !feed.view.resizeDirty {
                ghostty_surface_raise_scrollback_limit(feed.view.surface)
                return self.fetch(pane, feed, token: token, chunk: chunk, retries: retries + 1)
            }
            let loaded = self.publish(feed, history: capture.history, insertionRefused: capture.rows > 0 && added == 0,
                                      emptyCaptureChunk: capture.rows == 0 ? chunk : nil).retainedHistoryRows
            if let goal = feed.goal, loaded < goal.distance {
                guard added > 0 else { self.failGoal(feed); return }
                feed.history = .fetching(token)
                self.fetch(pane, feed, token: token, chunk: min(historyChunkSize, max(0, capture.history - loaded)))
            } else { feed.goal = nil }
        }
    }

    private func failGoal(_ feed: PaneFeed) {
        guard let goal = feed.goal else { return }
        feed.goal = nil
        DispatchQueue.main.async { [weak view = feed.view] in view?.find?.failed(goal.token) }
    }

    @discardableResult private func publish(_ feed: PaneFeed, history: Int, alternate: Bool = false,
                                           insertionRefused: Bool? = nil, emptyCaptureChunk: Int? = nil) -> PaneView.ScrollPosition {
        let position = feed.view.scrollPosition()
        let refused = insertionRefused ?? { if case .settled(.refused) = feed.history { return true }; return false }()
        let unchangedExhaustion = insertionRefused == nil && history == feed.sampledTmuxHistoryRows && {
            if case .settled(.exhausted(let epoch)) = feed.history { return epoch == feed.outputEpoch }
            return false
        }()
        feed.sampledTmuxHistoryRows = history
        let exhausted = unchangedExhaustion || alternate || history <= position.retainedHistoryRows || emptyCaptureChunk.map { $0 >= history - position.retainedHistoryRows } == true
        feed.history = .settled(exhausted ? .exhausted(epoch: feed.outputEpoch) : refused ? .refused : .older)
        let epoch = feed.view.historyEpoch
        DispatchQueue.main.async { [weak view = feed.view] in
            guard let view, view.historyEpoch == epoch else { return }
            view.updateScroller(sampledTmuxHistoryRows: history, position: position, alternate: alternate, mayHaveOlderHistory: !exhausted)
            view.find?.loaded(position)
        }
        return position
    }

    private func repair(_ feed: PaneFeed, metadata: HistoryMetadata) -> Bool {
        guard metadata.history < feed.sampledTmuxHistoryRows || (!metadata.alternate && metadata.history < feed.view.scrollPosition().retainedHistoryRows) else { return false }
        feed.sampledTmuxHistoryRows = metadata.history
        invalidateSearch(feed, restart: false)
        if !feed.view.resizeDirty { feed.view.markContentDirty() }
        DispatchQueue.main.async { [weak view = feed.view] in view?.syncResize() }
        return true
    }

    private func teardown() -> [PaneID: PaneFeed]? {
        let gone = panes
        panes = nil
        gone?.values.forEach { invalidateSearch($0, restart: false); $0.completePendingRestore() }
        return gone
    }

    private func closed(_ status: Int32, _ stderr: String) {
        let gone = teardown(), reason = (reasons + [stderr]).filter { !$0.isEmpty }.joined(separator: "\n")
        let exit = detached.map(Exit.detached) ?? .ended(reason.isEmpty ? nil : reason)
        let why = switch exit {
        case .detached(let reason): "detached: \(reason)"
        case .ended(let reason): "ended: \(reason ?? "no reason given")"
        }
        note("connection closed, tmux exited \(status), \(why.replacingOccurrences(of: "\n", with: "; "))")
        DispatchQueue.main.async {
            self.active = false
            self.view?.invalidateClipboard()
            withExtendedLifetime(gone) { self.onClose(exit) }
        }
    }

    private func report(_ message: String) {
        note(message)
        let line = message.replacingOccurrences(of: "\n", with: "; ")
        DispatchQueue.main.async { self.onDiagnostic(line) }
    }
}
