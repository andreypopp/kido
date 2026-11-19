import XCTest
import KoModel
@testable import Kido

final class PromptTargetTests: XCTestCase {
    @MainActor func testChoiceUsesTheLongestRecordBoundaryPrefix() {
        let pane = PaneID(number: 3)
        let session = SessionID(number: 1)
        let window = WindowID(number: 1)
        let root = KoSchema.Candidate(session: session, target: .init(pane: pane, record: ""), title: "root", window: window)
        let child = KoSchema.Candidate(session: session, target: .init(pane: pane, record: "agents/a"), title: "a", window: window)
        let nested = KoSchema.Candidate(session: session, target: .init(pane: pane, record: "agents/a/agents/b"), title: "b", window: window)
        let list = [root, child, nested]
        for (record, expected) in [("", root), ("agents/a", child), ("agents/a/jobs/j1", child), ("agents/a/agents/b/jobs/j2", nested), ("agents/ab/jobs/j1", root)] {
            XCTAssertEqual(PalettePrompt.choice(list, preselect: .init(pane: pane, record: record), pane: pane, window: window), expected)
        }
        XCTAssertEqual(PalettePrompt.choice([child, root], preselect: .init(pane: PaneID(number: 9), record: "agents/a"), pane: pane, window: window), child)
        XCTAssertNil(PalettePrompt.choice([], preselect: nil, pane: pane, window: window))
    }
}
