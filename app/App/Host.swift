import Foundation

enum Host: Equatable, Sendable {
    case local
    case remote(String)

    init(_ text: String) throws(Failure) {
        let destination = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              destination.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@:-").contains($0) }) else {
            throw Failure(message: "Host must be a user@hostname or SSH alias, without spaces or shell syntax. Configure ports and jump hosts in ~/.ssh/config.")
        }
        self = .remote(destination)
    }

    var label: String {
        switch self { case .local: "Local"; case .remote(let destination): destination }
    }
}
