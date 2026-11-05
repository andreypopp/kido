import Foundation

enum LoginPath {
    static func read(shell: String, deadline: TimeInterval) async -> String? {
        let marker = "__KIDO_" + UUID().uuidString + "__"
        var environment = ProcessInfo.processInfo.environment
        environment["KIDO_APP_LOGIN_MARK"] = marker
        let script = "exec /bin/sh -c 'printf \"%s%s%s\" \"$KIDO_APP_LOGIN_MARK\" \"$PATH\" \"$KIDO_APP_LOGIN_MARK\"'"
        guard let result = try? await Child.run(shell, ["-l", "-c", script], env: environment, deadline: deadline),
            result.status == 0, !result.signaled,
            let first = result.out.range(of: marker),
            let last = result.out.range(of: marker, options: .backwards),
            first.upperBound <= last.lowerBound
        else { return nil }
        let path = String(result.out[first.upperBound..<last.lowerBound])
        return path.isEmpty ? nil : path
    }
}
