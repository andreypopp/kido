import AppKit
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class NotificationTests: VisualTestCase {
    func testPrivateServerNotifications() async throws {
        XCTAssertTrue(background)
        let poster = try XCTUnwrap(Notifier.shared.poster as? RecordedNotifications)
        let authorizationBefore = poster.authorizeCalls
        let postsBefore = poster.posts.count
        let dir = "/tmp/ka-visual-notice-" + UUID().uuidString.prefix(8)
        let result = try await Child.run(tools.kido, ["server", "--server", dir], env: tools.environment)
        XCTAssertEqual(result.status, 0, result.err)
        let server = try JSONDecoder().decode(Server.self, from: Data(result.out.utf8))
        let created = try await Child.run(server.tmux, ["-u", "-S", server.socket, "new-window", "-d", "-t", "$0", "-n", "notice", "-P", "-F", "#{pane_id}\t#{pane_tty}", "printf '\\033]2;Builder\\007\\033]7501;state=blocked:app=builder:msg=QXBwcm92ZQ==\\007'; exec sleep 300"], env: tools.environment)
        XCTAssertEqual(created.status, 0, created.err)
        let fields = created.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        XCTAssertEqual(fields.count, 2)
        let pane = try XCTUnwrap(PaneID(String(fields[0])))
        let tty = try FileHandle(forWritingTo: URL(fileURLWithPath: String(fields[1])))
        let board = NSPasteboard(name: .init("kn-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let app = AppDelegate(runtime: runtime)
        let owner = try XCTUnwrap(app.open(.local, start: false))
        owner.testAttended = false
        owner.testEndpoint = Endpoint(server: server, kido: tools.kido)
        addTeardownBlock { @MainActor in
            owner.close()
            try? tty.close()
            board.releaseGlobally()
            _ = try? await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-session", "-t", "$0"], env: tools.environment)
            try? FileManager.default.removeItem(atPath: dir)
        }
        owner.start()
        try await wait("notification baseline") { !owner.feedFresh && sidebarRows(owner.stressState.4).contains { $0.target?.pane == pane && $0.status == .waiting } }
        XCTAssertEqual(poster.posts.count, postsBefore)
        XCTAssertEqual(poster.authorizeCalls, max(1, authorizationBefore))
        Notifier.shared.connected()
        XCTAssertEqual(poster.authorizeCalls, max(1, authorizationBefore))

        try tty.write(contentsOf: Data("\u{1b}]7501;state=working:app=builder\u{7}".utf8))
        try await wait("waiting left") { sidebarRows(owner.stressState.4).contains { $0.target?.pane == pane && $0.status == .running } }
        try tty.write(contentsOf: Data("\u{1b}]7501;state=blocked:app=builder:msg=QXBwcm92ZQ==\u{7}".utf8))
        try await wait("waiting posts") { poster.posts.count == postsBefore + 1 }
        let notice = try XCTUnwrap(poster.posts.last)
        XCTAssertEqual(notice.title, "builder")
        XCTAssertEqual(notice.subtitle, owner.snapshot?.sessions.first?.name)
        XCTAssertEqual(notice.body, "Waiting: Approve")
        XCTAssertEqual(notice.kind, .waiting)
        XCTAssertEqual(poster.badgeCount, 1)
        let snapshot = try XCTUnwrap(owner.snapshot)
        owner.testReceive(snapshot)
        XCTAssertEqual(poster.posts.count, postsBefore + 1)

        owner.testAttended = true
        app.route(notice.target)
        try await wait("client shows notification window and withdraws") {
            owner.snapshot?.client.window == notice.target.position.window && poster.withdrawals.contains(notice.key)
        }
        XCTAssertEqual(poster.badgeCount, 0)
        owner.testAttended = false
        try tty.write(contentsOf: Data("\u{1b}]133;A\u{7}\u{1b}]133;C;cmdline=make\u{7}\u{1b}]133;D;2\u{7}".utf8))
        try await wait("command failure posts") { poster.posts.count == postsBefore + 2 }
        XCTAssertEqual(poster.posts.last?.body, "Exit 2: make")
        try tty.write(contentsOf: Data("\u{1b}]133;C;cmdline=cancel\u{7}\u{1b}]133;D;130\u{7}".utf8))
        try await wait("interrupted command observed") {
            var nodes = owner.snapshot?.sessions.flatMap(\.nodes) ?? []
            while let node = nodes.popLast() {
                nodes += node.children
                if case .item(let item) = node, item.pane == pane,
                   case .live(.terminal(let shell)) = item.lifecycle,
                   case .idle(let exit?) = shell.phase, exit.code == 130 { return true }
            }
            return false
        }
        XCTAssertEqual(poster.posts.count, postsBefore + 2)
        try tty.write(contentsOf: Data("\u{1b}]7501;state=blocked:app=builder\u{7}".utf8))
        try await wait("closing notice posts") { poster.posts.count == postsBefore + 3 }
        let withdrawalsBefore = poster.withdrawals.count
        owner.close()
        XCTAssertGreaterThan(poster.withdrawals.count, withdrawalsBefore)
        XCTAssertEqual(poster.withdrawals.last, poster.posts.last?.key)
        XCTAssertEqual(poster.badgeCount, 0)
        let cleared = poster.withdrawAllCalls
        Notifier.shared.withdrawAll()
        XCTAssertEqual(poster.withdrawAllCalls, cleared + 1)
        XCTAssertEqual(poster.badgeCount, 0)
    }

    func testRoutingAndPendingJumps() async throws {
        XCTAssertTrue(background)
        let dir = "/tmp/ka-visual-route-" + UUID().uuidString.prefix(8)
        let result = try await Child.run(tools.kido, ["server", "--server", dir], env: tools.environment)
        XCTAssertEqual(result.status, 0, result.err)
        let server = try JSONDecoder().decode(Server.self, from: Data(result.out.utf8))
        let created = try await Child.run(server.tmux, ["-u", "-S", server.socket, "new-session", "-d", "-s", "target", "-P", "-F", "#{session_id} #{window_id} #{pane_id}", "exec sleep 300"], env: tools.environment)
        XCTAssertEqual(created.status, 0, created.err)
        let ids = created.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        XCTAssertEqual(ids.count, 3)
        let board = NSPasteboard(name: .init("route-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let app = AppDelegate(runtime: runtime)
        let coldApps = (0..<3).map { _ in AppDelegate(runtime: runtime) }
        let apps = [app] + coldApps
        addTeardownBlock { @MainActor in
            apps.flatMap(\.owners).forEach { $0.close() }
            board.releaseGlobally()
            for session in ["$0", ids[0]] {
                _ = try? await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-session", "-t", session], env: tools.environment)
            }
            try? FileManager.default.removeItem(atPath: dir)
        }
        let first = try XCTUnwrap(app.open(.local, start: false))
        first.testEndpoint = Endpoint(server: server, kido: tools.kido)
        first.start()
        try await wait("first owner snapshot") { first.snapshot?.error == nil && first.snapshot != nil }
        let instance = try XCTUnwrap(first.snapshot?.serverInstance)
        let data = try JSONSerialization.data(withJSONObject: ["host": "local", "instance": ["started_at": instance.startedAt, "pid": instance.pid], "position": ["session": ids[0], "window": ids[1], "pane": ids[2]]])
        let target = try JSONDecoder().decode(NoticeTarget.self, from: data)
        first.perform(.jump(try XCTUnwrap(sidebarRows(first.snapshot).first { $0.target?.session.description == "$0" }?.target)))
        try await wait("first stays in original session") { first.snapshot?.client.session.description == "$0" }
        let second = try XCTUnwrap(app.open(.local, start: false))
        second.testEndpoint = Endpoint(server: server, kido: tools.kido)
        second.start()
        try await wait("second snapshot") { second.snapshot != nil && second.snapshot?.error == nil }
        let other = try await Child.run(server.tmux, ["-u", "-S", server.socket, "new-window", "-d", "-t", ids[0], "exec sleep 300"], env: tools.environment)
        XCTAssertEqual(other.status, 0, other.err)
        try await wait("other target-session window observed") {
            sidebarRows(second.snapshot).contains { $0.target?.session == target.position.session && $0.target?.pane != target.position.pane }
        }
        let otherPosition = try XCTUnwrap(sidebarRows(second.snapshot).first { $0.target?.session == target.position.session && $0.target?.pane != target.position.pane }?.target)
        second.perform(.jump(otherPosition))
        try await wait("second in target session") { second.snapshot?.client.pane == otherPosition.pane }
        app.route(target)
        try await wait("target owner selected") { second.snapshot?.client.pane == target.position.pane }
        XCTAssertEqual(first.snapshot?.client.session.description, "$0")

        for (mode, cold) in zip(["matching", "mismatched", "expired"], coldApps) {
            let selected = try await Child.run(server.tmux, ["-u", "-S", server.socket, "select-window", "-t", otherPosition.window.description], env: tools.environment)
            XCTAssertEqual(selected.status, 0, selected.err)
            let pending: NoticeTarget
            if mode == "mismatched" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                object["instance"] = ["started_at": instance.startedAt, "pid": instance.pid + 1]
                pending = try JSONDecoder().decode(NoticeTarget.self, from: JSONSerialization.data(withJSONObject: object))
            } else { pending = target }
            cold.route(pending, now: mode == "expired" ? Date().addingTimeInterval(-31) : Date())
            XCTAssertTrue(cold.owners.isEmpty)
            cold.routes.ready(isDefaultLaunch: false) { host, cause in
                let owner = cold.open(host, start: false, cause: cause)!
                owner.testEndpoint = Endpoint(server: server, kido: tools.kido)
                owner.start()
            }
            let owner = try XCTUnwrap(cold.owners.first)
            try await wait("pending baseline \(mode)") { owner.snapshot != nil && !owner.feedFresh }
            let landed = try XCTUnwrap(owner.snapshot?.client)
            if mode == "matching" {
                try await wait("pending jump lands") { owner.snapshot?.client.pane == target.position.pane }
            } else {
                XCTAssertNotEqual(landed.pane, target.position.pane)
                owner.testReceive(try XCTUnwrap(owner.snapshot))
                XCTAssertEqual(owner.snapshot?.client.pane, landed.pane)
            }
        }
    }

}
