import KoClient
import XCTest

// The focus of each window comes from the server through the core's model: a focus
// event or a layout event, never a revision of its own.
@MainActor final class KoFocusTests: KoTestCase {
    struct Seen: Equatable {
        var revision: Int
        var focus: [String]
    }

    // Every layout event with the revision and the focus of every window that the model
    // held at that moment.
    @MainActor final class Layouts {
        var connection: KoConnection?
        var seen: [Seen] = []

        func record() {
            guard let connection, let model = try? connection.model(),
                  let revision = (model["layout"] as? [String: Any])?["revision"] as? Int else { return }
            seen.append(Seen(revision: revision, focus: KoTestCase.windows(model).map { $0["focus"] as? String ?? "" }))
        }
    }

    private func connectRecording(_ dir: String, panes: Int, sizes: Bool, _ layouts: Layouts) throws -> KoConnection {
        let connection = try connect(dir, hello: ko_hello(cols: 100, rows: 30, focused: false, sizes_windows: sizes), panes: panes) { event in
            if case .layout = event { layouts.record() }
        }
        layouts.connection = connection
        layouts.record()
        return connection
    }

    private func quiet() {
        mainQueueDrained()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        mainQueueDrained()
    }

    func testAFocusEventMovesTheFocusInTheModelAndKeepsTheRevision() throws {
        let dir = try serverWithWindows([2])
        let layouts = Layouts()
        let connection = try connectRecording(dir, panes: 2, sizes: false, layouts)
        try connection.focus(true)
        let before = try XCTUnwrap(layouts.seen.last)
        XCTAssertEqual(before.focus, ["pane_1"])
        layouts.seen = []

        try connection.select(KO_SELECT_PANE, "pane_2")
        wait("the focus of pane_2") { layouts.seen.last?.focus == ["pane_2"] }
        quiet()
        XCTAssertEqual(layouts.seen, [Seen(revision: before.revision, focus: ["pane_2"])], "one event, and the revision stayed")
    }

    func testASelectThatResizesTheWindowCarriesTheNewFocusInTheOneLayoutEvent() throws {
        let dir = try serverWithWindows([1, 2])
        let layouts = Layouts()
        let connection = try connectRecording(dir, panes: 3, sizes: true, layouts)
        try connection.focus(true)
        quiet()
        let before = try XCTUnwrap(layouts.seen.last)
        XCTAssertEqual(before.focus, ["pane_1", "pane_2"])
        layouts.seen = []

        try connection.select(KO_SELECT_PANE, "pane_3")
        wait("the layout event with the new focus") { layouts.seen.last?.focus == ["pane_1", "pane_3"] }
        quiet()
        XCTAssertEqual(layouts.seen.count, 1, "no focus event beside the layout event: \(layouts.seen)")
        XCTAssertGreaterThan(try XCTUnwrap(layouts.seen.first).revision, before.revision, "the resize is a new revision")
    }

    func testAFocusedPaneThatLeavesItsWindowMovesTheFocusInThatChangesLayoutEvent() throws {
        let dir = try serverWithWindows([2])
        let layouts = Layouts()
        let connection = try connectRecording(dir, panes: 2, sizes: false, layouts)
        try connection.focus(true)
        try connection.select(KO_SELECT_PANE, "pane_2")
        wait("the focus of pane_2") { layouts.seen.last?.focus == ["pane_2"] }
        let before = try XCTUnwrap(layouts.seen.last)
        layouts.seen = []

        try run(["api", "-X", "DELETE", "/panes/pane_2"], dir: dir)
        wait("the layout without pane_2") { layouts.seen.last?.focus == ["pane_1"] }
        quiet()
        XCTAssertEqual(layouts.seen.count, 1, "one event for the removal, with the moved focus: \(layouts.seen)")
        XCTAssertGreaterThan(try XCTUnwrap(layouts.seen.first).revision, before.revision)
    }
}
