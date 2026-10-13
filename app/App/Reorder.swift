import SidebarFeed

@MainActor final class Reorder {
    enum Gesture { case pane, tab, sidebar }
    private(set) var gesture: Gesture?
    var state = ReorderState()

    func claim(_ gesture: Gesture) -> Bool {
        guard self.gesture == nil, gesture == .pane || state.pending == nil else { return false }
        self.gesture = gesture
        return true
    }

    func release(_ gesture: Gesture) {
        if self.gesture == gesture { self.gesture = nil }
    }
}
