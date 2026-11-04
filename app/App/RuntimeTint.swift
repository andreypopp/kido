import KoModel

// How a runtime's colour is chosen: the configured `#rrggbb`, else a hue from the name.
enum RuntimeTint {
    // FNV-1a over the UTF-8 bytes of the name, 32 bits, modulo a full circle of degrees.
    static func hue(_ name: String) -> Int {
        var hash: UInt32 = 2166136261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return Int(hash % 360)
    }

    // `#rrggbb` in either case, as components from 0 to 1.
    static func rgb(hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.utf8.count == 7, hex.hasPrefix("#"), hex.dropFirst().allSatisfy(\.isHexDigit), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }
}
