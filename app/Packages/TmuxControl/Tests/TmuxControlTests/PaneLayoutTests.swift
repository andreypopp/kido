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
    let layout = PaneLayout(root: root, bounds: CGRect(x: 0, y: 0, width: 824, height: 750), cell: cell, pixel: pixel)
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

@Test(arguments: [CGSize(width: 563, height: 500), CGSize(width: 664, height: 560), CGSize(width: 664, height: 558), CGSize(width: 1281, height: 803)], [CGFloat(1), CGFloat(0.5)])
func paddedLayout(area: CGSize, pixel: CGFloat) {
    let cell = CGSize(width: 8, height: 17)
    func pane(_ id: UInt32, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Node {
        .pane(Pane(id: PaneID(number: id), index: Int(id), geometry: Geometry(x: x, y: y, width: width, height: height), focus: .unvisited, layer: .tiled))
    }
    let bounds = CGRect(origin: .zero, size: area)
    let client = PaneLayout(root: pane(0, 0, 0, 1, 1), bounds: bounds, cell: cell, pixel: pixel).client
    let cols = Int(client.width), rows = Int(client.height), left = (cols - 1) / 2, top = (rows - 1) / 2
    let root = Node.split(.topBottom, Geometry(x: 0, y: 0, width: cols, height: rows), [
        pane(0, 0, 0, cols, top),
        .split(.leftRight, Geometry(x: 0, y: top + 1, width: cols, height: rows - top - 1), [
            pane(1, 0, top + 1, left, rows - top - 1),
            pane(2, left + 1, top + 1, cols - left - 1, rows - top - 1),
        ]),
    ])
    let layout = PaneLayout(root: root, bounds: bounds, cell: cell, pixel: pixel)
    let frames = root.panes.map { layout.frame($0.geometry) }
    #expect(layout.grid(root.panes[0].geometry).maxX == layout.rightEdge)
    #expect(layout.grid(root.panes[1].geometry).maxX < layout.rightEdge)
    #expect(layout.grid(root.panes[2].geometry).maxX == layout.rightEdge)
    #expect(frames[0].minX == frames[1].minX)
    #expect(frames[0].maxX == frames[2].maxX)
    #expect(frames[0].maxY + pixel == frames[1].minY)
    #expect(frames[1].maxX + pixel == frames[2].minX)
    #expect(frames[1].maxY == frames[2].maxY)
    #expect(frames[0].minX >= PaneLayout.minimumMargin.width)
    #expect(frames[0].minY >= PaneLayout.minimumMargin.height)
    #expect(frames[0].minX < PaneLayout.minimumMargin.width + cell.width / 2)
    #expect(PaneLayout.minimumMargin == CGSize(width: 4, height: 2))
    #expect(client.height == floor((area.height - 40 - 2) / cell.height))
    #expect(layout.origin.y == area.height - 2 - CGFloat(rows) * cell.height)
    #expect(layout.historyStrip == min(cell.height - pixel, area.height - 40 - 2 - CGFloat(rows) * cell.height))
    #expect(layout.historyStrip >= 0 && layout.historyStrip < cell.height)
    #expect(frames[0].minY == layout.origin.y - layout.before.height)
    #expect(layout.grid(root.panes[2].geometry).maxY == bounds.maxY - 2)
    #expect(frames[2].maxY == bounds.maxY - 2 + layout.after.height)
    #expect(layout.floatingBounds.maxY == bounds.maxY - 2)
    let collapsedBounds = CGRect(origin: .zero, size: CGSize(width: area.width + 236, height: area.height))
    let collapsed = PaneLayout(root: root, bounds: collapsedBounds, cell: cell, pixel: pixel)
    #expect(collapsed.client.height == client.height)
    #expect(collapsed.origin.y == layout.origin.y)
    #expect(abs(frames[0].minX - (bounds.maxX - frames[0].maxX)) <= pixel)
    for pane in root.panes {
        let grid = layout.grid(pane.geometry), frame = layout.frame(pane.geometry)
        #expect(grid.width == CGFloat(pane.geometry.width) * cell.width)
        #expect(grid.height == CGFloat(pane.geometry.height) * cell.height)
        #expect(abs(grid.midX - frame.midX) <= pixel / 2 && abs(grid.midY - frame.midY) <= pixel / 2)
        #expect((grid.minX / pixel).rounded() == grid.minX / pixel)
        #expect((grid.minY / pixel).rounded() == grid.minY / pixel)
        #expect((grid.width / pixel).rounded() == grid.width / pixel)
        #expect((grid.height / pixel).rounded() == grid.height / pixel)
        #expect(frame.contains(grid))
    }
    let horizontal = layout.line(root.dividers[0], pixel: pixel)
    let vertical = layout.line(root.dividers[1], pixel: pixel)
    #expect(horizontal.height == pixel && horizontal.minY == frames[0].maxY)
    #expect(vertical.width == pixel && vertical.minX == frames[1].maxX)
    #expect((horizontal.minY / pixel).rounded() == horizontal.minY / pixel)
    #expect((vertical.minX / pixel).rounded() == vertical.minX / pixel)
    let sideBySide = Node.split(.leftRight, Geometry(x: 0, y: 0, width: cols, height: rows), [
        pane(0, 0, 0, left, rows), pane(1, left + 1, 0, cols - left - 1, rows),
    ])
    let stripDivider = layout.line(sideBySide.dividers[0], pixel: pixel)
    #expect(stripDivider.minY == 40)
    #expect(stripDivider.maxY == bounds.maxY - 2)
    #expect(stripDivider.minX == layout.frame(sideBySide.panes[0].geometry).maxX)
    let zoomed = pane(1, 0, 0, cols, rows)
    let zoom = PaneLayout(root: zoomed, bounds: bounds, cell: cell, pixel: pixel)
    let frame = zoom.frame(zoomed.panes[0].geometry)
    #expect(frame.minX == frames[0].minX && frame.maxX == frames[0].maxX)
    #expect(frame.minY == frames[0].minY && frame.maxY == frames[2].maxY)
    #expect(zoom.client == client)
    #expect(zoom.grid(zoomed.panes[0].geometry).maxX == zoom.rightEdge)
    #expect(layout.before.width + layout.after.width + pixel == cell.width)
    #expect(layout.before.height + layout.after.height + pixel == cell.height)
    if pixel == 0.5 {
        #expect(layout.before.width == 3.5 && layout.after.width == 4)
        #expect(layout.before.height == 8 && layout.after.height == 8.5)
    }
}

@Test func fractionalPointLayout() {
    paddedLayout(area: CGSize(width: 664, height: 558.5), pixel: 0.5)
}

@Test(arguments: [CGFloat(1), CGFloat(0.5), CGFloat(0.8)])
func pixelAlignedBottomMargin(pixel: CGFloat) {
    let cell = CGSize(width: 8, height: 16)
    for height in [CGFloat(802), 802.3, 803.2] {
        let rows = Int(floor((height - 40 - 2) / cell.height))
        let g = Geometry(x: 0, y: 0, width: 80, height: rows)
        let root = Node.pane(Pane(id: PaneID(number: 0), index: 0, geometry: g, focus: .active, layer: .tiled))
        let layout = PaneLayout(root: root, bounds: CGRect(x: 0, y: 0, width: 700, height: height), cell: cell, pixel: pixel)
        let grid = layout.grid(g), gap = height - grid.maxY
        #expect(layout.client.height == CGFloat(rows))
        #expect(gap >= 2 - 0.0001 && gap < 2 + pixel)
        #expect(abs(grid.minY / pixel - (grid.minY / pixel).rounded()) < 0.0001)
        let contentTop = grid.minY - layout.historyStrip
        #expect(abs(contentTop / pixel - (contentTop / pixel).rounded()) < 0.0001)
        #expect(layout.historyStrip >= 0 && layout.historyStrip < cell.height)
        #expect(abs(layout.historyStrip - min(cell.height - pixel, max(0, grid.minY - 40))) < 0.0001)
        #expect(abs(layout.floatingBounds.maxY - grid.maxY) < 0.0001)
        #expect(abs(layout.clamp(layout.frame(g).offsetBy(dx: 0, dy: 1000)).maxY - grid.maxY) < 0.0001)
    }
}

@Test func resizingHistoryStrip() {
    let cell = CGSize(width: 8, height: 17)
    for height in stride(from: CGFloat(400), through: 700, by: 0.5) {
        for rows in [Int(floor((height - 40 - 2) / cell.height)), 20, 40] {
            let g = Geometry(x: 0, y: 0, width: 80, height: rows)
            let root = Node.pane(Pane(id: PaneID(number: 0), index: 0, geometry: g, focus: .active, layer: .tiled))
            let layout = PaneLayout(root: root, bounds: CGRect(x: 0, y: 0, width: 700, height: height), cell: cell, pixel: 0.5)
            #expect(layout.client.height == floor((height - 40 - 2) / cell.height))
            #expect(layout.grid(g).maxY == height - 2)
            #expect(layout.historyStrip >= 0 && layout.historyStrip < cell.height)
            if rows == Int(layout.client.height) {
                #expect(layout.historyStrip == height - 40 - 2 - CGFloat(rows) * cell.height)
            }
        }
    }
}
