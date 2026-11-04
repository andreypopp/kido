import AppKit
import KoClient
import KoModel
import SidebarFeed
import PaneGeometry
import XCTest
@testable import Kido

// Tabs, seen marks, prompts, the empty document and window switching of a WindowOwner on a private server.
@MainActor final class OwnerModelTests: KoTestCase {
    private func owner(_ dir: String) throws -> WindowOwner {
        let board = NSPasteboard(name: .init("ko-model-" + UUID().uuidString))
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        owner.testServerDir = dir
        owner.testAttended = false
        addTeardownBlock { @MainActor in
            owner.close()
            board.releaseGlobally()
        }
        owner.start()
        return owner
    }

    private func shell(_ script: String, vars: String = "{}") -> String {
        let command = try! String(decoding: JSONSerialization.data(withJSONObject: ["type": "shell", "command": script]), as: UTF8.self)
        return #"{"pane":{"new":{"vars":\#(vars),"command":\#(command)}}}"#
    }

    private let cat = "stty raw -echo; exec cat"

    private func shown(_ windows: String) throws -> (dir: String, owner: WindowOwner) {
        let dir = try server()
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"s","windows":\#(windows)}]}}"#, dir: dir)
        let owner = try owner(dir)
        wait("the owner shows the layout") { owner.testBanner.isHidden && owner.snapshot != nil }
        return (dir, owner)
    }

    private func items(_ owner: WindowOwner) -> [Item] {
        func items(_ node: SidebarFeed.Node) -> [Item] {
            switch node {
            case .item(let item): [item] + item.children.flatMap(items)
            case .window(let group): group.children.flatMap { [$0] + $0.children.flatMap(items) }
            }
        }
        return owner.snapshot?.sessions.flatMap { $0.nodes.flatMap(items) } ?? []
    }

