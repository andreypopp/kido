public let historyChunkSize = 10_000

public struct HistoryCapture: Sendable {
    public let history: Int
    public let alternate: Bool
    public let rows: Int
    public let text: String

    public static func commands(_ pane: PaneID, loaded: Int, chunk: Int = historyChunkSize) -> [Command] {
        [
            Command("display-message", "-p", "-t", pane, "#{history_size} #{alternate_on}"),
            Command("capture-pane", "-p", "-r", "-G", "-S", "-\(loaded + chunk)", "-E", "-\(loaded + 1)", "-t", pane),
            Command("capture-pane", "-p", "-F", "-L", "-T", "-N", "-S", "-\(loaded + chunk + 1)", "-E", "-\(loaded + 1)", "-t", pane),
        ]
    }

    static func selectedRows(_ capture: Capture, loaded: Int, chunk: Int, initial: Bool) -> Int? {
        let start = max(-capture.state.history, -(loaded + chunk))
        let count = capture.lines.lazy.filter {
            $0.start >= start && $0.start < -loaded && (initial || (!$0.wrapped && $0.end < -loaded))
        }.reduce(0) { $0 + $1.end - $1.start + 1 }
        return count > 0 ? count : nil
    }

    public static func capture(
        _ client: Client, _ pane: PaneID, loaded: Int, chunk: Int = historyChunkSize,
        initial: Bool = false, first: [Command] = [], last: [Command] = [], retry: Bool = true,
        completion: @escaping @Sendable ((replies: [Reply], history: HistoryCapture?)?) -> Void
    ) {
        client.send(first + commands(pane, loaded: loaded, chunk: chunk) + last) { replies in
            guard let replies else { return completion(nil) }
            let body = Array(replies.dropFirst(first.count))
            guard body.count >= 3, let state = HistoryMetadata(body.first) else { return completion((body, nil)) }
            let count = min(max(0, state.history - loaded), chunk)
            let rows: Int
            if state.alternate { rows = count } else {
                guard let metadata = Capture([body[0], body[2]]) else { return completion((body, nil)) }
                let selected = selectedRows(metadata, loaded: loaded, chunk: chunk, initial: initial)
                if retry, let selected, selected < count {
                    return capture(client, pane, loaded: loaded, chunk: selected, initial: initial, last: last, retry: false, completion: completion)
                }
                rows = retry ? selected ?? 0 : count
            }
            completion((body, HistoryCapture(body.prefix(3), rows: rows, initial: initial)))
        }
    }

    init?(_ replies: some Collection<Reply>, rows: Int, initial: Bool = false) {
        let replies = Array(replies)
        guard replies.count == 3, let state = HistoryMetadata(replies.first),
              case .success(var lines) = replies[1] else { return nil }
        history = state.history
        alternate = state.alternate
        self.rows = rows
        if !initial, lines.last == "" {
            lines.removeLast()
            if lines.last?.hasSuffix("\r") == true { lines[lines.count - 1].removeLast() }
        }
        text = rows == 0 ? "" : lines.joined(separator: "\n")
    }
}
