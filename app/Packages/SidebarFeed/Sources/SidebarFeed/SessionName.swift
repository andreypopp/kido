import Foundation
import TmuxControl

public enum SessionName: Equatable, Sendable {
    case revert
    case reject(String)
    case accept(String)

    public enum Operation: Equatable, Sendable {
        case create, rename(SessionID, original: String)
        public var session: SessionID? { if case .rename(let id, _) = self { id } else { nil } }
    }

    public init(_ text: String, operation: Operation, sessions: [SessionNodes]) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .rename(_, let original) = operation, name.isEmpty || name == original { self = .revert }
        else if name.isEmpty { self = .reject("Enter a session name.") }
        else if name.contains(":") || name.contains(".") {
            self = .reject("Session names can’t contain “:” or “.”.")
        } else if sessions.contains(where: { $0.id != operation.session && $0.name == name }) {
            self = .reject("A session named “\(name)” already exists.")
        } else { self = .accept(name) }
    }
}
