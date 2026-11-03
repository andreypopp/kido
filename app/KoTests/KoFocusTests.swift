import KoClient
import KoModel
import XCTest
@testable import Kido

// The focus of each window comes from the server through the core's model: a focus
// event or a layout event, never a revision of its own.
@MainActor final class KoFocusTests: KoTestCase {
    struct Seen: Equatable {
        var revision: Int
        var focus: [PaneID]
    }

    // Every layout event with the revision and the focus of every window that the model
    // held at that moment.
    @MainActor final class Layouts {
        var connection: KoClient?
        var seen: [Seen] = []
        var selected = false

        func record() {
            guard let connection, let model = try? connection.model() else { return }
            seen.append(Seen(revision: model.layout.revision, focus: model.layout.layout.windows.map(\.focus)))
        }
    }

    private func connectRecording(_ dir: String, panes: Int, sizes: Bool, _ layouts: Layouts) throws -> KoClient {
        let connection = try connect(dir, hello: KoHello(cols: 100, rows: 30, sizesWindows: sizes), panes: panes) { event in
            if case .layout = event { layouts.record() }
            if case .selected = event { layouts.selected = true }
        }
        layouts.connection = connection
        layouts.record()
        return connection
    }

    // The events of a client arrive in the server's order, and the server answers each select with a
    // selected event: that event of a select that changes nothing follows every earlier event.
    private func barrier(_ connection: KoClient, _ layouts: Layouts) throws {
        layouts.selected = false
        try connection.select(KO_SELECT_PANE, try XCTUnwrap(connection.model().selection.pane))
        wait("the selected event of the barrier") { layouts.selected }
    }

    func testAFocusEventMovesTheFocusInTheModelAndKeepsTheRevision() throws {
        let dir = try serverWithWindows([2])
        let layouts = Layouts()
        let connection = try connectRecording(dir, panes: 2, sizes: false, layouts)
        try connection.focus(true)
        let before = try XCTUnwrap(layouts.seen.last)
        XCTAssertEqual(before.focus, [PaneID(number: 1)])
        layouts.seen = []

        try connection.select(KO_SELECT_PANE, PaneID(number: 2))
        wait("the focus of pane_2") { layouts.seen.last?.focus == [PaneID(number: 2)] }
        try barrier(connection, layouts)
        XCTAssertEqual(layouts.seen, [Seen(revision: before.revision, focus: [PaneID(number: 2)])], "one event, and the revision stayed")
    }

    func testASelectThatResizesTheWindowCarriesTheNewFocusInTheOneLayoutEvent() throws {
        let dir = try serverWithWindows([1, 2])
        let layouts = Layouts()
        let connection = try connectRecording(dir, panes: 3, sizes: true, layouts)
        try connection.focus(true)
        let before = try XCTUnwrap(layouts.seen.last)
        XCTAssertEqual(before.focus, [PaneID(number: 1), PaneID(number: 2)])
        layouts.seen = []

        try connection.select(KO_SELECT_PANE, PaneID(number: 3))
        wait("the layout event with the new focus") { layouts.seen.last?.focus == [PaneID(number: 1), PaneID(number: 3)] }
        try barrier(connection, layouts)
        XCTAssertEqual(layouts.seen.count, 1, "no focus event beside the layout event: \(layouts.seen)")
        XCTAssertGreaterThan(try XCTUnwrap(layouts.seen.first).revision, before.revision, "the resize is a new revision")
    }

    func testAFocusedPaneThatLeavesItsWindowMovesTheFocusInThatChangesLayoutEvent() throws {
        let dir = try serverWithWindows([2])
        let layouts = Layouts()
        let connection = try connectRecording(dir, panes: 2, sizes: false, layouts)
        try connection.focus(true)
        try connection.select(KO_SELECT_PANE, PaneID(number: 2))
        wait("the focus of pane_2") { layouts.seen.last?.focus == [PaneID(number: 2)] }
        let before = try XCTUnwrap(layouts.seen.last)
        layouts.seen = []

        try run(["api", "-X", "DELETE", "/panes/pane_2"], dir: dir)
        wait("the layout without pane_2") { layouts.seen.last?.focus == [PaneID(number: 1)] }
        try barrier(connection, layouts)
        XCTAssertEqual(layouts.seen.count, 1, "one event for the removal, with the moved focus: \(layouts.seen)")
        XCTAssertGreaterThan(try XCTUnwrap(layouts.seen.first).revision, before.revision)
    }
}
