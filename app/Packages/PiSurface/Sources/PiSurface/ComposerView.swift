import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable final class ComposerDraft { var text = ""; var images: [JSON] = [] }

struct ComposerView: View {
    @Bindable var session: Session
    @State var draft = ComposerDraft()
    @Binding var tailRequest: Int
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 440
    @State private var attaching = false
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
            let grown = draft.text.contains("\n") || (draft.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width > max(1, width - 100)
            let editor = TextField("Message pi…", text: $draft.text, axis: .vertical).textFieldStyle(.plain).lineLimit(1...9).font(.body)
                .fixedSize(horizontal: false, vertical: true).focused($focused).accessibilityLabel("Message pi")
                .onKeyPress(keys: [.return], phases: .down) { key in
                    if key.modifiers.contains(.shift) { return .ignored }
                    submit(followUp: key.modifiers.contains(.option)); return .handled
                }.onKeyPress(.escape) {
                    guard session.dialogs.isEmpty else { return .ignored }
                    if session.streaming || queued > 0 { session.command("clear_queue") }
                    return .handled
                }
            let controls = HStack(spacing: 6) {
                Button("Attach image", systemImage: "paperclip") { attaching = true }.disabled(!enabled)
                if session.streaming { Button("Stop", systemImage: "stop.fill") { session.command("abort") }.disabled(!enabled) }
                else { Button("Send", systemImage: "arrow.up") { submit(followUp: false) }.tint(.accentColor).disabled(!enabled || pending || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small).frame(height: 28)
            if !draft.images.isEmpty { Text("\(draft.images.count) images attached").font(.caption).foregroundStyle(.secondary) }
            if grown { editor; HStack { Spacer(); controls } }
            else { HStack(spacing: 10) { editor; controls } }
            widgets("belowEditor")
            Divider().padding(.horizontal, -12)
            HStack(spacing: 6) {
                MenuPicker(options: session.models.map { ($0.id, $0.name) }, selection: Binding(get: { session.state["model"]["provider"].string + "/" + session.state["model"]["id"].string }, set: { key in
                    if let model = session.models.first(where: { $0.id == key }) { session.command("set_model", fields: ["provider": .string(model.provider), "modelId": .string(model.modelID)]) }
                }), label: "Model").fixedSize().disabled(!enabled || session.requests.values.contains("set_model"))
                if let usage = session.rows.last(where: { $0.message["usage"] != .null })?.message["usage"], case .number(let maximum) = session.state["model"]["contextWindow"] {
                    let used = ["input", "output", "cacheRead", "cacheWrite"].reduce(0.0) { sum, key in if case .number(let value) = usage[key] { return sum + value }; return sum }
                    Text("· " + (used / 1000).formatted(.number.precision(.fractionLength(1))) + "k / " + (maximum / 1000).formatted(.number.precision(.fractionLength(0))) + "k context").lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(!session.connected ? "Disconnected" : !session.synchronized ? "Synchronizing…" : session.compaction != .null ? "Compacting…" : session.retry != .null ? "Retrying…" : session.streaming ? "Running" : "Ready").fixedSize()
            }.font(.caption).foregroundStyle(.secondary).frame(height: 19)
                .contextMenu {
                    ForEach(session.thinkingLevels, id: \.self) { level in Button(level) { session.command("set_thinking_level", fields: ["level": .string(level)]) } }
                    ForEach(session.status.object.keys.sorted(), id: \.self) { key in Text(session.status[key].string) }
                }
            if !session.error.isEmpty { Label(session.error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Color(nsColor: .systemRed)).textSelection(.enabled) }
        }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .fileImporter(isPresented: $attaching, allowedContentTypes: [.png, .jpeg, .gif, .webP], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url), let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType {
                        draft.images.append(.object(["type": .string("image"), "data": .string(data.base64EncodedString()), "mimeType": .string(type)]))
                    }
                }
            }
            .onChange(of: session.scope) { _, _ in dismissed.removeAll() }
            .onChange(of: session.acceptedPrompt) { _, value in if draft.text == value["text"].string { draft.text = ""; draft.images = []; tailRequest += 1 } }
            .onChange(of: session.restoredQueue) { _, value in let text = value["text"].string; if !text.isEmpty { draft.text = [draft.text, text].filter { !$0.isEmpty }.joined(separator: "\n\n") } }
    }
    private func submit(followUp: Bool) {
        guard enabled, !pending, !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var fields: [String: JSON] = ["message": .string(draft.text)]
        if !draft.images.isEmpty { fields["images"] = .array(draft.images) }
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
