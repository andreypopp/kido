import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

@Test func sessionNameValidation() throws {
    let sessions = try JSONDecoder().decode([SessionNodes].self, from: Data("""
    [{"id":"$0","name":"main","current":true,"nodes":[]},{"id":"$1","name":"work","current":false,"nodes":[]}]
    """.utf8))
    for (text, expected) in [
        ("", SessionName.revert), ("   ", .revert), ("main", .revert),
        ("work", .reject("A session named “work” already exists.")),
        ("a:b", .reject("Session names can’t contain “:” or “.”.")),
        ("a.b", .reject("Session names can’t contain “:” or “.”.")),
        ("new name", .accept("new name"))
    ] {
        #expect(SessionName(text, operation: .rename(SessionID(number: 0), original: "main"), sessions: sessions) == expected)
    }
    for (text, expected) in [
        ("", SessionName.reject("Enter a session name.")),
        ("   ", .reject("Enter a session name.")),
        ("main", .reject("A session named “main” already exists.")),
        ("work", .reject("A session named “work” already exists.")),
        ("a:b", .reject("Session names can’t contain “:” or “.”.")),
        ("a.b", .reject("Session names can’t contain “:” or “.”.")),
        (" new name ", .accept("new name"))
    ] {
        #expect(SessionName(text, operation: .create, sessions: sessions) == expected)
    }
}
