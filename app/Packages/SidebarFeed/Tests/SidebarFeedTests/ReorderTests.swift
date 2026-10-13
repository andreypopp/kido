import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private let s0 = SessionID(number: 0), s1 = SessionID(number: 1)
private func w(_ n: UInt32) -> WindowID { WindowID(number: n) }

private func tree(instance: Int = 12345, sessions: [Int] = [0, 1]) throws -> Snapshot {
    let record: [String: Any] = ["id": "task", "state": "working", "title": "Task", "msg": "step", "progress": 10]
    let nodes: [[String: Any]] = [
        pane(0, records: [record], serial: 1, children: [pane(1, run: "agent", children: [pane(2, run: "bash")])]),
        ["kind": "window", "id": "@3", "window": "@3", "name": "Group", "children": [pane(3, children: [pane(5, run: "agent")]), pane(4, window: 3)]],
        pane(6),
    ]
    var object = snapshotObject(nodes, sessions: sessions)
    object["server_instance"] = ["started_at": 1780000000, "pid": instance]
    return try decode(object)
}

@Test func reorderRequestsAndReplies() throws {
    let requests: [(RPCRequest, String)] = [
        (.reorder(.session(SessionID(number: 3), relativeTo: SessionID(number: 1), .before)),
         #"{"id":51,"reorder-session":{"session":"$3","relative-to":"$1","placement":"before"}}"#),
        (.reorder(.window(SessionID(number: 3), w(12), relativeTo: w(9), .after)),
         #"{"id":51,"reorder-window":{"session":"$3","window":"@12","relative-to":"@9","placement":"after"}}"#),
    ]
    for (request, json) in requests {
        #expect(try JSONSerialization.jsonObject(with: request.data(id: 51)) as? NSDictionary == JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        #expect(try request.data(id: 51).last == 10)
    }
    let reply = try JSONDecoder().decode(RPCEvent.Reply.self, from: Data(#"{"id":51,"reordered":true}"#.utf8))
    #expect(reply.id == 51)
    #expect(requests[0].0.accepts(reply.value))
    #expect(!RPCRequest.releaseSideFocus.accepts(reply.value))
    let released = try JSONDecoder().decode(RPCEvent.Reply.self, from: Data(#"{"id":51,"released":true}"#.utf8))
    #expect(!requests[1].0.accepts(released.value))
    let failed = try JSONDecoder().decode(RPCEvent.Reply.self, from: Data(#"{"id":51,"error":"no such window"}"#.utf8))
    #expect(requests[1].0.accepts(failed.value))
    for json in [#"{"id":51,"reordered":false}"#, #"{"id":51,"reordered":true,"released":true}"#] {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RPCEvent.Reply.self, from: Data(json.utf8)) }
    }
}

@Test func placingRelativeToRemainingSiblings() {
    let ids = ["a", "b", "c", "d"]
    #expect(ReorderMove.placing("b", at: 0, in: ids)! == ("a", .before))
    #expect(ReorderMove.placing("a", at: 4, in: ids)! == ("d", .after))
    #expect(ReorderMove.placing("a", at: 3, in: ids)! == ("d", .before))
    #expect(ReorderMove.placing("d", at: 2, in: ids)! == ("c", .before))
    for slot in [1, 2] { #expect(ReorderMove.placing("b", at: slot, in: ids) == nil, "dropping in place is a no-op") }
    #expect(ReorderMove.placing("a", at: 1, in: ["a"]) == nil, "a singleton never moves")
    #expect(ReorderMove.placing("x", at: 0, in: ids) == nil)
}

@Test func rootMovesWithItsWholeSubtree() throws {
    let snapshot = try tree()
    let rows = sidebarRows(snapshot).filter { $0.id.session == s0 }
    let moved = try #require(snapshot.reordered(.window(s0, w(0), relativeTo: w(6), .after)))
    let after = sidebarRows(moved).filter { $0.id.session == s0 }
    func block(_ rows: [SidebarRow], _ root: UInt32) -> [SidebarRow] { rows.filter { $0.root == w(root) } }
    #expect(block(rows, 0).count == 4, "pane, its program record, and two nested runs")
    #expect(block(rows, 3).count == 3, "both group panes and the group's nested run")
    #expect(after.count == rows.count)
    #expect(after.first == rows.first)
    #expect(after.last == rows.last)
    #expect(Array(after.dropFirst().dropLast()) == block(rows, 3) + block(rows, 6) + block(rows, 0), "guides, records and runs travel unchanged")
    #expect(moved.sessions[1] == snapshot.sessions[1], "only the named session reorders")
    let group = try #require(snapshot.reordered(.window(s0, w(3), relativeTo: w(0), .before)))
    #expect(group.sessions[0].nodes.map(\.window) == [w(3), w(0), w(6)])
    let sessions = try #require(snapshot.reordered(.session(s0, relativeTo: s1, .after)))
    #expect(sessions.sessions.map(\.id) == [s1, s0])
    #expect(sessions.sessions[1] == snapshot.sessions[0])
}

@Test func staleMovesDoNotApply() throws {
    let snapshot = try tree()
    for move in [ReorderMove.window(s0, w(1), relativeTo: w(6), .after), .window(s0, w(0), relativeTo: w(5), .before),
                 .window(s0, w(9), relativeTo: w(6), .after), .window(SessionID(number: 7), w(0), relativeTo: w(6), .after),
                 .window(s0, w(6), relativeTo: w(6), .after), .session(s0, relativeTo: SessionID(number: 7), .before)] {
        #expect(snapshot.reordered(move) == nil, "\(move)")
    }
}

@Test func successBeforeSnapshot() throws {
    let snapshot = try tree()
    let move = ReorderMove.window(s0, w(6), relativeTo: w(0), .before)
    let applied = try #require(snapshot.reordered(move))
    var state = ReorderState()
    let submitted = state.submit(move, to: snapshot)
    let token = try #require(submitted)
    #expect(state.project(snapshot) == applied)
    #expect(state.submit(.session(s0, relativeTo: s1, .after), to: snapshot) == nil, "one drop at a time")
    #expect(state.complete(token, error: nil) == nil)
    #expect(state.project(snapshot) == applied, "success alone keeps the optimistic order")
    state.observe(snapshot)
    #expect(state.project(snapshot) == applied, "a stale snapshot keeps the optimistic order")
    state.observe(applied)
    #expect(state.pending == nil)
    #expect(state.project(snapshot) == snapshot)
    #expect(state.expire(token) == nil, "a settled drop never times out")
}

@Test func snapshotBeforeSuccess() throws {
    let snapshot = try tree()
    let move = ReorderMove.session(s1, relativeTo: s0, .before)
    let applied = try #require(snapshot.reordered(move))
    var state = ReorderState()
    let submitted = state.submit(move, to: snapshot)
    let token = try #require(submitted)
    state.observe(applied)
    #expect(state.pending != nil, "still waiting for the reply")
    #expect(state.project(snapshot) == snapshot, "the server's order is authoritative once it matches")
    #expect(state.submit(move, to: snapshot) == nil)
    #expect(state.expire(token) == nil, "the order arrived, so a missing reply is not an error")
    #expect(state.pending == nil)
}

@Test func failureTimeoutAndResetRevert() throws {
    let snapshot = try tree()
    let move = ReorderMove.window(s0, w(0), relativeTo: w(6), .after)
    var state = ReorderState()
    var token = state.submit(move, to: snapshot) ?? -1
    #expect(token > 0)
    #expect(state.complete(token, error: "no such window") == "no such window")
    #expect(state.pending == nil)
    #expect(state.project(snapshot) == snapshot)
    #expect(state.complete(token, error: "again") == nil, "a settled request is never reported twice")

    token = state.submit(move, to: snapshot) ?? -1
    #expect(token > 0)
    #expect(state.expire(token) == "The server did not answer the reorder request")
    #expect(state.project(snapshot) == snapshot)
    #expect(state.complete(token, error: nil) == nil, "a late reply changes nothing")
    #expect(state.pending == nil)

    token = state.submit(move, to: snapshot) ?? -1
    #expect(token > 0)
    #expect(state.complete(token, error: nil) == nil)
    #expect(state.expire(token) == "The server did not apply the new order")

    #expect(state.submit(move, to: snapshot) != nil)
    let restarted = try tree(instance: 999)
    #expect(state.project(restarted) == restarted, "ids from another server instance are not projected")
    state.observe(restarted)
    #expect(state.pending == nil)

    #expect(state.submit(move, to: snapshot) != nil)
    let reparented = try decode(snapshotObject([pane(6, children: [pane(0)])], sessions: [0, 1]), as: Snapshot.self)
    state.observe(reparented)
    #expect(state.project(reparented) == reparented, "a source that is no longer a root cancels the projection")
    #expect(state.pending != nil)
    #expect(state.submit(move, to: snapshot) == nil)
    state.reset()
    #expect(state.pending == nil)
    #expect(state.submit(.window(s0, w(0), relativeTo: w(3), .before), to: snapshot) == nil, "a no-op drop is never sent")
}

@Test func navigationFollowsSnapshotRoots() throws {
    let snapshot = try tree()
    let projection = sidebarWindows(snapshot, session: s0, surviving: Set(([0, 1, 2, 3, 6, 8] as [UInt32]).map(w)))
    #expect(projection.order == [w(0), w(3), w(6)])
    let orphan = sidebarWindows(snapshot, session: s0, surviving: [w(1), w(6)])
    #expect(orphan.order == [w(1), w(6)], "an orphaned run is ordered where its subtree sits")
    #expect(arranged([w(6), w(8), w(3), w(0)], by: projection.order, \.self) == [w(0), w(8), w(3), w(6)],
            "a window the snapshot has not reported keeps its inventory slot")
    #expect(arranged([w(1), w(2)], by: [WindowID](), \.self) == [w(1), w(2)])
}