    func testATabIsTitledByItsFocusPaneAndAPiAgentWithAnOpenMessageStreamIsMessageable() throws {
        let checkout = try XCTUnwrap(ProcessInfo.processInfo.environment["KO_CHECKOUT"].flatMap { $0.isEmpty ? nil : $0 }, "KO_CHECKOUT")
        let printf = "printf '\\033]7501;state=idle:app=pi\\007'; " + cat
        let streaming = "printf '\\033]7501;state=idle:app=pi\\007'; \(checkout)/build/ko/bin/ko api --stream \"/panes/$KO_PANE/messages\" </dev/null >/dev/null & " + cat
        let pi = shell(streaming, vars: #"{"pi.session":"s1","pi.name":"Worker"}"#)
        let mute = shell(printf, vars: #"{"pi.session":"s2","pi.name":"Mute"}"#)
        let (_, owner) = try shown(#"[{"name":"first","tree":\#(pi)},{"name":"second","tree":\#(mute)}]"#)
        wait("both tabs are pi agents") { owner.sidebar.tabs.entries.count == 2 && owner.sidebar.tabs.entries.allSatisfy(\.agent) }
        wait("the pane with a message stream takes a prompt") { owner.sidebar.tabs.entries.map(\.messageable) == [true, false] }
        let tabs = owner.sidebar.tabs.entries
        XCTAssertEqual(tabs.map(\.displayName), ["@Worker", "Mute"])
        XCTAssertEqual(owner.navigation.windows.map(\.name), ["first", "second"], "the window keeps its name")
    }

    func testAnOutcomeShownByOneAttendedWindowIsSeenInEveryWindowOfTheHost() throws {
        let failing = "while [ ! -e \"$HOME/go\" ]; do sleep 0.02; done; printf '\\033]133;C;cmdline_url=false\\007\\033]133;D;1\\007\\033]133;A\\007'; " + cat
        let (dir, first) = try shown(#"[{"name":"w","tree":\#(shell(failing))}]"#)
        let second = try owner(dir)
        wait("the second owner shows the layout") { second.snapshot != nil }
        FileManager.default.createFile(atPath: dir + "/go", contents: nil)
        for owner in [first, second] {
            wait("the failure is unseen") { self.items(owner).first?.mark == .failed }
        }
        XCTAssertEqual(sidebarRows(second.snapshot).first { $0.target != nil }?.status, .error)
        first.testAttended = true
        for owner in [first, second] {
            wait("the failure is seen") { self.items(owner).first?.mark == KoSchema.Mark.none_ }
        }
        XCTAssertEqual(sidebarRows(second.snapshot).first { $0.target != nil }?.status, .quiet,
                       "the other window of the host agrees without a shared record")
    }

    func testAPromptResolvesItsCandidatesAndSendsThroughTheCore() throws {
        let agent = shell("printf '\\033]7501;state=idle:app=claude-code\\007'; " + cat)
        let (_, owner) = try shown(#"[{"name":"w","tree":{"split":"h","children":[\#(shell(cat)),\#(agent)]}}]"#)
        wait("the agent") { self.items(owner).contains { if case .live(.someAgent) = $0.lifecycle { true } else { false } } }
        var candidates: WindowOwner.PromptReply?
        owner.prompt(.resolve(from: PaneID(number: 1))) { candidates = try? $0.get() }
        wait("the candidates") { candidates != nil }
        guard case .candidates(let found)? = candidates else { return XCTFail("no candidates") }
        XCTAssertEqual(found.map(\.pane), [PaneID(number: 2)])
        var sent: Result<WindowOwner.PromptReply, Error>?
        owner.prompt(.send(from: PaneID(number: 1), to: PaneID(number: 2), text: "hello")) { sent = $0 }
        wait("the prompt is sent") { sent != nil }
        XCTAssertEqual(try sent?.get(), .sent)
        var refused: Result<WindowOwner.PromptReply, Error>?
        owner.prompt(.send(from: PaneID(number: 2), to: PaneID(number: 1), text: "hello")) { refused = $0 }
        wait("a pane that is no candidate") { refused != nil }
        XCTAssertThrowsError(try refused?.get()) { XCTAssertEqual(($0 as? KoError)?.code, KO_ERR_INVALID) }
    }

    func testConnectingToAnEmptyServerCreatesOneSessionButDeletingItDoesNotRecreateIt() throws {
        let dir = try server()
        let owner = try owner(dir)
        wait("one session without Start") { owner.navigation.sessions.count == 1 && owner.testBanner.isHidden }
        wait("the pane's directory") { owner.testModel?.panes.first?.cwd.isEmpty == false }
        XCTAssertEqual(URL(fileURLWithPath: owner.testModel?.panes.first?.cwd ?? "").standardizedFileURL,
                       URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL)
        let id = try XCTUnwrap(owner.testModel?.layout.layout.sessions.first?.id)
        try run(["api", "-X", "DELETE", "/sessions/\(id)"], dir: dir)
        wait("the deliberate empty layout") { owner.testModel?.layout.layout.sessions.isEmpty == true && owner.testBanner.testText.title == "No sessions" && !owner.testEditing }
        XCTAssertEqual(owner.testBanner.testText.button, "Start")
        mainQueueDrained()
        XCTAssertEqual(owner.testModel?.layout.layout.sessions.count, 0)
        owner.start()
        wait("Start still creates a session") { owner.navigation.sessions.count == 1 && owner.testBanner.isHidden }
    }

    func testTwoOwnersConnectingToAnEmptyServerCreateExactlyOneSession() throws {
        let dir = try server()
        let first = try owner(dir)
        let second = try owner(dir)
        wait("both owners show one session") { first.navigation.sessions.count == 1 && second.navigation.sessions.count == 1 && first.testBanner.isHidden && second.testBanner.isHidden && !first.testEditing && !second.testEditing }
        let layout = try JSONDecoder().decode(KoSchema.Snapshot.self, from: Data(output(["api", "/layout"], dir: dir).utf8))
        XCTAssertEqual(layout.layout.sessions.count, 1)
        XCTAssertEqual(first.testModel?.layout.layout.sessions.first?.id, second.testModel?.layout.layout.sessions.first?.id)
    }

    func testSwitchingWindowsSkipsANestedRunWindow() throws {
        let pi = shell("printf '\\033]7501;state=idle:app=pi\\007'; " + cat, vars: #"{"pi.session":"s1","pi.name":"Parent"}"#)
        let (dir, owner) = try shown(#"[{"name":"parent","tree":\#(pi)},{"name":"last","tree":\#(shell(cat))}]"#)
        let before = Set(try XCTUnwrap(owner.testModel.map(\.layout.layout.windows)).map(\.id))
        try run(["run-child", "--session", "session_1", "--name", "kid", "pane_1", "--", "/bin/sleep", "60"], dir: dir)
        wait("the run window nested under its parent pane") {
            owner.snapshot?.sessions.first?.nodes.count == 2 && owner.snapshot?.sessions.first?.nodes.first?.children.isEmpty == false
        }
        let windows = try XCTUnwrap(owner.testModel.map(\.layout.layout.windows)).map(\.id)
        let nested = try XCTUnwrap(windows.first { !before.contains($0) })
        let top = windows.filter { $0 != nested }
        XCTAssertEqual(owner.navigation.window, top[0])
        owner.perform(.switchWindow(next: true))
        wait("the last top-level window") { owner.navigation.window == top[1] }
        owner.perform(.switchWindow(next: true))
        wait("the first window again") { owner.navigation.window == top[0] }
        let session = try XCTUnwrap(owner.navigation.session)
        owner.perform(.selectWindow(session, nested))
        wait("the nested run window") { owner.navigation.window == nested }
        owner.perform(.switchWindow(next: false))
        wait("its parent") { owner.navigation.window == top[0] }
    }
}
