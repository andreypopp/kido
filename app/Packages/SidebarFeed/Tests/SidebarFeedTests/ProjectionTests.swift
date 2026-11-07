import Foundation
import KoModel
import Testing
@testable import SidebarFeed

private func recorded() throws -> KoModel {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ko-tree.json")
    return try JSONDecoder().decode(KoModel.self, from: Data(contentsOf: url))
}

private func shape(_ nodes: [SidebarFeed.Node]) -> [String] {
    nodes.map { node in
        switch node {
        case .window(let group): "\(group.id.number)[\(group.children.map { shape([.item($0)])[0] }.joined(separator: ","))]"
        case .item(let item):
            item.children.isEmpty ? "\(item.id.number)" : "\(item.id.number)>\(shape(item.children).joined(separator: ","))"
        }
    }
}

private func items(_ snapshot: Snapshot) -> [PaneID: Item] {
    var found: [PaneID: Item] = [:]
    func walk(_ nodes: [SidebarFeed.Node]) {
        for node in nodes {
            if case .item(let item) = node { found[item.id] = item }
            if case .window(let group) = node { group.children.forEach { found[$0.id] = $0 } }
            walk(node.children)
        }
    }
    snapshot.sessions.forEach { walk($0.nodes) }
    return found
}

@Test func theRecordedModelBecomesTheSidebarTree() throws {
    let snapshot = try #require(Snapshot(model: recorded()))
    #expect(snapshot.sessions.map(\.name) == ["main", "other"])
    #expect(snapshot.client == .init(session: .init(number: 1), window: .init(number: 1), pane: .init(number: 1)))
    #expect(shape(snapshot.sessions[0].nodes) == ["1[1,2]", "3", "4", "5>7>8", "9"])
    #expect(shape(snapshot.sessions[1].nodes) == ["6"])
}

@Test func runClocksUseOnlyLiveChildrenAndActiveRecords() throws {
    var model = try recorded()
    model.panes[0].parent = .init(number: 5)
    model.panes[0].started = model.now - 12_000_000_000
    let ended = try #require(model.panes.firstIndex { $0.id.number == 9 })
    model.panes[ended].parent = .init(number: 5)
    model.panes[0].status?.programStatus = .init(records: [
        .working(.init(id: "job/1", started: model.now - 65_000_000_000)),
        .blocked(.init(id: "job/2", started: model.now - 125_000_000_000)),
        .done(.init(id: "job/3", started: model.now - 12_000_000_000)),
        .idle(.init(id: "job/4", started: model.now - 12_000_000_000)),
        .error(.init(id: "job/5", started: model.now - 12_000_000_000)),
    ], serial: 1)
    let snapshot = try #require(Snapshot(model: model))
    let rows = sidebarRows(snapshot)
    let child = try #require(rows.first { $0.target?.pane.number == 1 })
    let started = try #require(child.started)
    #expect(started == model.now - 12_000_000_000)
    #expect(snapshot.clock.now == model.now)
    #expect(snapshot.clock.local > 0)
    model.now += 1_000_000_000
    #expect(sidebarRows(try #require(Snapshot(model: model))) == rows)
    let jobs = rows.filter { if case .program = $0.id { true } else { false } }
    #expect(jobs.prefix(5).map { $0.started != nil } == [true, true, false, false, false])
    #expect(rows.first { $0.target?.pane.number == 2 }?.started == nil)
    #expect(rows.first { $0.target?.pane.number == 9 }?.started == nil)
}

@Test func elapsedClockFormatsSecondsMinutesAndHours() {
    let start = 10_000_000_000
    for (seconds, expected) in [(-1, "0s"), (12, "12s"), (59, "59s"), (60, "1m00s"),
                                (185, "3m05s"), (3599, "59m59s"), (3720, "1h02m")] {
        #expect(sidebarElapsed(started: start, now: start + seconds * 1_000_000_000) == expected)
    }
}

@Test func projectedQuietTerminalCloseIgnoresTheForeground() throws {
    var model = try recorded()
    let index = try #require(model.panes.firstIndex { $0.id == PaneID(number: 4) })
    model.panes[index].pid = 100
    for foreground in [KoSchema.Foreground(name: "zsh", pid: 100), .init(name: "nvim", pid: 101), nil] {
        model.panes[index].foreground = foreground
        let snapshot = try #require(Snapshot(model: model))
        let item = try #require(items(snapshot)[PaneID(number: 4)])
        #expect(item.rowTitle == "Terminal")
        #expect(!closeScope(snapshot, target: .pane(item.id)).ask)
    }
}

