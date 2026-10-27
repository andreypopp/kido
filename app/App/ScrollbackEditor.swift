import Foundation

enum ScrollbackEditor {
    struct Login: Equatable, Sendable {
        var visual = ""
        var editor = ""
        var path = ""
    }

    static let fileVariable = "KIDO_SCROLLBACK_FILE"
    static let statusVariable = "KIDO_SCROLLBACK_STATUS"
    static let commandVariable = "KIDO_SCROLLBACK_COMMAND"

    @MainActor private static var cache: [String: Login] = [:]

    // A word of the editor setting is not quoted, as git does not quote it.
    // login(1) prints its last-login banner before the command starts, so the
    // command clears the screen. The exit code that Ghostty reports is not
    // reliable on macOS, so the shell records the editor's status in a file.
    static func command(_ login: Login) -> String {
        let editor = [login.visual, login.editor].first { !$0.allSatisfy(\.isWhitespace) } ?? "vi"
        let program = editor.split(whereSeparator: \.isWhitespace).first.map { ($0 as NSString).lastPathComponent }
        let end = program.map { ["vi", "vim", "nvim", "view"].contains($0) } == true ? " +" : ""
        return "printf '\\033[2J\\033[H'; \(editor)\(end) \"$\(fileVariable)\"; echo $? > \"$\(statusVariable)\""
    }

    static func parse(_ output: String) -> Login {
        var login = Login()
        for line in output.split(whereSeparator: \.isNewline) {
            if let value = line.value(after: "kido-visual=") { login.visual = value }
            else if let value = line.value(after: "kido-editor=") { login.editor = value }
            else if let value = line.value(after: "kido-path=") { login.path = value }
        }
        return login
    }

    // Ghostty starts the command under bash with no startup files, so the
    // editor settings and PATH come from the user's login shell.
    @MainActor static func login(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") async -> Login {
        if let cached = cache[shell] { return cached }
        let script = "printf 'kido-visual=%s\\nkido-editor=%s\\nkido-path=%s\\n' \"$VISUAL\" \"$EDITOR\" \"$PATH\""
        guard let result = try? await Child.run(shell, ["-ilc", script], deadline: 3) else { return Login() }
        let login = parse(result.out)
        cache[shell] = login
        return login
    }

    #if KIDO_VISUAL
    @MainActor static func forget() { cache = [:] }
    #endif
}

private extension Substring {
    func value(after marker: String) -> String? { range(of: marker).map { String(self[$0.upperBound...]) } }
}
