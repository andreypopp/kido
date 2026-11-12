import Foundation
import KoClient
import KoClientKit
import KoModel

struct ConfigProblem: Error, Decodable, Equatable {
    let line: Int?
    let column: Int?
    let message: String
    var detail: String {
        if let line, let column { return "\(line):\(column): \(message)" }
        return message
    }
}

struct ConfigError: Error, Equatable {
    let path: String
    let problem: ConfigProblem
}

enum AppConfig {
    struct Document: Decodable { let app: KoSchema.App }
    struct Defaults: Decodable {
        let path: String
        let config: Document
    }
    private struct Loaded: Decodable { let config: Document }
    private struct Failed: Decodable { let error: ConfigProblem }

    private static func buffer(_ call: (UnsafeMutablePointer<ko_buffer>) -> ko_code) throws -> Data {
        var buffer = ko_buffer()
        let code = call(&buffer)
        defer { ko_buffer_free(&buffer) }
        let data = Data(bytes: buffer.data!, count: Int(buffer.len))
        guard code == KO_OK else { throw try JSONDecoder().decode(Failed.self, from: data).error }
        return data
    }

    static func defaults() throws -> Defaults {
        try JSONDecoder().decode(Defaults.self, from: buffer { ko_config_defaults($0) })
    }

    static func load(_ path: String) throws -> KoSchema.App {
        try JSONDecoder().decode(Loaded.self, from: buffer { ko_config_load(path, $0) }).config.app
    }

    static func setTheme(_ path: String, _ pair: KoSchema.ThemePair) throws {
        _ = try buffer { ko_config_set_theme(path, pair.light, pair.dark, $0) }
    }

    static func pair(_ theme: KoSchema.Theme) -> KoSchema.ThemePair {
        switch theme {
        case .themeName(let name): .init(dark: name, light: name)
        case .themePair(let pair): pair
        }
    }
}
