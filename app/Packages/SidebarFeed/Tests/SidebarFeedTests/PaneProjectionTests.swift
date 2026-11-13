import Testing
import KoModel
@testable import SidebarFeed

@Test func placementsFollowTheOutlineAncestryAndWindows() {
    func id(_ number: Int) -> PaneID { PaneID(number: UInt32(number)) }
    let tree = pane(0, children: [pane(1, window: 0), pane(2, window: 0, children: [pane(3, window: 0)])])
    let projection = PaneProjection(makeSnapshot([tree, pane(4)]))
    #expect(projection.placements[id(0)]?.parent == nil)
    #expect(projection.placements[id(1)]?.parent == id(0))
    #expect(projection.placements[id(3)]?.parent == id(2))
    #expect(projection.placements[id(3)]?.position.window == WindowID(number: 0))
    #expect(projection.placements[id(4)]?.position.window == WindowID(number: 4))
    #expect(projection.items[id(9)] == nil)
}
