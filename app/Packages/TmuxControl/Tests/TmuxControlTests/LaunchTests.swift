import Foundation
import Testing
@testable import TmuxControl

@Test func attachLaunchNeverStartsServer() {
    let launch = Launch.attach("/remote/install/bin/kido-tmux", socket: "/tmp/state space $literal/socket", session: "$7")
    #expect(launch.path == "/remote/install/bin/kido-tmux")
    #expect(launch.arguments == ["-u", "-S", "/tmp/state space $literal/socket", "-N", "-T", "hyperlinks", "-C", "attach-session", "-t", "$7", "-f", "pause-after=5,new-layouts,no-detach-on-destroy"])
}

@Test(.timeLimit(.minutes(1))) func stoppedPreparedClientIsKilled() async throws {
    let seen = Recorder<Event>()
    let client = Client(launch: Launch("/bin/sh", ["-c", "trap '' TERM; printf '%%session-renamed $0 %s\\n' \"$PRIVATE\"; kill -STOP $$; while :; do /bin/sleep 1; done"], environment: ["PRIVATE": "prepared"]))
    try client.start(onEvent: seen.add, onClose: seen.close)
    defer { client.close() }
    _ = try await seen.wait("prepared environment reaches parser") { events, _ in
        events.contains(.sessionRenamed(SessionID(number: 0), "prepared")) ? () : nil
    }
    client.close()
    let status = try await seen.wait("stopped client must be reaped") { _, status in status }
    #expect(status == SIGKILL)
}
