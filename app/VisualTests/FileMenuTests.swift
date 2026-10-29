import AppKit
import XCTest
@testable import Kido

@MainActor final class FileMenuTests: VisualTestCase {
    func testConnectMenusAndPalette() throws {
        let app = AppDelegate()
        let menu = app.mainMenu()
        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let dock = try XCTUnwrap(app.applicationDockMenu(NSApp))
        let local = try XCTUnwrap(file.items.first { $0.action == #selector(AppDelegate.connectLocalHost) })
        let remote = try XCTUnwrap(file.items.first { $0.action == #selector(AppDelegate.connectRemoteHost) })
        XCTAssertEqual(file.index(of: remote), file.index(of: local) + 1)
        XCTAssertTrue(file.items[file.index(of: local) - 1].isSeparatorItem)
        XCTAssertEqual(local.keyEquivalent, "")
        XCTAssertEqual(local.keyEquivalentModifierMask, [])
        XCTAssertEqual(dock.items.map(\.title), [local.title, remote.title])
        for (item, source) in zip(dock.items, [local, remote]) {
            XCTAssertEqual(item.action, source.action)
            XCTAssertTrue(item.target === app)
            XCTAssertTrue(source.target === app)
        }
        let entries = PaletteEntry.commands(menu, owner: nil, responder: nil)
        var opened: [Kido.Host] = []
        app.routes.ready(isDefaultLaunch: false) { host, cause in
            opened.append(host)
            XCTAssertEqual(cause.label, "new window")
        }
        let entry = try XCTUnwrap(entries.first { $0.title == local.title })
        guard case .run(let run) = entry.operation else { return XCTFail("Local must run the shared action") }
        run()
        app.connectLocalHost()
        XCTAssertEqual(opened, [.local, .local])
    }

    func testLocalConnectCreatesNewOwners() throws {
        let board = NSPasteboard(name: .init("local-connect-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let app = AppDelegate(runtime: runtime)
        defer {
            app.owners.forEach { $0.close() }
            board.releaseGlobally()
        }
        app.connectLocalHost()
        app.routes.ready(isDefaultLaunch: false) { host, cause in _ = app.open(host, start: false, cause: cause) }
        XCTAssertEqual(app.owners.map(\.host), [.local])
        app.owners.forEach { $0.close() }
        _ = app.open(.remote("alias"), start: false)
        app.connectLocalHost()
        app.connectLocalHost()
        XCTAssertEqual(app.owners.filter(\.alive).map(\.host), [.remote("alias"), .local, .local])
    }

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
        let result = try await Child.run(tools.kido, ["server", "--server", dir], env: serverEnvironment)
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
