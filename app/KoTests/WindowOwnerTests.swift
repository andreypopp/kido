import AppKit
import KoClient
import TmuxControl
import XCTest
import KoModel
@testable import Kido

@MainActor final class WindowOwnerTests: KoTestCase {
    private func owner(_ dir: String, start: Bool = true) throws -> WindowOwner {
        let board = NSPasteboard(name: .init("ko-owner-" + UUID().uuidString))
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        owner.testServerDir = dir
        addTeardownBlock { @MainActor in
            owner.close()
            board.releaseGlobally()
        }
        if start { owner.start() }
        return owner
    }

    // A server that the owner launches itself, which the test stops.
    private func launchedDir() throws -> String {
        let dir = try stateDir()
        addTeardownBlock { @MainActor in
            try? self.run(["kill-server"], dir: dir)
            try? FileManager.default.removeItem(atPath: dir)
        }
        return dir
    }

    private func names(_ owner: WindowOwner) -> [String] { owner.snapshot?.sessions.map(\.name) ?? [] }

    func testTheOwnerStartsTheServerShowsNoSessionsAndThenTheLayoutOfTheServer() throws {
        let dir = try launchedDir()
        let owner = try owner(dir)
        wait("the empty server") { owner.testBanner.testText.title == "No sessions" }
        XCTAssertNil(owner.snapshot)

        try put(#"{"revision":0,"layout":{"sessions":[{"name":"main","windows":[{"name":"first","tree":{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}},{"name":"second","tree":{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}}]}]}}"#, dir: dir)
        wait("the sessions") { self.names(owner) == ["main"] }
        wait("the banner goes") { owner.testBanner.isHidden }
        XCTAssertTrue(owner.canNavigate)
        XCTAssertEqual(owner.navigation.windows.map(\.name), ["first", "second"])
        XCTAssertEqual(owner.window.title, "main — first")
        XCTAssertEqual(owner.sidebar.tabs.entries.map(\.id), owner.navigation.windows.map(\.id))
    }

    func testAServerThatCannotStartShowsTheStartBanner() throws {
        let dir = try stateDir()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/file"
        FileManager.default.createFile(atPath: file, contents: Data())
        let owner = try owner(file + "/server")
        wait("the failure") { owner.testBanner.testText.title == "Kido could not start the ko server" }
        XCTAssertEqual(owner.testBanner.testText.button, "Start")
        XCTAssertFalse(owner.testBanner.testText.detail.isEmpty)
        XCTAssertFalse(owner.canNavigate)
    }

    func testARestartedServerIsAFreshWelcomeAndTheOwnerShowsItsNewLayout() throws {
        let dir = try launchedDir()
        let owner = try owner(dir)
        wait("the empty server") { owner.testBanner.testText.title == "No sessions" }
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"before","windows":[{"name":"w","tree":{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}}]}]}}"#, dir: dir)
        wait("the first layout") { self.names(owner) == ["before"] }
        let client = try XCTUnwrap(owner.testClient)
        owner.testEditor { edit in
            var done = try client.edit(edit)
            done.snapshot.revision = 99
            return done
        }
        owner.renameSession(SessionID(number: 1), "held") { _ in }
        wait("an edit held for a revision that the old server never reaches") { self.names(owner) == ["held"] }
        XCTAssertTrue(owner.testEditing)

        try run(["kill-server"], dir: dir)
        wait("the socket is gone") { !FileManager.default.fileExists(atPath: dir + "/socket") }
        _ = try ko(["server"], dir: dir)
        wait("the new server") { FileManager.default.fileExists(atPath: dir + "/socket") }
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"after","windows":[{"name":"w","tree":{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}}]}]}}"#, dir: dir)
        wait("the layout of the new server") { self.names(owner) == ["after"] }
        XCTAssertEqual(owner.window.title, "after — w")
        XCTAssertFalse(owner.testEditing, "the fresh welcome ended the hold")
    }

    func testNavigationSelectsAndSwitchesThroughTheCore() throws {
        let dir = try launchedDir()
        let owner = try owner(dir)
        let sleep = #"{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}"#
        wait("the empty server") { owner.testBanner.testText.title == "No sessions" }
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"one","windows":[{"name":"a","tree":\#(sleep)},{"name":"b","tree":\#(sleep)}]},{"name":"two","windows":[{"name":"c","tree":\#(sleep)}]}]}}"#, dir: dir)
        wait("the windows of the first session") { owner.navigation.windows.map(\.name) == ["a", "b"] }
        XCTAssertEqual(owner.navigation.window, WindowID(number: 1))

        owner.perform(.selectWindow(SessionID(number: 1), WindowID(number: 2)))
        wait("window b") { owner.navigation.window == WindowID(number: 2) }
        owner.perform(.switchWindow(next: true))
        wait("the next window, in the next session") { owner.navigation.window == WindowID(number: 3) && owner.navigation.session == SessionID(number: 2) }
        owner.perform(.switchWindow(next: true))
        wait("the first window again") { owner.navigation.window == WindowID(number: 1) }
        owner.perform(.switchSession(next: true))
        wait("the second session") { owner.navigation.session == SessionID(number: 2) }
        owner.perform(.selectSession(SessionID(number: 1)))
        wait("the first session") { owner.navigation.session == SessionID(number: 1) }
    }

    func testClosingAWindowDeletesItOnTheServer() throws {
        let dir = try launchedDir()
        let owner = try owner(dir)
        let sleep = #"{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}"#
        wait("the empty server") { owner.testBanner.testText.title == "No sessions" }
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"s","windows":[{"name":"a","tree":\#(sleep)},{"name":"b","tree":\#(sleep)}]}]}}"#, dir: dir)
        wait("two windows") { owner.navigation.windows.count == 2 }
        owner.confirmClose(.window(WindowID(number: 2)), name: "b")
        wait("one window") { owner.navigation.windows.map(\.name) == ["a"] }
    }

    func testAServerOfAnotherTerminalRevisionOpensTheRestartSheetAndCloseKeepsTheBanner() throws {
        let own = KoClient.version
        let dir = try stateDir()
        let server = try KoFakeServer(directory: dir, version: #"{"protocol":"\#(own.protocolVersion)","vt":"abc","build":"theirs"}"#)
        addTeardownBlock {
            server.stop()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let owner = try owner(dir)
        wait("the sheet") { owner.preparedAlert != nil }
        let alert = try XCTUnwrap(owner.preparedAlert).alert
        XCTAssertEqual(alert.messageText, "Restart the local ko server")
        XCTAssertTrue(alert.informativeText.contains("abc"), alert.informativeText)
        XCTAssertTrue(alert.informativeText.contains("theirs"), alert.informativeText)
        XCTAssertEqual(alert.buttons.map(\.title), ["Restart", "Close"])
        owner.respondToAlert(.alertSecondButtonReturn)
        XCTAssertEqual(owner.testBanner.testText.title, "Disconnected from Local")
        XCTAssertEqual(owner.testBanner.testText.button, "Reconnect")
        XCTAssertFalse(owner.testBanner.isHidden)
        XCTAssertFalse(owner.canNavigate)
    }

    func testAServerThatNeverWelcomesEndsInTheStartBannerAtTheDeadline() throws {
        let dir = try stateDir()
        let server = try KoFakeServer(directory: dir, version: nil)
        let timeout = WindowOwner.welcomeTimeout
        WindowOwner.welcomeTimeout = 0.3
        addTeardownBlock { @MainActor in
            WindowOwner.welcomeTimeout = timeout
            server.stop()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let owner = try owner(dir)
        wait("the deadline") { owner.testBanner.testText.title == "Kido could not reach Local" }
        XCTAssertTrue(owner.testBanner.testText.detail.contains("did not welcome"), owner.testBanner.testText.detail)
        XCTAssertEqual(owner.testBanner.testText.button, "Start")
    }
}
