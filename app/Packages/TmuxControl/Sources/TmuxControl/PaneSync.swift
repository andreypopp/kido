import Foundation

public enum PaneSync {
    private static let state = [
        "history_size", "alternate_on", "cursor_x", "cursor_y", "scroll_region_upper",
        "scroll_region_lower", "keypad_flag", "insert_flag", "alternate_saved_x", "alternate_saved_y",
        "cursor_blinking", "cursor_shape", "pane_key_mode", "pane_tabs", "pane_private_modes",
    ].map { "#{\($0)}" }.joined(separator: "\u{1F}")

    public struct Snapshot {
        public let data: Data
        public let history: Int
        fileprivate let retainedRows: Int
        fileprivate let alternate: Bool
        fileprivate let historyMetadata: [String]
        fileprivate let screenMetadata: [String]
        public var anchorRows: [Reply] {
            let retained = historyMetadata.filter {
                guard let row = $0.split(separator: " ", maxSplits: 1).first.flatMap({ Int($0) }) else { return false }
                return row >= -retainedRows && row < 0
            }
            return [.success(["\(retainedRows) \(alternate ? 1 : 0)"]), .success(retained + screenMetadata)]
        }
    }

    public static func commands(_ pane: PaneID, chunk: Int = historyChunkSize) -> [Command] {
        HistoryCapture.commands(pane, loaded: 0, chunk: chunk) + [
            Command("capture-pane", "-p", "-e", "-J", "-t", pane),
            Command("capture-pane", "-p", "-e", "-J", "-a", "-q", "-t", pane),
            Command("capture-pane", "-p", "-P", "-C", "-t", pane),
            Command("display-message", "-p", "-t", pane, state),
            Command("capture-pane", "-p", "-F", "-L", "-T", "-N", "-t", pane),
        ]
    }

    public static func restore(_ replies: some Collection<Reply>) -> Snapshot? {
        let lines = replies.compactMap { if case .success(let l) = $0 { l } else { nil } }
        guard lines.count == 8, let state = lines[6].first,
              let history = HistoryCapture(replies.prefix(3), loaded: 0, initial: true) else { return nil }
        return restore(history: history, screen: lines[3], main: lines[4], pending: lines[5].first ?? "", state: state)
            .map { Snapshot(data: $0, history: history.history, retainedRows: history.rows, alternate: history.alternate,
                            historyMetadata: lines[2], screenMetadata: lines[7]) }
    }

    private static func restore(
        history: HistoryCapture, screen: [String], main: [String], pending: String, state: String
    ) -> Data? {
        let f = state.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        let n = f.prefix(11).compactMap { Int($0) }
        guard f.count == 15, n.count == 11 else { return nil }
        let (hsize, alternate, x, y, upper, lower, keypad, insert, savedX, savedY, blinking) =
            (n[0], n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8], n[9], n[10])
        let (shape, keys, tabs, modes) = (f[11], f[12], f[13].split(separator: ","), f[14].split(separator: ","))
        let e = "\u{1B}"
        let scrollback = hsize == 0 || history.rows == 0 ? "" : history.text + (history.wrapsIntoScreen ? "" : "\r\n")
        var out = "\(e)c\(e)[3J" + scrollback + (alternate == 1 ? main : screen).joined(separator: "\r\n")
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
}
