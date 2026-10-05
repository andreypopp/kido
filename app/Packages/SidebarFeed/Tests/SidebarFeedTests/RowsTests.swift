import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private func fixture(filter: String = "", client: Int = 0, sessions: [Int] = [0], grouped: Bool = false) throws -> Snapshot {
    func item(_ id: Int, _ window: Int, run: String? = nil, started: Double? = nil, tail: String = "", children: [[String: Any]] = []) -> [String: Any] {
        ["kind": run == "bash" || run == "stream" ? "run" : "agent", "id": "%\(id)", "pane": "%\(id)", "window": "@\(window)",
         "run": run as Any? ?? NSNull(), "started": started as Any? ?? NSNull(), "indicator": ["kind": "running"],
         "title": [["text": "pane-\(id)", "role": "plain"]], "tail": tail.isEmpty ? [] : [["text": tail, "role": "dim"]],
         "attention": id == 2, "children": children]
    }
    let children = [item(1, 1, run: "agent", started: 100, tail: "working", children: [item(2, 2, run: "stream", started: 100)]),
                    item(3, 3, run: "bash", started: 100), item(4, 4, run: "bash")]
    let nodes: [[String: Any]] = grouped
        ? [["kind": "window", "id": "@0", "window": "@0", "name": "group", "children": [item(0, 0), item(5, 0)]]]
        : [item(0, 0, started: 100), item(5, 5, children: children)]
    let object: [String: Any] = ["v": 2, "client": ["session": "$0", "window": "@\(client)", "pane": "%\(client)"],
                               "filter": filter, "error": NSNull(), "sessions": sessions.map {
                                   ["id": "$\($0)", "name": "session-\($0)", "current": $0 == 0, "nodes": nodes]
                               }]
    return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func slicesAndLastCorners() throws {
    let rows = sidebarRows(try fixture(client: 5), folded: [])
    let panes = rows.filter { $0.target != nil }
    #expect(panes.map(\.indent) == [0, 0, 1, 2, 1, 1])
    #expect(rows.count == 14)
    #expect(rows.filter { $0.kind == .divider }.map(\.indent) == [0, 0, 1, 2, 1, 1])
    #expect(rows.filter { $0.kind == .divider }.map(\.height) == [3, 3, 3, 3, 3, 3])
    #expect(rows.allSatisfy { $0.height > 0 })
    #expect(rows.map(\.height).reduce(0, +) == 230)
    #expect(rows.dropLast().allSatisfy { $0.segments.first?.height == 221 })
    #expect(panes.map { $0.segments.filter { $0.kind == .window(active: true) }.count } == [0, 1, 1, 1, 1, 1])
    let nested = try #require(panes.first { $0.title == "pane-1" })
    #expect(nested.segments.last?.topLeft == 6)
    #expect(nested.segments.last?.bottomLeft == 6)
    #expect(nested.segments.last?.height == 69)
    let last = try #require(panes.last)
    #expect(last.segments.dropFirst().allSatisfy { $0.bottomLeft == 0 })
    #expect(last.segments.first?.bottomLeft == 10)
    let parent = try #require(panes.first { $0.title == "pane-5" })
    let child = try #require(panes.first { $0.title == "pane-2" })
    #expect(child.segments[1].height == parent.segments[1].height)
    #expect(parent.segments[1].height == 156)
    #expect(child.segments[1].top < 0)
    let activeChild = sidebarRows(try fixture(client: 2), folded: []).filter { $0.target != nil }
    #expect(activeChild.filter { $0.segments.contains { $0.kind == .window(active: true) } }.map(\.title) == ["pane-2"])
}

@Test func groupedPanesHaveOneDivider() throws {
    let rows = sidebarRows(try fixture(grouped: true), folded: [])
    #expect(rows.map(\.height) == [31, 3, 28, 28, 9])
    #expect(rows.filter { $0.kind == .divider }.map(\.indent) == [0])
    #expect(rows.allSatisfy { $0.height > 0 })
}

@Test func foldsAndFilteredSessionsKeepIdentity() throws {
    let snapshot = try fixture(sessions: [0, 1])
    let folded: Set<SessionID> = [.init(number: 0)]
    let rows = sidebarRows(snapshot, folded: folded)
    #expect(rows.filter { $0.id.session == SessionID(number: 0) }.map(\.kind) == [.header, .gap])
    #expect(sidebarRows(try fixture(filter: "session", sessions: [0]), folded: folded).count == 2)
    #expect(sidebarRows(try fixture(filter: "absent", sessions: []), folded: folded).isEmpty)
    let expanded = sidebarRows(snapshot, folded: [])
    #expect(Set(expanded.map(\.id)).count == expanded.count)
    #expect(expanded.filter { $0.focused }.count == 1)
}

@Test func paneTargetsAndTimePolicy() throws {
    let panes = sidebarRows(try fixture(), folded: []).filter { $0.target != nil }
    #expect(panes.map(\.started) == [nil, nil, Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 100), nil])
    #expect(panes.allSatisfy { if case .pane = $0.kind { return true }; return false })
    #expect(panes.first { $0.title == "pane-1" }?.tail == "working")
    #expect(panes.map(\.height) == [28, 28, 41, 25, 25, 25])
}

@Test(arguments: [(0, "0s"), (59, "59s"), (60, "1m00s"), (3599, "59m59s"), (3600, "1h00m"), (7260, "2h01m"), (-1, "0s")])
func elapsed(_ seconds: Int, _ expected: String) {
    #expect(sidebarElapsed(started: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: Double(100 + seconds))) == expected)
}

@Test func originalIndicatorDescriptions() throws {
    let indicators: [(String, String?, SidebarRow.Status, String)] = [
        ("waiting", nil, .attention, "waiting"), ("stalled", nil, .stalled, "stalled"),
        ("done", nil, .done, "done"), ("idle", nil, .quiet, "idle"),
        ("gone", "completed", .done, "gone, completed")
    ]
    for (kind, outcome, status, description) in indicators {
        let data = """
        {"v":2,"client":{"session":"$0","window":"@0","pane":"%0"},"filter":"","sessions":[
          {"id":"$0","name":"main","current":true,"nodes":[
            {"kind":"agent","id":"%0","pane":"%0","window":"@0","indicator":{"kind":"\(kind)","outcome":\(outcome.map { "\"\($0)\"" } ?? "null")},
             "title":[],"tail":[],"attention":true,"children":[]}]}]}
        """
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(data.utf8))
        let row = try #require(sidebarRows(snapshot, folded: []).first { $0.target != nil })
        #expect(row.status == status)
        #expect(row.indicatorDescription == description)
        #expect(row.attention)
        #expect(sidebarTarget(snapshot, attention: 1) == row.target)
    }
}

@Test func navigationOrderWrappingAndFallback() throws {
    let snapshot = try fixture(sessions: [0, 1])
    let panes = sidebarRows(snapshot, folded: []).compactMap(\.target)
    #expect(panes.map(\.pane) == [0, 5, 1, 2, 3, 4, 0, 5, 1, 2, 3, 4].map { PaneID(number: UInt32($0)) })
    #expect(sidebarTarget(snapshot) == panes.first)
    #expect(sidebarTarget(snapshot, attention: 1) == panes[3])
    #expect(sidebarTarget(snapshot, attention: -1) == panes[9])
    #expect(sidebarTarget(snapshot, selected: panes[9], attention: 1) == panes[3])
    #expect(sidebarTarget(snapshot, selected: panes[3], attention: -1) == panes[9])
    #expect(sidebarRows(snapshot, folded: [.init(number: 0), .init(number: 1)]).allSatisfy { $0.target == nil })
    #expect(sidebarTarget(snapshot, selected: panes[0], attention: 1) == panes[3])
    #expect(sidebarTarget(try fixture(sessions: [])) == nil)
    #expect(sidebarTarget(try fixture(sessions: []), attention: 1) == nil)
}
