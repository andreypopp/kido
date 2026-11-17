import XCTest
import KidoPairing

final class ServerNameTests: XCTestCase {
    func testDNSName() throws {
        XCTAssertEqual(try ServerName("KO.Example.COM").value, "ko.example.com")
        for invalid in ["", "127.0.0.1", "[::1]", "user@ko.example.com", "ko.example.com:443", "ko.example.com.", "a..example.com", "-a.example.com", "a-.example.com", "é.example.com", "Ko.example.com", "a/b.example.com"] {
            XCTAssertThrowsError(try ServerName(invalid))
        }
    }
}
