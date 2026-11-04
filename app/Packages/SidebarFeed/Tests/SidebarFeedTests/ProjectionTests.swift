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
        case .window(let group): "\(group.name)[\(group.children.map { shape([.item($0)])[0] }.joined(separator: ","))]"
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
    #expect(snapshot.sessions.map(\.current) == [true, false])
    #expect(snapshot.client == .init(session: .init(number: 1), window: .init(number: 1), pane: .init(number: 1)))
    #expect(shape(snapshot.sessions[0].nodes) == ["build[1,2]", "3", "4", "5>7>8", "9"])
    #expect(shape(snapshot.sessions[1].nodes) == ["6"])
}

private func nest(_ model: inout KoModel, _ moved: [UInt32], under parentNumber: UInt32, window: UInt32) throws {
    let gone = Set(moved.map { PaneID(number: $0) })
    model.outline.removeAll { if case .pane(let pane) = $0 { gone.contains(pane.id) } else { false } }
    let parent = try #require(model.outline.firstIndex { if case .pane(let pane) = $0 { pane.id == .init(number: parentNumber) } else { false } })
    model.outline.insert(contentsOf: moved.map { .pane(.init(depth: 1, id: .init(number: $0), window: .init(number: window))) }, at: parent + 1)
}

@Test func theTwoPanesOfARunWindowAreOneGroupUnderTheParentPane() throws {
    var model = try recorded()
    try nest(&model, [3, 4], under: 5, window: 2)
    let snapshot = try #require(Snapshot(model: model))
    #expect(shape(snapshot.sessions[0].nodes) == ["build[1,2]", "5>running[3,4],7>8", "9"])
}

@Test func statusesRunsAndEndedPanesKeepTheirMeaning() throws {
    let found = items(try #require(Snapshot(model: recorded())))
    func item(_ number: UInt32) throws -> Item { try #require(found[.init(number: number)]) }
    let working = try item(1)
    #expect(working.agent?.state == .running(progress: nil))
    #expect(working.title == "claude-code")
    let blocked = try item(2)
    #expect(blocked.agent?.state == .waiting(.permission, progress: nil))
    #expect(blocked.program_status.records.map(\.state) == [.blocked])
    #expect(blocked.program_status.records.first?.kind == .permission)
    #expect(blocked.program_status.records.first?.title == "Message")
    guard case .running(let command?, fullscreen: false)? = try item(3).shell?.phase else { Issue.record("not running a command"); return }
    #expect(command.command == "make")
    let failed = try item(4)
    guard case .idle(let last?) = failed.shell?.phase else { Issue.record("not idle after a command"); return }
    #expect(last.code == 1 && last.command == "false")
    #expect(try item(5).lifecycle == .live(.piAgent(session: "s1", try #require(item(5).agent))))
    #expect(try item(5).title == "Worker")
    #expect(try item(6).shell?.phase == .unknown)
    let child = try item(7)
    #expect(child.run != nil && child.started != nil)
    #expect(try item(8).run != nil)
    let ended = try item(9)
    #expect(ended.lifecycle == .ended(.failed))
    #expect(ended.run != nil && ended.started == nil)
    #expect(try [1, 2, 4].map { try item($0).mark } == [.running, .waiting, .none_], "the core's mark; an exit before the connection is no news")
    #expect(try !item(5).inbox && !item(5).isMessageable, "a pi agent without an inbox takes no prompt")
}

private func edited(_ number: UInt32, _ edit: (inout KoSchema.PaneJson) -> Void) throws -> Item {
    var model = try recorded()
    let at = try #require(model.panes.firstIndex { $0.id == .init(number: number) })
    edit(&model.panes[at])
    let snapshot = try #require(Snapshot(model: model))
    return try #require(items(snapshot)[.init(number: number)])
}

@Test func aPaneWithAParentNestsUnderItWhetherOrNotItIsARun() throws {
    var model = try recorded()
    let at = try #require(model.panes.firstIndex { $0.id == .init(number: 4) })
    model.panes[at].parent = .init(number: 5)
    try nest(&model, [4], under: 5, window: 3)
    let snapshot = try #require(Snapshot(model: model))
    #expect(shape(snapshot.sessions[0].nodes) == ["build[1,2]", "3", "5>4,7>8", "9"])
}

@Test func theInboxDotReadsTheRow() throws {
    #expect(try !edited(5) { _ in }.inbox)
    #expect(try edited(5) { $0.inbox = true }.inbox)
}

@Test func aDeadPaneThatClosesOnExitLingersByItsCauseAndAKeptOrRunPaneDoesNot() throws {
    func lingering(_ cause: KoSchema.Cause, close: KoSchema.Close = .onExit) throws -> (SidebarRow.Status, String) {
        try edited(4) { $0.dead = .init(at: 1, cause: cause); $0.close = close }.indicator
    }
    #expect(try lingering(.exited(.init(code: 0))) == (.endedClean, "gone, exited"))
    #expect(try lingering(.exited(.init(code: 3))) == (.endedFailed, "gone, exited with code 3"))
    #expect(try lingering(.signaled(.init(signal: 9))) == (.endedFailed, "gone, killed by signal 9"))
    #expect(try lingering(.failed(.init(message: "no such file"))) == (.endedFailed, "gone, failed to start"))
    #expect(try edited(4) { $0.dead = .init(at: 1, cause: .exited(.init(code: 0))) }.indicator == (.done, "gone, completed"), "no close is a kept pane")
    #expect(try lingering(.exited(.init(code: 0)), close: .keep) == (.done, "gone, completed"))
    #expect(try lingering(.exited(.init(code: 3)), close: .keep) == (.error, "gone, failed"))
    #expect(try edited(9) { $0.close = .onExit }.indicator == (.error, "gone, failed"), "a run pane keeps the outcome of its run")
}

@Test func theProjectedTreeDrawsOneRowForEachPane() throws {
    let snapshot = try #require(Snapshot(model: recorded()))
    let rows = sidebarRows(snapshot)
    #expect(rows.filter { $0.target != nil }.count == 9)
    #expect(rows.filter(\.focused).map(\.title) == ["claude-code"])
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
