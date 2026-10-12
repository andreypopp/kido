import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

@Test func sessionRenameValidation() throws {
    let sessions = try JSONDecoder().decode([SessionNodes].self, from: Data("""
    [{"id":"$0","name":"main","current":true,"nodes":[]},{"id":"$1","name":"work","current":false,"nodes":[]}]
    """.utf8))
    for (text, expected) in [
        ("", SessionRename.revert), ("   ", .revert), ("main", .revert),
        ("work", .reject("A session named “work” already exists.")),
        ("a:b", .reject("Session names can’t contain “:” or “.”.")),
        ("a.b", .reject("Session names can’t contain “:” or “.”.")),
        ("new name", .rename("new name"))
    ] {
        #expect(SessionRename(text, session: SessionID(number: 0), original: "main", sessions: sessions) == expected)
    }
}
