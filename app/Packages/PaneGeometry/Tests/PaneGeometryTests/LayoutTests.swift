import Foundation
import KoModel
import Testing
@testable import PaneGeometry

private func windows() throws -> [KoSchema.Window] {
    let url = try #require(Bundle.module.url(forResource: "ko-layout", withExtension: "json", subdirectory: "Fixtures"))
    let model = try JSONDecoder().decode(KoModel.self, from: Data(contentsOf: url))
    return model.layout.layout.windows
}

private func pane(_ number: UInt32) -> PaneID { PaneID(number: number) }

@Test func aSplitTreeGetsItsOffsetsFromTheSiblingSizesAndOneDividerCell() throws {
    let tiles = try windows()[0]
    let layout = Layout(tiles)
    let tiled = layout.root.panes.filter { $0.layer == .tiled }
    #expect(tiled.map(\.id) == [pane(1), pane(2), pane(3)])
    #expect(tiled.map(\.geometry) == [
        Geometry(x: 0, y: 0, width: 40, height: 24),
        Geometry(x: 41, y: 0, width: 39, height: 12),
        Geometry(x: 41, y: 13, width: 39, height: 11),
    ])
    #expect(layout.root.geometry == Geometry(x: 0, y: 0, width: 80, height: 24))
}

@Test func theDividersNameTheNeighboursOnBothSides() throws {
    let root = Layout(try windows()[0]).root
    let dividers = root.dividers
    #expect(dividers.map(\.geometry) == [Geometry(x: 40, y: 0, width: 1, height: 24), Geometry(x: 41, y: 12, width: 39, height: 1)])
    #expect(dividers[0].resize(to: 30) == .resizePair(KoSchema.EditResizePair(first: pane(1), firstSize: 30, second: pane(2))))
    #expect(dividers[1].resize(to: 8) == .resizePair(KoSchema.EditResizePair(first: pane(2), firstSize: 8, second: pane(3))))
    #expect(dividers[0].resize(to: 0) == nil)
}

@Test func floatsFollowTheTiledPanesInZOrderWithTheirOwnPlace() throws {
    let floats = Layout(try windows()[0]).root.panes.filter { $0.layer != .tiled }
    #expect(floats.map(\.id) == [pane(5), pane(4)])
    #expect(floats.map(\.layer) == [.floating(z: 0, source: .window), .floating(z: 1, source: .window)])
    #expect(floats.map(\.geometry) == [Geometry(x: 12, y: 6, width: 20, height: 6), Geometry(x: 6, y: 4, width: 28, height: 8)])
}

@Test func theSelectedPaneElseTheFocusPaneIsActiveAndNoOtherIs() throws {
    let panes = Layout(try windows()[0]).root.panes
    #expect(panes.filter { $0.active }.map(\.id) == [pane(1)])
    let selected = Layout(try windows()[0], active: pane(3)).root.panes
    #expect(selected.filter { $0.active }.map(\.id) == [pane(3)], "the client's selection wins over the window's focus")
}

@Test func aZoomedPaneAloneFillsTheVisibleLayoutAndTheFullOneKeepsEveryPane() throws {
    let zoomed = try windows()[1]
    let visible = Layout(zoomed, visible: true).root
    #expect(visible.panes.map(\.id) == [pane(7)])
    #expect(Layout(zoomed, visible: true, active: pane(6)).root.panes.first?.active == true, "the zoomed pane is active whatever the selection")
    #expect(visible.geometry == Geometry(x: 0, y: 0, width: 80, height: 24))
    #expect(Layout(zoomed).root.panes.map(\.id) == [pane(6), pane(7)])
    #expect(Layout(try windows()[0], visible: true) == Layout(try windows()[0]))
}

@Test func floatsOfAShownChildWindowDrawOverItsSlotAndStayInside() throws {
    func window(zoom: String = "") throws -> KoSchema.Window {
        try JSONDecoder().decode(KoSchema.Window.self, from: Data(#"{"id":"window_0","name":"w","vars":{},"cols":81,"rows":20,\#(zoom)"focus":"pane_0","tree":{"split":"h","children":[{"pane":"pane_0","cols":40,"rows":20},{"pane":"pane_1","cols":40,"rows":20}]},"floats":[]}"#.utf8))
    }
    let child = [KoSchema.Float(border: true, cols: 50, pane: pane(9), rows: 10, title: "", x: 2, y: 3, z: 0),
                 KoSchema.Float(border: true, cols: 5, pane: pane(8), rows: 4, title: "", x: 100, y: 0, z: 1)]
    let layout = Layout(try window(), active: pane(9), children: [ChildFloats(slot: pane(1), floats: child)])
    let floats = layout.root.panes.filter { $0.layer != .tiled }
    #expect(floats.map(\.id) == [pane(9), pane(8)])
    #expect(floats[0].geometry == Geometry(x: 41, y: 3, width: 40, height: 10), "offset by the slot and cut to it")
    #expect(floats[1].geometry == Geometry(x: 76, y: 0, width: 5, height: 4), "an x beyond the slot is pulled inside")
    #expect(floats.map(\.active) == [true, false])
    #expect(floats[0].layer == .floating(z: 0, source: .child(clip: Geometry(x: 41, y: 0, width: 40, height: 20), z: 0, count: 2)))
    let zoomed = Layout(try window(zoom: #""zoom":"pane_1","#), visible: true, children: [ChildFloats(slot: pane(1), floats: child)])
    #expect(zoomed.root.panes.map(\.id) == [pane(1), pane(9), pane(8)])
    #expect(zoomed.root.panes[1].geometry == Geometry(x: 2, y: 3, width: 50, height: 10))
    #expect(Layout(try window(), children: [ChildFloats(slot: pane(7), floats: child)]).root.panes.filter { $0.layer != .tiled }.isEmpty)
}
