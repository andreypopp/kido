import AppKit
import KoClient
import PaneGeometry
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

    func testClosingSavesAPendingMoveAndAFailedFullscreenEntry() throws {
        let name = "WindowOwnerFrameTests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let board = NSPasteboard(name: .init("ko-owner-frame-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let dir = try stateDir()
        let frames = WindowFrames(preferences: preferences, serverDir: dir)
        for failedFullscreen in [false, true] {
            let owner = WindowOwner(host: .local, runtime: runtime, start: false, preferences: preferences)
            owner.testServerDir = dir
            let moved = CGRect(x: 100, y: 150, width: 950, height: 650)
            owner.window.setFrame(moved, display: false)
            let notification = Notification(name: NSWindow.didMoveNotification, object: owner.window)
            if failedFullscreen {
                owner.windowWillEnterFullScreen(notification)
                owner.windowDidFailToEnterFullScreen(owner.window)
                owner.window.setFrame(CGRect(x: 140, y: 170, width: 950, height: 650), display: false)
            }
            owner.windowDidMove(notification)
            let expected = owner.window.frame
            owner.close()
            XCTAssertEqual(frames.frame(for: .local), expected)
        }
    }

    private func names(_ owner: WindowOwner) -> [String] { owner.snapshot?.sessions.map(\.name) ?? [] }

    func testTheOwnerStartsTheServerCreatesTheFirstSessionAndThenShowsTheLayoutOfTheServer() throws {
        let dir = try stateDir()
        let owner = try owner(dir)
        wait("the first session") { self.names(owner) == ["session"] && owner.testBanner.isHidden }
        XCTAssertNotNil(owner.snapshot)
        XCTAssertTrue(owner.canNavigate)
        owner.renameSession(SessionID(number: 1), "main") { error in XCTAssertNil(error) }
        wait("the server's changed layout") { self.names(owner) == ["main"] }
        XCTAssertTrue(owner.window.title.hasPrefix("main — "))
        XCTAssertEqual(owner.sidebar.tabs.entries.map(\.id), owner.navigation.windows.map(\.id))
    }

    func testClosingAnOwnerBeforeItsLaunchTaskRunsDoesNotStartAServer() async throws {
        let dir = try stateDir()
        let owner = try owner(dir)
        owner.close()
        await Task.yield()
        await KoServer.finishLaunches(dir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/socket"))
    }

    func testAServerThatCannotStartShowsTheStartBanner() throws {
        let dir = try stateDir()
        let file = dir + "/file"
        FileManager.default.createFile(atPath: file, contents: Data())
        let owner = try owner(file + "/server")
        wait("the failure") { owner.testBanner.testText.title == "Kido could not start the ko server" }
        XCTAssertEqual(owner.testBanner.testText.button, "Start")
        XCTAssertFalse(owner.testBanner.testText.detail.isEmpty)
        XCTAssertFalse(owner.canNavigate)
    }

    func testARestartedServerIsAFreshWelcomeAndTheOwnerShowsItsNewLayout() throws {
        let dir = try server()
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"before","windows":[{"name":"w","tree":{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}}]}]}}"#, dir: dir)
        let owner = try owner(dir)
        wait("the first layout") { self.names(owner) == ["before"] }
        let client = try XCTUnwrap(owner.testClient)
        owner.testEditor { edit in
            var done = try client.edit(edit)
            if case .renameSession(let rename) = edit, rename.name == "held" {
                done.snapshot.revision = 99
            }
            return done
        }
        owner.renameSession(SessionID(number: 1), "held") { _ in }
        wait("an edit held for a revision that the old server never reaches") { self.names(owner) == ["held"] }
        XCTAssertTrue(owner.testEditing)

        try run(["kill-server"], dir: dir)
        wait("the owner starts a replacement server and its first session") {
            FileManager.default.fileExists(atPath: dir + "/socket") && self.names(owner) == ["session"] && !owner.testEditing
        }
        owner.renameSession(SessionID(number: 1), "after") { error in XCTAssertNil(error) }
        wait("the layout of the new server") { self.names(owner) == ["after"] }
        XCTAssertTrue(owner.window.title.hasPrefix("after — "))
        XCTAssertFalse(owner.testEditing, "the fresh welcome ended the hold")
    }

    func testAFailedRestartShowsStartForAManualRetry() throws {
        let dir = try stateDir()
        let owner = try owner(dir)
        wait("the first session") { self.names(owner) == ["session"] && owner.testBanner.isHidden }
        let file = dir + "/file"
        FileManager.default.createFile(atPath: file, contents: Data())
        owner.testServerDir = file + "/server"
        try run(["kill-server"], dir: dir)
        wait("the failed restart") { owner.testBanner.testText.title == "Could not start the ko server" }
        XCTAssertEqual(owner.testBanner.testText.button, "Start")
        XCTAssertFalse(owner.testBanner.testText.detail.isEmpty)
        owner.testServerDir = dir
        owner.start()
        wait("the manual restart") { self.names(owner) == ["session"] && owner.testBanner.isHidden }
    }

    func testNavigationSelectsAndSwitchesThroughTheCore() throws {
        let dir = try server()
        let sleep = #"{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}"#
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"one","windows":[{"name":"a","tree":\#(sleep)},{"name":"b","tree":\#(sleep)}]},{"name":"two","windows":[{"name":"c","tree":\#(sleep)}]}]}}"#, dir: dir)
        let owner = try owner(dir)
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

    func testRuntimeShutdownMenuAndPalette() throws {
        let dir = try stateDir()
        try FileManager.default.createDirectory(atPath: dir + "/.config/ko", withIntermediateDirectories: true)
        try "runtimes:\n  deb: {command: {}}\n".write(toFile: dir + "/.config/ko/config.yaml", atomically: true, encoding: .utf8)
        _ = try server(at: dir, environment: ["KO_RUNTIME_COMMAND_KIND": "1"])
        let owner = try owner(dir)
        wait("the runtime model") { owner.canNavigate && owner.runtimes.count == 1 }
        XCTAssertFalse(owner.canShutDownRuntime("deb"))
        let delegate = AppDelegate()
        let runtimeMenu = NSMenu()
        owner.testRuntimes = ([
            KoSchema.ClientRuntime(kind: .command, name: "down", state: .down),
            KoSchema.ClientRuntime(kind: .command, name: "starting", state: .starting),
            KoSchema.ClientRuntime(kind: .command, name: "up", state: .up),
            KoSchema.ClientRuntime(kind: .command, name: "failed", state: .failed(.init(message: "failed"))),
        ], nil)
        delegate.updateRuntimesMenu(runtimeMenu, owner: owner)
        XCTAssertEqual(runtimeMenu.items.map(\.isEnabled), [false, true, true, false])
        owner.testRuntimes = nil
        let dead = try createPane(#"{"runtime":"deb","command":{"type":"argv","argv":["/usr/bin/true"]}}"#, dir: dir)
        let deadID = try XCTUnwrap(PaneID(ko: dead))
        wait("the dead runtime pane") { owner.testModel?.pane(deadID)?.dead != nil }
        let pane = try createPane(#"{"runtime":"deb","command":{"type":"argv","argv":["/bin/sleep","60"]}}"#, dir: dir)
        wait("the starting runtime") { owner.canShutDownRuntime("deb") && owner.runtimePaneCount("deb") == 1 }
        let menu = NSMenuItem(title: "Shut Down", action: nil, keyEquivalent: "")
        menu.representedObject = "deb"
        owner.shutDownRuntimeItem(menu)
        let pending = try XCTUnwrap(owner.preparedAlert)
        XCTAssertEqual(pending.alert.messageText, "Shut down “deb”?")
        XCTAssertEqual(pending.alert.informativeText, "1 pane runs in this runtime. Shutting it down ends the pane.")
        XCTAssertTrue(try output(["api", "/panes"], dir: dir).contains(pane))
        owner.respondToAlert(.alertFirstButtonReturn)
        wait("the runtime stopped") { owner.runtimes.first?.state == .down && owner.runtimePaneCount("deb") == 0 }
        XCTAssertFalse(owner.canShutDownRuntime("deb"))
        _ = try createPane(#"{"runtime":"deb","command":{"type":"argv","argv":["/bin/sleep","60"]}}"#, dir: dir)
        wait("the runtime starts again") { owner.canShutDownRuntime("deb") && owner.runtimePaneCount("deb") == 1 }
        let row = try XCTUnwrap(PaletteEntry.runtimeStep(owner.runtimes.first.map { RuntimeMark($0) }, owner: owner, responder: nil).first { $0.id == .runtimeDown })
        if case .run(let run) = row.operation { run() } else { XCTFail("Not an action") }
        let sheet = try XCTUnwrap(owner.preparedAlert)
        XCTAssertEqual(sheet.alert.buttons.first?.title, "Shut Down")
        owner.respondToAlert(.alertFirstButtonReturn)
        wait("the palette stops the runtime") { owner.runtimes.first?.state == .down && owner.runtimePaneCount("deb") == 0 }
        let empty = try createPane(#"{"runtime":"deb","command":{"type":"argv","argv":["/bin/sleep","60"]}}"#, dir: dir)
        wait("the runtime is up") { owner.runtimes.first?.state == .up }
        try run(["api", "-X", "DELETE", "/panes/" + empty], dir: dir)
        wait("no runtime panes") { owner.runtimePaneCount("deb") == 0 }
        owner.shutDownRuntime("deb")
        XCTAssertNil(owner.preparedAlert)
        wait("the empty runtime stopped") { owner.runtimes.first?.state == .down }
    }

    func testRuntimeConfirmationDoesNotStopAReplacementServer() throws {
        enum Command { case runtime, pane }
        for command in [Command.runtime, .pane] {
            let dir = try stateDir()
            try FileManager.default.createDirectory(atPath: dir + "/.config/ko", withIntermediateDirectories: true)
            try "runtimes:\n  deb: {command: {}}\n".write(toFile: dir + "/.config/ko/config.yaml", atomically: true, encoding: .utf8)
            _ = try server(at: dir, environment: ["KO_RUNTIME_COMMAND_KIND": "1"])
            let owner = try owner(dir)
            wait("connected with the first session") { self.names(owner) == ["session"] }
            let pane = try createPane(#"{"runtime":"deb","command":{"type":"shell","command":"printf '\\033]133;C\\007'; exec /bin/sleep 60"}}"#, dir: dir)
            let paneID = try XCTUnwrap(PaneID(ko: pane))
            wait("the running runtime pane") { owner.runtimes.first?.state == .up && owner.testModel?.pane(paneID)?.mark == .running }
            let instance = try XCTUnwrap(owner.snapshot?.serverInstance)
            switch command {
            case .runtime: owner.shutDownRuntime("deb")
            case .pane: owner.confirmClose(.pane(paneID), name: "old pane")
            }
            XCTAssertNotNil(owner.preparedAlert)
            let environment = ["HOME": dir, "PATH": "/usr/bin:/bin"]
            XCTAssertEqual(try runTool(tools.ko, ["kill-server", "--server", dir], env: environment).status, 0)
            let replacementServer = try ko(["server"], dir: dir, environment: ["KO_RUNTIME_COMMAND_KIND": "1"])
            addTeardownBlock {
                if replacementServer.isRunning { replacementServer.terminate() }
                replacementServer.waitUntilExit()
            }
            let deadline = Date(timeIntervalSinceNow: 5)
            while try runTool(tools.ko, ["api", "--server", dir, "/version"], env: environment).status != 0 {
                guard Date() < deadline else { return XCTFail("The replacement server did not start") }
            }
            wait("the replacement welcome") { owner.canNavigate && owner.snapshot?.serverInstance != instance && self.names(owner) == ["session"] }
            let replacement = try createPane(#"{"runtime":"deb","command":{"type":"argv","argv":["/bin/sleep","60"]}}"#, dir: dir)
            let replacementID = try XCTUnwrap(PaneID(ko: replacement))
            XCTAssertEqual(replacementID, paneID)
            wait("the replacement runtime") { owner.runtimes.first?.state == .up && owner.testModel?.pane(replacementID)?.dead == nil }
            owner.respondToAlert(.alertFirstButtonReturn)
            let quiet = expectation(description: "the replacement stays up")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { quiet.fulfill() }
            wait(for: [quiet], timeout: 2)
            XCTAssertEqual(owner.runtimes.first?.state, .up)
            XCTAssertNotNil(owner.testModel?.pane(replacementID))
            XCTAssertNil(owner.testModel?.pane(replacementID)?.dead)
        }
    }

    func testClosingAWindowDeletesItOnTheServer() throws {
        let dir = try server()
        let sleep = #"{"pane":{"new":{"command":{"type":"argv","argv":["/bin/sleep","60"]}}}}"#
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"s","windows":[{"name":"a","tree":\#(sleep)},{"name":"b","tree":\#(sleep)}]}]}}"#, dir: dir)
        let owner = try owner(dir)
        wait("two windows") { owner.navigation.windows.count == 2 }
        owner.confirmClose(.window(WindowID(number: 2)), name: "b")
        XCTAssertEqual(owner.preparedAlert?.alert.informativeText, "Programs are still running in this window. Closing the window will end them.")
        XCTAssertEqual(owner.navigation.windows.count, 2)
        owner.respondToAlert(.alertFirstButtonReturn)
        wait("one window") { owner.navigation.windows.map(\.name) == ["a"] }
    }

    func testAServerOfAnotherTerminalRevisionOpensTheRestartSheetAndCloseKeepsTheBanner() throws {
        let own = KoClient.version
        let dir = try stateDir()
        let server = try KoFakeServer(directory: dir, version: #"{"protocol":"\#(own.protocolVersion)","vt":"abc","build":"theirs"}"#)
        addTeardownBlock { server.stop() }
        let owner = try owner(dir)
        wait("the sheet") { owner.preparedAlert != nil }
        let alert = try XCTUnwrap(owner.preparedAlert).alert
        XCTAssertEqual(alert.messageText, "Restart the local ko server")
        XCTAssertTrue(alert.informativeText.contains("abc"), alert.informativeText)
        XCTAssertTrue(alert.informativeText.contains("theirs"), alert.informativeText)
        XCTAssertEqual(alert.buttons.map(\.title), ["Restart Server", "Close"])
        let defaultDir = KoClient.defaultDir()
        let defaultAlert = WindowOwner.mismatchAlert(host: .local, code: KO_ERR_VT_MISMATCH, server: own, own: own, serverDir: defaultDir)
        XCTAssertEqual(defaultAlert.accessoryView?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue, "ko kill-server --server '\(defaultDir)'")
        owner.respondToAlert(.alertSecondButtonReturn)
        XCTAssertEqual(owner.testBanner.testText.title, "Disconnected from Local")
        XCTAssertEqual(owner.testBanner.testText.button, "Reconnect")
        XCTAssertFalse(owner.testBanner.isHidden)
        XCTAssertFalse(owner.canNavigate)
    }

    func testRestartReplacesAnIncompatibleProcessWithTheBundledServerAndCreatesTheFirstSession() throws {
        let dir = try mismatchServer()
        let owner = try owner(dir)
        wait("the mismatch sheet") { owner.preparedAlert != nil }
        let alert = try XCTUnwrap(owner.preparedAlert).alert
        XCTAssertEqual(alert.buttons.map(\.title), ["Restart Server", "Close"])
        XCTAssertTrue(alert.informativeText.contains("different version"))
        XCTAssertTrue(alert.informativeText.contains("incompatible-test"))
        XCTAssertTrue(alert.informativeText.contains(KoClient.version.build))
        let command = try XCTUnwrap(alert.accessoryView?.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(command.isSelectable)
        XCTAssertEqual(command.stringValue, "ko kill-server --server '\(dir)'")
        XCTAssertEqual(alert.window.defaultButtonCell, alert.buttons[1].cell as? NSButtonCell)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        owner.respondToAlert(.alertFirstButtonReturn)
        wait("the bundled server attaches and creates the first session") { self.names(owner) == ["session"] && owner.testBanner.isHidden }
        let version = try JSONDecoder().decode([String: String].self, from: Data(output(["api", "/version"], dir: dir).utf8))
        XCTAssertEqual(version["vt"], KoClient.version.vt)
        XCTAssertEqual(version["build"], KoClient.version.build)
    }

    func testARefusedHelloShowsTheServerErrorWithoutTheWelcomeTimeout() throws {
        let dir = try stateDir()
        let server = try KoFakeServer(directory: dir, version: nil, refusal: "missing field `required_extra`")
        defer { server.stop() }
        let owner = try owner(dir)
        wait("the refusal") { owner.testBanner.testText.button == "Restart Server" }
        XCTAssertTrue(owner.testBanner.testText.detail.hasPrefix("missing field `required_extra`"))
        XCTAssertEqual(owner.testBanner.testText.title, "The ko server refused the connection")
    }

    func testRestartAfterRefusalReplacesTheLocalServerAndItsPanes() throws {
        let dir = try stateDir()
        let owner = try owner(dir)
        wait("the first session") { self.names(owner) == ["session"] && owner.testBanner.isHidden }
        owner.renameSession(SessionID(number: 1), "before-restart") { error in XCTAssertNil(error) }
        wait("the old session") { self.names(owner) == ["before-restart"] }
        owner.refused("hello refused")
        let stack = try XCTUnwrap(owner.testBanner.subviews.first as? NSStackView)
        try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSButton }.first).performClick(nil)
        wait("the replacement server") { self.names(owner) == ["session"] && owner.testBanner.isHidden }
    }

    func testARefusalShowsTheServerTextAndOnlyLocalOffersRestart() throws {
        let dir = try stateDir()
        let local = try owner(dir, start: false)
        local.refused("missing field `required_extra`")
        XCTAssertEqual(local.testBanner.testText.title, "The ko server refused the connection")
        XCTAssertTrue(local.testBanner.testText.detail.hasPrefix("missing field `required_extra`"))
        XCTAssertTrue(local.testBanner.testText.detail.contains(WindowOwner.restartWarning))
        XCTAssertEqual(local.testBanner.testText.button, "Restart Server")
        XCTAssertFalse(local.canNavigate)
        let remote = WindowOwner(host: .remote("example"), runtime: local.runtime, start: false)
        defer { remote.close() }
        remote.refused("missing field `required_extra`")
        XCTAssertEqual(remote.testBanner.testText.detail, "missing field `required_extra`")
        XCTAssertEqual(remote.testBanner.testText.button, "Reconnect")
        XCTAssertNil(remote.preparedAlert)
    }

    func testAServerThatNeverWelcomesEndsInTheStartBannerAtTheDeadline() throws {
        let dir = try stateDir()
        let server = try KoFakeServer(directory: dir, version: nil)
        let timeout = WindowOwner.welcomeTimeout
        WindowOwner.welcomeTimeout = 0.3
        addTeardownBlock { @MainActor in
            WindowOwner.welcomeTimeout = timeout
            server.stop()
        }
        let owner = try owner(dir)
        wait("the deadline") { owner.testBanner.testText.title == "Kido could not reach Local" }
        XCTAssertTrue(owner.testBanner.testText.detail.contains("did not welcome"), owner.testBanner.testText.detail)
        XCTAssertEqual(owner.testBanner.testText.button, "Start")
    }
}
