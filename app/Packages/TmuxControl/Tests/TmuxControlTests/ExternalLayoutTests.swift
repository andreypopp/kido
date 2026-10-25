import CoreGraphics
import Testing
@testable import TmuxControl

@Test func oversizedExternalLayoutKeepsGrid() {
    let a = Node.pane(Pane(id: PaneID(number: 0), index: 0, geometry: Geometry(x: 0, y: 0, width: 20, height: 20), focus: .active, layer: .tiled))
    let b = Node.pane(Pane(id: PaneID(number: 1), index: 1, geometry: Geometry(x: 21, y: 0, width: 179, height: 20), focus: .unvisited, layer: .tiled))
    let c = Node.pane(Pane(id: PaneID(number: 2), index: 2, geometry: Geometry(x: 0, y: 21, width: 200, height: 59), focus: .unvisited, layer: .tiled))
    let root = Node.split(.topBottom, Geometry(x: 0, y: 0, width: 200, height: 80), [
        .split(.leftRight, Geometry(x: 0, y: 0, width: 200, height: 20), [a, b]), c,
    ])
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let layout = PaneLayout(root: root, bounds: bounds, cell: CGSize(width: 8, height: 17), pixel: 0.5, spacing: 8)
    for pane in root.panes {
        let placed = layout.tiled(pane.geometry)
        #expect(placed.grid.width == CGFloat(pane.geometry.width) * 8)
        #expect(placed.grid.height == CGFloat(pane.geometry.height) * 17)
        #expect(placed.chrome.size.width >= 0 && placed.chrome.size.height >= 0)
    }
}
