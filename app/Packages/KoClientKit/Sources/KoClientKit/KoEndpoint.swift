import Foundation
import KoClient

public enum KoEndpoint: Sendable {
    case unix(String)
    case tls(host: String, port: UInt16, identity: KoIdentity)
}

public struct KoIdentity: Sendable {
    public let certificate: Data
    public let sign: @Sendable (Data) throws -> Data

    public init(certificate: Data, sign: @escaping @Sendable (Data) throws -> Data) {
        self.certificate = certificate
        self.sign = sign
    }
}

final class IdentitySigner: Sendable {
    let sign: @Sendable (Data) throws -> Data

    init(_ identity: KoIdentity) { sign = identity.sign }
}

let identitySign: ko_sign_fn = { user, message, length, signature, capacity in
    guard let user, let message, let signature else { return 0 }
    let signer = Unmanaged<IdentitySigner>.fromOpaque(user).takeUnretainedValue()
    guard let result = try? signer.sign(Data(bytes: message, count: length)),
          !result.isEmpty, result.count <= capacity, result.count <= 72 else { return 0 }
    result.copyBytes(to: signature, count: result.count)
    return result.count
}

extension KoEndpoint {
    func withEndpoint<T>(signer: IdentitySigner?, _ body: (UnsafePointer<ko_endpoint>) -> T) -> T {
        switch self {
        case .unix(let socket):
            return socket.withCString { socket in
                var endpoint = ko_endpoint(kind: Int32(KO_ENDPOINT_UNIX), socket: socket, host: nil, port: 0, identity: nil)
                return body(&endpoint)
            }
        case .tls(let host, let port, let identity):
            return host.withCString { host in
                identity.certificate.withUnsafeBytes { certificate in
                    var identity = ko_identity(certificate: certificate.bindMemory(to: UInt8.self).baseAddress,
                                               certificate_len: certificate.count, sign: identitySign,
                                               user: signer.map { Unmanaged.passUnretained($0).toOpaque() })
                    return withUnsafePointer(to: &identity) { identity in
                        var endpoint = ko_endpoint(kind: Int32(KO_ENDPOINT_TLS), socket: nil, host: host, port: port, identity: identity)
                        return body(&endpoint)
                    }
                }
            }
        }
    }

    var signer: IdentitySigner? {
        if case .tls(_, _, let identity) = self { return IdentitySigner(identity) }
        return nil
    }
}
