import Foundation

struct DisplayRow: Identifiable, Equatable {
    enum Content: Equatable {
        case user(JSON), markdown(String), thinking(String, Bool), tool(JSON, JSON, JSON)
        case custom(JSON), marker(String, String), image(JSON), stopped, error(String), history(Bool), thinkingUnavailable, responding, bash(JSON)
    }
    var id: String
    var content: Content
}

func project(_ rows: [Row], scope: String, active: Bool = false) -> [DisplayRow] {
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
        if ["compaction", "branch_summary"].contains(role) {
            output.append(.init(id: id, content: .marker(role == "compaction" ? "Context compacted" : "Branch summary", message["content"].string))); continue
        }
        if role == "toolResult" {
            let key = message["toolCallId"].string
            if calls[key] == nil && emitted.insert(key).inserted {
                output.append(.init(id: scope + ":tool:" + key, content: .tool(.null, message, .null)))
            }
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
                if emitted.insert(call).inserted { output.append(.init(id: scope + ":tool:" + call, content: .tool(block, results[call] ?? .null, .null))) }
            default: break
            }
        }
        if message["stopReason"].string == "aborted" { output.append(.init(id: id + ":stop", content: .stopped)) }
        if !message["errorMessage"].string.isEmpty { output.append(.init(id: id + ":error", content: .error(message["errorMessage"].string))) }
    }
    return output
}
