import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

@Test func decodesContractTree() throws {
    let line = """
    {"v":2,"client":{"session":"$1","window":"@2","pane":"%3"},"server_instance":{"started_at":1780000000,"pid":12345},"asks":[],"error":null,"sessions":[
      {"id":"$1","name":"main","current":true,"nodes":[
        {"kind":"pane","id":"%3","pane":"%3","window":"@2","title":"kido","lifecycle":["Live",["Pi_agent",{"id":"pi-session-id","status":{"since":1780000000,"msg":"fixing tests","state":["Running",{"progress":null}]}}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[
          {"kind":"window","id":"@7","window":"@7","name":"build","children":[
            {"kind":"pane","id":"%9","pane":"%9","window":"@7","title":"tests","lifecycle":["Live",["Terminal",{"phase":["Running",{"origin":["Command",{"command":"make","started_at":1780000000}],"fullscreen":false}],"report":null}]],"program_status":{"serial":0,"records":[]},"run":"bash","started":1700000000.5,"children":[
              {"kind":"pane","id":"%11","pane":"%11","window":"@8","title":"ssh","lifecycle":["Live",["Ssh",{"user":"alice","host":"example.org","pane":["Remote_terminal",{"interactive":true,"status":{"phase":["Idle",{"last":null}],"report":null}}]}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[
                {"kind":"pane","id":"%12","pane":"%12","window":"@9","title":"helper","lifecycle":["Ended",{"result":"completed"}],"program_status":{"serial":0,"records":[]},"run":"agent","started":null,"children":[]}]}]},
            {"kind":"pane","id":"%10","pane":"%10","window":"@7","title":"zsh","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[]}]}]}]}]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    #expect(snapshot.client.pane == PaneID(number: 3))
    #expect(snapshot.serverInstance.startedAt == 1780000000 && snapshot.serverInstance.pid == 12345)
    #expect(snapshot.sessions[0].current)
    guard case .item(let agent) = snapshot.sessions[0].nodes[0],
        case .window(let group) = agent.children[0],
        case .item(let ssh) = group.children[0].children[0],
        case .item(let ended) = ssh.children[0] else { Issue.record("wrong tree shape"); return }
    #expect(agent.title == "kido")
    #expect(agent.lifecycle == .live(.piAgent(id: "pi-session-id", agent.agent!)))
    #expect(agent.agent?.msg == "fixing tests" && agent.agent?.state == .running(progress: nil))
    #expect(group.name == "build")
    #expect(group.children[0].run == .bash)
    #expect(group.children[0].started == Date(timeIntervalSince1970: 1_700_000_000.5))
    #expect(group.children[0].shell?.phase == .running(.init(command: "make", startedAt: Date(timeIntervalSince1970: 1780000000)), fullscreen: false))
    #expect(group.children[1].shell?.phase == .unknown)
    guard case .live(.ssh(let destination, .terminal(interactive: true, _))) = ssh.lifecycle else { Issue.record("not a remote terminal"); return }
    #expect(destination.user == "alice" && destination.host == "example.org")
    #expect(ended.lifecycle == .ended(.completed))
}

@Test func decodesEveryRFCVariant() throws {
    let lifecycles = [
        #"["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":null}]]"#,
        #"["Live",["Some_agent",{"name":"claude-code","status":{"since":1780000000,"msg":null,"state":["Idle",{"outcome":null}]}}]]"#,
        #"["Live",["Pi_agent",{"id":"pi-session-id","status":{"since":1780000000,"msg":null,"state":["Idle",{"outcome":null}]}}]]"#,
        #"["Live",["Ssh",{"user":"alice","host":"example.org","pane":["Remote_terminal",{"interactive":true,"status":{"phase":["Idle",{"last":null}],"report":null}}]}]]"#,
        #"["Live",["Ssh",{"user":"alice","host":"example.org","pane":["Remote_agent",{"name":"pi","status":{"since":1780000000,"msg":null,"state":["Idle",{"outcome":null}]}}]}]]"#,
        #"["Ended",{"result":"unknown"}]"#, #"["Ended",{"result":"completed"}]"#, #"["Ended",{"result":"failed"}]"#,
        #"["Ended",{"result":"died"}]"#, #"["Ended",{"result":"stopped"}]"#
    ]
    for json in lifecycles { _ = try JSONDecoder().decode(Lifecycle.self, from: Data(json.utf8)) }
    let agents: [(String, AgentStatus.State)] = [
        (#"{"since":1780000000,"msg":null,"state":["Running",{"progress":42}]}"#, .running(progress: 42)),
        (#"{"since":1780000000,"msg":"Approve deployment","state":["Waiting",{"source":["Blocked",{"kind":"permission"}],"progress":null}]}"#, .waiting(.blocked(.permission), progress: nil)),
        (#"{"since":1780000000,"msg":null,"state":["Waiting",{"source":["Blocked",{"kind":null}],"progress":7}]}"#, .waiting(.blocked(nil), progress: 7)),
        (#"{"since":1780000000,"msg":null,"state":["Waiting",{"source":["Ask",{"id":"ask-id"}],"progress":null}]}"#, .waiting(.ask(id: "ask-id"), progress: nil)),
        (#"{"since":1780000000,"msg":null,"state":["Stalled"]}"#, .stalled),
        (#"{"since":1780000000,"msg":null,"state":["Idle",{"outcome":null}]}"#, .idle(nil)),
        (#"{"since":1780000000,"msg":"Finished","state":["Idle",{"outcome":{"serial":17,"result":"success"}}]}"#, .idle(Outcome(serial: 17, result: .success))),
        (#"{"since":1780000000,"msg":"Failed","state":["Idle",{"outcome":{"serial":18,"result":"failure"}}]}"#, .idle(Outcome(serial: 18, result: .failure)))
    ]
    for (json, state) in agents { #expect(try JSONDecoder().decode(AgentStatus.self, from: Data(json.utf8)).state == state) }
    let phases = [
        #"{"phase":["Unknown"],"report":null}"#,
        #"{"phase":["Idle",{"last":null}],"report":null}"#,
        #"{"phase":["Idle",{"last":{"code":1,"command":"false","started_at":1780000000,"ended_at":1780000001}}],"report":null}"#,
        #"{"phase":["Idle",{"last":{"code":1,"command":"false","started_at":1780000000.0,"ended_at":1780000001.75}}],"report":null}"#,
        #"{"phase":["Running",{"origin":["Command",{"command":"make","started_at":1780000000}],"fullscreen":false}],"report":null}"#,
        #"{"phase":["Running",{"origin":["Command",{"command":"","started_at":1780000000}],"fullscreen":true}],"report":null}"#,
        #"{"phase":["Running",{"origin":["Unknown"],"fullscreen":true}],"report":null}"#
    ]
    for json in phases { _ = try JSONDecoder().decode(ShellStatus.self, from: Data(json.utf8)) }
    let reports: [(String, ShellStatus.Report.State)] = [
        (#"{"since":1780000000,"msg":null,"state":["Running",{"progress":42}]}"#, .running(progress: 42)),
        (#"{"since":1780000000,"msg":"Login required","state":["Waiting",{"kind":"auth","progress":null}]}"#, .waiting(.auth, progress: nil)),
        (#"{"since":1780000000,"msg":null,"state":["Idle",{"outcome":null}]}"#, .idle(nil)),
        (#"{"since":1780000000,"msg":"Built","state":["Idle",{"outcome":{"serial":17,"result":"success"}}]}"#, .idle(Outcome(serial: 17, result: .success))),
        (#"{"since":1780000000,"msg":"Build failed","state":["Idle",{"outcome":{"serial":18,"result":"failure"}}]}"#, .idle(Outcome(serial: 18, result: .failure)))
    ]
    for (json, state) in reports {
        let status = try JSONDecoder().decode(ShellStatus.self, from: Data(#"{"phase":["Unknown"],"report":\#(json)}"#.utf8))
        #expect(status.report?.state == state)
    }
    let pane = #"{"kind":"pane","id":"%1","pane":"%1","window":"@1","title":"zsh","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[]}"#
    guard case .item(let item) = try JSONDecoder().decode(SidebarFeed.Node.self, from: Data(pane.utf8)) else { Issue.record("not a pane"); return }
    #expect(item.title == "zsh" && item.run == nil && item.started == nil)
}

@Test(arguments: [
    #"["Live",["Terminal",{"phase":["Unknown",{}],"report":null}]]"#,
    #"["Live",["Terminal",{"phase":["Idle"],"report":null}]]"#,
    #"["Live",["Terminal",{"phase":["Idle",{}],"report":null}]]"#,
    #"["Live",["Terminal",{"phase":["Idle",{"last":null}]}]]"#,
    #"["Live",["Terminal",{"phase":["Running",{"origin":["Unknown"],"fullscreen":false}],"report":null}]]"#,
    #"["Live",["Terminal",{"phase":["Running",{"origin":["Command",{"command":"make"}],"fullscreen":false}],"report":null}]]"#,
    #"["Live",["Terminal",{"phase":["Future"],"report":null}]]"#,
    #"["Live",["Terminal",{"phase":["Idle",{"last":null}],"report":null}],"extra"]"#,
    #"["Live",["Some_agent",{"name":"claude-code","status":{"since":1,"state":["Idle",{"outcome":null}]}}]]"#,
    #"["Live",["Some_agent",{"name":"claude-code","status":{"since":1,"msg":null,"state":["Running",{"progress":101}]}}]]"#,
    #"["Live",["Some_agent",{"name":"claude-code","status":{"since":1,"msg":null,"state":["Running",{}]}}]]"#,
    #"["Live",["Some_agent",{"name":"claude-code","status":{"since":1,"msg":null,"state":["Stalled",{}]}}]]"#,
    #"["Live",["Some_agent",{"name":"claude-code","status":{"since":1,"msg":null,"state":["Waiting",{"source":["Ask",{"id":"a"}],"progress":3}]}}]]"#,
    #"["Live",["Some_agent",{"name":"claude-code","status":{"since":1,"msg":null,"state":["Idle",{"outcome":{"serial":1,"result":"done"}}]}}]]"#,
    #"["Live",["Ssh",{"user":"alice","pane":["Remote_terminal",{"interactive":true,"status":{"phase":["Unknown"],"report":null}}]}]]"#,
    #"["Live",["Ssh",{"user":"alice","host":"h","pane":["Remote_shell",{}]}]]"#,
    #"["Live",["Shell",{"phase":["Unknown"],"report":null}]]"#,
    #"["Ended",{"result":"future"}]"#,
    #"["Ended"]"#,
    #"{"kind":"idle"}"#
]) func rejectsMalformedLifecycles(_ json: String) {
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Lifecycle.self, from: Data(json.utf8)) }
}

@Test(arguments: [1, 3]) func rejectsOtherVersions(_ version: Int) throws {
    var object = snapshotObject([])
    object["v"] = version
    #expect(throws: DecodingError.self) { try decode(object) }
}

@Test(arguments: [nil, ["started_at": 0, "pid": 1], ["started_at": 1780000000, "pid": -1], ["started_at": 1780000000]] as [[String: Int]?])
func requiresServerInstance(_ instance: [String: Int]?) {
    var object = snapshotObject([])
    object["server_instance"] = instance
    #expect(throws: DecodingError.self) { try decode(object) }
}

@Test(arguments: [
    "{\"kind\":\"window\",\"id\":\"@1\",\"window\":\"@1\",\"name\":\"panes\",\"children\":[{\"kind\":\"window\",\"id\":\"@2\",\"window\":\"@2\",\"name\":\"panes\",\"children\":[]}]}",
    "{\"kind\":\"window\",\"id\":\"@1\",\"window\":\"@2\",\"name\":\"panes\",\"children\":[]}",
    "{\"kind\":\"window\",\"id\":\"@1\",\"window\":\"@1\",\"name\":\"panes\",\"children\":[]}"
]) func rejectsMalformedWindows(_ line: String) {
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(SidebarFeed.Node.self, from: Data(line.utf8)) }
}

@Test func rejectsMalformedPanes() {
    var cases: [[String: Any]] = []
    for (key, value) in [("id", "%2"), ("window", null), ("kind", "agent"), ("title", [] as [Any])] as [(String, Any)] {
        var item = pane(1)
        item[key] = value
        cases.append(item)
    }
    for key in ["run", "started", "children", "lifecycle", "title"] {
        var item = pane(1)
        item.removeValue(forKey: key)
        cases.append(item)
    }
    cases += [pane(1, started: 100), pane(1, lifecycle: ["Ended", ["result": "completed"]]),
              pane(1, lifecycle: ["Ended", ["result": "completed"]], run: "agent", started: 100)]
    for item in cases {
        #expect(throws: DecodingError.self) { try decode(item, as: SidebarFeed.Node.self) }
    }
    #expect((try? decode(pane(1, lifecycle: ["Ended", ["result": "completed"]], run: "agent"), as: SidebarFeed.Node.self)) != nil)
}

@Test func windowGroupRequiresName() throws {
    let group: [String: Any] = ["kind": "window", "id": "@1", "window": "@1", "children": [pane(1, window: 1), pane(2, window: 1)]]
    #expect(throws: DecodingError.self) { try decode(group, as: SidebarFeed.Node.self) }
    var named = group
    named["name"] = "panes"
    #expect((try? decode(named, as: SidebarFeed.Node.self)) != nil)
}

@Test func decodesErrorAndEmptySessions() throws {
    let snapshot = try decode(snapshotObject([], sessions: [], error: "state unreadable"))
    #expect(snapshot.asks.isEmpty)
    #expect(snapshot.error == "state unreadable")
    #expect(snapshot.sessions.isEmpty)
}

@Test(arguments: [false, true]) func nodeIdentityIsScopedToSession(_ duplicate: Bool) throws {
    var object = snapshotObject(duplicate ? [pane(1), pane(1)] : [pane(1)])
    var sessions = object["sessions"] as! [[String: Any]]
    sessions.append(["id": "$1", "name": "work", "current": false, "nodes": [pane(1)]])
    object["sessions"] = sessions
    if duplicate {
        #expect(throws: DecodingError.self) { try decode(object) }
    } else {
        let snapshot = try decode(object)
        #expect(snapshot.sessions[0].nodes == snapshot.sessions[1].nodes)
    }
}

@Test func decodesCapturedKido30Feed() throws {
    let hello = #"{"hello":{"protocol":"3.0"}}"#
    let line = #"{"v":2,"server_instance":{"started_at":1791708862,"pid":10744},"client":{"session":"$1","window":"@1","pane":"%1"},"asks":[],"error":null,"sessions":[{"id":"$0","name":"main","current":false,"nodes":[{"kind":"pane","id":"%0","pane":"%0","window":"@0","title":"zsh","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[]}]},{"id":"$1","name":"probe","current":true,"nodes":[{"kind":"window","id":"@1","window":"@1","name":"sleep","children":[{"kind":"pane","id":"%1","pane":"%1","window":"@1","title":"mpb-andre.local","lifecycle":["Live",["Some_agent",{"name":"claude-code","status":{"since":1791708863.57487,"msg":"Approve","state":["Waiting",{"source":["Blocked",{"kind":"permission"}],"progress":null}]}}]],"program_status":{"serial":2,"records":[{"id":"","state":"blocked","app":"claude-code","kind":"permission","msg":"Approve"},{"id":"sub","state":"error","title":"Sub"}]},"run":null,"started":null,"children":[]},{"kind":"pane","id":"%2","pane":"%2","window":"@1","title":"builder","lifecycle":["Live",["Terminal",{"phase":["Unknown"],"report":{"since":1791708863.57487,"msg":"Built","state":["Idle",{"outcome":{"serial":2,"result":"success"}}]}}]],"program_status":{"serial":2,"records":[{"id":"","state":"done","app":"builder","msg":"Built"}]},"run":null,"started":null,"children":[]}]},{"kind":"pane","id":"%3","pane":"%3","window":"@2","title":"mpb-andre.local","lifecycle":["Live",["Some_agent",{"name":"claude-code","status":{"since":1791708863.57487,"msg":null,"state":["Waiting",{"source":["Blocked",{"kind":null}],"progress":null}]}}]],"program_status":{"serial":1,"records":[{"id":"","state":"blocked","app":"claude-code"}]},"run":null,"started":null,"children":[]},{"kind":"pane","id":"%4","pane":"%4","window":"@3","title":"less","lifecycle":["Live",["Terminal",{"phase":["Running",{"origin":["Unknown"],"fullscreen":true}],"report":null}]],"program_status":{"serial":0,"records":[]},"run":null,"started":null,"children":[]}]}]}"#
    guard case .hello(.accepted(let version)) = try JSONDecoder().decode(RPCEvent.self, from: Data(hello.utf8)) else { Issue.record("no hello"); return }
    #expect(version.compatible)
    guard case .snapshot(let snapshot) = try JSONDecoder().decode(RPCEvent.self, from: Data(line.utf8)) else { Issue.record("no snapshot"); return }
    let rows = sidebarRows(snapshot).filter { $0.target != nil }
    #expect(rows.map(\.title) == ["zsh", "@mpb-andre.local", "builder", "@mpb-andre.local", "less"])
    #expect(rows.map(\.status) == [.quiet, .waiting, .done, .waiting, .quiet])
    #expect(rows.map(\.tail) == ["", "Approve", "Built", "", ""])
    let programs = sidebarRows(snapshot).filter { if case .program = $0.kind { true } else { false } }
    #expect(programs.map(\.status) == [.error])
}
