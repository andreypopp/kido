import Foundation
import Testing
@testable import SidebarFeed

@Test(arguments: ["", "1", "1.0.0", "-1.0", "1.-1", "1.a", " 1.0", "1.0\n", ".0", "1.", "١.0"]) func invalidProtocol(_ text: String) {
    #expect(RPCVersion(text) == nil)
}

@Test(arguments: [("2.1", false), ("2.0", false), ("3.0", true), ("3.1", false), ("0.9", false), ("4.0", false)]) func protocolCompatibility(_ text: String, _ compatible: Bool) throws {
    #expect(try #require(RPCVersion(text)).compatible == compatible)
    #expect(RPCVersion.required.description == "3.0")
}

@Test func tolerantRawEnums() throws {
    let item = pane(3, window: 2, lifecycle: terminal(), run: "future", records: [["id": "", "state": "future", "kind": "future"]])
    let snapshot = try decode(snapshotObject([item], client: 3, window: 2))
    guard case .item(let decoded) = snapshot.sessions[0].nodes[0] else { Issue.record("not an item"); return }
    #expect(decoded.run == .unknown)
    #expect(decoded.program_status.records[0].state == .unknown && decoded.program_status.records[0].kind == .unknown)
}

@Test func rpcEventsInterleave() throws {
    let lines = [
        #"{"hello":{"protocol":"3.0"}}"#,
        #"{"reply":{"id":2,"switched":null}}"#,
        #"{"v":2,"client":{"session":"$1","window":"@2","pane":"%3"},"server_instance":{"started_at":1780000000,"pid":12345},"asks":[],"error":null,"sessions":[]}"#,
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

@Test(arguments: [(#"{"hello":{"protocol":"3.0","server":null}}"#, nil), (#"{"hello":{"protocol":"3.0","server":"9.9"}}"#, "9.9"), (#"{"hello":{"protocol":"3.0","server":"invalid"}}"#, nil)]) func rejectedHello(_ line: String, _ expected: String?) throws {
    guard case .hello(.rejected(let binary, let server)) = try JSONDecoder().decode(RPCEvent.self, from: Data(line.utf8)) else { Issue.record("not rejected"); return }
    #expect(binary == .required)
    #expect(server?.description == expected)
}
