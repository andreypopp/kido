import AppKit
import TmuxControl

final class PaneSession: @unchecked Sendable {
    private let view: PaneView
    private let client: Client
    private var pane: PaneID?
    private var resize: DispatchWorkItem?
    private var keyObserver: (any NSObjectProtocol)?

    @MainActor init(server: Server, view: PaneView) throws {
        self.view = view
        client = Client(tmux: URL(fileURLWithPath: server.tmux), socket: server.socket, session: nil, pauseAfter: 5)
        try client.start(
            onEvent: { [weak self] in self?.handle($0) },
            onClose: { [weak self] in self?.report("tmux exited with status \($0)") })
        client.send([Command("display-message", "-p", "#{window_id} #{pane_id}")]) { [weak self] replies in
            guard case .success(let lines)? = replies?.first, let words = lines.first?.split(separator: " "),
                  words.count == 2, let window = WindowID(words[0]), let pane = PaneID(words[1]) else {
                self?.report("no active pane")
                return
            }
            self?.pane = pane
            DispatchQueue.main.async { self?.show(window, pane) }
        }
    }

    deinit {
        keyObserver.map(NotificationCenter.default.removeObserver)
    }

    @MainActor private func show(_ window: WindowID, _ pane: PaneID) {
        view.onInput = { [weak self] bytes in
            for keys in Command.sendKeys(pane, bytes) { self?.client.send([keys]) { _ in } }
        }
        view.onGridChange = { [weak self] _ in self?.scheduleResize() }
        keyObserver.map(NotificationCenter.default.removeObserver)
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: view.window, queue: .main
        ) { [weak self] _ in
            self?.client.send([Command("select-window", "-t", window), Command("select-pane", "-t", pane)]) { _ in }
        }
        client.send([size()]) { _ in }
        sync(pane, first: [])
    }

    @MainActor private func size() -> Command {
        Command("refresh-client", "-C", "\(view.grid.cols)x\(view.grid.rows)")
    }

    @MainActor private func scheduleResize() {
        resize?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            client.send([size()]) { _ in }
        }
        resize = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private static let state = [
        "history_size", "pane_height", "alternate_on", "cursor_x", "cursor_y", "scroll_region_upper",
        "scroll_region_lower", "keypad_flag", "insert_flag", "alternate_saved_x", "alternate_saved_y",
        "cursor_blinking", "cursor_shape", "pane_key_mode", "pane_tabs", "pane_private_modes",
    ].map { "#{\($0)}" }.joined(separator: "\u{1F}")

    // %output queued before a reply is written ahead of its %begin
    // (control.c), and the reply is completed on the reader thread, so output
    // fed before the restore is wiped by it and output after it is not in it.
    private func sync(_ pane: PaneID, first: [Command]) {
        let commands = first + [
            Command("capture-pane", "-p", "-e", "-J", "-S", "-2000", "-E", "-1", "-t", pane),
            Command("capture-pane", "-p", "-e", "-J", "-t", pane),
            Command("capture-pane", "-p", "-e", "-J", "-a", "-q", "-t", pane),
            Command("capture-pane", "-p", "-P", "-C", "-t", pane),
            Command("display-message", "-p", "-t", pane, Self.state),
        ]
        client.send(commands) { [weak self] replies in
            guard let self, let replies else { return }
            let lines = replies.dropFirst(first.count).compactMap { if case .success(let l) = $0 { l } else { nil } }
            guard lines.count == 5, let state = lines[4].first,
                  let restore = Self.restore(
                      history: lines[0], screen: lines[1], main: lines[2], pending: lines[3].first ?? "", state: state)
            else { return report("could not capture \(pane): \(replies)") }
            view.feed(restore)
        }
    }

    private static func restore(
        history: [String], screen: [String], main: [String], pending: String, state: String
    ) -> Data? {
        let f = state.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        let n = f.prefix(12).compactMap { Int($0) }
        guard f.count == 16, n.count == 12 else { return nil }
        let (hsize, alternate, x, y, upper, lower, keypad, insert, savedX, savedY, blinking) =
            (n[0], n[2], n[3], n[4], n[5], n[6], n[7], n[8], n[9], n[10], n[11])
        let (shape, keys, tabs, modes) = (f[12], f[13], f[14].split(separator: ","), f[15].split(separator: ","))
        let e = "\u{1B}"
        let scrollback = hsize == 0 ? [] : history
        var out = "\(e)c\(e)[3J" + (scrollback + (alternate == 1 ? main : screen)).joined(separator: "\r\n")
        if alternate == 1 {
            out += "\(e)[m"
            if savedX != UInt32.max { out += "\(e)[\(savedY + 1);\(savedX + 1)H" }
            out += "\(e)[?1049h" + screen.joined(separator: "\r\n")
        }
        out += "\(e)[m\(e)[\(upper + 1);\(lower + 1)r\(e)[3g"
        out += tabs.compactMap { Int($0) }.map { "\(e)[1;\($0 + 1)H\(e)H" }.joined()
        out += "\(e)[?7l\(e)[?25l" + modes.map { "\(e)[?\($0)h" }.joined()
        out += (keypad == 1 ? "\(e)=" : "\(e)>") + (insert == 1 ? "\(e)[4h" : "\(e)[4l")
        if let code = ["block": 1, "underline": 3, "bar": 5][String(shape)] {
            out += "\(e)[\(code + 1 - blinking) q"
        }
        out += ["Ext 1": "\(e)[>4;1m", "Ext 2": "\(e)[>4;2m"][String(keys)] ?? ""
        out += "\(e)[\(y + 1 - (modes.contains("6") ? upper : 0));\(x + 1)H"
        return Data(out.utf8) + decodeOctal(ArraySlice(pending.utf8))
    }

    private func handle(_ event: Event) {
        switch event {
        case .output(let p, let bytes) where p == pane, .extendedOutput(let p, _, let bytes) where p == pane:
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
