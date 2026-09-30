import TmuxControl

struct SessionModel {
    struct Window {
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
}
