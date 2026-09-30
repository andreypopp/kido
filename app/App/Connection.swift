import AppKit
import TmuxControl

// Every Client callback runs on client.queue. `panes` and `session` are
// touched only there, so a PaneView leaves `panes` between two feeds and is
// released on the main thread after that (detach).
final class Connection: @unchecked Sendable {
    private let client: Client
    private var panes: [PaneID: PaneView] = [:]
    private var session: SessionID?
    @MainActor private weak var view: WindowView?
    @MainActor private var sizing: DispatchWorkItem?

    @MainActor init(server: Server, view: WindowView) throws {
        self.view = view
        client = Client(tmux: URL(fileURLWithPath: server.tmux), socket: server.socket, session: nil, pauseAfter: 5)
        view.connection = self
        try client.start(
            onEvent: { [weak self] in self?.handle($0) },
            onClose: { [weak self] in self?.report("tmux exited with status \($0)") })
    }

    @MainActor func attach(_ pane: PaneView) {
        client.queue.async { self.panes[pane.pane] = pane }
        sync(pane.pane, first: [])
    }

    @MainActor func detach(_ pane: PaneID) {
        client.queue.async {
            let view = self.panes.removeValue(forKey: pane)
            DispatchQueue.main.async { _ = view }
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
            DispatchQueue.main.async { self.view?.layoutChanged(window, layout, visible) }
        case .windowPaneChanged(let window, let pane):
            DispatchQueue.main.async { self.view?.focus(window, pane) }
        case .sessionChanged(let s, _):
            session = s
            show(s)
        case .sessionWindowChanged(let s, let window) where s == session:
            show(window)
        case .exit(let reason?):
            report(reason)
        default:
            break
        }
    }

    private func show(_ target: some CustomStringConvertible & Sendable) {
        let format = "#{window_id} #{window_layout} #{window_visible_layout}"
        client.send([Command("display-message", "-p", "-t", target, format)]) { [weak self] replies in
            guard case .success(let lines)? = replies?.first, let words = lines.first?.split(separator: " "),
                  words.count == 3, let window = WindowID(words[0]),
                  let layout = try? Layout(json: words[1]), let visible = try? Layout(json: words[2])
            else { return self?.report("could not read the layout of \(target): \(String(describing: replies))") ?? () }
            DispatchQueue.main.async { self?.view?.show(window, layout, visible) }
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

    private func report(_ message: String) {
        panes.values.forEach { $0.feed(Self.notice(message)) }
    }

    private static func notice(_ message: String) -> Data {
        Data("\r\n\u{1B}[m[kido: \(message)]".utf8)
    }
}
