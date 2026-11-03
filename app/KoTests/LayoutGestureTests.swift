import AppKit
import KoClient
import KoModel
import PaneGeometry
import XCTest
@testable import Kido

// Every gesture of the layout is one edit through the owner's LayoutEditor, against a private server.
@MainActor final class LayoutGestureTests: KoTestCase {
    private func owner(_ dir: String) throws -> WindowOwner {
        let board = NSPasteboard(name: .init("ko-gesture-" + UUID().uuidString))
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        owner.testServerDir = dir
        addTeardownBlock { @MainActor in
            owner.close()
            board.releaseGlobally()
        }
        owner.start()
        return owner
    }

    private let sleep = #"{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}"#

    // An owner on a server with the given session list, shown.
    private func shown(_ sessions: String) throws -> (WindowOwner, KoClient) {
        let dir = try server()
        try put(#"{"revision":0,"layout":{"sessions":\#(sessions)}}"#, dir: dir)
        let owner = try owner(dir)
        wait("the owner shows the layout at its own size") {
            owner.testBanner.isHidden && owner.testSession?.windows.values.contains { !$0.isHidden && $0.visualGeometryReady } == true
        }
        return (owner, try XCTUnwrap(owner.testClient))
    }

    private func windows(_ client: KoClient) -> [KoSchema.Window] {
        (try? client.model()).map(\.layout.layout.windows) ?? []
    }

    private func panes(_ client: KoClient) -> [Pane] {
        windows(client).flatMap { Layout($0).root.panes }
    }

    func testPaneCommandsSplitZoomEqualizeAndSelect() throws {
        let (owner, client) = try shown(#"[{"name":"s","windows":[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep)]}}]}]"#)
        let session = try XCTUnwrap(owner.testSession)
        let first = PaneID(number: 1), second = PaneID(number: 2)

        session.paneCommand(.split(.down), first)
        wait("a third pane below the first") {
            let panes = self.panes(client)
            guard panes.count == 3, let top = panes.first(where: { $0.id == first }), let new = panes.first(where: { $0.id.number == 3 }) else { return false }
            return new.geometry.x == top.geometry.x && new.geometry.y > top.geometry.y
        }
        wait("the split selects its new pane") { (try? client.model())?.selection.pane == PaneID(number: 3) }

        owner.window.makeFirstResponder(session.pane(first))
        session.paneCommand(.zoom, second)
        wait("the owner shows the zoom") { owner.testModel.map(\.layout.layout.windows)?.first?.zoom == PaneID(number: 2) }
        wait("the zoom selects its pane") { (try? client.model())?.selection.pane == PaneID(number: 2) }
        wait("the focus follows the zoomed pane") { owner.window.firstResponder === session.pane(second) }
        session.paneCommand(.zoom, second)
        wait("the owner shows the zoom ended") { owner.testModel.map(\.layout.layout.windows)?.first.map { $0.zoom == nil } == true }
        let revision = try client.model().layout.revision
        session.paneCommand(.zoom, second)
        session.paneCommand(.zoom, second)
        wait("two presses inside one round trip zoom and unzoom") { (try? client.model())?.layout.revision == revision + 2 }
        XCTAssertNil(windows(client).first?.zoom)

        session.selectPane(first)
        wait("the first pane") { (try? client.model())?.selection.pane == PaneID(number: 1) }
        session.paneCommand(.select(.right), first)
        wait("the pane on the right") { (try? client.model())?.selection.pane == PaneID(number: 2) }
        session.paneCommand(.next, second)
        wait("the next pane wraps") { (try? client.model())?.selection.pane == PaneID(number: 1) }

        let wide = try XCTUnwrap(panes(client).first { $0.id == first }).geometry.width
        let step = 3 * (session.cell?.width ?? 1)
        session.paneCommand(.resize(.right, points: step), first)
        session.paneCommand(.resize(.right, points: step), first)
        wait("two presses inside one round trip are two steps") { self.panes(client).first { $0.id == first }?.geometry.width == wide + 6 }
        session.paneCommand(.resize(.right, points: step), second)
        wait("the last pane of a split moves its divider toward the edge") { self.panes(client).first { $0.id == first }?.geometry.width == wide + 9 }
        session.paneCommand(.zoom, first)
        wait("the zoom") { self.windows(client).first?.zoom == PaneID(number: 1) }
        session.paneCommand(.resize(.left, points: step), first)
        wait("a resize while zoomed unzooms and resizes the tiled panes") {
            self.windows(client).first?.zoom == nil && self.panes(client).first { $0.id == first }?.geometry.width == wide + 6
        }
        session.paneCommand(.equalize, second)
        wait("the split is even again") {
            let widths = self.panes(client).filter { $0.id != PaneID(number: 3) }.map(\.geometry.width)
            return widths.count == 2 && abs(widths[0] - widths[1]) <= 1
        }
    }

    func testADividerDragSendsOnlyItsLatestStepAndSettles() throws {
        let (owner, client) = try shown(#"[{"name":"s","windows":[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep),\#(sleep)]}}]}]"#)
        let session = try XCTUnwrap(owner.testSession)
        let window = try XCTUnwrap(windows(client).first)
        let divider = try XCTUnwrap(Layout(window).root.dividers.first)
        let third = try XCTUnwrap(Layout(window).root.panes.last).geometry.width
        for position in 5...12 { session.edit(try XCTUnwrap(divider.resize(to: position)), .divider(PaneID(number: 1))) }
        XCTAssertTrue(session.editing())
        wait("the first pane has the last step's width") { self.panes(client).first?.geometry.width == 12 }
        wait("the edits settled") { !session.editing() }
        XCTAssertEqual(panes(client).last?.geometry.width, third, "the drag moves one divider only")
    }

    func testAFloatMovesAndRaisesThroughEdits() throws {
        let new = String(sleep.dropFirst(8).dropLast())
        let floats = #"[{"pane":\#(new),"x":2,"y":2,"cols":20,"rows":6},{"pane":\#(new),"x":10,"y":4,"cols":20,"rows":6}]"#
        let (owner, client) = try shown(#"[{"name":"s","windows":[{"name":"w","tree":\#(sleep),"floats":\#(floats)}]}]"#)
        let session = try XCTUnwrap(owner.testSession)
        session.edit(.float(KoSchema.EditFloat(pane: PaneID(number: 2), x: 7, y: 3)), .float(PaneID(number: 2)))
        wait("the float moved") { self.windows(client).first?.floats.first { $0.pane == PaneID(number: 2) }.map { [$0.x, $0.y] } == [7, 3] }
        let pane = try XCTUnwrap(session.pane(PaneID(number: 2)))
        pane.onSelect()
        wait("the selected float is on top") { self.windows(client).first?.floats.last?.pane == PaneID(number: 2) }
        wait("the float is selected") { (try? client.model())?.selection.pane == PaneID(number: 2) }
    }

    func testADroppedPaneSwapsOrDocks() throws {
        let (owner, client) = try shown(#"[{"name":"s","windows":[{"name":"w","tree":{"split":"h","children":[\#(sleep),\#(sleep),\#(sleep)]}}]}]"#)
        let session = try XCTUnwrap(owner.testSession)
        session.edit(.swap(KoSchema.EditSwap(other: PaneID(number: 3), pane: PaneID(number: 1))), nil)
        wait("swapped") { self.panes(client).map(\.id.number) == [3, 2, 1] }
        session.edit(.dock(KoSchema.EditDock(edge: .bottom, pane: PaneID(number: 1), target: PaneID(number: 3))), nil)
        wait("docked below the third") {
            let panes = self.panes(client)
            guard let one = panes.first(where: { $0.id.number == 1 }), let three = panes.first(where: { $0.id.number == 3 }) else { return false }
            return panes.count == 3 && one.geometry.x == three.geometry.x && one.geometry.y > three.geometry.y
        }
    }

    func testANewWindowAndANewSessionAreSelected() throws {
        let (owner, client) = try shown(#"[{"name":"s","windows":[{"name":"w","tree":\#(sleep)}]}]"#)
        owner.newWindow()
        wait("the new window is selected") { owner.navigation.windows.count == 2 && owner.navigation.window == owner.navigation.windows.last?.id }
        var result: String?? = .none
        owner.createSession("other") { result = .some($0) }
        wait("the new session is selected") { owner.navigation.session.flatMap { id in owner.navigation.sessions.first { $0.id == id }?.name } == "other" }
        wait("the result") { result != nil }
        XCTAssertEqual(result, .some(nil))
        owner.renameSession(try XCTUnwrap(owner.navigation.session), "renamed") { _ in }
        wait("renamed") { (try? client.model())?.layout.layout.sessions.last?.name == "renamed" }
    }

    func testAReorderHoldsItsOrderUntilTheLayoutShowsIt() throws {
        let (owner, client) = try shown(#"[{"name":"a","windows":[{"name":"w","tree":\#(sleep)}]},{"name":"b","windows":[{"name":"w","tree":\#(sleep)}]}]"#)
        owner.sidebar.list.move(.session(SessionID(number: 2), relativeTo: SessionID(number: 1), .before))
        XCTAssertNotNil(owner.reorder.state.pending, "the drop shows its order at once")
        wait("the server's order") { (try? client.model())?.layout.layout.sessions.map(\.name) == ["b", "a"] }
        wait("the order settled") { owner.reorder.state.pending == nil }
        XCTAssertEqual(owner.snapshot?.sessions.map(\.name), ["b", "a"])
    }
}
