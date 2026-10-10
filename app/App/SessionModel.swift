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
    struct Tab: Equatable {
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

    func navigation(_ snapshot: Snapshot?, activePanes: [WindowID: PaneID] = [:]) -> (model: SessionModel, tabs: [Tab]) {
        let projection = sidebarWindows(snapshot, session: session, surviving: Set(windows.map(\.id)), activePanes: activePanes)
        var model = self
        model.windows = windows.filter { projection.ancestors[$0.id] == nil || projection.ancestors[$0.id] == $0.id }
        let active = window.flatMap { projection.ancestors[$0] ?? $0 }
        return (model, model.windows.map { Tab(id: $0.id, name: projection.titles[$0.id] ?? $0.name, active: $0.id == active,
                                              status: projection.statuses[$0.id] ?? .quiet) })
    }

    func select(_ step: WindowStep) -> RPCRequest? {
        switch step {
        case .next: return .switchWindow(next: true)
        case .previous: return .switchWindow(next: false)
        default: break
        }
        guard let session, !windows.isEmpty else { return nil }
        let target: WindowID? = switch step {
        case .next, .previous: nil
        case .last: windows.last?.id
        case .number(let n): windows[max(0, min(n, windows.count) - 1)].id
        }
        return target.map { .selectWindow(session, $0) }
    }
}
