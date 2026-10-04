import SwiftUI

public struct Surface: View {
    @Bindable var session: Session
    @State private var prompt = ""
    @State private var answer = ""
    public init(session: Session) { self.session = session }
    public var body: some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.rows) { row in message(row.message) }
                    if session.partial != .null { message(session.partial) }
                    ForEach(Array(session.tools.enumerated()), id: \.offset) { _, tool in
                        DisclosureGroup(tool["toolName"].string) {
                            Text(tool["args"].text).font(.system(.body, design: .monospaced))
                            message(tool["latestResult"] == .null ? tool["partialResult"] : tool["latestResult"])
                        }
                    }
                }.padding().textSelection(.enabled)
            }.defaultScrollAnchor(.bottom)
            TextEditor(text: $prompt).frame(height: 100)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    session.command("prompt", fields: ["message": .string(prompt), "streamingBehavior": .string(press.modifiers.contains(.option) ? "followUp" : "steer")]); prompt = ""; return .handled
                }
                .onKeyPress(.escape) {
                    prompt = (session.queues["steering"].array + session.queues["followUp"].array).map(\.string).joined(separator: "\n")
                    session.command("clear_queue"); session.command("abort"); return .handled
                }
            HStack {
                Text(session.connected ? (session.streaming ? "Streaming" : "Idle") : "Disconnected")
                Text("Queue: \(session.queues["steering"].array.count + session.queues["followUp"].array.count)")
                Text(session.partial["usage"] != .null ? session.partial["usage"].text : session.stats == .null ? "" : session.stats.text)
                Text(session.error).foregroundStyle(.red)
            }.font(.caption).textSelection(.enabled)
        }.padding()
        .toolbar {
            Picker("Model", selection: Binding(get: { session.state["model"]["id"].string }, set: { id in
                if let model = session.models.first(where: { $0["id"].string == id }) { session.command("set_model", fields: ["provider": model["provider"], "modelId": model["id"]]) }
            })) { ForEach(session.models, id: \.text) { model in Text(model["name"].string).tag(model["id"].string) } }
            Picker("Thinking", selection: Binding(get: { session.state["thinkingLevel"].string }, set: { session.command("set_thinking_level", fields: ["level": .string($0)]) })) {
                ForEach(session.thinkingLevels, id: \.self) { Text($0).tag($0) }
            }
        }
        .sheet(isPresented: Binding(get: { !session.dialogs.isEmpty }, set: { _ in })) {
            if let dialog = session.dialogs.first {
                VStack {
                    Text(dialog["title"].string).font(.headline)
                    Text(dialog["message"].string)
                    if dialog["method"].string == "select" {
                        ForEach(dialog["options"].array, id: \.text) { option in Button(option.string) { respond(dialog, ["value": option]) } }
                    } else if dialog["method"].string == "confirm" {
                        Button("Confirm") { respond(dialog, ["confirmed": .bool(true)]) }
                    } else {
                        TextEditor(text: $answer).frame(width: 400, height: 180)
                        Button("Submit") { respond(dialog, ["value": .string(answer)]) }
                    }
                    Button("Cancel") { respond(dialog, ["cancelled": .bool(true)]) }
                }.padding().textSelection(.enabled).onAppear { answer = dialog["prefill"].string }
            }
        }
    }
    private func respond(_ dialog: JSON, _ fields: [String: JSON]) {
        session.command("extension_ui_response", fields: fields.merging(["id": dialog["id"]]) { _, new in new })
    }
    @ViewBuilder private func message(_ value: JSON) -> some View {
        VStack(alignment: .leading) {
            if !value["role"].string.isEmpty { Text(value["role"].string).font(.caption).foregroundStyle(.secondary) }
            if case .string(let text) = value["content"] { markdown(text) }
            ForEach(Array(value["content"].array.enumerated()), id: \.offset) { _, block in
                switch block["type"].string {
                case "thinking": DisclosureGroup("Thinking") { markdown(block["thinking"].string) }
                case "toolCall": DisclosureGroup(block["name"].string) { Text(block["arguments"] == .null ? block["argumentsText"].string : block["arguments"].text).font(.system(.body, design: .monospaced)) }
                default: markdown(block["text"].string)
                }
            }
            if !value["details"]["patch"].string.isEmpty {
                ForEach(Array(value["details"]["patch"].string.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.body, design: .monospaced)).foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : .primary)
                }
            }
            if !value["output"].string.isEmpty { Text(value["output"].string).font(.system(.body, design: .monospaced)) }
        }
    }
    private func markdown(_ text: String) -> Text { Text((try? AttributedString(markdown: text)) ?? AttributedString(text)) }
}
