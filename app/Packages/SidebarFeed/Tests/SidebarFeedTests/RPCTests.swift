import Foundation
import Testing
@testable import SidebarFeed

@Test(arguments: ["", "1", "1.0.0", "-1.0", "1.-1", "1.a", " 1.0", "1.0\n", ".0", "1.", "١.0"]) func invalidProtocol(_ text: String) {
    #expect(RPCVersion(text) == nil)
}

@Test(arguments: [("1.0", true), ("1.7", true), ("0.9", false), ("2.0", false)]) func protocolCompatibility(_ text: String, _ compatible: Bool) throws {
    #expect(try #require(RPCVersion(text)).compatible == compatible)
    #expect(RPCVersion.required.description == "1.0")
}

@Test func tolerantSnapshotEnums() throws {
    let line = #"{"v":2,"client":{"session":"$1","window":"@2","pane":"%3"},"filter":"","error":null,"sessions":[{"id":"$1","name":"main","current":true,"nodes":[{"kind":"future","id":"%3","pane":"%3","window":"@2","indicator":{"kind":"future"},"title":[{"text":"new","role":"future"}],"tail":[],"run":"future","started":null,"attention":false,"children":[]}]}]}"#
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    guard case .item(let item) = snapshot.sessions[0].nodes[0] else { Issue.record("not an item"); return }
    #expect(item.kind == .unknown)
    #expect(item.run == .unknown)
    #expect(item.indicator == .unknown)
    #expect(item.title[0].role == .unknown)
    #expect(try JSONDecoder().decode(Indicator.self, from: Data(#"{"kind":"gone","outcome":"future"}"#.utf8)) == .gone(.unknown))
}

@Test func rpcEventsInterleave() throws {
    let lines = [
        #"{"hello":{"protocol":"1.0"}}"#,
        #"{"reply":{"id":2,"switched":null}}"#,
        #"{"v":2,"client":{"session":"$1","window":"@2","pane":"%3"},"filter":"","error":null,"sessions":[]}"#,
        #"{"reply":{"id":1,"switched":{"session":"$3","window":"@12"}}}"#,
        #"{"reply":{"id":3,"error":"invalid or unknown request"}}"#,
    ]
    let events = try lines.map { try JSONDecoder().decode(RPCEvent.self, from: Data($0.utf8)) }
    guard case .hello(.accepted(let version)) = events[0], case .reply(let second) = events[1], case .snapshot = events[2],
          case .reply(let first) = events[3], case .reply(let failed) = events[4] else { Issue.record("wrong event shapes"); return }
    #expect(version.compatible)
    #expect(second.id == 2 && second.switched == nil && second.error == nil)
    #expect(first.id == 1 && first.switched?.window.description == "@12")
    #expect(failed.error == "invalid or unknown request")
}

@Test(arguments: [(#"{"hello":{"protocol":"1.0","server":null}}"#, nil), (#"{"hello":{"protocol":"1.0","server":"9.9"}}"#, "9.9"), (#"{"hello":{"protocol":"1.0","server":"invalid"}}"#, nil)]) func rejectedHello(_ line: String, _ expected: String?) throws {
    guard case .hello(.rejected(let server)) = try JSONDecoder().decode(RPCEvent.self, from: Data(line.utf8)) else { Issue.record("not rejected"); return }
    #expect(server?.description == expected)
}
