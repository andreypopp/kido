import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

@Test func decodesTheContractExample() throws {
    let line = """
        {
          "v": 1,
          "client": { "session": "$1", "window": "@2", "pane": "%3" },
          "filter": "",
          "error": null,
          "sessions": [
            {
              "id": "$1",
              "name": "main",
              "current": true,
              "rows": [
                {
                  "pane": "%3",
                  "window": "@2",
                  "tree": "\u{251C}",
                  "indicator": { "kind": "running" },
                  "title": [ { "text": "kido", "role": "current" } ],
                  "tail": [ { "text": " fixing tests", "role": "dim" } ],
                  "attention": false
                }
              ]
            }
          ]
        }
        """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    #expect(snapshot.v == 1)
    #expect(snapshot.client == Snapshot.Position(session: SessionID(number: 1), window: WindowID(number: 2), pane: PaneID(number: 3)))
    #expect(snapshot.filter == "")
    #expect(snapshot.error == nil)
    #expect(snapshot.sessions.count == 1)
    let session = snapshot.sessions[0]
    #expect(session.id == SessionID(number: 1))
    #expect(session.name == "main")
    #expect(session.current)
    #expect(session.rows.count == 1)
    let row = session.rows[0]
    #expect(row.pane == PaneID(number: 3))
    #expect(row.window == WindowID(number: 2))
    #expect(row.tree == "\u{251C}")
    #expect(row.indicator == Indicator(kind: .running, outcome: nil))
    #expect(row.title == [Span(text: "kido", role: .current)])
    #expect(row.tail == [Span(text: " fixing tests", role: .dim)])
    #expect(!row.attention)
}

@Test func decodesAGoneRowAndAnErrorLine() throws {
    let line = """
        {
          "v": 1,
          "client": { "session": "$1", "window": "@1", "pane": "%1" },
          "filter": "fix",
          "error": "no match",
          "sessions": [
            {
              "id": "$1",
              "name": "main",
              "current": true,
              "rows": [
                {
                  "pane": null,
                  "window": null,
                  "tree": "\u{2514}",
                  "indicator": { "kind": "gone", "outcome": "failed" },
                  "title": [],
                  "tail": [],
                  "attention": true
                }
              ]
            }
          ]
        }
        """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    #expect(snapshot.filter == "fix")
    #expect(snapshot.error == "no match")
    let row = snapshot.sessions[0].rows[0]
    #expect(row.pane == nil)
    #expect(row.window == nil)
    #expect(row.indicator == Indicator(kind: .gone, outcome: .failed))
    #expect(row.title.isEmpty)
    #expect(row.attention)
}

@Test func decodesARowWithNoIndicator() throws {
    let line = """
        {"v":1,"client":{"session":"$1","window":"@1","pane":"%1"},"filter":"","error":null,
         "sessions":[{"id":"$1","name":"main","current":true,"rows":[
           {"pane":"%1","window":"@1","tree":"","indicator":null,"title":[],"tail":[],"attention":false}
         ]}]}
        """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    #expect(snapshot.sessions[0].rows[0].indicator == nil)
}
