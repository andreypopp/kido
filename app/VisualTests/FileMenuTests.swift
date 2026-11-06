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

    func testSessionAndWindowMenusRequireACurrentSessionButCloseWindowDoesNot() throws {
        let board = NSPasteboard(name: .init("empty-menu-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let app = AppDelegate(runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)))
        let owner = try XCTUnwrap(app.open(.local, start: false))
        defer { owner.close() }
        let menu = app.mainMenu()
        for title in ["Session", "Window"] {
            let submenu = try XCTUnwrap(menu.items.first { $0.title == title }?.submenu)
            for item in submenu.items where item.target is SessionMenus {
                XCTAssertFalse((item.target as! SessionMenus).validateMenuItem(item), item.title)
            }
        }
        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let close = try XCTUnwrap(file.items.first { $0.title == "Close Window" })
        XCTAssertTrue(app.validateMenuItem(close))
        let entries = PaletteEntry.commands(menu, owner: owner, responder: nil)
        XCTAssertTrue(entries.contains { $0.title == "Close Window" })
        XCTAssertFalse(entries.contains { ["Rename Session…", "Close Session", "Next Window", "Previous Window"].contains($0.title) })
        app.closeWindow()
        XCTAssertFalse(owner.alive)
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

    func testDockReopenKeepsTheMostRecentWindow() throws {
        let board = NSPasteboard(name: .init("dock-order-" + UUID().uuidString))
        let app = AppDelegate(runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)))
        defer {
            app.owners.forEach { $0.close() }
            board.releaseGlobally()
        }
        let first = try XCTUnwrap(app.open(.local, start: false))
        let second = try XCTUnwrap(app.open(.local, start: false))
        first.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: first.window))
        second.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: second.window))
        XCTAssertTrue(app.reopenOwner === second)
        second.window.setIsVisible(true)
        let order = NSApp.orderedWindows
        let key = NSApp.keyWindow
        XCTAssertTrue(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(NSApp.orderedWindows, order)
        XCTAssertTrue(NSApp.keyWindow === key)
        XCTAssertTrue(app.reopenOwner === second)
        first.window.miniaturize(nil)
        second.window.miniaturize(nil)
        first.window.orderOut(nil)
        second.window.orderOut(nil)
        XCTAssertFalse(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertTrue(app.reopenOwner === second)
        second.close()
        XCTAssertTrue(app.reopenOwner === first)
    }

    func testDockReopenWithoutAWindowOpensAndConnectsLocal() async throws {
        let dir = try await koLaunched()
        let board = NSPasteboard(name: .init("kr-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let app = AppDelegate(runtime: runtime)
        addTeardownBlock { @MainActor in
            app.owners.forEach { $0.close() }
            board.releaseGlobally()
        }
        var dialed: [WindowOwner.DialCause] = []
        app.routes.ready(isDefaultLaunch: true) { host, cause in
            dialed.append(cause)
            let owner = app.open(host, start: false, cause: cause)
            owner?.testServerDir = dir
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
