import AppKit
import XCTest
@testable import Kido

@MainActor final class FileMenuTests: VisualTestCase {
    func testLocalMenuRespectsColdRemoteGate() {
        let app = AppDelegate()
        var opened: [Kido.Host] = []
        app.routes.ready(isDefaultLaunch: false) { host, _ in opened.append(host) }
        app.newSession()
        XCTAssertTrue(opened.isEmpty)
        app.routes.connect(.remote("alias"))
        app.newSession()
        XCTAssertEqual(opened, [.remote("alias"), .local])
    }

    func testDockReopenWithoutAWindowOpensAndConnectsLocal() async throws {
        let dir = "/tmp/kr-" + UUID().uuidString.prefix(8)
        let result = try await Child.run(tools.kido, ["server", "--server", dir], env: tools.environment)
        XCTAssertEqual(result.status, 0, result.err)
        let server = try JSONDecoder().decode(Server.self, from: Data(result.out.utf8))
        let board = NSPasteboard(name: .init("kr-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let app = AppDelegate(runtime: runtime)
        addTeardownBlock { @MainActor in
            app.owners.forEach { $0.close() }
            board.releaseGlobally()
            _ = try? await Child.run(server.tmux, ["-u", "-S", server.socket, "kill-server"], env: tools.environment)
            try? FileManager.default.removeItem(atPath: dir)
        }
        var dialed: [WindowOwner.DialCause] = []
        app.routes.ready(isDefaultLaunch: true) { host, cause in
            dialed.append(cause)
            let owner = app.open(host, start: false, cause: cause)
            owner?.testEndpoint = Endpoint(server: server, kido: tools.kido)
            owner?.start()
        }
        for round in 1...2 {
            XCTAssertFalse(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            XCTAssertEqual(dialed.map(\.label), Array(repeating: "reopen", count: round))
            let owner = try XCTUnwrap(app.owners.last)
            XCTAssertEqual(owner.host, .local)
            try await wait("reopened Local window \(round) connects") { owner.canNavigate && owner.snapshot?.sessions.isEmpty == false }
            owner.close()
            XCTAssertFalse(owner.alive)
        }
    }
}
