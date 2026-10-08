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

@Test func localSearchAndResolvedProgramRows() throws {
    func pane(_ n: Int, kind: String, title: [[String: String]], children: [[String: Any]] = []) -> [String: Any] {
        ["kind": kind, "id": "%\(n)", "pane": "%\(n)", "window": "@\(n)", "indicator": ["kind": "waiting"],
         "program_status": ["serial": 7, "records": [["id": "", "state": "working", "title": "ignored raw title", "msg": "ignored raw caption", "progress": 90]]],
         "title": title, "tail": [["text": "resolved caption", "role": "dim"]], "attention": true, "children": children]
    }
    let nodes = [pane(0, kind: "shell", title: [["text": "excluded shell", "role": "plain"]], children: [
        pane(1, kind: "agent", title: [["text": "Compiler", "role": "plain"], ["text": " expert", "role": "plain"]]),
        pane(2, kind: "ssh", title: [["text": "ssh ", "role": "proc"], ["text": "devbox", "role": "plain"], ["text": ": excluded-command", "role": "dim"]])])]
    var object: [String: Any] = ["v": 2, "client": ["session": "$0", "window": "@0", "pane": "%0"], "asks": [],
        "sessions": [["id": "$0", "name": "workspace", "current": true, "nodes": nodes],
                     ["id": "$1", "name": "devbox", "current": false, "nodes": []]]]
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(sidebarSearch(snapshot, query: "") == snapshot)
    #expect(sidebarSearch(snapshot, query: "CMPEX")?.sessions.map(\.id) == [SessionID(number: 0)])
    #expect(sidebarSearch(snapshot, query: "devbox")?.sessions.map(\.id) == [SessionID(number: 0), SessionID(number: 1)])
    #expect(sidebarSearch(snapshot, query: "wrksp")?.sessions[0].nodes == snapshot.sessions[0].nodes)
    for query in ["excluded shell", "excluded-command", "resolved caption", "ignored raw title", "@Compiler", "missing"] {
        #expect(sidebarSearch(snapshot, query: query)?.sessions.isEmpty == true)
    }
    let row = try #require(sidebarRows(snapshot).first { $0.target != nil })
    #expect(row.title == "excluded shell" && row.tail == "resolved caption")
    #expect(row.status == .attention && row.attention && !row.quietShell)
    #expect(sidebarWindows(snapshot, session: SessionID(number: 0), surviving: [WindowID(number: 0)]).statuses[WindowID(number: 0)] == .attention)
    var sessions = object["sessions"] as! [[String: Any]]
    var changedNodes = sessions[0]["nodes"] as! [[String: Any]]
    changedNodes[0]["program_status"] = ["serial": 99, "records": []]
    sessions[0]["nodes"] = changedNodes
    object["sessions"] = sessions
    object["asks"] = [["id": "A12345678", "session": "agent-session", "name": "Ada", "text": "Question?", "created": "2026-07-17T12:00:00Z", "pane": NSNull(), "ended": true, "revivable": false]]
    let rawChanged = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(snapshot != rawChanged && snapshot.sameSidebarContent(as: rawChanged))
    changedNodes[0]["title"] = [["text": "resolved update", "role": "plain"]]
    sessions[0]["nodes"] = changedNodes
    object["sessions"] = sessions
    #expect(!snapshot.sameSidebarContent(as: try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))))
    object.removeValue(forKey: "asks")
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object)) }
    var item = nodes[0]
    item.removeValue(forKey: "program_status")
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: item)) }
}

@Test(arguments: ["2026-07-17T12:00:00Z", "2026-07-17T12:00:00.123Z"]) func outstandingAsks(_ created: String) throws {
    let json = "{\"id\":\"A12345678\",\"session\":\"agent-session\",\"name\":\"Ada\",\"text\":\"Question?\",\"created\":\"\(created)\",\"pane\":null,\"ended\":true,\"revivable\":false}"
    let ask = try JSONDecoder().decode(Ask.self, from: Data(json.utf8))
    #expect(ask.session == "agent-session" && ask.ended && !ask.revivable && ask.pane == nil)
}
