import Testing
@testable import SidebarFeed

@Test func fuzzyMatchesInOrderAndPrefersRuns() {
    #expect(fuzzyMatch("", "anything") == FuzzyMatch(score: 0, offsets: []))
    #expect(fuzzyMatch("KD", "kido") == FuzzyMatch(score: 1, offsets: [0, 2]))
    #expect(fuzzyMatch("ki", "Kido") == FuzzyMatch(score: 4, offsets: [0, 1]))
    #expect(fuzzyMatch("dk", "kido") == nil)
    #expect(fuzzyMatch("kidoo", "kido") == nil)
    #expect(fuzzyMatch("ε", "π·Ε") == FuzzyMatch(score: -1, offsets: [2]))
    let run = fuzzyMatch("split", "Split Right")!, scattered = fuzzyMatch("split", "Select Pane Left Item")!
    #expect(run.score > scattered.score)
}

@Test func fuzzyWordsMatchAnyFieldInAnyOrder() {
    let fields = ["Terminal", "main"]
    for query in ["main term", "term main", "main > term", "main›term", "  term  "] {
        #expect(fuzzyMatch(query, fields: fields) != nil, "\(query)")
    }
    #expect(fuzzyMatch("main term", fields: fields)?.offsets == [[0, 1, 2, 3], [0, 1, 2, 3]])
    #expect(fuzzyMatch("mainterm", fields: fields) == nil, "one word must match within one field")
    #expect(fuzzyMatch("main zz", fields: fields) == nil)
    #expect(fuzzyMatch("", fields: fields)?.score == 0)
    let title = fuzzyMatch("main", fields: ["main", "x"])!, detail = fuzzyMatch("main", fields: ["x", "main"])!
    #expect(title.score == detail.score + 1, "a title match wins a tie with the same detail match")
}
