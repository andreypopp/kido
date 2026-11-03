import KoModel
import XCTest
@testable import Kido

// Records the model documents that SidebarFeedTests and TmuxControlTests decode, from a private ko server:
// make ko-fixtures. Without KO_RECORD_FIXTURES the test is skipped.
@MainActor final class KoFixtureRecorder: KoTestCase {
    // The model as the app decodes it, written with sorted keys.
    private func write(_ model: KoModel, _ path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try encoder.encode(model).write(to: URL(fileURLWithPath: path))
    }

    private func shell(_ script: String, vars: String = "{}") -> String {
        let command = try! String(decoding: JSONSerialization.data(withJSONObject: ["type": "shell", "command": script]), as: UTF8.self)
        return #"{"pane":{"new":{"vars":\#(vars),"command":\#(command)}}}"#
    }

    func testRecordTheTreeModel() throws {
        guard let destination = ProcessInfo.processInfo.environment["KO_RECORD_FIXTURES"], !destination.isEmpty else { throw XCTSkip("set KO_RECORD_FIXTURES to record") }
        let dir = try server()
        let echo = "stty raw -echo; exec cat"
        let build = #"{"split":"h","children":[\#(shell("printf '\\033]7501;state=working:app=claude-code\\007'; " + echo)),\#(shell("printf '\\033]7501;state=blocked:kind=permission:app=claude-code:title=TWVzc2FnZQ==\\007'; " + echo))]}"#
        let pi = shell("printf '\\033]7501;state=working:app=pi\\007'; " + echo, vars: #"{"pi.session":"s1","pi.name":"Worker"}"#)
        let failed = shell("printf '\\033]133;C;cmdline_url=false\\007\\033]133;D;1\\007\\033]133;A\\007'; " + echo)
        let running = shell("printf '\\033]133;C;cmdline_url=make\\007'; " + echo)
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"main","windows":[{"name":"build","tree":\#(build)},{"name":"running","tree":\#(running)},{"name":"failed","tree":\#(failed)},{"name":"pi","tree":\#(pi)}]},{"name":"other","windows":[{"name":"plain","tree":\#(shell(echo))}]}]}}"#, dir: dir)
        let client = try connect(dir, panes: 6) { _ in }
        wait("every pane has its status") {
            guard let panes = (try? client.model())?.panes else { return false }
            let phases = panes.compactMap { pane -> KoSchema.Phase? in
                if case .terminal(let shell)? = pane.status?.kind { shell.phase } else { nil }
            }
            let ran = phases.contains { if case .idle(let idle) = $0 { idle.last != nil } else { false } }
            let running = phases.contains { if case .running = $0 { true } else { false } }
            return ran && running && panes.allSatisfy { $0.status != nil }
        }
        let piPane = try XCTUnwrap(try client.model().panes.first { if case .piAgent = $0.status?.kind { true } else { false } }?.id)
        let first = try output(["run-child", "--session", "session_1", "--name", "first", piPane.description, "--", "/bin/sleep", "60"], dir: dir)
        let firstRun = try XCTUnwrap(try JSONDecoder().decode([String: String].self, from: Data(first.utf8))["id"])
        _ = try output(["run-child", "--session", "session_1", "--name", "nested", firstRun, "--", "/bin/sleep", "60"], dir: dir)
        _ = try output(["run", "--session", "session_1", "--name", "ended", "--", "/bin/sh", "-c", "exit 3"], dir: dir)
        wait("the runs") { (try? client.model())?.runs.count == 3 }
        wait("the ended pane") { (try? client.model())?.panes.contains { $0.dead != nil } == true }
        wait("every live pane has its status") { (try? client.model())?.panes.allSatisfy { $0.dead != nil || $0.status != nil } == true }
        try write(client.model(), destination + "/SidebarFeed/Tests/SidebarFeedTests/Fixtures/ko-tree.json")
    }

    func testRecordTheLayoutModel() throws {
        guard let destination = ProcessInfo.processInfo.environment["KO_RECORD_FIXTURES"], !destination.isEmpty else { throw XCTSkip("set KO_RECORD_FIXTURES to record") }
        let dir = try server()
        let cat = shell("stty raw -echo; exec cat")
        let tiles = #"{"split":"h","children":[\#(cat),{"split":"v","children":[\#(cat),\#(cat)]}]}"#
        let fresh = String(cat.dropFirst(8).dropLast())
        let floats = #"[{"pane":\#(fresh),"x":6,"y":4,"cols":28,"rows":8},{"pane":\#(fresh),"x":12,"y":6,"cols":20,"rows":6,"z":3}]"#
        let pair = #"{"split":"h","children":[\#(cat),\#(cat)]}"#
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"main","windows":[{"name":"tiles","tree":\#(tiles),"floats":\#(floats)},{"name":"zoomed","tree":\#(pair)}]}]}}"#, dir: dir)
        let client = try connect(dir, panes: 7) { _ in }
        let zoomed = try XCTUnwrap(client.model().layout.layout.windows.last?.panes.last)
        _ = try client.edit(.toggleZoom(KoSchema.EditToggleZoom(pane: zoomed)))
        wait("the zoom") { (try? client.model())?.layout.layout.windows.last?.zoom == zoomed }
        wait("every pane has its status") { (try? client.model())?.panes.allSatisfy { $0.status != nil } == true }
        try write(client.model(), destination + "/TmuxControl/Tests/TmuxControlTests/Fixtures/ko-layout.json")
    }
}
