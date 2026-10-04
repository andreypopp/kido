import SwiftUI

struct ActivityView: View {
    let items: [DisplayRow]
    var expanded: Bool
    var expansionChanged: (Bool) -> Void
    @State private var open = false
    @State private var detail: String?
    var body: some View {
        let values = items.map { item -> (String, String, String, Bool, Bool) in
            switch item.content {
            case .thinking(let text, let active): return ("thinking", text.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? "", "", active, false)
            case .tool(let call, let result, let execution):
                let name = call["name"].string.isEmpty ? result["toolName"].string.isEmpty ? execution["toolName"].string : result["toolName"].string : call["name"].string
                let args = call["arguments"] == .null ? execution["args"] : call["arguments"]
                let preview = ["command", "code", "path"].map { args[$0].string }.first(where: { !$0.isEmpty }) ?? args.text
                let final = result == .null ? execution["result"] == .null ? execution["partialResult"] : execution["result"] : result
                return (name, preview.components(separatedBy: .newlines).first ?? "", final["content"].array.filter { $0["type"].string == "text" }.map { $0["text"].string }.joined(separator: "\n"), execution != .null && execution["ended"] != .bool(true), final["isError"] == .bool(true) || execution["isError"] == .bool(true))
            default: return ("thinking", "Unavailable", "", false, false)
            }
        }
        let active = values.last?.3 == true
        let prefix = active ? Array(values.dropLast()) : values
        let summary = prefix.reduce(into: [(String, Int)]()) { runs, value in
            if runs.last?.0 == value.0 && value.0 != "thinking" { runs[runs.count - 1].1 += 1 }
            else { runs.append((value.0, 1)) }
        }.map { $0.0 + ($0.1 > 1 ? " ×\($0.1)" : "") }.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 8) {
            Button { expansionChanged(!open); open.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption)
                    if open { Text("Activity · \(items.count) steps") }
                    else {
                        Text(summary).lineLimit(1).truncationMode(.tail)
                        if active { Text((prefix.isEmpty ? "" : ", ") + (values.last?.0 ?? "")).fixedSize() }
                    }
                    if values.contains(where: { $0.4 }) { Label("Failed", systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize() }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let value = values[index]
                        Button { expansionChanged(open); detail = detail == item.id ? nil : item.id } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(value.0).frame(minWidth: 65, alignment: .leading)
                                Text(value.1).monospaced().lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                if value.4 { Text("Failed").foregroundStyle(.red) }
                            }.foregroundStyle(value.3 ? .primary : .secondary).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if value.3 && !value.2.isEmpty {
                            Text(value.2.components(separatedBy: "\n").suffix(3).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).lineLimit(3).padding(.leading, 73)
                        }
                        if detail == item.id { MessageView(row: item, expanded: true) }
                    }
                }.padding(.leading, 13).overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }.padding(.leading, 4)
            }
        }.font(.callout).foregroundStyle(.secondary).padding(.vertical, 5)
            .onAppear { open = expanded }.onChange(of: expanded) { _, value in open = value }
    }
}
