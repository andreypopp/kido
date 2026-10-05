import Foundation

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

    var label: String {
        switch self { case .local: "Local"; case .remote(let destination): destination }
    }
}
