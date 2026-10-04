import SwiftUI
import ImageIO

func firstLine(_ text: String, skippingEmpty: Bool = false, separators: CharacterSet = CharacterSet(charactersIn: "\n")) -> String {
    let value = text as NSString
    var start = 0
    while start < value.length {
        let end = value.rangeOfCharacter(from: separators, range: NSRange(location: start, length: value.length - start))
        if end.location == NSNotFound { return value.substring(from: start) }
        if !skippingEmpty || end.location > start { return value.substring(with: NSRange(location: start, length: end.location - start)) }
        start = NSMaxRange(end)
    }
    return ""
}

struct MessageView: View {
    let row: DisplayRow
    var expanded = false
    var loadHistory: () -> Void = {}
    var expansionChanged: (Bool) -> Void = { _ in }
    var willToggle: () -> Void = {}
    @State private var open = false
    @State private var image: NSImage?
    @State private var imageSheet = false
    var body: some View {
        Group {
            switch row.content {
            case .history(let loading):
                Group {
                    if loading { ProgressView().controlSize(.small) }
                    else { Button("Load older messages", action: loadHistory) }
                }.frame(height: 20)
            case .user(let message):
                VStack(alignment: .leading, spacing: 6) {
                    if case .string(let text) = message["content"] { MarkdownBody(text: text) }
                    ForEach(Array(message["content"].array.enumerated()), id: \.offset) { index, block in
                        if block["type"].string == "image" { MessageView(row: .init(id: row.id + ":\(index)", content: .image(block))) }
                        else { MarkdownBody(text: block["text"].string) }
                    }
                }.fontWeight(.medium).padding(.vertical, 9).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .background(Color(nsColor: NSColor.windowBackgroundColor.blended(withFraction: 0.06, of: .labelColor) ?? .controlBackgroundColor))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }.clipShape(RoundedRectangle(cornerRadius: 8))
            case .activity(let items): ActivityView(items: items, expanded: expanded, expansionChanged: expansionChanged, willToggle: willToggle)
            case .markdown(let text): MarkdownBody(text: text)
            case .responding: HStack { ProgressView().controlSize(.small); Text("Responding…").foregroundStyle(.secondary) }
            case .thinkingUnavailable: Text("Thinking unavailable").font(.callout).foregroundStyle(.secondary)
            case .thinking(let text, let active):
                if text.isEmpty { HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) } }
                else {
                    DisclosureGroup(isExpanded: $open) { MarkdownBody(text: text).foregroundStyle(.secondary).padding(.top, 8) } label: {
                        HStack(spacing: 6) {
                            if active { ProgressView().controlSize(.small) }
                            Text(active ? "Thinking…" : "Thoughts · " + (firstLine(text, skippingEmpty: true)))
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
            case .custom(let message):
                let kind = message["role"].string
                let details = message["details"]
                let text: String = {
                    if kind == "kido-ask", details["question"] != .null { return details["question"].string }
                    let raw = message["content"].string, from = details["from"].string
                    guard details != .null else { return raw }
                    let headers = kind == "kido-message" ? ["your parent, who spawned you", "your subagent", "another agent in this session, not the user"].map { "message from @\(from) (\($0)):\n" } : kind == "kido-reply" ? ["\(from) replied (to ask \(details["replyTo"].string)): "] : kind == "kido-notice" ? ["notice from \(from) (a subagent or background run's report, not the user):\n"] : []
                    if let header = headers.first(where: { raw.hasPrefix($0) }) { return String(raw.dropFirst(header.count)) }
                    let first = firstLine(raw)
                    if kind == "kido-stream", first.range(of: "^async run \\\".*\\\" output \\(run .+\\)$", options: .regularExpression) != nil { return String(raw.dropFirst(first.count + 1)) }
                    return raw
                }()
                VStack(alignment: .leading, spacing: 8) {
                    Text((details["from"].string.isEmpty ? "Another agent" : details["from"].string) + " · " + (["kido-ask": "Question", "kido-reply": "Reply", "kido-notice": "Notice", "kido-stream": "Run output"][kind] ?? "Message")).font(.caption.weight(.semibold))
                    if details["replyTo"] != .null { Text(details["replyTo"].string).font(.caption).foregroundStyle(.secondary) }
                    if ["kido-notice", "kido-stream"].contains(kind) {
                        DisclosureGroup(firstLine(text), isExpanded: $open) {
                            if kind == "kido-stream" { OutputView(text: text) } else { MarkdownBody(text: text) }
                        }
                    } else { MarkdownBody(text: text) }
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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
            .onChange(of: expanded) { _, value in open = value }
            .onChange(of: open) { _, value in expansionChanged(value) }
    }
    @ViewBuilder private func tool(_ call: JSON, _ result: JSON, _ execution: JSON) -> some View {
        let name = call["name"].string.isEmpty ? result["toolName"].string.isEmpty ? execution["toolName"].string : result["toolName"].string : call["name"].string
        let args = call["argumentsText"] != .null && call["arguments"].object.isEmpty ? JSON.null : call["arguments"] == .null ? execution["args"] : call["arguments"]
        let final = result == .null ? execution["result"] == .null ? execution["partialResult"] : execution["result"] : result
        let running = execution != .null && execution["ended"] != .bool(true)
        let failed = final["isError"] == .bool(true) || execution["isError"] == .bool(true)
        let builtin = args != .null && ["read", "edit", "write"].contains(name)
        let title = if args == .null { name + " · Receiving arguments…" }
            else if name == "bash" { args["command"].string.replacingOccurrences(of: "\n", with: " ") }
            else if builtin { name.capitalized + " " + args["path"].string }
            else { name + " " + String(args.object.keys.sorted().map { key in
                let value = args[key]
                return key + "=" + (value.string.isEmpty ? value.array.isEmpty ? value.object.isEmpty ? value.text : "\(value.object.count) fields" : "\(value.array.count) items" : value.string)
            }.joined(separator: " ").prefix(100)) }
        let output = open || failed ? final["content"].array.filter { $0["type"].string == "text" }.map { $0["text"].string }.joined(separator: "\n") : ""
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    if name == "bash" { OutputView(text: args["command"].string) }
                    else if args != .null {
                        DisclosureGroup("Details") {
                            ForEach(args.object.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key).font(.caption).foregroundStyle(.secondary)
                                    if ["oldText", "newText", "content"].contains(key) { OutputView(text: args[key].string) }
                                    else { Text(args[key].string.isEmpty ? args[key].text : args[key].string).textSelection(.enabled) }
                                }
                            }
                        }.font(.callout)
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
                HStack(spacing: 6) {
                    Image(systemName: name == "bash" ? "terminal" : name == "read" ? "doc.text" : name == "edit" ? "pencil" : name == "write" ? "doc.badge.plus" : "wrench.and.screwdriver").frame(width: 16)
                    (builtin ? Text("\(name.capitalized) \(Text(args["path"].string).monospaced())") : Text(title).monospaced()).font(.callout).lineLimit(1).truncationMode(.middle).help(title)
                    if running { ProgressView().controlSize(.small).accessibilityLabel("Running") }
                    else if failed { Label("Failed", systemImage: "exclamationmark.circle").foregroundStyle(Color(nsColor: .systemRed)) }
                    else if final == .null { Text("Pending").font(.caption).foregroundStyle(.secondary) }
                    else { Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Completed") }
                }
            }
            if failed { Text(firstLine(output)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}
