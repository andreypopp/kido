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
    private(set) var displayRows: [DisplayRow] = []
    private(set) var partialID = ""
    @ObservationIgnored public private(set) var partial: JSON = .null
    public private(set) var visualRevision = 0
    private var redraw: Task<Void, Never>?
    public private(set) var bash: JSON = .null
    public private(set) var retry: JSON = .null
    public private(set) var compaction: JSON = .null
    public private(set) var historyLoading = false
    public private(set) var requests: [String: String] = [:]
    public private(set) var acceptedPrompt: JSON = .null
    public private(set) var restoredQueue: JSON = .null
    private var submitted: [String: String] = [:]
    var synchronized: Bool { connected && ready }
    var scope: String { instance + ":" + generation.text }
    @ObservationIgnored public private(set) var tools: [JSON] = []
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
    public func disconnect() { requests.removeAll(); submitted.removeAll(); historyLoading = false; connected = false; ready = false; pending.removeAll(); writer?.cancel(); writer = nil; assembly.removeAll(); seq = nil; generation = .null }
    public func command(_ type: String, fields: [String: JSON] = [:]) {
        guard connected else { return }
        if type == "history" { guard !historyLoading else { return }; historyLoading = true }
        if ["prompt", "set_model", "set_thinking_level", "clear_queue"].contains(type), requests.values.contains(type) { return }
        counter += 1
        let id = "\(client):\(counter)"
        requests[id] = type
        if type == "bash" { var values = bash.object; values[id] = .object(["command": fields["command"] ?? .null, "output": .string(""), "ended": .bool(false)]); bash = .object(values) }
        if type == "prompt" { submitted[id] = fields["message"]?.string }
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
                for _ in 0..<10 {
                    try Task.checkCancellation()
                    try await self?.sendBytes(frame.bytes)
                    try await Task.sleep(for: .milliseconds(500))
                }
                throw NSError(domain: "PiSurface", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bridge acknowledgement timed out"])
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
            if message["role"].string == "custom", message["display"] != .bool(false) { message = .object(["role": message["customType"], "content": message["content"], "details": message["details"]]) }
            return message == .null || entry["display"] == .bool(false) ? nil : Row(id: entry["uiId"].string.isEmpty ? entry["id"].string : entry["uiId"].string, message: message)
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
            if generation != event["generation"] { pending.removeAll(); requests.removeAll(); submitted.removeAll(); writer?.cancel(); writer = nil }
            generation = event["generation"]
            connected = true; ready = true; instance = event["hello"]["instance"].string
            let record = event["record"]
            rows = transcript(record["entries"].array)
            displayRows = project(rows, scope: scope)
            partialID = record["partialAssistant"]["uiId"].string
            bash = record["bash"]; retry = record["retry"]; compaction = record["compaction"]
            historyLoading = false
            historyBefore = record["entries"].array.first?["id"] ?? .null
            partial = record["partialAssistant"]; tools = record["tools"].orderedValues; visualRevision += 1
            dialogs = record["dialogs"].orderedValues
            queues = record["queues"]; state = record["state"]; models = record["models"].array
            thinkingLevels = record["thinkingLevels"].array.map(\.string)
            status = record["status"]; widgets = record["widgets"]; notifications = record["notifications"].array; title = record["title"].string
            return
        }
        guard ready else { return }
        switch type {
        case "history":
            guard event["generation"] == generation, requests[event["id"].string] == "history" else { return }
            requests[event["id"].string] = nil
            let known = Set(rows.map(\.id))
            rows.insert(contentsOf: transcript(event["entries"].array).filter { !known.contains($0.id) }, at: 0)
            historyBefore = event["before"]; historyLoading = false
            displayRows = project(rows, scope: scope)
        case "message_start":
            if event["message"]["role"].string == "assistant" { partial = event["message"]; partialID = event["uiId"].string.isEmpty ? UUID().uuidString : event["uiId"].string }
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
                            if kind == "thinking_start" { block["active"] = .bool(true) }
                            if kind == "thinking_end" { block["active"] = .bool(false) }
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
            let id = event["uiId"].string.isEmpty ? event["message"]["role"].string == "assistant" ? partialID : UUID().uuidString : event["uiId"].string
            let message = event["message"]
            let value = message["role"].string == "custom" ? JSON.object(["role": message["customType"], "content": message["content"], "details": message["details"]]) : message
            if message["display"] != .bool(false) { rows.append(Row(id: id, message: value)) }
            displayRows = project(rows, scope: scope)
            if event["message"]["role"].string == "assistant" { partial = .null }
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            let id = event["toolCallId"]
            if type == "tool_execution_update", let index = tools.firstIndex(where: { $0["toolCallId"] == id }) {
                var tool = tools[index].object; tool["partialResult"] = event["partialResult"]; tools[index] = .object(tool)
            } else if type == "tool_execution_end", let index = tools.firstIndex(where: { $0["toolCallId"] == id }) {
                var tool = tools[index].object; tool["result"] = event["result"]; tool["isError"] = event["isError"]; tool["ended"] = .bool(true); tools[index] = .object(tool)
            } else if type == "tool_execution_start" {
                tools.removeAll { $0["toolCallId"] == id }; tools.append(event)
            }
            tools.sort { $0["toolCallId"].string < $1["toolCallId"].string }
        case "bash_execution_start":
            var values = bash.object; values[event["id"].string] = .object(["command": event["command"], "output": .string(""), "ended": .bool(false)]); bash = .object(values)
        case "bash_execution_update":
            var values = bash.object; let id = event["id"].string
            var value = values[id]?.object ?? [:]; value["output"] = .string((value["output"]?.string ?? "") + event["delta"].string); values[id] = .object(value); bash = .object(values)
        case "auto_retry_start": retry = event
        case "auto_retry_end": retry = .null
        case "compaction_start", "auto_compaction_start": compaction = event
        case "compaction_end", "auto_compaction_end": compaction = .null
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
            if event["command"].string == "bash" {
                var values = bash.object, value = values[event["id"].string]?.object ?? [:]
                value.merge(event["data"].object) { _, new in new }; value["ended"] = .bool(true)
                values[event["id"].string] = .object(value); bash = .object(values)
            }
            if event["command"].string == "get_entries", event["success"] == .bool(true) {
                let incoming = transcript(event["data"]["entries"].array)
                var executions = bash.object
                for entry in event["data"]["entries"].array where entry["message"]["role"] == .string("bashExecution") { executions[entry["uiId"].string] = nil }
                bash = .object(executions)
                var known = Set(rows.map(\.id))
                for (index, row) in incoming.enumerated() where known.insert(row.id).inserted {
                    let next = incoming.dropFirst(index + 1).first { known.contains($0.id) }
                    let position = next.flatMap { next in rows.firstIndex { $0.id == next.id } } ?? rows.count
                    rows.insert(row, at: position)
                }
                displayRows = project(rows, scope: scope)
            }
            guard event["id"].string.hasPrefix(client + ":") else { return }
            let id = event["id"].string
            requests[id] = nil
            if event["success"] == .bool(false) { error = event["error"].string }
            else {
                if let text = submitted[id] { acceptedPrompt = .object(["id": .string(id), "text": .string(text)]) }
                if event["command"].string == "clear_queue" {
                    restoredQueue = .object(["id": .string(id), "text": .string((event["data"]["steering"].array + event["data"]["followUp"].array).map(\.string).joined(separator: "\n\n"))])
                    command("abort")
                }
            }
            submitted[id] = nil
            if event["command"].string == "set_model", event["success"] == .bool(true), case .object(var value) = state { value["model"] = event["data"]; state = .object(value) }
            if event["command"].string == "set_thinking_level" { command("snapshot") }
        default: break
        }
        if redraw == nil {
            redraw = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(34))
                self?.visualRevision += 1; self?.redraw = nil
            }
        }
    }
}
