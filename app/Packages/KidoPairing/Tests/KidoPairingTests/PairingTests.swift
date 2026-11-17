import XCTest
import CryptoKit
import X509
@testable import KidoPairing

@MainActor final class PairingTests: XCTestCase {
    private var tokens: Set<Data> = []
    private func session(store: IdentityStore, expectedHost: ServerName?, enroll: @escaping (PairingCode, EnrollmentRequest, Data) async throws -> EnrollmentResult) -> PairingSession {
        PairingSession(store: store, expectedHost: expectedHost, defaultDeviceName: "Mac",
                       claim: { [self] in tokens.insert($0).inserted }, release: { [self] in tokens.remove($0) }, enroll: enroll)
    }
    private func payload(host: String = "ko.example.com", enroll: String = "https://enroll.example.com/v1/enroll", token: String = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", version: Int = 1) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["v": version, "host": host, "enroll": enroll, "name": "Test Server", "token": token]), as: UTF8.self)
    }

    func testPayloadValidation() throws {
        let text = try payload()
        XCTAssertEqual(try PairingCode(" \n kido-pair:" + text + "\n").host.value, "ko.example.com")
        XCTAssertEqual(try PairingCode(text).token, Data(repeating: 0, count: 32))
        for value in [try payload(version: 2), try payload(host: "127.0.0.1"), try payload(host: "a..example.com"), try payload(enroll: "http://enroll.example.com/v1/enroll"), try payload(enroll: "https://user@enroll.example.com/v1/enroll"), try payload(enroll: "https://enroll.example.com/else"), try payload(enroll: "https://enroll.example.com:8443/v1/enroll"), try payload(token: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"), text + "junk"] {
            XCTAssertThrowsError(try PairingCode(value))
        }
        XCTAssertThrowsError(try PairingCode(text, expectedHost: ServerName("other.example.com")))
        for name in ["", String(repeating: "x", count: 65), "Server\n", "Server\u{85}"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            object["name"] = name
            let invalid = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertThrowsError(try PairingCode(invalid)) { error in
                XCTAssertEqual(error as? PairingFailure, PairingFailure(message: "Not a pairing code"))
            }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        object.removeValue(forKey: "name")
        let missing = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertThrowsError(try PairingCode(missing)) { error in
            XCTAssertEqual(error as? PairingFailure, PairingFailure(message: "Not a pairing code"))
        }
    }

    func testRequestBodyAndName() throws {
        let code = try PairingCode(payload())
        let request = try EnrollmentRequest(code: code, name: PairingName("My Mac"), certificate: Data([1, 2]), signature: Data([3, 4]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body()) as? [String: String])
        XCTAssertEqual(object, ["token": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "name": "My Mac", "certificate": "AQI=", "signature": "AwQ="])
        for name in ["", String(repeating: "x", count: 65), "Mac\n", "Mac\u{85}", String(repeating: "e\u{301}", count: 33)] {
            XCTAssertThrowsError(try PairingName(name))
        }
    }

    func testHTTPResultsAndNoRedirect() async throws {
        let bundle = Bundle.module
        let pem = try String(contentsOf: XCTUnwrap(bundle.url(forResource: "device", withExtension: "pem", subdirectory: "testdata")), encoding: .utf8)
        let certificate = Data(try Certificate(pemEncoded: pem).serializeAsPEM().derBytes)
        let keyPEM = try String(contentsOf: XCTUnwrap(bundle.url(forResource: "device", withExtension: "key", subdirectory: "testdata")), encoding: .utf8)
        let key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        let fingerprint = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        let cases: [(PairingProtocol.Reply, EnrollmentResult)] = [
            (.response(200, Data("{\"fingerprint\":\"\(fingerprint)\"}".utf8)), .accepted),
            (.response(400, Data()), .rejected(400)), (.response(403, Data()), .rejected(403)),
            (.response(429, Data()), .rejected(429)), (.response(200, Data("malformed".utf8)), .uncertain),
            (.disconnect, .uncertain), (.redirect, .rejected(302))
        ]
        for (reply, expected) in cases {
            PairingProtocol.fixture.set(reply)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PairingProtocol.self]
            let code = try PairingCode(payload())
            let signature = try key.signature(for: enrollmentMessage(token: code.token, certificateDER: certificate)).derRepresentation
            let request = try EnrollmentRequest(code: code, name: PairingName("Mac"), certificate: certificate, signature: signature)
            let result = try await EnrollmentTransport.send(code: code, request: request, certificate: certificate, configuration: configuration)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(PairingProtocol.fixture.count, 1)
        }
    }

    @MainActor func testActivationDeadlineAndTerminalCertificate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("activation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try IdentityStore(root: root).create()
        let host = try ServerName("ko.example.com")
        var instant = ContinuousClock.now
        var probes = 0
        let result = await PairingSession.activate(host: host, identity: identity, probe: { _, _, within in
            XCTAssertEqual(within, .seconds(1))
            probes += 1
            return probes == 2 ? .ready : .identity
        }, now: { instant }, wait: { instant = instant.advanced(by: $0) })
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(probes, 2)
        probes = 0
        let timeout = await PairingSession.activate(host: host, identity: identity, probe: { _, _, _ in probes += 1; return .noServer }, now: { instant }, wait: { instant = instant.advanced(by: $0) })
        XCTAssertEqual(timeout, .failed(.timedOut))
        XCTAssertEqual(probes, 30)
        let refused = await PairingSession.activate(host: host, identity: identity, probe: { _, _, _ in .serverCertificate("expired") }, now: { instant }, wait: { _ in XCTFail("A TLS failure must not retry") })
        XCTAssertEqual(refused, .failed(.serverCertificate("expired")))
    }

    @MainActor func testUncertainCommitsAndRejectedPairAgainKeepsOldIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pair-session-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityStore(root: root)
        let host = try ServerName("ko.example.com")
        let old = try store.create()
        try store.commit(old, for: host, name: PairingName("Test Server"))
        let rejected = expectation(description: "Rejected")
        var posts = 0
        let attempt = session(store: store, expectedHost: host, enroll: { _, _, _ in posts += 1; return .rejected(403) })
        attempt.changed = { if case .rejected = attempt.state { rejected.fulfill() } }
        attempt.submit(try payload(), name: "Mac")
        await fulfillment(of: [rejected], timeout: 5)
        attempt.changed = nil
        XCTAssertEqual(try store.load(host).certificate, old.certificate)
        attempt.submit(try payload(), name: "Mac")
        XCTAssertEqual(posts, 1)
        let committed = expectation(description: "Committed")
        let uncertain = session(store: store, expectedHost: host, enroll: { _, _, _ in posts += 1; return .uncertain })
        uncertain.changed = { if case .uncertain = uncertain.state { committed.fulfill() } }
        let freshToken = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        uncertain.submit(try payload(token: freshToken), name: "Mac")
        await fulfillment(of: [committed], timeout: 5)
        XCTAssertNotEqual(try store.load(host).certificate, old.certificate)
        XCTAssertEqual(try store.name(for: host)?.value, "Test Server")
        uncertain.retrySend()
        uncertain.submit(try payload(), name: "Mac")
        XCTAssertEqual(posts, 2)
        attempt.changed = nil
        uncertain.changed = nil
    }

