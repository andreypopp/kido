import Foundation

public struct Launch: Sendable {
    private static let imageShmFlag = "image-shm"
    public let path: String
    public let arguments: [String]
    public let environment: [String: String]?

    public init(_ path: String, _ arguments: [String], environment: [String: String]? = nil) {
        self.path = path
        self.arguments = arguments
        self.environment = environment
    }

    private static func flags(_ base: String, imageShm: Bool) -> String {
        base + ",no-detach-on-destroy" + (imageShm ? ",\(imageShmFlag)" : "")
    }

    public static func attachImages(_ tmux: String, socket: String, session: SessionID, imageShm: Bool) -> Launch {
        Launch("/usr/bin/env", ["-u", "TMUX", tmux, "-u", "-S", socket, "-C", "attach-session", "-E", "-f",
                                 flags("no-output,ignore-size", imageShm: imageShm), "-t", session.description])
    }

    public static func attach(_ tmux: String, socket: String, session: String? = nil, pauseAfter: Int = 5, imageShm: Bool) -> Launch {
        Launch(tmux, ["-u", "-S", socket, "-N", "-T", "hyperlinks", "-C", "attach-session"] + (session.map { ["-t", $0] } ?? [])
            + ["-f", flags("pause-after=\(pauseAfter),new-layouts", imageShm: imageShm)])
    }
}
