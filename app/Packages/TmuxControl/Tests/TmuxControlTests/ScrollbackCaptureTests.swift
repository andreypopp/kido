import Testing
@testable import TmuxControl

@Test func scrollbackCaptureAsksForTheWholeHistoryUnderTheCap() {
    let pane = PaneID(number: 7)
    #expect(ScrollbackCapture.historyRequest(pane).line == "display-message -p -t %7 \"#{history_size}\"")
    #expect(ScrollbackCapture.capture(pane, history: 2000).line == "capture-pane -p -J -S - -t %7")
    #expect(ScrollbackCapture.capture(pane, history: 200_000).line == "capture-pane -p -J -S - -t %7")
}

@Test func scrollbackCaptureKeepsTheNewestRowsOverTheCap() {
    let pane = PaneID(number: 7)
    #expect(ScrollbackCapture.capture(pane, history: 200_001).line == "capture-pane -p -J -S -200000 -t %7")
    #expect(ScrollbackCapture.capture(pane, history: 50, limit: 10).line == "capture-pane -p -J -S -10 -t %7")
}

@Test func scrollbackCaptureReadsTheHistorySize() {
    #expect(ScrollbackCapture.historySize(.success(["1234"])) == 1234)
    #expect(ScrollbackCapture.historySize(.success(["x"])) == nil)
    #expect(ScrollbackCapture.historySize(.failure(["no pane"])) == nil)
    #expect(ScrollbackCapture.historySize(nil) == nil)
}

@Test func scrollbackCaptureTextDropsTrailingBlankRows() {
    #expect(ScrollbackCapture.text(.success(["a", "", "b", "", ""])) == "a\n\nb\n")
    #expect(ScrollbackCapture.text(.success(["", ""])) == nil)
    #expect(ScrollbackCapture.text(.failure(["x"])) == nil)
    #expect(ScrollbackCapture.text(nil) == nil)
}
