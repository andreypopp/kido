import AppKit
import XCTest
@testable import Kido

@MainActor final class FileMenuTests: VisualTestCase {
    func testNewLocalWindowWithRemoteOwner() throws {
        XCTAssertTrue(background)
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("kido-file-menu-\(UUID().uuidString)"))))
        let app = AppDelegate(runtime: runtime)
        let remote = try XCTUnwrap(app.open(.remote("example.invalid"), start: false))
        app.routes.ready(isDefaultLaunch: true) { _ = app.open($0, start: false) }
        defer { app.owners.forEach { $0.close() } }
        app.newLocalWindow()
        XCTAssertEqual(app.owners.count, 2)
        XCTAssertTrue(app.owners.first === remote)
        XCTAssertEqual(app.owners.filter { $0.host == .local }.count, 1)
        XCTAssertTrue(app.owners.allSatisfy { !$0.window.isVisible })
    }

    func testRemoteDialogResponses() {
        let routes = WindowRoutes()
        var opened: [Kido.Host] = []
        routes.ready(isDefaultLaunch: true) { opened.append($0) }
        let dialog = RemoteHostDialog(routes: routes)
        dialog.field.stringValue = "user@alias"
        XCTAssertTrue(dialog.handle(.alertSecondButtonReturn))
        XCTAssertTrue(opened.isEmpty)
        for invalid in ["", "-option", "bad host"] {
            dialog.field.stringValue = invalid
            XCTAssertFalse(dialog.handle(.alertFirstButtonReturn))
            XCTAssertEqual(dialog.field.stringValue, invalid)
            XCTAssertTrue(opened.isEmpty)
        }
        dialog.field.stringValue = " user@alias "
        XCTAssertTrue(dialog.handle(.alertFirstButtonReturn))
        XCTAssertEqual(opened, [.remote("user@alias")])
    }

    func testLocalMenuRespectsColdRemoteGate() {
        let app = AppDelegate()
        var opened: [Kido.Host] = []
        app.routes.ready(isDefaultLaunch: false) { opened.append($0) }
        app.newLocalWindow()
        XCTAssertTrue(opened.isEmpty)
        app.routes.connect(.remote("alias"))
        app.newLocalWindow()
        XCTAssertEqual(opened, [.remote("alias"), .local])
    }
}
