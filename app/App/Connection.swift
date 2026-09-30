import AppKit
import TmuxControl

// Every Client callback runs on client.queue. `panes` is touched only
// there, so a PaneView leaves `panes` between two feeds; `retiring` holds it
// on main until the queue has let go of it, so it is freed on main (detach).
// A layout reaches main synchronously, so its grid is set before the reader
// feeds the output that follows it. Main never waits on client.queue. Once
// the client has closed, `panes` is emptied and released on main.
final class Connection: @unchecked Sendable {
    private let client: Client
    private var panes: [PaneID: PaneView] = [:]
    private var exitReason: String?
    @MainActor private var retiring: [ObjectIdentifier: PaneView] = [:]
    @MainActor private weak var view: SessionView?
    @MainActor private var sizing: DispatchWorkItem?
    @MainActor private(set) var model = SessionModel() {
        didSet { onChange(model) }
    }
    @MainActor private let onChange: (SessionModel) -> Void
    @MainActor private let onClose: (String?) -> Void

    @MainActor init(
        server: Server, view: SessionView, onChange: @escaping (SessionModel) -> Void,
        onClose: @escaping (String?) -> Void
    ) throws {
        self.view = view
        self.onChange = onChange
        self.onClose = onClose
        client = Client(tmux: URL(fileURLWithPath: server.tmux), socket: server.socket, session: nil, pauseAfter: 5)
        view.connection = self
        try client.start(
            onEvent: { [weak self] in self?.handle($0) },
            onClose: { [weak self] _ in self?.closed() })
    }

    @MainActor func attach(_ pane: PaneView) {
        client.queue.async { self.panes[pane.pane] = pane }
        sync(pane.pane, first: [])
    }

    @MainActor func detach(_ pane: PaneView) {
        let id = pane.pane, key = ObjectIdentifier(pane)
        retiring[key] = pane
        client.queue.async {
            if self.panes[id].map(ObjectIdentifier.init) == key { self.panes[id] = nil }
            DispatchQueue.main.async { self.retiring[key] = nil }
        }
    }

    func send(_ commands: [Command]) {
        client.send(commands) { _ in }
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
            panes[p]?.feed(Data(bytes))
        case .pause(let p):
            let resume = Command("refresh-client", "-A", "\(p):continue")
            if panes[p] == nil { send([resume]) } else { sync(p, first: [resume]) }
        case .layoutChange(let window, let layout, let visible, _):
            DispatchQueue.main.sync { self.view?.windows[window]?.update(layout, visible) }
        case .windowPaneChanged(let window, let pane):
            DispatchQueue.main.async { self.view?.windows[window]?.focus(pane) }
        case .sessionWindowChanged(let s, let window):
            DispatchQueue.main.async {
                guard s == self.model.session else { return }
                self.model.window = window
                self.view?.show(window)
            }
        case .sessionChanged, .sessionsChanged, .sessionRenamed, .windowAdd(_, .linked), .windowClose(_, .linked),
            .windowRenamed(_, .linked, _):
            refresh()
        case .exit(let reason):
            exitReason = reason
        default:
            break
        }
    }

    private func refresh() {
        let commands = [
            Command("list-sessions", "-F", SessionListing.format), Command("display-message", "-p", "#{session_id}"),
            Command("list-windows", "-F", WindowListing.format),
        ]
        client.send(commands) { [weak self] replies in
            guard let replies else { return }
            guard replies.count == 3, case .success(let sessions) = replies[0], case .success(let current) = replies[1],
                let session = current.first.flatMap(SessionID.init), case .success(let windows) = replies[2]
            else { return self?.report("could not list the session's windows: \(replies)") ?? () }
            let listing = windows.compactMap(WindowListing.init)
            DispatchQueue.main.sync {
                guard let self else { return }
                self.model = SessionModel(
                    sessions: sessions.compactMap(SessionListing.init), session: session,
                    windows: listing.map { .init(id: $0.id, name: $0.name) }, window: listing.first(where: \.active)?.id)
                self.view?.update(listing, shown: self.model.window)
            }
        }
    }

    // %output queued before a reply is written ahead of its %begin
    // (control.c), and the reply is completed on the reader queue, so output
    // fed before the restore is wiped by it and output after it is not in it.
    private func sync(_ pane: PaneID, first: [Command]) {
        client.send(first + PaneSync.commands(pane)) { [weak self] replies in
            guard let self, let replies else { return }
            panes[pane]?.feed(
                PaneSync.restore(replies.dropFirst(first.count)) ?? Self.notice("could not capture \(pane): \(replies)"))
        }
    }

    private func closed() {
        let gone = panes, reason = exitReason
        panes = [:]
        DispatchQueue.main.async { withExtendedLifetime(gone) { self.onClose(reason) } }
    }

    private func report(_ message: String) {
        panes.values.forEach { $0.feed(Self.notice(message)) }
    }

    private static func notice(_ message: String) -> Data {
        Data("\r\n\u{1B}[m[kido: \(message)]".utf8)
    }
}
