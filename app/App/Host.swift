import Foundation
import KidoPairing

@MainActor final class ClipboardConsent {
    enum Capability: String, CaseIterable { case clipboard = "clipboardReadHosts", rich = "richClipboardReadHosts", upload = "uploadHosts" }
    private let grants: UserDefaults?
    private var allowedHosts: Set<String> = []
    var askingHosts: Set<String> = []

    init(grants: UserDefaults? = nil) { self.grants = grants }

    func allows(_ host: Host, _ capability: Capability = .clipboard) -> Bool {
        grants.map { $0.stringArray(forKey: capability.rawValue)?.contains(host.clipboardKey) ?? false }
            ?? allowedHosts.contains(capability.rawValue + " " + host.clipboardKey)
    }

    func allowAlways(_ host: Host, _ capability: Capability = .clipboard) {
        if let grants {
            grants.set(Array(Set(grants.stringArray(forKey: capability.rawValue) ?? []).union([host.clipboardKey])), forKey: capability.rawValue)
        } else { allowedHosts.insert(capability.rawValue + " " + host.clipboardKey) }
    }

    func reset() {
        Capability.allCases.forEach { grants?.removeObject(forKey: $0.rawValue) }
        allowedHosts.removeAll()
    }
}

enum Host: Hashable, Sendable, Codable {
    case local
    case remote(String)
    case tls(ServerName)

    private enum Kind: String, Codable { case local, ssh, https }
    private enum CodingKeys: CodingKey { case kind, destination }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local: self = .local
        case .ssh: try self.init(container.decode(String.self, forKey: .destination))
        case .https: self = .tls(try container.decode(ServerName.self, forKey: .destination))
        }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local: try container.encode(Kind.local, forKey: .kind)
        case .remote(let destination):
            try container.encode(Kind.ssh, forKey: .kind)
            try container.encode(destination, forKey: .destination)
        case .tls(let name):
            try container.encode(Kind.https, forKey: .kind)
            try container.encode(name, forKey: .destination)
        }
    }

    init(_ destination: String) throws(Failure) {
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              destination.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@:-").contains($0) }) else {
            throw Failure(message: "Host must be a user@hostname or SSH alias, without spaces or shell syntax. Configure ports and jump hosts in ~/.ssh/config.")
        }
        self = .remote(destination)
    }

    init(url: URL) throws(Failure) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "kido-app", let host = parts.host,
              parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw Failure(message: "Expected kido-app://<host> without a session path, port, password, query or fragment")
        }
        try self.init(parts.user.map { $0 + "@" + host } ?? host)
    }

    var clipboardKey: String {
        switch self { case .local: "local"; case .remote(let destination): "ssh:\(destination)"; case .tls(let name): "tls:\(name.value)" }
    }

    var imageFetches: Int { switch self { case .local: 8; case .remote, .tls: 4 } }

    func title(in identities: IdentityStore?) -> String {
        if case .tls(let host) = self, let name = try? identities?.name(for: host) { return name.value }
        return label
    }

    var label: String {
        switch self { case .local: "Local"; case .remote(let destination): destination; case .tls(let name): name.value }
    }
}
