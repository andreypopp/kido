import Foundation

@MainActor final class ClipboardConsent {
    private let grants: UserDefaults?
    private var allowedHosts: Set<String> = []
    var askingHosts: Set<String> = []

    init(grants: UserDefaults? = nil) { self.grants = grants }

    func allows(_ host: Host) -> Bool {
        grants?.stringArray(forKey: "clipboardReadHosts")?.contains(host.clipboardKey) ?? allowedHosts.contains(host.clipboardKey)
    }

    func allowAlways(_ host: Host) {
        if let grants {
            grants.set(Array(Set(grants.stringArray(forKey: "clipboardReadHosts") ?? []).union([host.clipboardKey])), forKey: "clipboardReadHosts")
        } else { allowedHosts.insert(host.clipboardKey) }
    }

    func reset() {
        grants?.removeObject(forKey: "clipboardReadHosts")
        allowedHosts.removeAll()
    }
}

enum Host: Equatable, Sendable {
    case local
    case remote(String)

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
        switch self { case .local: "local"; case .remote(let destination): "ssh:\(destination)" }
    }

    var label: String {
        switch self { case .local: "Local"; case .remote(let destination): destination }
    }
}
