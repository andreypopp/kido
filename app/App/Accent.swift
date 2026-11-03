import AppKit

enum Preset: String, CaseIterable, Codable {
    case red, orange, green, teal, blue, indigo, purple, pink

    private static let values: [Preset: (light: Int, dark: Int)] = [
        .red: (0xb54a46, 0xdc8c85), .orange: (0xa05b11, 0xdca476), .green: (0x357a3a, 0x88c28a), .teal: (0x007979, 0x7abfbf),
        .blue: (0x0072a8, 0x61afda), .indigo: (0x5d53ae, 0x9794e0), .purple: (0x894b9c, 0xc18ed1), .pink: (0xab4a7d, 0xde94b7),
    ]

    func color(dark: Bool) -> NSColor {
        let value = Self.values[self]!
        let hex = dark ? value.dark : value.light
        return Chrome.rgb(Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255)
    }
}

enum Accent: Codable, Equatable {
    case system
    case preset(Preset)
    case custom(red: Double, green: Double, blue: Double) // chrome-allow: stored components

    static let textContrast = 4.5
    static let ringContrast = 3.0

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB)!
        self = .custom(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent)) // chrome-allow: stored components
    }

    var name: String {
        switch self {
        case .system: "System"
        case .preset(let preset): preset.rawValue.capitalized
        case .custom: "Custom"
        }
    }

    func color(dark: Bool) -> NSColor {
        switch self {
        case .system:
            var result = Chrome.accent
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { result = Chrome.accent.usingColorSpace(.sRGB)! }
            return result
        case .preset(let preset): return preset.color(dark: dark)
        case .custom(let red, let green, let blue): return Chrome.rgb(red, green, blue)
        }
    }

    @MainActor func colors(runtime: GhosttyRuntime) -> (text: NSColor, ring: NSColor) {
        (legible(on: runtime.canvas, minimum: Accent.textContrast), legible(on: runtime.background, minimum: Accent.ringContrast))
    }

    func legible(on background: NSColor, minimum: Double) -> NSColor {
        guard self != .system else { return Chrome.accent }
        let dark = background.isDark
        let start = color(dark: dark), pole = Chrome.pole(dark: dark)
        for step in 0...20 {
            let candidate = start.mixed(toward: pole, amount: Double(step) * 0.05)
            if candidate.contrast(with: background) >= minimum { return candidate }
        }
        return pole
    }
}

@MainActor final class HostAccents {
    static let changed = Notification.Name("HostAccents.changed")
    private let preferences: UserDefaults

    init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    private var stored: [String: Accent] {
        get { preferences.data(forKey: "hostAccents").flatMap { try? JSONDecoder().decode([String: Accent].self, from: $0) } ?? [:] }
        set { preferences.set(try? JSONEncoder().encode(newValue), forKey: "hostAccents") }
    }

    func accent(for host: Host) -> Accent { known(host) ?? (host == .local ? .preset(.blue) : .system) }
    func known(_ host: Host) -> Accent? { stored[host.clipboardKey] }

    var suggestion: Accent {
        let stored = stored
        var used = stored.values.compactMap { if case .preset(let preset) = $0 { preset } else { nil } }
        if stored["local"] == nil { used.append(.blue) }
        return .preset(Preset.allCases.min { first, second in used.filter { $0 == first }.count < used.filter { $0 == second }.count }!)
    }

    func set(_ accent: Accent, for host: Host) {
        guard known(host) != accent else { return }
        stored[host.clipboardKey] = accent
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["host": host])
    }

    func assign(_ host: Host, chosen: Accent? = nil) {
        if let chosen { set(chosen, for: host) }
        else if host != .local, known(host) == nil { set(suggestion, for: host) }
    }

    func colors(for host: Host, runtime: GhosttyRuntime) -> (text: NSColor, ring: NSColor) {
        accent(for: host).colors(runtime: runtime)
    }
}
