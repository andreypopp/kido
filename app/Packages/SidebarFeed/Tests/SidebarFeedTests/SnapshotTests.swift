import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

@Test func decodesContractTree() throws {
    let line = """
    {"v":2,"client":{"session":"$1","window":"@2","pane":"%3"},"asks":[],"error":null,"sessions":[
      {"id":"$1","name":"main","current":true,"nodes":[
        {"kind":"agent","id":"%3","pane":"%3","window":"@2","indicator":{"kind":"running"},"program_status":{"serial":0,"records":[]},"title":[{"text":"kido","role":"current"}],"tail":[{"text":"fixing tests","role":"dim"}],"run":null,"started":null,"attention":false,"children":[
          {"kind":"window","id":"@7","window":"@7","name":"build","children":[
            {"kind":"run","id":"%9","pane":"%9","window":"@7","indicator":{"kind":"running"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":"bash","started":1700000000.5,"attention":false,"children":[
              {"kind":"ssh","id":"%11","pane":"%11","window":"@8","indicator":{"kind":"stalled"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":null,"started":null,"attention":true,"children":[
                {"kind":"agent","id":"%12","pane":"%12","window":"@9","indicator":{"kind":"gone","outcome":"completed"},"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":null,"started":null,"attention":true,"children":[]}]}]},
            {"kind":"shell","id":"%10","pane":"%10","window":"@7","indicator":null,"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":null,"started":null,"attention":false,"children":[]}]}]}]}]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    #expect(snapshot.client.pane == PaneID(number: 3))
    #expect(snapshot.sessions[0].current)
    guard case .item(let agent) = snapshot.sessions[0].nodes[0],
        case .window(let group) = agent.children[0],
        case .item(let ssh) = group.children[0].children[0],
        case .item(let gone) = ssh.children[0] else { Issue.record("wrong tree shape"); return }
    #expect(agent.kind == .agent)
    #expect(agent.title == [Span(text: "kido", role: .current)])
    #expect(group.name == "build")
    #expect(group.children[0].kind == .run)
    #expect(group.children[0].started == Date(timeIntervalSince1970: 1_700_000_000.5))
    #expect(group.children[1].kind == .shell)
    #expect(group.children[1].indicator == nil)
    #expect(ssh.kind == .ssh && ssh.attention && ssh.indicator == .stalled)
    #expect(gone.indicator == .gone(.completed))
}

@Test(arguments: [1, 3]) func rejectsOtherVersions(_ version: Int) {
    let line = """
    {"v":\(version),"client":{"session":"$1","window":"@1","pane":"%1"},"asks":[],"error":null,"sessions":[]}
    """
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8)) }
}

@Test(arguments: [
    "{\"kind\":\"window\",\"id\":\"@1\",\"window\":\"@1\",\"name\":\"panes\",\"children\":[{\"kind\":\"window\",\"id\":\"@2\",\"window\":\"@2\",\"name\":\"panes\",\"children\":[]}]}",
    "{\"kind\":\"window\",\"id\":\"@1\",\"window\":\"@2\",\"name\":\"panes\",\"children\":[]}",
    "{\"kind\":\"window\",\"id\":\"@1\",\"window\":\"@1\",\"name\":\"panes\",\"children\":[]}",
    "{\"kind\":\"agent\",\"id\":\"%2\",\"pane\":\"%1\",\"window\":\"@1\",\"title\":[],\"tail\":[],\"attention\":false,\"children\":[]}",
    "{\"kind\":\"shell\",\"id\":\"%1\",\"pane\":\"%1\",\"window\":null,\"title\":[],\"tail\":[],\"attention\":false,\"children\":[]}",
    "{\"kind\":\"run\",\"id\":\"%1\",\"pane\":\"%1\",\"window\":\"@1\",\"title\":[],\"tail\":[],\"attention\":false}"
]) func rejectsMalformedNodes(_ line: String) {
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(SidebarFeed.Node.self, from: Data(line.utf8)) }
}

@Test func windowGroupRequiresName() {
    let line = """
    {"kind":"window","id":"@1","window":"@1","children":[
      {"kind":"shell","id":"%1","pane":"%1","window":"@1","indicator":null,"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":null,"started":null,"attention":false,"children":[]},
      {"kind":"shell","id":"%2","pane":"%2","window":"@1","indicator":null,"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":null,"started":null,"attention":false,"children":[]}]}
    """
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(SidebarFeed.Node.self, from: Data(line.utf8)) }
}

@Test func decodesErrorAndEmptySessions() throws {
    let line = """
    {"v":2,"client":{"session":"$1","window":"@1","pane":"%1"},"asks":[],"error":"state unreadable","sessions":[]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    #expect(snapshot.asks.isEmpty)
    #expect(snapshot.error == "state unreadable")
    #expect(snapshot.sessions.isEmpty)
}

@Test(arguments: [false, true]) func nodeIdentityIsScopedToSession(_ duplicate: Bool) throws {
    let item = #"{"kind":"shell","id":"%1","pane":"%1","window":"@1","indicator":null,"program_status":{"serial":0,"records":[]},"title":[],"tail":[],"run":null,"started":null,"attention":false,"children":[]}"#
    let nodes = duplicate ? "\(item),\(item)" : item
    let line = """
    {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"asks":[],"error":null,"sessions":[
      {"id":"$0","name":"main","current":true,"nodes":[\(nodes)]},
      {"id":"$1","name":"work","current":false,"nodes":[\(item)]}]}
    """
    if duplicate {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8)) }
    } else {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
        #expect(snapshot.sessions[0].nodes == snapshot.sessions[1].nodes)
    }
}
