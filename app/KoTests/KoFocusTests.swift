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
        var selected: PaneID?

        func record() {
            guard let connection, let model = try? connection.model() else { return }
            seen.append(Seen(revision: model.layout.revision, focus: model.layout.layout.windows.map(\.focus)))
        }
    }

    private func connectRecording(_ dir: String, panes: Int, sizes: Bool, _ layouts: Layouts) throws -> KoClient {
        let connection = try connect(dir, hello: KoHello(viewport: sizes ? KoSize(cols: 100, rows: 30, cell: nil) : nil), panes: panes) { event in
            if case .layout = event { layouts.record() }
            if case .selected(_, _, _, let pane) = event { layouts.selected = pane }
        }
        layouts.connection = connection
        layouts.record()
        return connection
    }

    // The events of a client arrive in the server's order, and the server answers each select with a
    // selected event: that event of a select that changes nothing follows every earlier event.
    private func barrier(_ connection: KoClient, _ layouts: Layouts) throws {
        let pane = try XCTUnwrap(connection.model().selection.pane)
        layouts.selected = nil
        try connection.select(KO_SELECT_PANE, pane)
        wait("the selected event of the barrier") { layouts.selected == pane }
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
        try connection.select(KO_SELECT_PANE, PaneID(number: 1))
        wait("the initial selected pane") { layouts.selected == PaneID(number: 1) }
        let size = KoSize(cols: 100, rows: 30, cell: nil)
        let report = [KoWindowSize(window: WindowID(number: 2), size: size)]
        try connection.size(viewport: size, windows: report)
        try connection.focus(true)
        wait("the reported window is sized") { (try? connection.model().layout.layout.window(WindowID(number: 2))?.cols) == 100 }
        let small = KoSize(cols: 80, rows: 24, cell: nil)
        let peer = try connect(dir, hello: KoHello(focused: true, viewport: small), panes: 3) { _ in }
        try peer.size(viewport: small, windows: [KoWindowSize(window: WindowID(number: 2), size: small)])
        wait("the peer owns the reported window") { (try? connection.model().layout.layout.window(WindowID(number: 2))?.cols) == 80 }
        try connection.size(viewport: size, windows: report)
        try barrier(connection, layouts)
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
