import XCTest
import AppKit
import KidoPairing
@testable import Kido

@MainActor final class PairingTests: XCTestCase {
    private func payload(host: String = "ko.example.com") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["v": 1, "host": host, "enroll": "https://enroll.example.com/v1/enroll", "name": "Test Server", "token": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]), as: UTF8.self)
    }

    func testStoredNameAndDNSMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pair-display-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityStore(root: root)
        let host = try ServerName("ko.example.com")
        let tls = Host.tls(host)
        XCTAssertEqual(tls.title(in: store), host.value)
        let identity = try store.create()
        try store.commit(identity, for: host, name: PairingName("Home VM"))
        let app = AppDelegate(identities: store)
        app.routes.remember(tls)
        let entry = try XCTUnwrap(app.connectEntries(query: "Home", invalid: true).first)
        XCTAssertEqual(entry.entry.title, "Home VM")
        XCTAssertEqual(entry.entry.hostKind, "https · ko.example.com")
        XCTAssertFalse(entry.offsets[0].isEmpty)
        XCTAssertTrue(entry.offsets[2].isEmpty)
        let dns = try XCTUnwrap(app.connectEntries(query: host.value, invalid: true).first)
        XCTAssertTrue(dns.offsets[0].isEmpty)
        XCTAssertFalse(dns.offsets[2].isEmpty)
        XCTAssertEqual(AppDelegate.forgetAlert(host, identities: store).informativeText, "This Mac's key and certificate for Home VM (ko.example.com) are deleted. Pair again to connect.")
        try store.commit(identity, for: host, name: PairingName("New VM"))
        XCTAssertEqual(tls.title(in: store), "New VM")
        XCTAssertEqual(app.connectEntries(query: "New", invalid: true).first?.entry.title, "New VM")
        try store.forget(host)
        XCTAssertEqual(tls.title(in: store), host.value)
    }

    func testCorrectedCodeReturnsToParsedLine() throws {
        let store = IdentityStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let attempt = PairingSession(store: store, expectedHost: nil, defaultDeviceName: "Mac", claim: { _ in false }, release: { _ in })
        let view = PalettePair(frame: .zero)
        let field = NSTextField(string: "invalid")
        view.codeField = field
        view.session = attempt
        attempt.submit(field.stringValue, name: "Mac")
        field.stringValue = try payload()
        attempt.edited()
        view.refresh()
        XCTAssertTrue(view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Pairs this Mac with Test Server (ko.example.com)" })
        attempt.submit(field.stringValue, name: "Mac")
        field.stringValue = try payload(host: "fresh.example.com")
        attempt.edited()
        view.refresh()
        XCTAssertTrue(view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Pairs this Mac with Test Server (fresh.example.com)" })
    }

}
