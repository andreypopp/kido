import Foundation
import KoModel
@testable import Kido

extension VisualTestCase {
    func configYAML(at file: URL, background: String? = nil, foreground: String? = nil, size: Int = 13, sidebarShade: String? = nil, unfocusedShift: Int? = nil) throws -> String {
        var text = "app:\n  font: {size: \(size)}\n"
        if let background {
            let directory = ThemePaths.directory(configFile: file.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let prefix = "fixture-" + file.lastPathComponent + "-" + background.replacingOccurrences(of: "#", with: "")
            let pair = KoSchema.ThemePair(light: prefix + "-light", dark: prefix + "-dark")
            for (base, name) in [("kido-light", pair.light), ("kido-dark", pair.dark)] {
                let theme = directory.appendingPathComponent(name)
                var contents = try String(contentsOfFile: ThemePaths.path(base, configFile: file.path), encoding: .utf8)
                contents += "\nbackground = \(background.hasPrefix("#") ? background : "#" + background)\n"
                if let foreground { contents += "foreground = \(foreground.hasPrefix("#") ? foreground : "#" + foreground)\n" }
                try contents.write(to: theme, atomically: true, encoding: .utf8)
                addTeardownBlock { try? FileManager.default.removeItem(at: theme) }
            }
            text += "  theme: {light: \(pair.light), dark: \(pair.dark)}\n"
        }
        if sidebarShade != nil || unfocusedShift != nil {
            text += "  window:\n"
            if let sidebarShade { text += "    sidebar_shade: \(sidebarShade.replacingOccurrences(of: "%", with: ""))\n" }
            if let unfocusedShift { text += "    unfocused_shift: \(unfocusedShift)\n" }
        }
        return text
    }
}
