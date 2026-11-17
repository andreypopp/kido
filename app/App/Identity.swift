import Foundation
import CryptoKit
import Security
import X509
import KoClientKit
import Darwin

struct ServerIdentity: Sendable {
    let certificate: Data
    fileprivate let key: SecureEnclave.P256.Signing.PrivateKey

    func sign(_ message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}

final class IdentityStore: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    init(root: URL) { self.root = root }

    func create() throws -> ServerIdentity {
        let installID = try lock.withLock {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = root.appendingPathComponent("install-id")
            if FileManager.default.fileExists(atPath: path.path) {
                guard let id = UUID(uuidString: try String(contentsOf: path, encoding: .utf8)) else { throw Failure(message: "The Kido install ID is not valid") }
                return id
            }
            let id = UUID()
            let staging = root.appendingPathComponent(".install-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            guard FileManager.default.createFile(atPath: staging.path, contents: Data(id.uuidString.utf8), attributes: [.posixPermissions: 0o600]) else { throw Failure(message: "Could not write the Kido install ID") }
            let file = try FileHandle(forWritingTo: staging)
            try file.synchronize()
            try file.close()
            try FileManager.default.moveItem(at: staging, to: path)
            return id
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
            throw error?.takeRetainedValue() as Error? ?? Failure(message: "Could not create access for the Secure Enclave key")
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let name = try DistinguishedName { CommonName("Kido device") }
        var random = SystemRandomNumberGenerator()
        var serial = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        serial[0] = (serial[0] & 0x7f) | 1
        let certificate = try Certificate(
            version: .v3, serialNumber: .init(bytes: serial), publicKey: .init(key.publicKey),
            notValidBefore: Date(timeIntervalSince1970: 1767225600),
            notValidAfter: Date(timeIntervalSince1970: 253402300799),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                try ExtendedKeyUsage([.clientAuth])
                SubjectAlternativeNames([.uniformResourceIdentifier("urn:kido:install:" + installID.uuidString.lowercased())])
            }, issuerPrivateKey: .init(key))
        return ServerIdentity(certificate: Data(try certificate.serializeAsPEM().derBytes), key: key)
    }

    func load(_ host: ServerName) throws -> ServerIdentity {
        let (der, representation) = try lock.withLock {
            let directory = root.appendingPathComponent("servers").appendingPathComponent(host.value)
            return (try Data(contentsOf: directory.appendingPathComponent("certificate.der")), try Data(contentsOf: directory.appendingPathComponent("key")))
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: representation)
        let certificate = try Certificate(derEncoded: Array(der))
        guard certificate.publicKey == Certificate.PublicKey(key.publicKey) else { throw Failure(message: "The server key does not match its certificate") }
        return ServerIdentity(certificate: der, key: key)
    }

    func endpoint(for host: ServerName, certificate: Data) -> KoEndpoint {
        .tls(host: host.value, port: 443, identity: KoIdentity(certificate: certificate) { [self] message in
            try sign(message, for: host, certificate: certificate)
        })
    }

    private func sign(_ message: Data, for host: ServerName, certificate: Data) throws -> Data {
        let identity = try load(host)
        guard identity.certificate == certificate else { throw Failure(message: "This Mac's server identity was replaced") }
        return try identity.sign(message)
    }

    func commit(_ identity: ServerIdentity, for host: ServerName) throws {
        try lock.withLock {
            let manager = FileManager.default
            let servers = root.appendingPathComponent("servers")
            try manager.createDirectory(at: servers, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = servers.appendingPathComponent("." + UUID().uuidString)
            let destination = servers.appendingPathComponent(host.value)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: staging) }
            for (name, data) in [("certificate.der", identity.certificate), ("key", identity.key.dataRepresentation)] {
                let path = staging.appendingPathComponent(name)
                guard manager.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure(message: "Could not write the server identity") }
                let file = try FileHandle(forWritingTo: path)
                try file.synchronize()
                try file.close()
            }
            if manager.fileExists(atPath: destination.path) {
                let result = staging.withUnsafeFileSystemRepresentation { from in
                    destination.withUnsafeFileSystemRepresentation { to in renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_SWAP)) }
                }
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } else { try manager.moveItem(at: staging, to: destination) }
            let directory = open(servers.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(directory) }
            guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    func forget(_ host: ServerName) throws {
        try lock.withLock { try FileManager.default.removeItem(at: root.appendingPathComponent("servers").appendingPathComponent(host.value)) }
    }
}
