import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

@Test(arguments: [false, true]) func closingPaneIncludesDescendants(_ waitingState: Bool) throws {
    let child = pane(2, lifecycle: agent(waitingState ? waiting() : working()))
    let snapshot: Snapshot = try decode(snapshotObject([pane(0, children: [pane(1, children: [child])]), pane(3)]))
    #expect(closeScope(snapshot, target: .pane(PaneID(number: 0))).running)
    #expect(closeScope(snapshot, target: .pane(PaneID(number: 1))).running)
    #expect(!closeScope(snapshot, target: .pane(PaneID(number: 3))).running)
    #expect(closeScope(snapshot, target: .pane(PaneID(number: 0))).descendants == [WindowID(number: 2), WindowID(number: 1)])
}

@Test func closingWindowIncludesEveryPaneAndDescendants() throws {
    let group: [String: Any] = ["kind": "window", "id": "@0", "window": "@0", "name": "group", "children":
        [pane(0), pane(1, window: 0, children: [pane(2, lifecycle: agent(waiting()))])]]
    let snapshot: Snapshot = try decode(snapshotObject([group, pane(3)]))
    #expect(closeScope(snapshot, target: .window(WindowID(number: 0))).running)
    #expect(!closeScope(snapshot, target: .pane(PaneID(number: 0))).running)
    #expect(!closeScope(snapshot, target: .window(WindowID(number: 3))).running)
    #expect(closeScope(snapshot, target: .window(WindowID(number: 0))).descendants == [WindowID(number: 2)])
}

@Test func closingIncludesProgramRecordsAndQuietOutcomes() throws {
    for state in ["working", "blocked", "done", "error", "idle"] {
        let record: [String: Any] = ["id": "child", "app": "pi", "state": state]
        let snapshot: Snapshot = try decode(snapshotObject([pane(0, records: [record])]))
        #expect(closeScope(snapshot, target: .pane(PaneID(number: 0))).running == ["working", "blocked"].contains(state))
        #expect(closeScope(snapshot, target: .window(WindowID(number: 0))).running == ["working", "blocked"].contains(state))
    }
    #expect(!closeScope(nil, target: .pane(PaneID(number: 0))).running)
}

@Test func recentHostsAddRefreshOrderClearAndEmpty() throws {
    var recent = RecentHosts()
    #expect(recent.isEmpty)
    recent.add("first", at: Date(timeIntervalSince1970: 10))
    recent.add("second", at: Date(timeIntervalSince1970: 20))
    #expect(recent.entries.map(\.host) == ["second", "first"])
    recent.add("first", at: Date(timeIntervalSince1970: 30))
    #expect(recent.entries.map(\.host) == ["first", "second"])
    #expect(recent.entries[0].date == Date(timeIntervalSince1970: 30))
    #expect(recent.relativeTime(recent.entries[0], now: Date(timeIntervalSince1970: 86430)) == "1 d ago")
    #expect(try JSONDecoder().decode(RecentHosts.self, from: JSONEncoder().encode(recent)) == recent)
    recent.clear()
    #expect(recent.isEmpty)
    #expect(recent.entries.isEmpty)
}
