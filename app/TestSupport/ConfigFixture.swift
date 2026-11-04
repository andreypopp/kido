import Foundation
import KoModel

func themeYAML(_ pair: KoSchema.ThemePair) -> String {
    "app:\n  theme:\n    light: \(pair.light)\n    dark: \(pair.dark)\n"
}

extension KoSchema.ThemePair {
    init(light: String = "kido-light", dark: String = "kido-dark") { self.init(dark: dark, light: light) }
}
