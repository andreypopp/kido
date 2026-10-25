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

    var sessions: [SessionListing] = []
    var session: SessionID?
    var windows: [Window] = []
    var window: WindowID?

    var title: String {
        let session = sessions.first { $0.id == self.session }?.name ?? "Kido"
        guard let window = windows.first(where: { $0.id == self.window }) else { return session }
        return "\(session) — \(window.name)"
    }

    func navigation(_ snapshot: Snapshot?) -> SessionModel {
        let projection = sidebarWindows(snapshot, session: session, surviving: Set(windows.map(\.id)))
        var model = self
        model.sessions = arranged(sessions, by: snapshot?.sessions.map(\.id) ?? [], \.id)
        model.windows = arranged(windows.filter { projection.ancestors[$0.id] == $0.id || (projection.ancestors[$0.id] == nil && (snapshot == nil || $0.id == window)) }, by: projection.order, \.id)
        return model
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
