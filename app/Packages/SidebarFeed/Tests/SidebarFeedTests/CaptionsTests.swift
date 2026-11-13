import Testing
@testable import SidebarFeed

@Test func captionDebounceHoldsTheSecondLine() {
    func rows(_ text: String) -> [SidebarRow] {
        sidebarRows(makeSnapshot([group(0, [pane(0, cwd: "/work", lifecycle: agent(working(), msg: text), mark: .running, children: [pane(1, parent: 0)]), pane(2, window: 0)])], client: 99))
    }
    var captions = SidebarCaptions()
    #expect(captions.apply(rows("busy"), now: 0, delay: 1)[1].second == .activity("busy"))
    #expect(captions.apply(rows(""), now: 0.1, delay: 1)[1].second == .activity("busy"))
    #expect(captions.apply(rows(""), now: 1.2, delay: 1)[1].second == .none)
}

@Test func captionTransitions() {
    var captions = SidebarCaptions()
    func rows(_ text: String) -> [SidebarRow] {
        [SidebarRow(id: .pane(.init(number: 0), .init(number: 0)), kind: .program(nil, []), indent: 0,
                    title: "Title", second: .activity(text),
                    status: .running, focused: false)]
    }
    func check(_ raw: String, _ time: Double, _ shown: String) {
        let row = captions.apply(rows(raw), now: time, delay: 0.2)[0]
        #expect(row.second == .activity(shown))
    }
    check("A", 0, "A")
    check("", 1, "A")
    check("A", 1.1, "A")
    #expect(captions.deadline == nil)
    check("B", 2, "A")
    check("A", 2.1, "A")
    #expect(captions.deadline == nil)
    check("B", 3, "A")
    check("B", 3.21, "B")
    check("C", 4, "B")
    check("", 4.1, "B")
    check("", 4.29, "B")
    check("", 4.31, "")
    check("A", 5, "")
    check("", 5.1, "")
    #expect(captions.deadline == nil)
    check("A", 6, "")
    check("A", 6.21, "A")
    check("B", 7, "A")
    check("C", 7.1, "A")
    check("C", 7.29, "A")
    check("C", 7.31, "C")
    check("D", 8, "C")
    #expect(captions.apply([], now: 8.1, delay: 0.2).isEmpty)
    #expect(captions.deadline == nil)
    check("D", 8.2, "D")
    #expect(captions.apply(rows("Zero delay"), now: 8.3, delay: 0)[0].second == .activity("Zero delay"))
    #expect(captions.deadline == nil)
    captions = SidebarCaptions()
    check("E", 9, "E")
}
