import CoreGraphics
import Foundation
import Testing
@testable import TmuxControl

@Test(arguments: [CGFloat(1), CGFloat(0.5)])
func floatingGeometry(pixel: CGFloat) {
    let cell = CGSize(width: 8, height: 17)
    let g = Geometry(x: 10, y: 8, width: 20, height: 10)
    let root = Node.pane(Pane(id: PaneID(number: 0), index: 0,
        geometry: Geometry(x: 0, y: 0, width: 100, height: 40), focus: .active, layer: .tiled))
    let layout = PaneLayout(root: root, bounds: CGRect(x: 0, y: 0, width: 824, height: 750), cell: cell, pixel: pixel, spacing: 8)
    let initial = layout.frame(g)
    let moved = initial.offsetBy(dx: 13.3, dy: 3.1)
    #expect(layout.clamp(moved) == moved)
    #expect(abs(moved.minX - initial.minX - 13.3) < 0.0001)
    #expect(layout.geometry(initial) == g)
    let bordered = Geometry(x: g.x + 1, y: g.y + 1, width: g.width - 2, height: g.height - 2)
    let borderFrame = layout.frame(bordered)
    #expect(layout.geometry(borderFrame) == bordered)
    #expect(borderFrame.minX == initial.minX + cell.width)
    #expect(borderFrame.minY == initial.minY + cell.height)
    #expect(borderFrame.width == initial.width - 2 * cell.width)
    #expect(borderFrame.height == initial.height - 2 * cell.height)
    for delta in [CGFloat(3.99), 4, 4.01] {
        let moved = initial.offsetBy(dx: delta, dy: 0)
        #expect(layout.geometry(moved).x == g.x + (delta < 4 ? 0 : 1))
        var sized = initial
        sized.size.width += delta
        #expect(layout.geometry(sized).width == g.width + (delta < 4 ? 0 : 1))
    }
    for delta in [CGFloat(8.49), 8.5, 8.51] {
        #expect(layout.geometry(initial.offsetBy(dx: 0, dy: delta)).y == g.y + (delta < 8.5 ? 0 : 1))
        var sized = initial
        sized.size.height += delta
        #expect(layout.geometry(sized).height == g.height + (delta < 8.5 ? 0 : 1))
    }
    let minimum = layout.frame(Geometry(x: 0, y: 0, width: 2, height: 2))
    #expect(layout.geometry(minimum).width == 2 && layout.geometry(minimum).height == 2)
    #expect(minimum.width == 2 * cell.width + layout.before.width + layout.after.width)
    #expect(minimum.height == 2 * cell.height + layout.before.height + layout.after.height)
    #expect(layout.geometry(CGRect(x: initial.minX, y: initial.minY, width: 1, height: 1)).width == 2)
    #expect(layout.geometry(CGRect(x: initial.minX, y: initial.minY, width: 1, height: 1)).height == 2)
    var right = initial
    right.size.width = 2000
    let clampedRight = layout.clamp(right, resizing: .right)
    #expect(clampedRight.minX == initial.minX)
    #expect(clampedRight.maxX == layout.floatingBounds.maxX)
    var bottom = initial
    bottom.size.height = 2000
    let clampedBottom = layout.clamp(bottom, resizing: .bottom)
    #expect(clampedBottom.minY == initial.minY)
    #expect(clampedBottom.maxY == layout.floatingBounds.maxY)
    let left = CGRect(x: -1000, y: initial.minY, width: initial.maxX + 1000, height: initial.height)
    let top = CGRect(x: initial.minX, y: -1000, width: initial.width, height: initial.maxY + 1000)
    #expect(layout.clamp(left, resizing: .left).maxX == initial.maxX)
    #expect(layout.clamp(left, resizing: .left).minX == layout.floatingBounds.minX)
    #expect(layout.clamp(top, resizing: .top).maxY == initial.maxY)
    #expect(layout.clamp(top, resizing: .top).minY == layout.floatingBounds.minY)
    #expect(layout.floatingBounds.contains(layout.clamp(initial.offsetBy(dx: 2000, dy: 2000))))
    #expect(initial.minX == layout.origin.x + 10 * cell.width - layout.before.width)
    #expect(initial.minY == layout.origin.y + 8 * cell.height - layout.before.height)
}

