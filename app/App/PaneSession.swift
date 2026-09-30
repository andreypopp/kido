import AppKit
import TmuxControl

final class PaneSession: @unchecked Sendable {
    private let view: PaneView
    private var client: Client!
    private let lock = NSLock()
    private var pane: PaneID?
    private var syncs = 0
    private var resize: DispatchWorkItem?

    init(server: Server, view: PaneView) throws {
        self.view = view
        client = try Client(
            tmux: URL(fileURLWithPath: server.tmux), socket: server.socket, session: .attach(nil), pauseAfter: 5,
            onEvent: { [weak self] in self?.handle($0) },
            onClose: { [weak self] in self?.report("tmux exited with status \($0)") })
        client.send([Command("display-message", "-p", "#{window_id} #{pane_id}")]) { [weak self] replies in
            guard case .success(let lines)? = replies?.first, let words = lines.first?.split(separator: " "),
                  words.count == 2, let window = WindowID(words[0]), let pane = PaneID(words[1]) else {
                self?.report("no active pane")
                return
            }
            DispatchQueue.main.async { self?.show(window, pane) }
        }
    }

    private func show(_ window: WindowID, _ pane: PaneID) {
        lock.withLock { self.pane = pane }
        view.onInput = { [weak self] bytes in self?.client.send(Command.sendKeys(pane, bytes)) { _ in } }
        view.onGridChange = { [weak self] _ in self?.scheduleResize() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: view.window, queue: .main
        ) { [weak self] _ in
            self?.client.send([Command("select-window", "-t", window), Command("select-pane", "-t", pane)]) { _ in }
        }
        sync(pane, first: [size()])
    }

    private func size() -> Command {
        Command("refresh-client", "-C", "\(view.grid.cols)x\(view.grid.rows)")
    }

    private func scheduleResize() {
        resize?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            client.send([size()]) { _ in }
        }
        resize = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private static let state = [
        "pane_id", "pane_height", "alternate_on", "cursor_x", "cursor_y", "scroll_region_upper",
        "scroll_region_lower", "keypad_flag", "insert_flag", "alternate_saved_x", "alternate_saved_y",
        "pane_private_modes",
    ].map { "#{\($0)}" }.joined(separator: " ")

    // Commands on one line run in one server loop pass, so %output before
    // the replies is in the capture and %output after them is not.
    private func sync(_ pane: PaneID, first: [Command]) {
        lock.withLock { syncs += 1 }
        let commands = first + [
            Command("capture-pane", "-p", "-e", "-N", "-S", "-2000", "-t", pane),
            Command("capture-pane", "-p", "-e", "-N", "-a", "-q", "-t", pane),
            Command("list-panes", "-t", pane, "-F", Self.state),
        ]
        client.send(commands) { [weak self] replies in
            guard let self, let replies else { return }
            lock.withLock { self.syncs -= 1 }
            let tail = Array(replies.suffix(3))
            guard case .success(let screen) = tail[0], case .success(let main) = tail[1],
                  case .success(let panes) = tail[2],
                  let row = panes.first(where: { $0.hasPrefix("\(pane) ") }),
                  let restore = Self.restore(screen: screen, main: main, state: row) else {
                return report("could not capture \(pane): \(replies)")
            }
            view.feed(restore)
        }
    }

    private static func restore(screen: [String], main: [String], state: String) -> Data? {
        let f = state.split(separator: " ", omittingEmptySubsequences: false).dropFirst()
        let n = f.prefix(10).compactMap { Int($0) }
        guard n.count == 10, let modes = f.last?.split(separator: ",") else { return nil }
        let (height, alternate, x, y, upper, lower, keypad, insert, savedX, savedY) =
            (n[0], n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8], n[9])
        let e = "\u{1B}"
        var out = "\(e)c\(e)[3J"
        if alternate == 1 {
            out += (screen.dropLast(height) + main).joined(separator: "\r\n") + "\(e)[m"
            if savedX != UInt32.max { out += "\(e)[\(savedY + 1);\(savedX + 1)H" }
            out += "\(e)[?1049h" + screen.suffix(height).joined(separator: "\r\n")
        } else {
            out += screen.joined(separator: "\r\n")
        }
        out += "\(e)[m\(e)[\(upper + 1);\(lower + 1)r\(e)[?7l\(e)[?25l"
        out += modes.map { "\(e)[?\($0)h" }.joined()
        out += (keypad == 1 ? "\(e)=" : "\(e)>") + (insert == 1 ? "\(e)[4h" : "\(e)[4l")
        out += "\(e)[\(y + 1 - (modes.contains("6") ? upper : 0));\(x + 1)H"
        return Data(out.utf8)
    }

    private func handle(_ event: Event) {
        let (pane, syncing) = lock.withLock { (self.pane, syncs > 0) }
        switch event {
        case .output(let p, let bytes) where p == pane && !syncing,
             .extendedOutput(let p, _, let bytes) where p == pane && !syncing:
            view.feed(Data(bytes))
        case .pause(let p) where p == pane:
            sync(p, first: [Command("refresh-client", "-A", "\(p):continue")])
        case .exit(let reason?):
            report(reason)
        default:
            break
        }
    }

    private func report(_ message: String) {
        view.feed(Data("\r\n\u{1B}[m[kido: \(message)]".utf8))
    }
}
