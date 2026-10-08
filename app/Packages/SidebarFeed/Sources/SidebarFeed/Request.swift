import Foundation
import TmuxControl

public enum RPCRequest: Equatable, Sendable {
    case switchWindow(next: Bool), switchSession(next: Bool)
    case jump(Snapshot.Position), selectWindow(SessionID, WindowID), selectSession(SessionID)
    case newWindow(WindowID), newSession, releaseSideFocus

    public func data(id: Int) throws -> Data {
        let operation: [String: Any] = switch self {
        case .switchWindow(let next): ["switch-window": ["direction": next ? "next" : "prev"]]
        case .switchSession(let next): ["switch-session": ["direction": next ? "next" : "prev"]]
        case .jump(let p): ["jump": ["session": p.session.description, "window": p.window.description, "pane": p.pane.description]]
        case .selectWindow(let s, let w): ["select-window": ["session": s.description, "window": w.description]]
        case .selectSession(let s): ["select-session": s.description]
        case .newWindow(let w): ["new-window": w.description]
        case .newSession: ["new-session": true]
        case .releaseSideFocus: ["release-side-focus": true]
        }
        return try JSONSerialization.data(withJSONObject: operation.merging(["id": id]) { _, new in new }) + Data([10])
    }

    public func accepts(_ value: RPCEvent.Reply.Value) -> Bool {
        switch (self, value) {
        case (_, .error), (.switchWindow, .switched), (.switchSession, .switched), (.jump, .jumped),
             (.selectWindow, .selected), (.selectSession, .selected), (.newWindow, .created), (.newSession, .created),
             (.releaseSideFocus, .released): true
        default: false
        }
    }
}
