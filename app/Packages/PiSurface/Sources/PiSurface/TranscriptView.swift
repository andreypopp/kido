import SwiftUI

struct TranscriptView: View {
    @Bindable var session: Session
    var expanded: Bool
    var tailRequest: Int
    @State private var following = true
    @State private var jump = 0
    var body: some View {
        let history: [DisplayRow] = session.historyBefore == .null ? [] : [.init(id: session.scope + ":history", content: .history(session.historyLoading))]
        let rows = groupedActivity(history + session.displayRows + session.transcriptRows.tail)
        let changed = Set(rows.filter { row in
            if case .activity(let items) = row.content { return items.contains { session.transcriptRows.changed.contains($0.id) } }
            return session.transcriptRows.changed.contains(row.id)
        }.map(\.id))
        TranscriptTable(scope: session.scope, rows: rows, revision: session.visualRevision, structure: session.transcriptRows.structure, changed: changed, applied: { _ in session.transcriptRows.changed.removeAll() }, expanded: expanded, tailRequest: tailRequest + jump, following: $following) {
            session.command("history", fields: ["generation": session.generation, "before": session.historyBefore, "limit": .number(200)])
        }.overlay(alignment: .bottom) {
            if !following { Button("to recent messages") { following = true; jump += 1 }.font(.caption).buttonStyle(.bordered).buttonBorderShape(.capsule).padding(.bottom, 12) }
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
