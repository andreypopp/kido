import SwiftUI

struct ComposerView: View {
    @Bindable var session: Session
    @Binding var draft: String
    @Binding var tailRequest: Int
    @FocusState private var focused: Bool
    @State private var dismissed = Set<Int>()
    private var enabled: Bool { session.synchronized && session.dialogs.isEmpty }
    private var pending: Bool { session.requests.values.contains("prompt") }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let notifications = session.notifications.enumerated().filter { !dismissed.contains($0.offset) }
            ForEach(Array(notifications.suffix(3)), id: \.offset) { index, notice in
                HStack(alignment: .top) {
                    Label(notice["message"].string, systemImage: notice["notifyType"].string == "error" ? "exclamationmark.circle" : "info.circle").font(.caption)
                    Spacer()
                    Button("Dismiss notification", systemImage: "xmark") { dismissed.insert(index) }.labelStyle(.iconOnly).help("Dismiss notification")
                }
            }
            if notifications.count > 3 { Text("\(notifications.count - 3) more").font(.caption).foregroundStyle(.secondary) }
            widgets("aboveEditor")
            let queued = session.queues["steering"].array.count + session.queues["followUp"].array.count
            if queued > 0 {
                DisclosureGroup("Queued · \(queued)") {
                    ForEach(["steering", "followUp"], id: \.self) { kind in
                        ForEach(Array(session.queues[kind].array.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind == "steering" ? "Steer" : "Follow-up").font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup { Text(item.string).textSelection(.enabled) } label: { Text(item.string).lineLimit(2) }
                            }
                        }
                    }
                }.font(.callout)
            }
            TextField("Message pi…", text: $draft, axis: .vertical).textFieldStyle(.plain).lineLimit(3...10).font(.body)
                .padding(10).fixedSize(horizontal: false, vertical: true).focused($focused).accessibilityLabel("Message pi")
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
                .onKeyPress(keys: [.return], phases: .down) { key in
                    if key.modifiers.contains(.shift) { return .ignored }
                    submit(followUp: key.modifiers.contains(.option)); return .handled
                }
                .onKeyPress(.escape) {
                    guard session.dialogs.isEmpty else { return .ignored }
                    if session.streaming || queued > 0 { session.command("clear_queue") }
                    return .handled
                }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pickers; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 8) { HStack { pickers }; HStack { Spacer(); actions } }
            }
            HStack(spacing: 6) {
                Text(!session.connected ? "Reconnecting…" : !session.synchronized ? "Synchronizing…" : session.compaction != .null ? "Compacting…" : session.retry != .null ? "Retrying…" : session.streaming ? "Responding…" : "Ready")
                ForEach(session.status.object.keys.sorted(), id: \.self) { key in Text(session.status[key].string) }
            }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !session.error.isEmpty { Label(session.error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Color(nsColor: .systemRed)).textSelection(.enabled) }
            widgets("belowEditor")
        }.padding(.vertical, 12).frame(maxWidth: 760, alignment: .leading)
            .onChange(of: session.scope) { _, _ in dismissed.removeAll() }
            .onChange(of: session.acceptedPrompt) { _, value in if draft == value["text"].string { draft = ""; tailRequest += 1 } }
            .onChange(of: session.restoredQueue) { _, value in let text = value["text"].string; if !text.isEmpty { draft = [draft, text].filter { !$0.isEmpty }.joined(separator: "\n\n") } }
    }
    private var pickers: some View {
        Group {
            Picker("Model", selection: Binding(get: { session.state["model"]["provider"].string + ":" + session.state["model"]["id"].string }, set: { key in
                if let model = session.models.first(where: { $0["provider"].string + ":" + $0["id"].string == key }) { session.command("set_model", fields: ["provider": model["provider"], "modelId": model["id"]]) }
            })) {
                ForEach(session.models, id: \.text) { model in Text(model["name"].string + " · " + model["provider"].string).tag(model["provider"].string + ":" + model["id"].string) }
            }.pickerStyle(.menu).disabled(!enabled || session.requests.values.contains("set_model"))
            Picker("Thinking", selection: Binding(get: { session.state["thinkingLevel"].string }, set: { session.command("set_thinking_level", fields: ["level": .string($0)]) })) {
                ForEach(session.thinkingLevels, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).disabled(!enabled || session.requests.values.contains("set_thinking_level"))
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            Button("Send", systemImage: "arrow.up") { submit(followUp: false) }.labelStyle(.iconOnly).buttonStyle(.borderedProminent)
                .disabled(!enabled || pending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Return: send or steer. Option-Return: queue follow-up. Shift-Return: newline.")
                .contextMenu { if session.streaming { Button("Queue follow-up") { submit(followUp: true) } } }
            if session.streaming { Button("Stop", systemImage: "stop.fill") { session.command("abort") }.labelStyle(.iconOnly).buttonStyle(.bordered).disabled(!enabled).help("Stop without clearing queue") }
        }
    }
    private func submit(followUp: Bool) {
        guard enabled, !pending, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var fields: [String: JSON] = ["message": .string(draft)]
        if session.streaming { fields["streamingBehavior"] = .string(followUp ? "followUp" : "steer") }
        session.command("prompt", fields: fields)
    }
    @ViewBuilder private func widgets(_ placement: String) -> some View {
        ForEach(session.widgets.object.keys.sorted(), id: \.self) { key in
            let widget = session.widgets[key]
            if (widget["widgetPlacement"].string.isEmpty ? "belowEditor" : widget["widgetPlacement"].string) == placement {
                let text = widget["widgetLines"].array.map(\.string).joined(separator: "\n")
                if widget["widgetLines"].array.count > 3 { DisclosureGroup(key) { Text(text).textSelection(.enabled) }.font(.caption) }
                else { Text(text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
}

struct DialogView: View {
    @Bindable var session: Session
    let dialog: JSON
    @State private var answer = ""
    @State private var selection: Int?
    @State private var submitted = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(dialog["title"].string).font(.headline)
            if !dialog["message"].string.isEmpty { Text(dialog["message"].string).textSelection(.enabled) }
            switch dialog["method"].string {
            case "select":
                List(selection: $selection) { ForEach(Array(dialog["options"].array.enumerated()), id: \.offset) { index, option in Text(option.string).tag(index) } }.frame(minHeight: 120, maxHeight: 300)
            case "input": TextField(dialog["placeholder"].string, text: $answer).focused($focused).onSubmit { respond() }
            case "editor": TextEditor(text: $answer).frame(minHeight: 180, maxHeight: 400).focused($focused).onKeyPress(keys: [.return], phases: .down) { key in if key.modifiers.contains(.command) { respond(); return .handled }; return .ignored }
            default: EmptyView()
            }
            HStack {
                if submitted { Text("Submitting…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { send(["cancelled": .bool(true)]) }.keyboardShortcut(.cancelAction)
                Button(dialog["method"].string == "confirm" ? "Confirm" : dialog["method"].string == "select" ? "Choose" : "Submit") { respond() }
                    .keyboardShortcut(.defaultAction).disabled(dialog["method"].string == "select" && selection == nil)
            }.disabled(submitted)
        }.padding(20).frame(width: dialog["method"].string == "editor" ? 600 : 440)
            .onAppear { answer = dialog["prefill"].string; focused = true }
    }
    private func respond() {
        if dialog["method"].string == "confirm" { send(["confirmed": .bool(true)]) }
        else if dialog["method"].string == "select", let selection { send(["value": dialog["options"].array[selection]]) }
        else { send(["value": .string(answer)]) }
    }
    private func send(_ fields: [String: JSON]) { guard !submitted else { return }; submitted = true; session.command("extension_ui_response", fields: fields.merging(["id": dialog["id"]]) { _, new in new }) }
}
