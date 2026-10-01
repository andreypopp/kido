import CoreGraphics
import Foundation
import Testing
@testable import TmuxControl

@Test(arguments: [CGSize(width: 563, height: 500), CGSize(width: 664, height: 560), CGSize(width: 1281, height: 803)], [CGFloat(1), CGFloat(0.5)])
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
    #expect(layout.origin.y == 44)
    #expect(frames[0].minY == 44 - layout.before.height)
    #expect(bounds.maxY - frames[2].maxY >= PaneLayout.minimumMargin.height)
    #expect(bounds.maxY - frames[2].maxY < PaneLayout.minimumMargin.height + cell.height)
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