    @MainActor func testExplicitCertainRetryUsesFreshIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pair-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityStore(root: root)
        let host = try ServerName("ko.example.com")
        var certificates: [Data] = []
        let retryable = expectation(description: "Safe retry")
        let committed = expectation(description: "Uncertain committed")
        let attempt = session(store: store, expectedHost: nil, enroll: { _, request, certificate in
            XCTAssertEqual(request.name, "First Mac")
            certificates.append(certificate)
            return certificates.count == 1 ? .retryable("offline") : .uncertain
        })
        attempt.changed = {
            if case .retryable = attempt.state { retryable.fulfill() }
            if case .uncertain = attempt.state { committed.fulfill() }
        }
        attempt.submit(try payload(), name: "First Mac")
        await fulfillment(of: [retryable], timeout: 5)
        XCTAssertEqual(certificates.count, 1)
        XCTAssertThrowsError(try store.load(host))
        attempt.retrySend()
        await fulfillment(of: [committed], timeout: 5)
        XCTAssertEqual(certificates.count, 2)
        XCTAssertNotEqual(certificates[0], certificates[1])
        XCTAssertEqual(try store.load(host).certificate, certificates[1])
        XCTAssertEqual(try store.name(for: host)?.value, "Test Server")
        attempt.changed = nil
    }

    func testOnePostAcrossPendingAndUncertainSessionsAndEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pair-dedup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityStore(root: root)
        let started = expectation(description: "POST started")
        let committed = expectation(description: "Uncertain committed")
        var reply: CheckedContinuation<EnrollmentResult, Never>?
        var posts = 0
        let first = session(store: store, expectedHost: nil, enroll: { _, _, _ in
            posts += 1
            started.fulfill()
            return await withCheckedContinuation { reply = $0 }
        })
        first.submit(try payload(), name: "Mac")
        await fulfillment(of: [started], timeout: 5)
        first.changed = nil
        let second = session(store: store, expectedHost: nil, enroll: { _, _, _ in posts += 1; return .uncertain })
        second.submit(try payload(), name: "Mac")
        guard case .rejected(let reason) = second.state else { return XCTFail("A pending token must be refused") }
        XCTAssertEqual(reason, .usedOrExpired)
        first.changed = { if case .uncertain = first.state { committed.fulfill() } }
        reply?.resume(returning: .uncertain)
        await fulfillment(of: [committed], timeout: 5)
        first.changed = nil
        let third = session(store: store, expectedHost: nil, enroll: { _, _, _ in posts += 1; return .uncertain })
        third.submit("not a code", name: "Mac")
        third.edited()
        guard case .editing = third.state else { return XCTFail("Editing must clear the old error") }
        third.submit(try payload(), name: "Mac")
        guard case .rejected = third.state else { return XCTFail("The token is still spent after invalid input") }
        XCTAssertEqual(posts, 1)
        third.edited()
        let fresh = try payload(token: Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""))
        XCTAssertNoThrow(try PairingCode(fresh))
        guard case .editing = third.state else { return XCTFail("A fresh code must return to validation") }
    }

    func testCertainFailureClassifier() {
        let certain: [URLError.Code] = [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .cannotLoadFromNetwork]
        for code in certain {
            XCTAssertTrue(certainEnrollmentFailure(URLError(code), bytesSent: 0))
            XCTAssertFalse(certainEnrollmentFailure(URLError(code), bytesSent: 1))
        }
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .cancelled, .badServerResponse, .unknown] {
            XCTAssertFalse(certainEnrollmentFailure(URLError(code), bytesSent: 0))
        }
        XCTAssertFalse(certainEnrollmentFailure(PairingFailure(message: "Other"), bytesSent: 0))
    }
}

