import Foundation
import TmuxControl

public enum SessionRename: Equatable, Sendable {
    case revert
    case reject(String)
    case rename(String)

    public init(_ text: String, session: SessionID, original: String, sessions: [SessionNodes]) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == original { self = .revert }
        else if name.contains(":") || name.contains(".") {
            self = .reject("Session names can’t contain “:” or “.”.")
        } else if sessions.contains(where: { $0.id != session && $0.name == name }) {
            self = .reject("A session named “\(name)” already exists.")
        } else { self = .rename(name) }
    }
}
