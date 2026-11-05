import Foundation
import Testing
import KoModel
@testable import SidebarFeed

@Test func sessionNameValidation() throws {
    let sessions = [SessionNodes(id: SessionID(number: 0), name: "main", current: true, nodes: []),
                    SessionNodes(id: SessionID(number: 1), name: "work", current: false, nodes: [])]
    for (text, expected) in [
        ("", SessionName.revert), ("   ", .revert), ("main", .revert),
        ("work", .reject("A session named “work” already exists.")),
        ("a:b", .accept("a:b")),
        ("a.b", .accept("a.b")),
        ("new name", .accept("new name"))
    ] {
        #expect(SessionName(text, operation: .rename(SessionID(number: 0), original: "main"), sessions: sessions) == expected)
    }
    for (text, expected) in [
        ("", SessionName.reject("Enter a session name.")),
        ("   ", .reject("Enter a session name.")),
        ("main", .reject("A session named “main” already exists.")),
        ("work", .reject("A session named “work” already exists.")),
        ("a:b", .accept("a:b")),
        ("a.b", .accept("a.b")),
        (" new name ", .accept("new name"))
    ] {
        #expect(SessionName(text, operation: .create, sessions: sessions) == expected)
    }
}