private final class PairingProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case response(Int, Data), disconnect, redirect }
    final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: Reply = .disconnect
        private var requests = 0
        var count: Int { lock.withLock { requests } }
        func set(_ reply: Reply) { lock.withLock { self.reply = reply; requests = 0 } }
        func take() -> Reply { lock.withLock { requests += 1; return reply } }
    }
    static let fixture = Fixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/enroll")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        do {
            struct Body: Decodable { let token: String; let name: String; let certificate: Data; let signature: Data }
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while bytes.count <= 8192 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count == 0 { break }
                guard count > 0 else { throw URLError(.cannotDecodeContentData) }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(bytes.count))
            let body = try JSONDecoder().decode(Body.self, from: bytes)
            XCTAssertEqual(body.name, "Mac")
            XCTAssertEqual(body.token, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            let certificate = try Certificate(derEncoded: Array(body.certificate))
            let signature = try P256.Signing.ECDSASignature(derRepresentation: body.signature)
            let publicKey = try XCTUnwrap(P256.Signing.PublicKey(certificate.publicKey))
            XCTAssertTrue(publicKey.isValidSignature(signature, for: enrollmentMessage(token: Data(repeating: 0, count: 32), certificateDER: body.certificate)))
        } catch {
            XCTFail("The upload body is missing or invalid: \(error)")
            client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData))
            return
        }
        switch Self.fixture.take() {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .disconnect: client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .redirect:
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://other.example.com/v1/enroll"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://other.example.com/v1/enroll")!), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
