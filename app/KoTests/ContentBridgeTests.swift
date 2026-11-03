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

    private func shown(_ script: String) throws -> (owner: WindowOwner, pane: PaneView) {
        let dir = try serverWithPane(script)
        let board = NSPasteboard(name: .init("ko-bridge-" + UUID().uuidString))
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        owner.testServerDir = dir
        addTeardownBlock { @MainActor in
            owner.close()
            board.releaseGlobally()
        }
        owner.start()
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
        let (owner, pane) = try shown("printf 'before\\r\\n'; stty raw -echo; exec cat")
        wait("the restored output") { self.text(pane).contains("before") }
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
}
