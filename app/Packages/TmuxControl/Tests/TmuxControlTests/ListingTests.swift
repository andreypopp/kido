import Foundation
import Testing
@testable import TmuxControl

@Test func listings() throws {
    #expect(SessionListing("$3\u{1F}a b\u{1F}c") == SessionListing("$3\u{1F}a b\u{1F}c"))
    #expect(SessionListing("$3\u{1F}a b\u{1F}c")?.name == "a b\u{1F}c")
    #expect(SessionListing("$3\u{1F}")?.name == "")
    #expect(SessionListing("@3\u{1F}a") == nil)
    #expect(SessionListing("$3") == nil)

    let layout = #"{"V":2,"L":{"t":"p","w":80,"h":24,"x":0,"y":0,"i":0,"I":"%4","a":true}}"#
    let window = try #require(WindowListing("@2\u{1F}1\u{1F}\(layout)\u{1F}\(layout)\u{1F}my  name"))
    #expect(window.id == w2)
    #expect(window.active)
    #expect(window.name == "my  name")
    #expect(window.visible == window.layout)
    #expect(window.layout.root.panes.map(\.id) == [PaneID(number: 4)])
    #expect(WindowListing("@2\u{1F}0\u{1F}\(layout)\u{1F}\(layout)\u{1F}")?.active == false)
    #expect(WindowListing("@2\u{1F}2\u{1F}\(layout)\u{1F}\(layout)\u{1F}x") == nil)
    #expect(WindowListing("@2\u{1F}1\u{1F}{}\u{1F}\(layout)\u{1F}x") == nil)
    #expect(WindowListing("@2\u{1F}1\u{1F}\(layout)\u{1F}\(layout)") == nil)
}

@Test(.enabled(if: tmux != nil), .timeLimit(.minutes(1)))
func liveSessions() async throws {
    let tmux = try #require(tmux)
    let socket = "/tmp/ts-\(getpid()).sock"
    #expect(try server(tmux, socket, "new-session", "-d", "-s", "a", "-n", "one", "-x", "80", "-y", "24", "/bin/sh") == 0)
    defer {
        _ = try? server(tmux, socket, "kill-server")
        try? FileManager.default.removeItem(atPath: socket)
    }
    #expect(try server(tmux, socket, "set-option", "-g", "detach-on-destroy", "off") == 0)
    #expect(try server(tmux, socket, "split-window", "-t", "a", "-h", "/bin/sh") == 0)
    #expect(try server(tmux, socket, "new-window", "-t", "a", "-n", "two words", "/bin/sh") == 0)
    #expect(try server(tmux, socket, "new-session", "-d", "-s", "b c", "/bin/sh") == 0)
    let seen = Recorder<Event>()
    let client = Client(tmux: tmux, socket: socket, session: "a", pauseAfter: 5)
    try client.start(onEvent: seen.add, onClose: seen.close)
    _ = try await seen.wait("attach") { e, _ in e.contains(.sessionChanged(s0, "a")) ? () : nil }

    func list() async throws -> ([SessionListing], [WindowListing]) {
        let r = try await client.run([
            Command("list-sessions", "-F", SessionListing.format), Command("list-windows", "-F", WindowListing.format),
        ])
        guard r.count == 2, case .success(let s) = r[0], case .success(let w) = r[1] else {
            Issue.record("listing: \(r)")
            return ([], [])
        }
        #expect(s.compactMap(SessionListing.init).count == s.count)
        #expect(w.compactMap(WindowListing.init).count == w.count)
        return (s.compactMap(SessionListing.init), w.compactMap(WindowListing.init))
    }

    let (sessions, windows) = try await list()
    #expect(sessions.map(\.name) == ["a", "b c"])
    #expect(sessions.map(\.id) == [s0, s1])
    #expect(windows.map(\.id) == [w0, w1])
    #expect(windows.map(\.name) == ["one", "two words"])
    #expect(windows.map(\.active) == [false, true])
    #expect(windows[0].layout.root.panes.map(\.id) == [p0, p1])

    #expect(try await client.run(Command("select-window", "-t", w0)) == .success([]))
    _ = try await seen.wait("window change") { e, _ in e.contains(.sessionWindowChanged(s0, w0)) ? () : nil }
    #expect(try await list().1.map(\.active) == [true, false])

    #expect(try server(tmux, socket, "new-window", "-d", "-t", "a", "/bin/sh") == 0)
    let w3 = WindowID(number: 3)
    _ = try await seen.wait("window add") { e, _ in e.contains(.windowAdd(w3, .linked)) ? () : nil }
    #expect(try server(tmux, socket, "new-window", "-d", "-t", "b c", "/bin/sh") == 0)
    _ = try await seen.wait("unlinked window add") { e, _ in e.contains(.windowAdd(WindowID(number: 4), .unlinked)) ? () : nil }
    #expect(try server(tmux, socket, "kill-window", "-t", w3.description) == 0)
    _ = try await seen.wait("window close") { e, _ in e.contains(.windowClose(w3, .linked)) ? () : nil }

    #expect(try await client.run(Command("switch-client", "-t", s1)) == .success([]))
    _ = try await seen.wait("session change") { e, _ in e.contains(.sessionChanged(s1, "b c")) ? () : nil }
    #expect(try await list().1.map(\.id) == [w2, WindowID(number: 4)])

    #expect(try server(tmux, socket, "kill-session", "-t", s1.description) == 0)
    _ = try await seen.wait("moved after kill") { e, _ in e.filter { $0 == .sessionChanged(s0, "a") }.count == 2 ? () : nil }
    #expect(try await list().0.map(\.name) == ["a"])
}
