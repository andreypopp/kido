import SwiftUI
import ImageIO

struct MessageView: View {
    let row: DisplayRow
    var expanded = false
    var loadHistory: () -> Void = {}
    var expansionChanged: (Bool) -> Void = { _ in }
    @State private var open = false
    @State private var image: NSImage?
    @State private var imageSheet = false
    var body: some View {
        Group {
            switch row.content {
            case .history(let loading):
                if loading { ProgressView().controlSize(.small) }
                else { Button("Load older messages", action: loadHistory) }
            case .user(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text("You").font(.caption).foregroundStyle(.secondary)
                    if case .string(let text) = message["content"] { Text(text).textSelection(.enabled) }
                    ForEach(Array(message["content"].array.enumerated()), id: \.offset) { index, block in
                        if block["type"].string == "image" { MessageView(row: .init(id: row.id + ":\(index)", content: .image(block))) }
                        else { Text(block["text"].string).textSelection(.enabled) }
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: 680, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            case .markdown(let text): MarkdownBody(text: text)
            case .responding: HStack { ProgressView().controlSize(.small); Text("Responding…").foregroundStyle(.secondary) }
            case .thinkingUnavailable: Text("Thinking unavailable").font(.callout).foregroundStyle(.secondary)
            case .thinking(let text, let active):
                if text.isEmpty { HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) } }
                else {
                    DisclosureGroup(isExpanded: $open) { MarkdownBody(text: text).foregroundStyle(.secondary).padding(.top, 8) } label: {
                        HStack(spacing: 6) {
                            if active { ProgressView().controlSize(.small) }
                            Text(active ? "Thinking…" : "Thoughts · " + (text.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? ""))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            case .tool(let call, let result, let execution): tool(call, result, execution)
            case .bash(let value):
                VStack(alignment: .leading, spacing: 6) {
                    tool(.object(["name": .string("bash"), "arguments": .object(["command": value["command"]])]), value["ended"] == .bool(false) ? .null : .object(["content": .array([.object(["type": .string("text"), "text": value["output"]])])]), .object(["ended": value["ended"] == .bool(false) ? .bool(false) : .bool(true), "partialResult": .object(["content": .array([.object(["type": .string("text"), "text": value["output"]])])])]))
                    if value["cancelled"] == .bool(true) { Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary) }
                    else if value["exitCode"] != .null { Text("Exited \(value["exitCode"].text)").font(.caption).foregroundStyle(.secondary) }
                    if !value["fullOutputPath"].string.isEmpty { Text(value["fullOutputPath"].string).font(.caption).textSelection(.enabled) }
                }
            case .custom(let message): custom(message)
            case .marker(let title, let summary):
                DisclosureGroup(isExpanded: $open) { MarkdownBody(text: summary) } label: {
                    HStack(spacing: 8) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1); Text(title).fixedSize(); Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
                }.font(.caption).foregroundStyle(.secondary)
            case .image(let attachment):
                VStack(alignment: .leading, spacing: 6) {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 320)
                        Button("Open image") { imageSheet = true }
                    } else { Label("Image unavailable", systemImage: "photo") }
                    if !attachment["filename"].string.isEmpty { Text(attachment["filename"].string).font(.caption) }
                }.task(id: row.id) {
                    let data = attachment["data"].string
                    let decoded = await Task.detached {
                        guard data.utf8.count < 32 * 1024 * 1024, let bytes = Data(base64Encoded: data), let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil as CGImage? }
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 960, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                    }.value
                    image = decoded.map { NSImage(cgImage: $0, size: .zero) }
                }.sheet(isPresented: $imageSheet) { if let image { Image(nsImage: image).resizable().scaledToFit().padding().frame(maxWidth: 800, maxHeight: 600) } }
            case .stopped: Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary)
            case .error(let text): Label { Text(text).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(Color(nsColor: .systemRed)) }
            }
        }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { if expanded { open = true } }
            .onChange(of: open) { _, value in expansionChanged(value) }
    }
    @ViewBuilder private func tool(_ call: JSON, _ result: JSON, _ execution: JSON) -> some View {
        let name = call["name"].string.isEmpty ? result["toolName"].string.isEmpty ? execution["toolName"].string : result["toolName"].string : call["name"].string
        let args = call["argumentsText"] != .null && call["arguments"].object.isEmpty ? JSON.null : call["arguments"] == .null ? execution["args"] : call["arguments"]
        let final = result == .null ? execution["result"] == .null ? execution["partialResult"] : execution["result"] : result
        let running = execution != .null && execution["ended"] != .bool(true)
        let failed = final["isError"] == .bool(true) || execution["isError"] == .bool(true)
        let output = final["content"].array.filter { $0["type"].string == "text" }.map { $0["text"].string }.joined(separator: "\n")
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    if args == .null { Text("Arguments not loaded").font(.caption).foregroundStyle(.secondary) }
                    else if name == "bash" { OutputView(text: args["command"].string) }
                    else {
                        ForEach(args.object.keys.sorted { lhs, rhs in
                            let order = name == "edit" ? ["path", "oldText", "newText"] : name == "read" ? ["path", "offset", "limit"] : ["path", "content"]
                            return (order.firstIndex(of: lhs) ?? 100, lhs) < (order.firstIndex(of: rhs) ?? 100, rhs)
                        }, id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key).font(.caption).foregroundStyle(.secondary)
                                if ["oldText", "newText", "content"].contains(key) { OutputView(text: args[key].string) }
                                else { Text(args[key].string.isEmpty ? args[key].text : args[key].string).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !output.isEmpty { OutputView(text: output, running: running) }
                    else { Text(final == .null ? "Output unavailable" : "Completed (no output)").foregroundStyle(.secondary) }
                    if !final["details"]["patch"].string.isEmpty { OutputView(text: final["details"]["patch"].string, diff: true) }
                    ForEach(Array(final["content"].array.enumerated()), id: \.offset) { index, block in
                        if block["type"].string == "image" { MessageView(row: .init(id: row.id + ":image:\(index)", content: .image(block))) }
                    }
                    DisclosureGroup("Raw arguments") { OutputView(text: args.text) }.font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: name == "bash" ? "terminal" : name == "read" ? "doc.text" : name == "edit" ? "pencil" : name == "write" ? "doc.badge.plus" : "wrench.and.screwdriver").frame(width: 16)
                    Text(summary(name, args)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(summary(name, args))
                    Spacer(minLength: 8)
                    if running { ProgressView().controlSize(.small).accessibilityLabel("Running") }
                    else if failed { Label("Failed", systemImage: "exclamationmark.circle").foregroundStyle(Color(nsColor: .systemRed)) }
                    else if final == .null { Text("Pending").font(.caption).foregroundStyle(.secondary) }
                    else { Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Completed") }
                }
            }
            if failed { Text(output.components(separatedBy: "\n").first ?? "Failed").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
    private func summary(_ name: String, _ args: JSON) -> String {
        if args == .null { return name + " · Receiving arguments…" }
        if name == "bash" { return args["command"].string.replacingOccurrences(of: "\n", with: " ") }
        if ["read", "edit", "write"].contains(name) { return name.capitalized + " " + args["path"].string }
        return name + " " + String(args.object.keys.sorted().map { key in
            let value = args[key]
            return key + "=" + (value.string.isEmpty ? value.array.isEmpty ? value.object.isEmpty ? value.text : "\(value.object.count) fields" : "\(value.array.count) items" : value.string)
        }.joined(separator: " ").prefix(100))
    }
    @ViewBuilder private func custom(_ message: JSON) -> some View {
        let kind = message["role"].string
        let details = message["details"]
        let text: String = {
            if kind == "kido-ask", details["question"] != .null { return details["question"].string }
            let raw = message["content"].string, from = details["from"].string
            guard details != .null else { return raw }
            let headers = kind == "kido-message" ? ["your parent, who spawned you", "your subagent", "another agent in this session, not the user"].map { "message from @\(from) (\($0)):\n" } : kind == "kido-reply" ? ["\(from) replied (to ask \(details["replyTo"].string)): "] : kind == "kido-notice" ? ["notice from \(from) (a subagent or background run's report, not the user):\n"] : []
            if let header = headers.first(where: { raw.hasPrefix($0) }) { return String(raw.dropFirst(header.count)) }
            if kind == "kido-stream", let first = raw.components(separatedBy: "\n").first, first.range(of: "^async run \\\".*\\\" output \\(run .+\\)$", options: .regularExpression) != nil { return String(raw.dropFirst(first.count + 1)) }
            return raw
        }()
        VStack(alignment: .leading, spacing: 8) {
            Text((details["from"].string.isEmpty ? "Another agent" : details["from"].string) + " · " + (["kido-ask": "Question", "kido-reply": "Reply", "kido-notice": "Notice", "kido-stream": "Run output"][kind] ?? "Message")).font(.caption.weight(.semibold))
            if details["replyTo"] != .null { Text(details["replyTo"].string).font(.caption).foregroundStyle(.secondary) }
            if ["kido-notice", "kido-stream"].contains(kind) {
                DisclosureGroup(text.components(separatedBy: "\n").first ?? "", isExpanded: $open) {
                    if kind == "kido-stream" { OutputView(text: text) } else { MarkdownBody(text: text) }
                }
            } else { MarkdownBody(text: text) }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }
}
