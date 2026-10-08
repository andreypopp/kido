import Foundation
import Testing
@testable import SidebarFeed

@Test(arguments: ["", "1", "1.0.0", "-1.0", "1.-1", "1.a", " 1.0", "1.0\n", ".0", "1.", "١.0"]) func invalidProtocol(_ text: String) {
    #expect(RPCVersion(text) == nil)
}

@Test(arguments: [("1.1", false), ("2.0", true), ("2.1", false), ("0.9", false), ("3.0", false)]) func protocolCompatibility(_ text: String, _ compatible: Bool) throws {
    #expect(try #require(RPCVersion(text)).compatible == compatible)
    #expect(RPCVersion.required.description == "2.0")
}

@Test func tolerantSnapshotEnums() throws {
    let line = #"{"v":2,"client":{"session":"$1","window":"@2","pane":"%3"},"asks":[],"error":null,"sessions":[{"id":"$1","name":"main","current":true,"nodes":[{"kind":"future","id":"%3","pane":"%3","window":"@2","indicator":{"kind":"future"},"program_status":{"serial":0,"records":[]},"title":[{"text":"new","role":"future"}],"tail":[],"run":"future","started":null,"attention":false,"children":[]}]}]}"#
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
        #"{"hello":{"protocol":"2.0"}}"#,
        #"{"reply":{"id":2,"switched":null}}"#,
        #"{"v":2,"client":{"session":"$1","window":"@2","pane":"%3"},"asks":[],"error":null,"sessions":[]}"#,
        #"{"reply":{"id":1,"switched":{"session":"$3","window":"@12"}}}"#,
        #"{"reply":{"id":3,"error":"invalid or unknown request"}}"#,
    ]
    let events = try lines.map { try JSONDecoder().decode(RPCEvent.self, from: Data($0.utf8)) }
    guard case .hello(.accepted(let version)) = events[0], case .reply(let second) = events[1], case .snapshot = events[2],
          case .reply(let first) = events[3], case .reply(let failed) = events[4] else { Issue.record("wrong event shapes"); return }
    #expect(version.compatible)
    guard case .switched(nil) = second.value, case .switched(let target) = first.value, case .error(let error) = failed.value else { Issue.record("wrong replies"); return }
    #expect(second.id == 2)
    #expect(first.id == 1 && target?.window.description == "@12")
    #expect(error == "invalid or unknown request")
}

@Test(arguments: [(#"{"hello":{"protocol":"2.0","server":null}}"#, nil), (#"{"hello":{"protocol":"2.0","server":"9.9"}}"#, "9.9"), (#"{"hello":{"protocol":"2.0","server":"invalid"}}"#, nil)]) func rejectedHello(_ line: String, _ expected: String?) throws {
    guard case .hello(.rejected(let binary, let server)) = try JSONDecoder().decode(RPCEvent.self, from: Data(line.utf8)) else { Issue.record("not rejected"); return }
    #expect(binary == .required)
    #expect(server?.description == expected)
}
