import Foundation

struct DisplayRow: Identifiable, Equatable {
    enum Content: Equatable {
        case activity([DisplayRow])
        case user(JSON), markdown(String), thinking(String, Bool), tool(JSON, JSON, JSON)
        case custom(JSON), marker(String, String), image(JSON), stopped, error(String), history(Bool), thinkingUnavailable, responding, bash(JSON)
    }
    var id: String
    var content: Content
}

struct Transcript {
    private(set) var rows: [DisplayRow] = []
    private var positions: [String: Int] = [:]
    private(set) var tail: [DisplayRow] = []
    var changed = Set<String>(), structure = 0
    mutating func reconcile(_ values: [DisplayRow]) {
        let old = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        if rows.count != values.count || zip(rows, values).contains(where: { $0.id != $1.id }) { structure += 1 }
        changed.formUnion(values.filter { old[$0.id] != $0 }.map(\.id))
        rows = values; positions = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.element.id, $0.offset) })
    }
    mutating func live(_ partial: Row?, scope: String, tools: [String: JSON], bash: JSON, streaming: Bool) {
        tail = project(partial.map { [$0] } ?? [], scope: scope, active: true, tools: tools)
        if streaming && tail.isEmpty && !tools.values.contains(where: { $0["ended"] != .bool(true) }) { tail.append(.init(id: scope + ":responding", content: .responding)) }
        tail += bash.object.keys.sorted().map { .init(id: scope + ":" + $0, content: .bash(bash[$0])) }
        if rows.isEmpty && tail.isEmpty { tail.append(.init(id: scope + ":empty", content: .markdown("Start a conversation"))) }
        changed.formUnion(tail.map(\.id))
    }
    mutating func execution(_ id: String, value: JSON) {
        guard let index = positions[id], case .tool(let call, let result, _) = rows[index].content else { return }
        rows[index].content = .tool(call, result, value); changed.insert(id)
    }
}

func project(_ rows: [Row], scope: String, active: Bool = false, tools: [String: JSON] = [:]) -> [DisplayRow] {
    var calls: [String: JSON] = [:], results: [String: JSON] = [:]
    for row in rows {
        if row.message["role"].string == "toolResult" { results[row.message["toolCallId"].string] = row.message }
        for block in row.message["content"].array where block["type"].string == "toolCall" { calls[block["id"].string] = block }
    }
    var output: [DisplayRow] = [], emitted = Set<String>()
    for row in rows {
        let message = row.message, role = message["role"].string, id = scope + ":" + row.id
        if role == "bashExecution" { output.append(.init(id: id, content: .bash(message))); continue }
        if role == "user" { output.append(.init(id: id, content: .user(message))); continue }
        if role.hasPrefix("kido-") { output.append(.init(id: id, content: .custom(message))); continue }
        if ["compaction", "branch_summary"].contains(role) { output.append(.init(id: id, content: .marker(role == "compaction" ? "Context compacted" : "Branch summary", message["content"].string))); continue }
        if role == "toolResult" {
            let key = message["toolCallId"].string
            if calls[key] == nil && emitted.insert(key).inserted { output.append(.init(id: scope + ":tool:" + key, content: .tool(.null, message, tools[key] ?? .null))) }
            continue
        }
        if case .string(let text) = message["content"] { output.append(.init(id: id, content: .markdown(text))) }
        for (index, block) in message["content"].array.enumerated() {
            let key = id + ":\(index)"
            switch block["type"].string {
            case "thinking":
                if block["redacted"] == .bool(true) { output.append(.init(id: key, content: .thinkingUnavailable)) }
                else if !block["thinking"].string.isEmpty || active && block["active"] == .bool(true) { output.append(.init(id: key, content: .thinking(block["thinking"].string, active && block["active"] == .bool(true)))) }
            case "text": if !block["text"].string.isEmpty { output.append(.init(id: key, content: .markdown(block["text"].string))) }
            case "image": output.append(.init(id: key, content: .image(block)))
            case "toolCall":
                let call = block["id"].string
                if emitted.insert(call).inserted { output.append(.init(id: scope + ":tool:" + call, content: .tool(block, results[call] ?? .null, tools[call] ?? .null))) }
            default: break
            }
        }
        if message["stopReason"].string == "aborted" { output.append(.init(id: id + ":stop", content: .stopped)) }
        if !message["errorMessage"].string.isEmpty { output.append(.init(id: id + ":error", content: .error(message["errorMessage"].string))) }
    }
    return output
}

func groupedActivity(_ rows: [DisplayRow]) -> [DisplayRow] {
    var result: [DisplayRow] = []
    for row in rows {
        switch row.content {
        case .thinking, .thinkingUnavailable, .tool:
            if let last = result.last, case .activity(var items) = last.content {
                items.append(row); result[result.count - 1].content = .activity(items)
            } else { result.append(.init(id: row.id, content: .activity([row]))) }
        default: result.append(row)
        }
    }
    return result
}
