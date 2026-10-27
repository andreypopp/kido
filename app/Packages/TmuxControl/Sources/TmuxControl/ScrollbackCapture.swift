public enum ScrollbackCapture {
    public static let maxRows = 200_000

    public static func historyRequest(_ pane: PaneID) -> Command {
        Command("display-message", "-p", "-t", pane, "#{history_size}")
    }

    public static func capture(_ pane: PaneID, history: Int, limit: Int = maxRows) -> Command {
        Command("capture-pane", "-p", "-J", "-S", history > limit ? "-\(limit)" : "-", "-t", pane)
    }

    public static func historySize(_ reply: Reply?) -> Int? {
        guard case .success(let lines)? = reply, let line = lines.first, let rows = Int(line), rows >= 0 else { return nil }
        return rows
    }

    public static func text(_ reply: Reply?) -> String? {
        guard case .success(let rows)? = reply else { return nil }
        var lines = rows.map { String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n"
    }
}
