import SidebarFeed
import TmuxControl

enum WindowStep {
    case next, previous, last
    case number(Int)
}

struct SessionModel: Equatable {
    struct Window: Equatable {
        let id: WindowID
        let name: String
    }
    struct Tab {
        let id: WindowID
        let name: String
        let active: Bool
        let status: SidebarRow.Status
    }

    var sessions: [SessionListing] = []
    var session: SessionID?
    var windows: [Window] = []
    var window: WindowID?

    var title: String {
        let session = sessions.first { $0.id == self.session }?.name ?? "Kido"
        guard let window = windows.first(where: { $0.id == self.window }) else { return session }
        return "\(session) — \(window.name)"
    }

    func navigation(_ snapshot: Snapshot?) -> (model: SessionModel, tabs: [Tab]) {
        let projection = sidebarWindows(snapshot, session: session, surviving: Set(windows.map(\.id)))
        var model = self
        model.windows = windows.filter { projection.ancestors[$0.id] == nil || projection.ancestors[$0.id] == $0.id }
        model.window = window.flatMap { projection.ancestors[$0] ?? $0 }
        return (model, model.windows.map { Tab(id: $0.id, name: $0.name, active: $0.id == model.window,
                                              status: projection.statuses[$0.id] ?? .quiet) })
    }

    func select(_ step: WindowStep) -> Command? {
        guard let session, !windows.isEmpty else { return nil }
        let current = windows.firstIndex { $0.id == window } ?? 0
        let index: Int = switch step {
        case .next: (current + 1) % windows.count
        case .previous: (current + windows.count - 1) % windows.count
        case .last: windows.count - 1
        case .number(let n): max(0, min(n, windows.count) - 1)
        }
        return Command("switch-client", "-t", "\(session):\(windows[index].id)")
    }
}
