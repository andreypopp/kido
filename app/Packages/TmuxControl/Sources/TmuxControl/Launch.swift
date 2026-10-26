import Foundation

public struct Launch: Sendable {
    public let path: String
    public let arguments: [String]
    public let environment: [String: String]?

    public init(_ path: String, _ arguments: [String], environment: [String: String]? = nil) {
        self.path = path
        self.arguments = arguments
        self.environment = environment
    }

    public static func attachImages(_ tmux: String, socket: String, session: SessionID) -> Launch {
        Launch("/usr/bin/env", ["-u", "TMUX", tmux, "-u", "-S", socket, "-C", "attach-session", "-E", "-f",
                                 "no-output,ignore-size,no-detach-on-destroy", "-t", session.description])
    }

    public static func attach(_ tmux: String, socket: String, session: String? = nil, pauseAfter: Int = 5) -> Launch {
        Launch(tmux, ["-u", "-S", socket, "-N", "-T", "hyperlinks", "-C", "attach-session"] + (session.map { ["-t", $0] } ?? [])
            + ["-f", "pause-after=\(pauseAfter),new-layouts,no-detach-on-destroy"])
    }
}
