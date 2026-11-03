import AppKit
import GhosttyKit
import KoClient
import KoModel
import TmuxControl
import XCTest
@testable import Kido

// The panes of an owner show the server's panes: their views restore, feed, take input and resize.
@MainActor final class ContentBridgeTests: KoTestCase {
    private func text(_ pane: PaneView) -> String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                                            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0), rectangle: false)
        guard ghostty_surface_read_text(pane.surface, selection, &text), let bytes = text.text else { return "" }
        defer { ghostty_surface_free_text(pane.surface, &text) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    // A Ghostty runtime on a private pasteboard, released with the test.
    private func runtime() throws -> GhosttyRuntime {
        let board = NSPasteboard(name: .init("ko-bridge-" + UUID().uuidString))
        addTeardownBlock { @MainActor in board.releaseGlobally() }
        return try XCTUnwrap(GhosttyRuntime(pasteboard: board))
    }

    // An owner that shows the server in `dir`, started and closed with the test.
    private func owner(dir: String) throws -> WindowOwner {
        let owner = WindowOwner(host: .local, runtime: try runtime(), start: false)
        owner.testServerDir = dir
        addTeardownBlock { @MainActor in owner.close() }
        owner.start()
        return owner
    }

    private func shown(_ script: String) throws -> (owner: WindowOwner, pane: PaneView) {
        let owner = try owner(dir: try serverWithPane(script))
        wait("the pane") { owner.testSession?.pane(PaneID(number: 1)) != nil }
        let pane = try XCTUnwrap(owner.testSession?.pane(PaneID(number: 1)))
        wait("the first restore at the window's own size") {
            pane.koView != nil && pane.visualReady && owner.testSession?.windows.values.contains { !$0.isHidden && $0.visualGeometryReady } == true
        }
        return (owner, pane)
    }

    func testAPaneShowsTheServersOutputAndSendsItsInput() throws {
        let (_, pane) = try shown("printf 'hello from ko\\r\\n'; stty raw -echo; exec cat")
        wait("the restored output") { self.text(pane).contains("hello from ko") }
        try XCTUnwrap(pane.koView).text(Data("typed back".utf8))
        wait("the input echoes through the server") { self.text(pane).contains("typed back") }
    }

    func testTheServerSizesTheGridAndTheFrameFollowsIt() throws {
        let (owner, pane) = try shown("stty raw -echo; exec cat")
        let grid = { () -> (Int, Int) in let size = ghostty_surface_size(pane.surface); return (Int(size.columns), Int(size.rows)) }
        let leaf = { () -> (Int, Int)? in
            guard let window = owner.testModel.map(\.layout.layout.windows)?.first, case .leaf(let leaf) = window.tree else { return nil }
            return (leaf.cols, leaf.rows)
        }
        wait("the grid has the leaf's size") { leaf().map { $0 == grid() } == true }
        let before = grid()
        // In MANUAL_MIRROR a pixel size change must leave the grid to the view's decoder.
        pane.setFrameSize(NSSize(width: pane.frame.width / 2, height: pane.frame.height / 2))
        pane.layoutSubtreeIfNeeded()
        mainQueueDrained()
        XCTAssertTrue(grid() == before, "a smaller frame keeps the grid")
        owner.window.setContentSize(NSSize(width: owner.window.frame.width + 200, height: owner.window.frame.height))
        owner.window.contentView?.layoutSubtreeIfNeeded()
        wait("the server took the wider window") { (leaf()?.0 ?? 0) > before.0 }
        wait("the view's resize set the grid") { leaf().map { $0 == grid() } == true }
    }

    func testCopyModeHoldsTheScreenAndCatchesUpWhenItEnds() throws {
        let (owner, pane) = try shown("printf 'before\\r\\n'; stty raw -echo; printf 'ready\\r\\n'; exec cat")
        wait("the shell is raw and echoes nothing") { self.text(pane).contains("ready") }
        owner.window.makeFirstResponder(pane)
        pane.toggleCopyMode(nil)
        wait("copy mode") { if case .cursor = pane.copyMode { true } else { false } }
        try XCTUnwrap(pane.koView).text(Data("while frozen".utf8))
        wait("the echo reaches the frozen pane") { pane.visualDroppedWhileFrozen }
        XCTAssertFalse(text(pane).contains("while frozen"), "copy mode holds the screen")
        pane.endCopy()
        XCTAssertTrue(pane.restoring, "the end of copy mode asks for a new snapshot")
        wait("the new snapshot shows what arrived") { !pane.restoring && self.text(pane).contains("while frozen") }
    }

    func testAViewOpenedOnASurfaceOfAnotherSizeRestoresOnceAtTheServersGrid() throws {
        let dir = try serverWithPane("stty raw -echo; exec cat")
        let recorder = Recorder()
        let connection = try connect(dir, recorder)
        let pane = try XCTUnwrap(PaneView(runtime: try runtime(), pane: PaneID(number: 1), font: 0))
        addTeardownBlock { @MainActor in pane.dispose() }
        let window = try XCTUnwrap(try connection.model().layout.layout.windows.first)
        guard case .leaf(let leaf) = window.tree else { throw XCTSkip("not a single pane window") }
        let before = ghostty_surface_size(pane.surface)
        XCTAssertTrue(Int(before.columns) != leaf.cols || Int(before.rows) != leaf.rows, "the surface starts at another size than the server's pane")
        pane.attach(connection)
        wait("the restore") { pane.koView != nil && pane.visualReady }
        let grid = ghostty_surface_size(pane.surface)
        XCTAssertEqual(Int(grid.columns), leaf.cols)
        XCTAssertEqual(Int(grid.rows), leaf.rows)
        XCTAssertEqual(pane.visualRestores, 1, "no second snapshot for the size")
    }

    func testTheTerminalIsDrawnAtTheGridsSizeFromTheTopLeftWhileTheFrameIsLarger() throws {
        let (_, pane) = try shown("stty raw -echo; exec cat")
        let size = ghostty_surface_size(pane.surface)
        let cell = pane.cell
        pane.setFrameSize(NSSize(width: pane.frame.width + 100, height: pane.frame.height + 60))
        pane.layoutSubtreeIfNeeded()
        let frame = pane.visualTerminalFrame
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.maxY, pane.bounds.height, "anchored at the top")
        XCTAssertEqual(frame.width, CGFloat(size.columns) * cell.width, accuracy: 1)
        XCTAssertLessThan(frame.width, pane.bounds.width - 50, "the paper fills the rest")
        XCTAssertLessThan(frame.height, pane.bounds.height - 30)
    }

    func testTheScrollersHistoryIsGhosttysAfterOutputAndAfterAResync() throws {
        let (_, pane) = try shown("seq 1 1000; stty raw -echo; exec cat")
        let history = { pane.scrollPosition().retainedHistoryRows }
        wait("the scroller has the history that Ghostty holds") { history() > 900 && pane.visualScrollerRows == history() }
        XCTAssertGreaterThan(pane.visualScrollerRows, 0)
        let restores = pane.visualRestores
        try XCTUnwrap(pane.koView).resync()
        wait("the second snapshot") { pane.visualRestores == restores + 1 && !pane.restoring }
        wait("the scroller has the history again") { history() > 900 && pane.visualScrollerRows == history() }
    }

    func testSwitchingThroughThreeWindowsOfTwelvePanesKeepsAtMostThirtyTwoHotSurfacesAndAnEvictedWindowShowsTheScreenAgain() throws {
        let dir = try serverWithWindows([12, 12, 12], argv: ["/bin/sh", "-c", #"printf "I am $KO_PANE"; exec sleep 60"#])
        let owner = try owner(dir: dir)
        wait("the first window") { owner.testSession?.windows.values.contains { !$0.isHidden && $0.panes.count == 12 } == true }
        let windows = try XCTUnwrap(owner.testModel).layout.layout.windows.map(\.id)
        XCTAssertEqual(windows.count, 3)
        for id in windows.dropFirst() {
            owner.perform(.selectWindow(SessionID(number: 1), id))
            wait("window \(id)") { owner.testSession?.windows[id].map { !$0.isHidden && $0.panes.count == 12 } == true }
        }
        wait("the oldest window is evicted") { owner.testSession?.windows[windows[0]]?.hot == false }
        XCTAssertEqual(owner.testSession?.visualHotSurfaces, 24)
        XCTAssertEqual(owner.testSession?.windows[windows[2]]?.hot, true, "the shown window stays")
        owner.perform(.selectWindow(SessionID(number: 1), windows[0]))
        wait("the evicted window's first pane shows the server's screen") {
            owner.testSession?.pane(PaneID(number: 1)).map { self.text($0).contains("I am pane_1") } == true
        }
        wait("the surplus window is evicted again") { (owner.testSession?.visualHotSurfaces ?? 99) <= 32 }
        XCTAssertEqual(owner.testSession?.windows[windows[0]]?.hot, true, "the shown window stays")
    }
}