@Test func runtimeWireProjectsAQuietTerminalWithoutAHostForeground() throws {
    let model = try recorded()
    let data = try JSONEncoder().encode(model)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var panes = try #require(object["panes"] as? [[String: Any]])
    let index = try #require(panes.firstIndex { $0["id"] as? String == "pane_4" })
    var status = try #require(panes[index]["status"] as? [String: Any])
    let kind = try #require(status["kind"] as? [String: Any])
    status["kind"] = ["type": "runtime", "pane": try #require(kind["pane"])]
    panes[index]["status"] = status
    panes[index].removeValue(forKey: "foreground")
    object["panes"] = panes
    let runtime = try JSONDecoder().decode(KoModel.self, from: JSONSerialization.data(withJSONObject: object))
    let snapshot = try #require(Snapshot(model: runtime))
    let item = try #require(items(snapshot)[PaneID(number: 4)])
    #expect(item.rowTitle == "Terminal")
    #expect(!closeScope(snapshot, target: .pane(item.id)).ask)
}

@Test func runtimePiProjectsAsAMessageableAgent() throws {
    var model = try recorded()
    let index = try #require(model.panes.firstIndex { $0.id == PaneID(number: 5) })
    guard case .host(let host)? = model.panes[index].status?.kind else { Issue.record("expected host"); return }
    model.panes[index].status?.kind = .runtime(.init(pane: host.pane))
    model.panes[index].inbox = true
    let snapshot = try #require(Snapshot(model: model))
    let item = try #require(items(snapshot)[PaneID(number: 5)])
    #expect(item.isMessageable)
    #expect(item.agent != nil)
    #expect(item.shell == nil)
    #expect(item.rowTitle == "@Worker")
    #expect(item.lifecycle == .live(.runtime(.init(pane: .piAgent(.init(session: "s1", status: try #require(item.agent)))))))
}

private func nest(_ model: inout KoModel, _ moved: [UInt32], under parentNumber: UInt32, window: UInt32) throws {
    let gone = Set(moved.map { PaneID(number: $0) })
    model.outline.removeAll { if case .pane(let pane) = $0 { gone.contains(pane.id) } else { false } }
    let parent = try #require(model.outline.firstIndex { if case .pane(let pane) = $0 { pane.id == .init(number: parentNumber) } else { false } })
    model.outline.insert(contentsOf: moved.map { .pane(.init(depth: 1, id: .init(number: $0), window: .init(number: window))) }, at: parent + 1)
}

@Test func theTwoPanesOfAChildWindowAreOneGroupUnderTheParentPane() throws {
    var model = try recorded()
    try nest(&model, [3, 4], under: 5, window: 2)
    let snapshot = try #require(Snapshot(model: model))
    #expect(shape(snapshot.sessions[0].nodes) == ["1[1,2]", "5>2[3,4],7>8", "9"])
}

@Test func statusesAndEndedPanesKeepTheirMeaning() throws {
    let found = items(try #require(Snapshot(model: recorded())))
    func item(_ number: UInt32) throws -> Item { try #require(found[.init(number: number)]) }
    let working = try item(1)
    #expect(working.agent?.state == .running(.init()))
    #expect(working.pane.label == "claude-code")
    let blocked = try item(2)
    #expect(blocked.agent?.state == .waiting(.init(kind: .permission)))
    guard case .blocked(let record)? = blocked.pane.status?.programStatus.records.first else { Issue.record("not blocked"); return }
    #expect(record.kind == .permission)
    #expect(record.title == "Message")
    guard case .running(let running)? = try item(3).shell?.phase,
          !running.fullscreen, case .command(let command) = running.origin else { Issue.record("not running a command"); return }
    #expect(command.command == "make")
    let failed = try item(4)
    guard case .idle(let idle)? = failed.shell?.phase, let last = idle.last else { Issue.record("not idle after a command"); return }
    #expect(last.code == 1 && last.command == "false")
    #expect(try item(5).lifecycle == .live(.host(.init(pane: .piAgent(.init(session: "s1", status: try #require(item(5).agent)))))))
    #expect(try item(5).pane.label == "Worker")
    #expect(try item(6).shell?.phase == .unknown)
    let child = try item(7)
    #expect(shape(child.children) == ["8"])
    let ended = try item(9)
    #expect(ended.lifecycle == .ended(try #require(recorded().panes.first { $0.id.number == 9 }?.dead?.cause)))
    #expect(try [1, 2, 4].map { try item($0).pane.mark } == [.running, .waiting, .none_], "the core's mark; an exit before the connection is no news")
    #expect(try (item(5).pane.inbox != true) && !item(5).isMessageable, "a pi agent without an inbox takes no prompt")
}

private func edited(_ number: UInt32, _ edit: (inout KoSchema.PaneJson) -> Void) throws -> Item {
    var model = try recorded()
    let at = try #require(model.panes.firstIndex { $0.id == .init(number: number) })
    edit(&model.panes[at])
    let snapshot = try #require(Snapshot(model: model))
    return try #require(items(snapshot)[.init(number: number)])
}

@Test func aPaneWithAParentNestsUnderIt() throws {
    var model = try recorded()
    let at = try #require(model.panes.firstIndex { $0.id == .init(number: 4) })
    model.panes[at].parent = .init(number: 5)
    try nest(&model, [4], under: 5, window: 3)
    let snapshot = try #require(Snapshot(model: model))
    #expect(shape(snapshot.sessions[0].nodes) == ["1[1,2]", "3", "5>4,7>8", "9"])
}

@Test func theInboxDotReadsTheRow() throws {
    #expect(try (edited(5) { _ in }.pane.inbox != true))
    #expect(try edited(5) { $0.inbox = true }.pane.inbox == true)
}

@Test func aDeadPaneThatClosesOnExitLingersByItsCauseAndAKeptPaneDoesNot() throws {
    func lingering(_ cause: KoSchema.Cause, close: KoSchema.Close = .onExit) throws -> (SidebarRow.Status, String) {
        try edited(4) { $0.dead = .init(at: 1, cause: cause); $0.close = close }.indicator
    }
    #expect(try lingering(.exited(.init(code: 0))) == (.endedClean, "gone, exited"))
    #expect(try lingering(.exited(.init(code: 3))) == (.endedFailed, "gone, exited with code 3"))
    #expect(try lingering(.signaled(.init(signal: 9))) == (.endedFailed, "gone, killed by signal 9"))
    #expect(try lingering(.failed(.init(message: "no such file"))) == (.endedFailed, "gone, failed to start"))
    #expect(try edited(4) { $0.dead = .init(at: 1, cause: .exited(.init(code: 0))) }.indicator == (.done, "gone, completed"), "no close is a kept pane")
    #expect(try lingering(.exited(.init(code: 0)), close: .keep) == (.done, "gone, completed"))
    #expect(try lingering(.exited(.init(code: 3)), close: .keep) == (.error, "gone, exited with code 3"))
    #expect(try lingering(.signaled(.init(signal: 9)), close: .keep) == (.error, "gone, killed by signal 9"))
    #expect(try lingering(.failed(.init(message: "no such file")), close: .keep) == (.error, "gone, failed to start"))
    #expect(try edited(9) { $0.close = .onExit }.indicator == (.endedFailed, "gone, exited with code 3"))
}

@Test func theProjectedTreeDrawsOneRowForEachPane() throws {
    let snapshot = try #require(Snapshot(model: recorded()))
    let rows = sidebarRows(snapshot)
    #expect(rows.filter { $0.target != nil }.count == 9)
    #expect(rows.filter(\.focused).map(\.title) == ["claude-code"])
}

@Test func aPaneWithoutStatusRemainsAnUnknownHostTerminal() throws {
    let item = try edited(5) { $0.status = nil; $0.inbox = true; $0.mark = .none_ }
    #expect(item.pane.status == nil)
    #expect(item.lifecycle == .live(.host(.init(pane: .terminal(.init(phase: .unknown))))))
    #expect(item.rowTitle == "Worker")
    #expect(item.caption == "")
    #expect(!item.isMessageable)
    #expect(!item.closesQuietly)
    let rows = sidebarRows(makeSnapshot([.item(item)]))
    #expect(rows.filter { if case .program = $0.id { true } else { false } }.isEmpty)
}

@Test func aModelWithoutPanesHasNoSidebarTree() throws {
    var model = try recorded()
    model.layout.layout.sessions = []
    #expect(Snapshot(model: model) == nil)
}

@Test func theGeneratedTypesEncodeAnEditTheWayTheCoreDecodesIt() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    func json(_ edit: KoSchema.Edit) throws -> String { String(decoding: try encoder.encode(edit), as: UTF8.self) }
    #expect(try json(.resizePair(.init(first: PaneID(number: 1), firstSize: 40, second: PaneID(number: 2)))) == #"{"first":"pane_1","first_size":40,"second":"pane_2","type":"resize_pair"}"#)
    #expect(try json(.float(.init(pane: PaneID(number: 3), x: 4, z: 9))) == #"{"pane":"pane_3","type":"float","x":4,"z":9}"#)
    #expect(try json(.split(.init(axis: .h, new: .init(), pane: PaneID(number: 1)))) == #"{"axis":"h","new":{},"pane":"pane_1","type":"split"}"#)
    let decoded = try JSONDecoder().decode(KoSchema.Edit.self, from: Data(#"{"type":"dock","pane":"pane_1","target":"pane_2","edge":"left"}"#.utf8))
    #expect(decoded == .dock(.init(edge: .left, pane: PaneID(number: 1), target: PaneID(number: 2))))
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(KoSchema.Edit.self, from: Data(#"{"type":"nonsense"}"#.utf8)) }
    #expect(throws: DecodingError.self, "an id that is not a ko pane id") {
        try JSONDecoder().decode(KoSchema.Edit.self, from: Data(#"{"type":"equalize","pane":"%1"}"#.utf8))
    }
}
