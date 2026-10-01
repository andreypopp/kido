import Foundation

public struct HistoryMetadata: Sendable {
    public let history: Int
    public let alternate: Bool

    public init?(_ reply: Reply?) {
        guard case .success(let lines) = reply, let state = lines.first else { return nil }
        let numbers = state.split(separator: " ").compactMap { Int($0) }
        guard numbers.count == 2, numbers[0] >= 0 else { return nil }
        history = numbers[0]
        alternate = numbers[1] != 0
    }
}

struct Capture {
    let state: HistoryMetadata
    var lines: [(text: String, start: Int, end: Int, wrapped: Bool)] = []

    var completeLines: ArraySlice<(text: String, start: Int, end: Int, wrapped: Bool)> {
        guard let first = lines.first else { return [] }
        return lines.dropFirst(first.start > -state.history && first.start < 0 ? 1 : 0)
    }
    var next: Int? {
        guard let first = lines.first, !state.alternate, first.start > -state.history else { return nil }
        return first.start < 0 ? first.end : first.start - 1
    }

    init?(_ replies: some Collection<Reply>, styled: Bool = false) {
        let replies = Array(replies)
        guard replies.count == (styled ? 3 : 2), let state = HistoryMetadata(replies.first),
              case .success(let metadata) = replies.last else { return nil }
        self.state = state
        var start: Int?, body = ""
        for line in metadata {
            guard let space = line.firstIndex(of: " "), let row = Int(line[..<space]),
                  let separator = line[line.index(after: space)...].firstIndex(of: " ") else { return nil }
            if start == nil { start = row }
            let wrapped = line[line.index(after: space)..<separator].contains("W")
            if !styled { body += line[line.index(after: separator)...] }
            if !wrapped { lines.append((body, start!, row, false)); start = nil; body = "" }
        }
        if let start, let row = metadata.last?.split(separator: " ").first.flatMap({ Int($0) }) {
            lines.append((body, start, row, true))
        }
        if styled {
            guard case .success(let text) = replies[1], text.count == lines.count else { return nil }
            for index in lines.indices { lines[index].text = text[index] }
        }
    }
}
