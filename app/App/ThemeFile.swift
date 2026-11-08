import AppKit
import GhosttyKit

struct ThemePaths {
    let light: String
    let dark: String
    static let bundled = ["kido-light", "kido-dark", "ahrefs-light", "ahrefs-dark", "solarized-light", "solarized-dark"]
    static var bundledDirectory: URL { Bundle.main.resourceURL!.appendingPathComponent("ghostty/themes") }

    static func directory(configFile: String) -> URL {
        URL(fileURLWithPath: configFile).deletingLastPathComponent().appendingPathComponent("themes")
    }

    static func path(_ name: String, configFile: String) -> String {
        (bundled.contains(name) ? bundledDirectory : directory(configFile: configFile)).appendingPathComponent(name).path
    }
}

struct ThemeFile: Equatable {
    enum Problem: Equatable {
        case missing, invalid(String)
        var text: String { switch self { case .missing: "theme file not found"; case .invalid(let line): "invalid: " + line } }
    }
    let contents: Data?
    let problem: Problem?

    static func lines(_ config: ghostty_config_t) -> Set<String> {
        let value = ghostty_config_serialize(config)
        defer { ghostty_string_free(value) }
        return Set(String(decoding: UnsafeRawBufferPointer(start: value.ptr, count: Int(value.len)), as: UTF8.self).split(separator: "\n").map(String.init))
    }
    @MainActor private static let baseline: Set<String> = {
        let config = ghostty_config_new()!
        defer { ghostty_config_free(config) }
        return lines(config)
    }()

    @MainActor init(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            contents = nil; problem = .missing
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let text = String(data: data, encoding: .utf8) else {
            contents = nil; problem = .invalid("Could not read theme file")
            return
        }
        contents = data
        let config = ghostty_config_new()!
        defer { ghostty_config_free(config) }
        ghostty_config_load_string(config, text, UInt(data.count), path)
        if ghostty_config_diagnostics_count(config) > 0 {
            problem = .invalid(String(cString: ghostty_config_get_diagnostic(config, 0).message))
            return
        }
        let allowed: Set<String> = ["background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground", "palette", "bold-color", "minimum-contrast"]
        let key = Self.lines(config).symmetricDifference(Self.baseline).sorted().map {
            $0.split(separator: "=", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
        }.first { !allowed.contains($0) }
        problem = key.map { .invalid("unsupported key \"\($0)\"") }
    }
}
