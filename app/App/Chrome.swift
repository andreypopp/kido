import AppKit

enum Chrome {
    static var fieldInk: NSColor { .controlTextColor }
    static var themeRadioInk: NSColor { NSColor.labelColor.withAlphaComponent(0.4) }
    static var themeRadioSelection: NSColor { .controlAccentColor }
    static var themeTagFill: NSColor { NSColor.labelColor.withAlphaComponent(0.08) }
    static var themeSwatchEdge: NSColor { NSColor.labelColor.withAlphaComponent(0.25) }
    static var themeDisabledAlpha: CGFloat { 0.5 }
    static var markdownInk: (ink: NSColor, secondary: NSColor, tertiary: NSColor) { (ink, inkSecondary, inkTertiary) }
    static var statusRunning: NSColor { .systemGreen }
    static var statusWaiting: NSColor { .systemOrange }
    static var statusError: NSColor { .systemRed }
    static var errorText: NSColor { .systemRed }
    static var statusQuiet: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(NSColor.secondaryLabelColor.alphaComponent * 0.45) }
    static var ink: NSColor { .labelColor }
    static var inkSecondary: NSColor { .secondaryLabelColor }
    static var inkTertiary: NSColor { .tertiaryLabelColor }
    static var hairline: NSColor { .separatorColor }
    static var defaultPaper: NSColor { .windowBackgroundColor }
    static var closeHover: NSColor { NSColor.labelColor.withAlphaComponent(0.1) }
    static var rowSelection: NSColor { NSColor.labelColor.withAlphaComponent(0.1) }
    static var iconHover: NSColor { NSColor.labelColor.withAlphaComponent(0.12) }
    static var scrollerKnob: NSColor { NSColor.labelColor.withAlphaComponent(0.3) }
    static var scrollerKnobActive: NSColor { NSColor.labelColor.withAlphaComponent(0.5) }
    static var modeChipFill: NSColor { NSColor.labelColor.withAlphaComponent(0.1) }
    static var modeChipInk: NSColor { NSColor.labelColor.withAlphaComponent(0.8) }
    static var disabledFill: NSColor { NSColor.labelColor.withAlphaComponent(0.14) }
    static var floatingListHairline: NSColor { NSColor.labelColor.withAlphaComponent(0.12) }
    static var dropPreview: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.3) }
    static var capsuleRing: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.4) }
    static var accent: NSColor { .controlAccentColor }
    static var swatchChevron: NSColor { NSColor.labelColor.withAlphaComponent(0.6) }
    static func pole(dark: Bool) -> NSColor { dark ? .white : .black }
    static func hex(_ value: Int) -> NSColor { rgb(Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255) }
    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    static var insertion: NSColor { .controlAccentColor }
    static var renameEdge: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.4) }
    static var sendFill: NSColor { .controlAccentColor }
    static var quoteBar: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(NSColor.secondaryLabelColor.alphaComponent * 0.45) }
    static var linkText: NSColor { .controlAccentColor }
    static var onAccent: NSColor { .white }
    static var onError: NSColor { .white }
    static var capsuleHighlight: CGColor { CGColor(gray: 1, alpha: 0.12) }
    static var capsuleShadow: (color: NSColor, blur: CGFloat) { (.black.withAlphaComponent(0.2), 9) }
    static var floatShadow: (color: NSColor, blur: CGFloat) { (.black.withAlphaComponent(0.22), 12) }
    static func sidebarShadow(dark: Bool) -> (color: NSColor, blur: CGFloat) { (.black.withAlphaComponent(dark ? 0.4 : 0.18), 14) }
    static var shadowMask: NSColor { .black }
    static var disabledIconAlpha: CGFloat { 0.35 }
    static var pickerRing: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.55) }
    static var codeFill: NSColor { NSColor.labelColor.withAlphaComponent(NSColor.labelColor.alphaComponent * 0.08) }
    static var capsuleSurface: (fillMix: Double, edgeAlpha: CGFloat) { (0.08, 0.12) }
    static var cardSurface: (fillMix: Double, edgeAlpha: CGFloat) { (0.07, 0.14) }
    static func capsuleEdge(_ foreground: NSColor, alpha: CGFloat) -> NSColor { foreground.withAlphaComponent(alpha) }
    static func bannerVeil(_ background: NSColor) -> NSColor { background.withAlphaComponent(0.85) }
    static func floatingOverlay(_ background: NSColor) -> NSColor { background.withAlphaComponent(0.45) }
    static func matchHighlight(_ foreground: NSColor) -> NSColor { foreground.withAlphaComponent(0.14) }
    static func treeGuide(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 79 / 255, green: 85 / 255, blue: 92 / 255, alpha: 1)
             : NSColor(srgbRed: 191 / 255, green: 186 / 255, blue: 177 / 255, alpha: 1)
    }
}
