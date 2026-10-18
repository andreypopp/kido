import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

@Test func rpc2RequestsAndReplies() throws {
    let s = SessionID(number: 3), w = WindowID(number: 12)
    let p = Snapshot.Position(session: s, window: w, pane: PaneID(number: 9))
    let requests: [(RPCRequest, String)] = [
        (.newWindow(w), #"{"id":7,"new-window":"@12"}"#),
        (.newSession, #"{"id":7,"new-session":true}"#),
        (.jump(p), #"{"id":7,"jump":{"session":"$3","window":"@12","pane":"%9"}}"#),
        (.selectWindow(s, w), #"{"id":7,"select-window":{"session":"$3","window":"@12"}}"#),
        (.selectSession(s), #"{"id":7,"select-session":"$3"}"#),
        (.switchWindow(next: true), #"{"id":7,"switch-window":{"direction":"next"}}"#),
        (.switchSession(next: false), #"{"id":7,"switch-session":{"direction":"prev"}}"#),
        (.releaseSideFocus, #"{"id":7,"release-side-focus":true}"#)
    ]
    for (request, json) in requests {
        #expect(try JSONSerialization.jsonObject(with: request.data(id: 7)) as? NSDictionary == JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }
    for key in ["jumped", "selected", "created"] {
        let reply = try JSONDecoder().decode(RPCEvent.Reply.self, from: Data("{\"id\":7,\"\(key)\":{\"session\":\"$3\",\"window\":\"@12\",\"pane\":\"%9\"},\"future\":1}".utf8))
        #expect((key == "jumped" ? RPCRequest.jump(p) : key == "selected" ? .selectWindow(s, w) : .newWindow(w)).accepts(reply.value))
        #expect(!RPCRequest.switchWindow(next: true).accepts(reply.value))
    }
    for json in [#"{"id":7}"#, #"{"id":7,"released":false}"#, #"{"id":7,"created":{"session":"$3","window":"@12"}}"#, #"{"id":7,"switched":null,"error":"bad"}"#] {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RPCEvent.Reply.self, from: Data(json.utf8)) }
    }
}

@Test func composedRows() throws {
    let records: [[String: Any]] = [["id": "", "state": "working", "title": "ignored raw title", "msg": "ignored raw caption", "progress": 90]]
    let nodes = [pane(0, title: "excluded shell", lifecycle: terminal(running("excluded-command"), report: report(waiting(), msg: "composed caption")), records: records, serial: 7, children: [
        pane(1, title: "Compiler expert", lifecycle: agent(working())),
        pane(2, title: "excluded-title", lifecycle: remote(["Remote_terminal", ["interactive": true, "status": shell(running("excluded-command"))]])),
        pane(3, title: "Reviewer", lifecycle: remote(["Remote_agent", ["name": "pi", "status": ["since": 1, "msg": null, "state": idle()]]], host: "agenthost"))])]
    var object = snapshotObject(nodes)
    object["sessions"] = [["id": "$0", "name": "workspace", "current": true, "nodes": nodes],
                          ["id": "$1", "name": "devbox", "current": false, "nodes": []]]
    let snapshot = try decode(object)
    let rows = sidebarRows(snapshot).filter { $0.target != nil }
    #expect(rows.map(\.title) == ["excluded shell", "Compiler expert", "ssh alice@devbox: excluded-command", "Reviewer"])
    #expect(rows[0].tail == "composed caption")
    #expect(rows[0].status == .waiting && !rows[0].quietShell)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == .waiting)
    var changedNodes = nodes
    changedNodes[0]["program_status"] = ["serial": 99, "records": []]
    object["sessions"] = [["id": "$0", "name": "workspace", "current": true, "nodes": changedNodes]]
    let rawChanged = try decode(object)
    #expect(snapshot != rawChanged && !snapshot.sameSidebarContent(as: rawChanged))
    var item = nodes[0]
    item.removeValue(forKey: "program_status")
    #expect(throws: DecodingError.self) { try decode(item, as: Item.self) }
}
