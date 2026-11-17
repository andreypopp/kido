import XCTest
import CryptoKit
import X509
@testable import Kido

final class IdentityTests: XCTestCase {
    func testEnrollmentVector() throws {
        let bundle = Bundle(for: Self.self)
        let tokenURL = try XCTUnwrap(bundle.url(forResource: "token", withExtension: nil, subdirectory: "testdata"))
        let pemURL = try XCTUnwrap(bundle.url(forResource: "device", withExtension: "pem", subdirectory: "testdata"))
        let expectedURL = try XCTUnwrap(bundle.url(forResource: "message", withExtension: "hex", subdirectory: "testdata"))
        let tokenText = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = try XCTUnwrap(Data(base64Encoded: tokenText.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="))
        let certificate = try Certificate(pemEncoded: String(contentsOf: pemURL, encoding: .utf8))
        let der = Data(try certificate.serializeAsPEM().derBytes)
        let message = enrollmentMessage(token: token, certificateDER: der)
        XCTAssertEqual(message.count, 79)
        XCTAssertEqual(message.map { String(format: "%02x", $0) }.joined(), try String(contentsOf: expectedURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testProfileAndFailedReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityStore(root: root)
        let host = try ServerName("ko.example.com")
        let identity = try store.create()
        let certificate = try Certificate(derEncoded: Array(identity.certificate))
        XCTAssertTrue(certificate.publicKey.isValidSignature(certificate.signature, for: certificate))
        let id = try String(contentsOf: root.appendingPathComponent("install-id"), encoding: .utf8).lowercased()
        XCTAssertEqual(try certificate.extensions.subjectAlternativeNames, SubjectAlternativeNames([.uniformResourceIdentifier("urn:kido:install:" + id)]))
        try store.commit(identity, for: host)
        let servers = root.appendingPathComponent("servers")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: servers.path)
        XCTAssertThrowsError(try store.commit(store.create(), for: host))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: servers.path)
        XCTAssertEqual(try store.load(host).certificate, identity.certificate)
        let other = try ServerName("other.example.com")
        try store.commit(identity, for: other)
        try store.forget(host)
        XCTAssertEqual(try store.load(other).certificate, identity.certificate)
        try Data([0]).write(to: servers.appendingPathComponent("other.example.com/key"))
        XCTAssertThrowsError(try store.load(other))
        XCTAssertThrowsError(try store.load(host))
    }

    func testCertificateAndStoreReplacementAndForget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityStore(root: root)
        let host = try ServerName("ko.example.com")
        let first = try store.create()
        let certificate = try Certificate(derEncoded: Array(first.certificate))
        XCTAssertEqual(certificate.version, .v3)
        XCTAssertEqual(certificate.issuer, certificate.subject)
        XCTAssertEqual(certificate.signatureAlgorithm, .ecdsaWithSHA256)
        XCTAssertEqual(certificate.notValidBefore, Date(timeIntervalSince1970: 1767225600))
        XCTAssertEqual(certificate.notValidAfter, Date(timeIntervalSince1970: 253402300799))
        XCTAssertEqual(try certificate.extensions.basicConstraints, .notCertificateAuthority)
        XCTAssertEqual(try certificate.extensions.keyUsage, KeyUsage(digitalSignature: true))
        XCTAssertEqual(try certificate.extensions.extendedKeyUsage, try ExtendedKeyUsage([.clientAuth]))
        try store.commit(first, for: host)
        XCTAssertEqual(try store.load(host).certificate, first.certificate)
        let message = Data("sign after reload".utf8)
        guard case .tls(_, _, let firstSigner) = store.endpoint(for: host, certificate: first.certificate) else { return XCTFail("Expected TLS") }
        let signature = try firstSigner.sign(message)
        XCTAssertFalse(signature.isEmpty)
        let directory = root.appendingPathComponent("servers/ko.example.com")
        for (path, permissions) in [(directory, 0o700), (directory.appendingPathComponent("key"), 0o600), (directory.appendingPathComponent("certificate.der"), 0o600)] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, permissions)
        }
        let second = try store.create()
        try store.commit(second, for: host)
        XCTAssertEqual(try store.load(host).certificate, second.certificate)
        XCTAssertThrowsError(try firstSigner.sign(message))
        guard case .tls(_, _, let secondSigner) = store.endpoint(for: host, certificate: second.certificate) else { return XCTFail("Expected TLS") }
        try store.forget(host)
        XCTAssertThrowsError(try secondSigner.sign(message))
    }
}
