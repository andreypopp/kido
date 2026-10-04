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
    public private(set) var stats: JSON = .null
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
    private var writing = false
    private let sendBytes: @MainActor (Data) async throws -> Void
    public init(client: String = UUID().uuidString.lowercased(), send: @escaping @MainActor (Data) async throws -> Void) { self.client = client; sendBytes = send }
    public func disconnect() { connected = false; ready = false; pending.removeAll(); writing = false; assembly.removeAll(); seq = nil }
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
        guard !writing, let frame = pending.first else { return }
        writing = true
        Task {
            do { try await sendBytes(frame.bytes) } catch { self.error = error.localizedDescription; disconnect() }
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
                pending.removeFirst(); writing = false; pump()
            }
            return
        }
        if type == "snapshot" {
            connected = true; ready = true; instance = event["hello"]["instance"].string
            let record = event["record"]
            rows = record["entries"].array.compactMap { entry in
                var message = entry["message"]
                if ["compaction", "branch_summary"].contains(entry["type"].string) { message = .object(["role": entry["type"], "content": entry["summary"]]) }
                if entry["type"].string == "custom_message", entry["display"] != .bool(false) { message = .object(["role": entry["customType"], "content": entry["content"], "details": entry["details"]]) }
                return message == .null || message["role"].string == "system" ? nil : Row(id: entry["id"].string, message: message)
            }
            rows += record["pendingMessages"].array.enumerated().map { Row(id: "pending-\($0.offset)", message: $0.element) }
            partial = record["partial"]; tools = record["tools"].array
            dialogs = record["dialogs"].array.map { $0["request"] }
            queues = record["queues"]; state = record["state"]; models = record["models"].array
            thinkingLevels = record["thinkingLevels"].array.map(\.string); stats = record["stats"]
            return
        }
        guard ready else { return }
        switch type {
        case "message_start": partial = event["message"]
        case "message_update":
            if event["message"] != .null { partial = event["message"] }
            else if case .object(var message) = partial {
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
        case "message_end": rows.append(Row(id: UUID().uuidString, message: event["message"])); partial = .null
        case "tool_execution_start": tools.append(event)
        case "tool_execution_update", "tool_execution_end":
            let id = event["toolCallId"]
            tools.removeAll { $0["toolCallId"] == id }
            if type == "tool_execution_update" { tools.append(event) }
        case "thinking_level_changed":
            if case .object(var value) = state { value["thinkingLevel"] = event["level"]; state = .object(value) }
        case "queue_update": queues = .object(["steering": event["steering"], "followUp": event["followUp"]])
        case "agent_start", "agent_settled":
            if case .object(var value) = state { value["isStreaming"] = .bool(type == "agent_start"); state = .object(value) }
        case "extension_ui_request":
            if ["select", "confirm", "input", "editor"].contains(event["method"].string) { dialogs.append(event) }
        case "dialog_closed": dialogs.removeAll { $0["id"] == event["id"] }
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
