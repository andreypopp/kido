import Foundation
import Observation

public enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    public var object: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
    public var orderedValues: [JSON] { object.sorted { $0.key < $1.key }.map(\.value) }
    public var text: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "" }
}

public struct Row: Identifiable, Equatable {
    public var id: String
    public var message: JSON
}

@MainActor @Observable public final class Session {
    public let client: String
    public private(set) var rows: [Row] = []
    public private(set) var partial: JSON = .null
    public private(set) var tools: [JSON] = []
    public private(set) var dialogs: [JSON] = []
    public private(set) var queues: JSON = .null
    public private(set) var state: JSON = .null
    public private(set) var models: [JSON] = []
    public private(set) var thinkingLevels: [String] = []
    public private(set) var status: JSON = .null
    public private(set) var widgets: JSON = .null
    public private(set) var notifications: [JSON] = []
    public private(set) var title = ""
    public private(set) var generation: JSON = .null
    public private(set) var historyBefore: JSON = .null
    public private(set) var connected = false
    public private(set) var error = ""
    public var streaming: Bool { state["isStreaming"] == .bool(true) }
    private var codec = Codec()
    private var assembly = Data()
    private var seq: Int?
    private var instance = ""
    private var ready = false
    private var counter = 0
    private var pending: [(msg: Int, index: Int, bytes: Data)] = []
    private var writer: Task<Void, Never>?
    private let sendBytes: @MainActor (Data) async throws -> Void
    public init(client: String = UUID().uuidString.lowercased(), send: @escaping @MainActor (Data) async throws -> Void) { self.client = client; sendBytes = send }
    public func disconnect() { connected = false; ready = false; pending.removeAll(); writer?.cancel(); writer = nil; assembly.removeAll(); seq = nil; generation = .null }
    public func command(_ type: String, fields: [String: JSON] = [:]) {
        guard connected else { return }
        counter += 1
        var object = fields
        object["type"] = .string(type)
        if type != "extension_ui_response" { object["id"] = .string("\(client):\(counter)") }
        let frames = Codec.encode(JSON.object(object).text, client: client, number: counter)
        pending += frames.enumerated().map { (counter, $0.offset, $0.element) }
        pump()
    }
    private func pump() {
        guard writer == nil, let frame = pending.first else { return }
        writer = Task { [weak self] in
            do {
                while !Task.isCancelled && self != nil {
                    try await self?.sendBytes(frame.bytes)
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                if !Task.isCancelled { self?.error = error.localizedDescription; self?.disconnect() }
            }
        }
    }
    public func receive(_ data: Data) {
        for frame in codec.receive(data) {
            guard frame.header.count == 2, let next = Int(frame.header[0]) else { continue }
            if let seq, next != seq + 1 { assembly.removeAll(); ready = false; command("snapshot") }
            seq = next
            assembly.append(frame.bytes)
            if assembly.count > 16 * 1024 * 1024 { assembly.removeAll(); ready = false; command("snapshot") }
            guard frame.header[1] == "1" else { continue }
            let value = try? JSONDecoder().decode(JSON.self, from: assembly)
            assembly.removeAll()
            if let value { apply(value) }
        }
    }
    private func transcript(_ entries: [JSON]) -> [Row] {
        entries.compactMap { entry in
            var message = entry["message"]
            if ["compaction", "branch_summary"].contains(entry["type"].string) { message = .object(["role": entry["type"], "content": entry["summary"]]) }
            if entry["type"].string == "custom_message", entry["display"] != .bool(false) { message = .object(["role": entry["customType"], "content": entry["content"], "details": entry["details"]]) }
            return message == .null ? nil : Row(id: entry["id"].string, message: message)
        }
    }
    private func apply(_ event: JSON) {
        let type = event["type"].string
        if type == "hello" {
            if !connected || instance != event["instance"].string {
                disconnect(); rows.removeAll(); partial = .null; tools.removeAll(); dialogs.removeAll(); state = .null
                instance = event["instance"].string; connected = true; command("snapshot")
            }
            return
        }
        if type == "bye" { disconnect(); return }
        if type == "ack" {
            if event["client"].string == client, let first = pending.first,
               event["msg"] == .number(Double(first.msg)), event["index"] == .number(Double(first.index)) {
                pending.removeFirst(); writer?.cancel(); writer = nil; pump()
            }
            return
        }
        if type == "snapshot" {
            if instance != event["hello"]["instance"].string { disconnect() }
            if generation != event["generation"] { pending.removeAll(); writer?.cancel(); writer = nil }
            generation = event["generation"]
            connected = true; ready = true; instance = event["hello"]["instance"].string
            let record = event["record"]
            rows = transcript(record["entries"].array)
            historyBefore = record["entries"].array.first?["id"] ?? .null
            partial = record["partialAssistant"]; tools = record["tools"].orderedValues
            dialogs = record["dialogs"].orderedValues
            queues = record["queues"]; state = record["state"]; models = record["models"].array
            thinkingLevels = record["thinkingLevels"].array.map(\.string)
            status = record["status"]; widgets = record["widgets"]; notifications = record["notifications"].array; title = record["title"].string
            return
        }
        guard ready else { return }
        switch type {
        case "history":
            guard event["generation"] == generation else { return }
            let known = Set(rows.map(\.id))
            rows.insert(contentsOf: transcript(event["entries"].array).filter { !known.contains($0.id) }, at: 0)
            historyBefore = event["before"]
        case "message_start": if event["message"]["role"].string == "assistant" { partial = event["message"] }
        case "message_update":
            if case .object(var message) = partial {
                let delta = event["assistantMessageEvent"]
                if case .number(let n) = delta["contentIndex"], n >= 0, n < 10000 {
                    var blocks = message["content"]?.array ?? []
                    let index = Int(n), kind = delta["type"].string
                    let key = kind.hasPrefix("thinking") ? "thinking" : kind.hasPrefix("toolcall") ? "argumentsText" : "text"
                    while blocks.count <= index { blocks.append(.object(["type": .string(key == "argumentsText" ? "toolCall" : key)])) }
                    if case .object(var block) = blocks[index] {
                        if kind == "toolcall_end" { blocks[index] = delta["toolCall"] }
                        else {
                            block[key] = kind.hasSuffix("_end") ? delta["content"] : .string((block[key]?.string ?? "") + delta["delta"].string)
                            if kind == "toolcall_start" { block["id"] = delta["id"]; block["name"] = delta["toolName"] }
                            blocks[index] = .object(block)
                        }
                    }
                    message["content"] = .array(blocks)
                    if event["usage"] != .null { message["usage"] = event["usage"] }
                    partial = .object(message)
                }
            }
        case "message_end":
            rows.append(Row(id: UUID().uuidString, message: event["message"]))
            if event["message"]["role"].string == "assistant" { partial = .null }
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            let id = event["toolCallId"]
            if type == "tool_execution_update", let index = tools.firstIndex(where: { $0["toolCallId"] == id }) {
                var tool = tools[index].object; tool["partialResult"] = event["partialResult"]; tools[index] = .object(tool)
            } else {
                tools.removeAll { $0["toolCallId"] == id }
                if type == "tool_execution_start" { tools.append(event) }
            }
            tools.sort { $0["toolCallId"].string < $1["toolCallId"].string }
        case "thinking_level_changed":
            if case .object(var value) = state { value["thinkingLevel"] = event["level"]; state = .object(value) }
        case "queue_update": queues = .object(["steering": event["steering"], "followUp": event["followUp"]])
        case "agent_start", "agent_end", "agent_settled":
            if case .object(var value) = state { value["isStreaming"] = .bool(type == "agent_start"); state = .object(value) }
        case "extension_ui_request":
            switch event["method"].string {
            case "select", "confirm", "input", "editor":
                dialogs.removeAll { $0["id"] == event["id"] }; dialogs.append(event); dialogs.sort { $0["id"].string < $1["id"].string }
            case "setStatus":
                var values = status.object; values[event["statusKey"].string] = event["statusText"] == .null ? nil : event["statusText"]; status = .object(values)
            case "setWidget":
                var values = widgets.object; values[event["widgetKey"].string] = event["widgetLines"] == .null ? nil : event; widgets = .object(values)
            case "notify": notifications.append(event)
            case "setTitle": title = event["title"].string
            default: break
            }
        case "dialog_closed":
            if event["generation"] == generation { dialogs.removeAll { $0["id"] == event["id"] } }
        case "response":
            guard event["id"].string.hasPrefix(client + ":") else { return }
            if event["success"] == .bool(false) { error = event["error"].string }
            if event["command"].string == "clear_queue" { queues = .object(["steering": .array([]), "followUp": .array([])]) }
            if event["command"].string == "set_model", case .object(var value) = state { value["model"] = event["data"]; state = .object(value) }
            if event["command"].string == "set_thinking_level" { command("snapshot") }
        default: break
        }
    }
}
