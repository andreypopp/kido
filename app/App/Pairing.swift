import Foundation
import CryptoKit

struct PairingCode: Sendable {
    let enroll: URL
    let host: ServerName
    let token: Data
    var tokenHash: Data { Data(SHA256.hash(data: token)) }

    init(_ text: String, expectedHost: ServerName? = nil) throws {
        struct Payload: Decodable { let v: Int; let enroll: String; let host: String; let token: String }
        guard text.utf8.count <= 8192 else { throw Failure(message: "Not a pairing code") }
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("kido-pair:") { text = String(text.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
        let name = try ServerName(payload.host)
        guard payload.v == 1, expectedHost == nil || expectedHost == name,
              let parts = URLComponents(string: payload.enroll), parts.scheme == "https",
              let authority = parts.host, (try? ServerName(authority)) != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, parts.path == "/v1/enroll", let url = parts.url,
              payload.token.utf8.count == 43,
              payload.token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let token = Data(base64Encoded: payload.token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              token.count == 32, token.base64URL == payload.token else { throw Failure(message: "Not a pairing code") }
        self.enroll = url
        self.host = name
        self.token = token
    }
}

extension Data {
    fileprivate var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

func enrollmentMessage(token: Data, certificateDER: Data) -> Data {
    Data("kido-enroll-v1".utf8) + Data([0]) + Data(SHA256.hash(data: token)) + Data(SHA256.hash(data: certificateDER))
}

struct DeviceName: Sendable {
    private let name: String
    var value: String { name }
    init(_ name: String) throws {
        guard (1...64).contains(name.unicodeScalars.count),
              !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
            throw Failure(message: "Use a device name of 1 to 64 characters, without control characters")
        }
        self.name = name
    }
}

struct EnrollmentRequest: Encodable {
    let token: String
    let name: String
    let certificate: String
    let signature: String

    init(code: PairingCode, name: DeviceName, certificate: Data, signature: Data) throws {
        guard certificate.count <= 2048 else { throw Failure(message: "The pairing certificate is too large") }
        token = code.token.base64URL
        self.name = name.value
        self.certificate = certificate.base64EncodedString()
        self.signature = signature.base64EncodedString()
    }

    func body() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 8192 else { throw Failure(message: "The pairing request is too large") }
        return data
    }
}

enum EnrollmentResult: Equatable, Sendable {
    case accepted
    case rejected(Int)
    case retryable(String)
    case uncertain
}

func certainEnrollmentFailure(_ error: Error, bytesSent: Int64) -> Bool {
    guard bytesSent == 0, let error = error as? URLError else { return false }
    switch error.code {
    case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
         .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
         .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .cannotLoadFromNetwork:
        return true
    default: return false
    }
}

final class EnrollmentTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var data = Data()
    private var response: HTTPURLResponse?
    private let fingerprint: String
    private let continuation: CheckedContinuation<EnrollmentResult, Never>

    private var body: Data?
    private init(certificate: Data, body: Data, continuation: CheckedContinuation<EnrollmentResult, Never>) {
        self.body = body
        fingerprint = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.data.count < 8193 { self.data.append(data.prefix(8193 - self.data.count)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let response {
            guard response.statusCode == 200 else { continuation.resume(returning: .rejected(response.statusCode)); return }
            struct Reply: Decodable { let fingerprint: String }
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
            continuation.resume(returning: error == nil && reply?.fingerprint == fingerprint ? .accepted : .uncertain)
        } else if let error, certainEnrollmentFailure(error, bytesSent: task.countOfBytesSent) {
            continuation.resume(returning: .retryable(error.localizedDescription))
        } else { continuation.resume(returning: .uncertain) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        let body = self.body
        self.body = nil
        completionHandler(body.map { InputStream(data: $0) })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        self.response = response
        completionHandler(nil)
    }

    static func send(code: PairingCode, request: EnrollmentRequest, certificate: Data,
              configuration: URLSessionConfiguration = .ephemeral) async throws -> EnrollmentResult {
        let body = try request.body()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        var post = URLRequest(url: code.enroll)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        return await withCheckedContinuation { continuation in
            let delegate = EnrollmentTransport(certificate: certificate, body: body, continuation: continuation)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session.uploadTask(withStreamedRequest: post).resume()
        }
    }
}
