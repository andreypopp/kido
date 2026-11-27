import Testing
import KoModel
@testable import SidebarFeed

@Test func placementsFollowTheOutlineWindows() {
    func id(_ number: Int) -> PaneID { PaneID(number: UInt32(number)) }
    let projection = PaneProjection(makeSnapshot([group(0, [pane(0), pane(1, window: 0, parent: 0), pane(2, window: 0), pane(3, window: 0, parent: 2)]), pane(4)]))
    #expect(projection.placements[id(3)]?.window == WindowID(number: 0))
    #expect(projection.placements[id(4)]?.window == WindowID(number: 4))
    #expect(projection.items[id(9)] == nil)
}
