import Testing
@testable import PiSurface

@Test func activityKeepsProseBoundariesAndIdentities() {
    let rows: [DisplayRow] = [
        .init(id: "thinking", content: .thinking("Check anchor", false)),
        .init(id: "call", content: .tool(.null, .null, .null)),
        .init(id: "prose", content: .markdown("Keep this position")),
        .init(id: "next", content: .tool(.null, .null, .null))
    ]
    let grouped = groupedActivity(rows)
    #expect(grouped.map(\.id) == ["thinking", "prose", "next"])
    #expect(grouped[0].content == .activity(Array(rows.prefix(2))))
    #expect(grouped[1] == rows[2])
    var changed = rows
    changed[1].content = .tool(.null, .null, .object(["ended": .bool(true)]))
    #expect(groupedActivity(changed)[0].id == grouped[0].id)
    #expect(groupedActivity(changed)[0] != grouped[0])
}
