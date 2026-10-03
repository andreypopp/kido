import TmuxControl

enum WindowStep {
    case next, previous, last
    case number(Int)
}

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

    // Ghostty's tab index is one-based, clamped to the last, as in Ghostty's
    // own app.
    func select(_ step: WindowStep) -> Command? {
        switch step {
        case .next: Command("select-window", "-t", ":+")
        case .previous: Command("select-window", "-t", ":-")
        case .last: Command("select-window", "-t", ":$")
        case .number(let n): windows.isEmpty ? nil : Command("select-window", "-t", windows[min(n, windows.count) - 1].id)
        }
    }
}
