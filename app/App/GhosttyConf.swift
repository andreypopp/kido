import KoModel

enum GhosttyConf {
    static let mirrorClipboard = "clipboard-read = deny\nclipboard-write = deny\n"

    static func theme(_ paths: ThemePaths) -> String {
        func quote(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") + "\""
        }
        return "theme = light:\(quote(paths.light)),dark:\(quote(paths.dark))"
    }

    static func text(_ app: KoSchema.App, themes: ThemePaths, systemFont: String) -> String {
        func bool(_ value: Bool) -> String { value ? "true" : "false" }
        let option: String = switch app.keyboard.optionAsAlt {
        case .off: "false"
        case .on: "true"
        case .left: "left"
        case .right: "right"
        }
        var lines = ["alpha-blending = linear", "cursor-style-blink = false",
                     "keybind = super+k=unbind", "keybind = super+j=unbind", "keybind = super+s=unbind", "keybind = super+shift+s=unbind",
                     "font-family = \(app.font.family ?? systemFont)", "font-size = \(app.font.size)"]
        lines += app.font.features.map { "font-feature = \($0)" }
        lines += ["font-thicken = \(bool(app.font.thicken))", "adjust-cell-height = \(app.font.lineHeight)%",
                  "macos-option-as-alt = \(option)",
                  "mouse-scroll-multiplier = precision:\(app.mouse.scrollMultiplier.precision),discrete:\(app.mouse.scrollMultiplier.discrete)",
                  "mouse-hide-while-typing = \(bool(app.mouse.hideWhileTyping))",
                  "copy-on-select = \(app.clipboard.copyOnSelect ? "clipboard" : "none")",
                  "clipboard-paste-protection = \(bool(app.clipboard.pasteProtection))",
                  "clipboard-trim-trailing-spaces = \(bool(app.clipboard.trimTrailingSpaces))"]
        lines += app.keys.sorted { $0.key < $1.key }.map { "keybind = \($0.key)=\($0.value)" }
        lines += [theme(themes), "window-padding-x = 0", "window-padding-y = 0", "scrollbar = never"]
        return lines.joined(separator: "\n") + "\n" + mirrorClipboard
    }
}
