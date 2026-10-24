import Foundation
import TmuxControl

public enum RPCRequest: Equatable, Sendable {
    case switchWindow(next: Bool), switchSession(next: Bool)
    case jump(Snapshot.Position), selectWindow(SessionID, WindowID), selectSession(SessionID)
    case newWindow(WindowID), newSession, releaseSideFocus
    case reorder(ReorderMove)
    case prompt(pane: PaneID, text: String?, target: PaneID?)

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
        case .reorder(.session(let s, let anchor, let placement)):
            ["reorder-session": ["session": s.description, "relative-to": anchor.description, "placement": placement.rawValue]]
        case .reorder(.window(let s, let w, let anchor, let placement)):
            ["reorder-window": ["session": s.description, "window": w.description, "relative-to": anchor.description, "placement": placement.rawValue]]
        case .prompt(let pane, let text, let target):
            ["prompt": {
                var prompt: [String: Any] = ["pane": pane.description]
                if let text { prompt["text"] = text }
                if let target { prompt["target"] = target.description }
                return prompt
            }()]
        }
        return try JSONSerialization.data(withJSONObject: operation.merging(["id": id]) { _, new in new }) + Data([10])
    }

    public static func composePrompt(prompt: String, selection: String) -> String {
        var quoted = selection
        if quoted.hasSuffix("\n") { quoted.removeLast() }
        let lines = quoted.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return (prompt.hasSuffix(":") ? prompt : prompt + ":") + "\n" + lines
    }

    public func accepts(_ value: RPCEvent.Reply.Value) -> Bool {
        switch (self, value) {
        case (_, .error), (.prompt(_, _, _), .promptError(_, _)), (.switchWindow, .switched), (.switchSession, .switched), (.jump, .jumped),
             (.selectWindow, .selected), (.selectSession, .selected), (.newWindow, .created), (.newSession, .created),
             (.releaseSideFocus, .released), (.reorder, .reordered): true
        case (.prompt(_, nil, _), .prompt(.candidates)), (.prompt(_, .some, _), .prompt(.delivered)): true
        default: false
        }
    }
}