@Test(arguments: [CGFloat(1), CGFloat(0.5)], [CGFloat(2), 8, 12])
func spacedCards(pixel: CGFloat, spacing: CGFloat) {
    let cell = CGSize(width: 8, height: 17)
    let bounds = CGRect(x: 0, y: 52, width: 900, height: 648)
    func pane(_ id: UInt32, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Node {
        .pane(Pane(id: PaneID(number: id), index: Int(id), geometry: Geometry(x: x, y: y, width: width, height: height), focus: .unvisited, layer: .tiled))
    }
    func tree(_ cols: Int, _ rows: Int, shift: Int = 0) -> Node {
        let left = cols / 2 + shift, top = rows / 2, inner = (cols - left - 1) / 2
        return .split(.leftRight, Geometry(x: 0, y: 0, width: cols, height: rows), [
            .split(.topBottom, Geometry(x: 0, y: 0, width: left, height: rows), [
                pane(0, 0, 0, left, top), pane(1, 0, top + 1, left, rows - top - 1),
            ]),
            .split(.topBottom, Geometry(x: left + 1, y: 0, width: cols - left - 1, height: rows), [
                .split(.leftRight, Geometry(x: left + 1, y: 0, width: cols - left - 1, height: top), [
                    pane(2, left + 1, 0, inner, top), pane(3, left + inner + 2, 0, cols - left - inner - 2, top),
                ]),
                pane(4, left + 1, top + 1, cols - left - 1, rows - top - 1),
            ]),
        ])
    }
    let probe = tree(80, 30)
    let client = PaneLayout(root: probe, bounds: bounds, cell: cell, pixel: pixel, spacing: spacing).client
    let root = tree(Int(client.width), Int(client.height))
    let layout = PaneLayout(root: root, bounds: bounds, cell: cell, pixel: pixel, spacing: spacing)
    #expect(layout.client == client)
    let cards = root.panes.map { layout.tiled($0.geometry) }
    let resized = PaneLayout(root: tree(Int(client.width), Int(client.height), shift: 1), bounds: bounds, cell: cell, pixel: pixel, spacing: spacing)
    #expect(resized == layout)
    #expect(resized.tiled(Geometry(x: 0, y: 0, width: Int(client.width) / 2 + 1, height: Int(client.height) / 2)).chrome.maxX > cards[0].chrome.maxX)
    let close = { (a: CGFloat, b: CGFloat) in abs(a - b) < 0.0001 }
    #expect(close(cards[1].chrome.minY - cards[0].chrome.maxY, spacing))
    #expect(close(cards[2].chrome.minX - cards[0].chrome.maxX, spacing))
    #expect(close(cards[3].chrome.minX - cards[2].chrome.maxX, spacing))
    #expect(close(cards[4].chrome.minY - cards[2].chrome.maxY, spacing))
    #expect(close(cards[4].chrome.minX, cards[2].chrome.minX) && close(cards[4].chrome.maxX, cards[3].chrome.maxX))
    #expect(close(cards[0].chrome.minX - bounds.minX, spacing) && close(bounds.maxX - cards[3].chrome.maxX, spacing))
    #expect(close(cards[0].chrome.minY - layout.top, spacing) && close(bounds.maxY - cards[4].chrome.maxY, spacing))
    for (pane, card) in zip(root.panes, cards) {
        #expect(card.grid.size == CGSize(width: CGFloat(pane.geometry.width) * cell.width, height: CGFloat(pane.geometry.height) * cell.height))
        let left = card.grid.minX - card.chrome.minX, right = card.chrome.maxX - card.grid.maxX
        let top = card.grid.minY - card.chrome.minY, bottom = card.chrome.maxY - card.grid.maxY
        let padY = (max(cell.height, 2 * spacing) - spacing) / 2
        #expect(left > spacing - pixel && abs(left - right) <= pixel)
        #expect(top > padY - pixel && abs(top - bottom) <= pixel)
        #expect((card.grid.minX / pixel).rounded() == card.grid.minX / pixel && (card.grid.minY / pixel).rounded() == card.grid.minY / pixel)
    }
    let lines = root.dividers.map { layout.line($0) }
    #expect(lines.count == 4)
    #expect(close(lines[0].minX, cards[0].chrome.maxX) && close(lines[0].maxX, cards[2].chrome.minX))
    #expect(close(lines[0].minY, cards[0].chrome.minY) && close(lines[0].maxY, cards[1].chrome.maxY))
    #expect(close(lines[1].minY, cards[0].chrome.maxY) && close(lines[1].maxY, cards[1].chrome.minY))
    #expect(close(lines[1].minX, cards[0].chrome.minX) && close(lines[1].maxX, cards[0].chrome.maxX))
    #expect(close(lines[2].minY, cards[2].chrome.maxY) && close(lines[2].maxY, cards[4].chrome.minY))
    #expect(close(lines[3].minX, cards[2].chrome.maxX) && close(lines[3].maxX, cards[3].chrome.minX))
    let zoomed = pane(0, 0, 0, Int(client.width), Int(client.height))
    let zoom = PaneLayout(root: zoomed, shape: root, bounds: bounds, cell: cell, pixel: pixel, spacing: spacing)
    #expect(zoom.client == client)
    let whole = zoom.tiled(zoomed.geometry)
    #expect(close(whole.chrome.minX - bounds.minX, spacing) && close(bounds.maxX - whole.chrome.maxX, spacing))
    #expect(abs(whole.grid.midX - whole.chrome.midX) <= pixel && abs(whole.grid.midY - whole.chrome.midY) <= pixel)
    #expect(PaneLayout(root: zoomed, bounds: bounds, cell: cell, pixel: pixel, spacing: spacing).client.width >= client.width)
    #expect((PaneLayout(root: zoomed, bounds: bounds, cell: cell, pixel: pixel, spacing: spacing).client.width > client.width) == (3 * spacing > cell.width))
}

@Test(arguments: [CGFloat(44), 52, 52.3], [CGFloat(1), 0.5])
func nativeHeaderBoundary(header: CGFloat, pixel: CGFloat) {
    let cell = CGSize(width: 8, height: 17)
    let bounds = CGRect(x: 0, y: header, width: 700, height: 700 - header)
    let g = Geometry(x: 0, y: 0, width: 80, height: 1)
    let root = Node.pane(Pane(id: PaneID(number: 0), index: 0, geometry: g, focus: .active, layer: .tiled))
    let layout = PaneLayout(root: root, bounds: bounds, cell: cell, pixel: pixel, spacing: 8)
    #expect(layout.top == ceil(header / pixel) * pixel)
    #expect(layout.floatingBounds.minY == layout.top)
    #expect(abs(layout.tiled(g).chrome.minY - layout.top - 8) < 0.0001)
    #expect(layout.tiled(g).grid.minY >= layout.top)
    #expect(layout.grid(g).size == CGSize(width: 640, height: 17))
}
