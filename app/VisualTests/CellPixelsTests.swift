import AppKit
import GhosttyKit
import XCTest
@testable import Kido

extension VisualTests {
    private struct Reported: Equatable {
        let text: String
        let cell: String
        let wsXpixel: Int
        let wsYpixel: Int
    }

    private func reported(_ pane: PaneView) -> Reported? {
        let text = surfaceText(pane, in: GHOSTTY_POINT_VIEWPORT)
        guard let match = text.firstMatch(of: /PX\|(4;\d+;\d+)\|(6;\d+;\d+)\|(\d+)\|(\d+)\|/) else { return nil }
        return Reported(text: String(match.1), cell: String(match.2), wsXpixel: Int(match.3)!, wsYpixel: Int(match.4)!)
    }

    private func expected(_ pane: PaneView) -> Reported {
        let size = ghostty_surface_size(pane.surface)
        let (width, height) = (Int(size.columns) * Int(size.cell_width_px), Int(size.rows) * Int(size.cell_height_px))
        return Reported(text: "4;\(height);\(width)", cell: "6;\(size.cell_height_px);\(size.cell_width_px)", wsXpixel: width, wsYpixel: height)
    }

    func testPaneReadsCellPixels() async throws {
        let script = "/tmp/kido-cellpx-\(getpid()).py"
        try """
        import os, tty, fcntl, termios, struct, time, select
        tty.setraw(0)
        def query(code):
            os.write(1, code.encode())
            reply = b''
            end = time.time() + 1
            while not reply.endswith(b't') and time.time() < end:
                if select.select([0], [], [], 0.1)[0]:
                    reply += os.read(0, 64)
            return reply.decode().lstrip('\\x1b[').rstrip('t')
        while True:
            text, cell = query('\\x1b[14t'), query('\\x1b[16t')
            ws = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\0' * 8))
            os.write(1, ('\\x1b[H\\x1b[2KPX|%s|%s|%d|%d|' % (text, cell, ws[2], ws[3])).encode())
            time.sleep(0.05)
        """.write(toFile: script, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: script) }
        try await start(pane: "exec python3 -u " + script)
        let pane = try XCTUnwrap(terminal?.panes.first)
        try await wait("the pane reads its cell size") { self.reported(pane) == self.expected(pane) }

        let first = expected(pane)
        session.fontChanged(pane.font + 5)
        try await wait("the pane reads the new cell size") {
            let now = self.expected(pane)
            return now.cell != first.cell && self.reported(pane) == now
        }

        try await settle()
        let grid = ghostty_surface_size(pane.surface)
        let larger = expected(pane)
        let scale: CGFloat = window.backingScaleFactor == 1 ? 2 : 1
        for pane in try XCTUnwrap(terminal).panes {
            pane.visualScale = scale
            pane.viewDidChangeBackingProperties()
        }
        XCTAssertNotEqual(expected(pane).cell, larger.cell, "the scale changes the cell's pixels")
        try await wait("the pane reads the cell size of the new scale") { self.reported(pane) == self.expected(pane) }
        let scaled = ghostty_surface_size(pane.surface)
        XCTAssertEqual([scaled.columns, scaled.rows], [grid.columns, grid.rows], "the scale keeps the grid")
    }
}
