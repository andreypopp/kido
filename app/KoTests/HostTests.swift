import XCTest
@testable import Kido

final class HostTests: XCTestCase {
    func testTLSHostAndTypedHistory() throws {
        let name = try ServerName("KO.Example.COM")
        XCTAssertEqual(name.value, "ko.example.com")
        let tls = Host.tls(name)
        XCTAssertEqual(tls.clipboardKey, "tls:ko.example.com")
        for invalid in ["", "127.0.0.1", "[::1]", "user@ko.example.com", "ko.example.com:443", "ko.example.com.", "a..example.com", "-a.example.com", "a-.example.com", "é.example.com", "Ko.example.com", "a/b.example.com"] {
            XCTAssertThrowsError(try ServerName(invalid))
        }
        var recent = RecentHosts()
        recent.add(.local, at: Date())
        XCTAssertTrue(recent.isEmpty)
        let ssh = Host.remote(name.value)
        recent.add(ssh, at: Date(timeIntervalSince1970: 10))
        recent.add(tls, at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(recent.entries.map(\.host), [tls, ssh])
        recent.add(ssh, at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(recent.entries.map(\.host), [ssh, tls])
        XCTAssertEqual(try JSONDecoder().decode(RecentHosts.self, from: JSONEncoder().encode(recent)), recent)
        XCTAssertThrowsError(try JSONDecoder().decode(RecentHosts.self, from: Data(#"{"entries":[{"host":"ko.example.com","date":0}]}"#.utf8)))
        recent.remove(tls)
        XCTAssertEqual(recent.entries.map(\.host), [ssh])
        recent.clear()
        XCTAssertTrue(recent.isEmpty)
    }
}
