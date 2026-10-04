import SwiftUI

struct TranscriptView: View {
    @Bindable var session: Session
    var expanded: Bool
    var tailRequest: Int
    @State private var following = true
    @State private var jump = 0
    private var rows: [DisplayRow] {
        _ = session.visualRevision
        var values = session.displayRows
        if session.partial != .null {
            values += project([Row(id: session.partialID, message: session.partial)], scope: session.scope, active: true)
        }
        values = values.map { row in
            if case .tool(let call, let result, _) = row.content {
                let id = call["id"] == .null ? result["toolCallId"] : call["id"]
                return .init(id: row.id, content: .tool(call, result, session.tools.first { $0["toolCallId"] == id } ?? .null))
            }
            return row
        }
        for id in session.bash.object.keys.sorted() {
            let bash = session.bash[id]
            values.append(.init(id: session.scope + ":" + id, content: .bash(bash)))
        }
        if values.isEmpty { values.append(.init(id: session.scope + ":empty", content: session.streaming ? .responding : .markdown("Start a conversation"))) }
        if session.historyBefore != .null { values.insert(.init(id: session.scope + ":history", content: .history(session.historyLoading)), at: 0) }
        return values
    }
    var body: some View {
        TranscriptTable(scope: session.scope, rows: rows, expanded: expanded, tailRequest: tailRequest + jump, following: $following) {
            session.command("history", fields: ["generation": session.generation, "before": session.historyBefore, "limit": .number(200)])
        }.overlay(alignment: .bottomTrailing) {
            if !following { Button("Jump to latest", systemImage: "arrow.down") { following = true; jump += 1 }.padding(12) }
        }
    }
}

struct InlineDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                    configuration.label
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content.frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
