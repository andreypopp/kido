import KoModel
import SidebarFeed
import TmuxControl

// A move of the sidebar and the tabs, as SessionModel.select and the sidebar ask for it.
enum Navigation: Equatable {
    case switchWindow(next: Bool), switchSession(next: Bool)
    case jump(Snapshot.Position), selectWindow(SessionID, WindowID), selectSession(SessionID)
    case releaseSideFocus
}

enum WindowStep {
    case next, previous, last
    case number(Int)
}

struct SessionModel: Equatable {
    struct Session: Equatable {
        let id: SessionID
        let name: String
        var window: WindowID
    }
    struct Window: Equatable {
        let id: WindowID
        let name: String
    }
    struct Tab: Equatable {
        let id: WindowID
        let name: String
        let active: Bool
        let status: SidebarRow.Status
        var agent = false
        var messageable = false
        var displayName: String { sidebarTitle(name, messageable: messageable) }
    }

    var sessions: [Session] = []
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
        model.sessions = arranged(sessions, by: snapshot?.sessions.map(\.id) ?? [], \.id)
        model.windows = arranged(windows.filter { projection.ancestors[$0.id] == $0.id || (projection.ancestors[$0.id] == nil && (snapshot == nil || $0.id == window)) }, by: projection.order, \.id)
        let active = window.flatMap { projection.ancestors[$0] ?? $0 }
        return (model, model.windows.map { Tab(id: $0.id, name: projection.labels[$0.id]?.title ?? $0.name, active: $0.id == active,
                                              status: projection.statuses[$0.id] ?? .quiet, agent: projection.labels[$0.id]?.agent ?? false,
                                              messageable: projection.labels[$0.id]?.messageable ?? false) })
    }

    func select(_ step: WindowStep) -> Navigation? {
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

extension SessionModel {
    init(_ model: KoModel) {
        sessions = model.layout.layout.sessions.compactMap { session in
            session.windows.first.map { Session(id: session.id, name: session.name, window: $0.id) }
        }
        let current = model.current
        session = current?.session.id
        windows = current?.session.windows.map { Window(id: $0.id, name: $0.name) } ?? []
        window = current?.window.id
    }
}
