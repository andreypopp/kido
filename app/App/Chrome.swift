import AppKit
import KoModel

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
    static var ink: NSColor { .labelColor }
    static var inkSecondary: NSColor { .secondaryLabelColor }
    static var inkTertiary: NSColor { .tertiaryLabelColor }
    static var hairline: NSColor { .separatorColor }
    static var defaultPaper: NSColor { .windowBackgroundColor }
    static var closeHover: NSColor { NSColor.labelColor.withAlphaComponent(0.1) }
    static var windowSelection: NSColor { NSColor.labelColor.withAlphaComponent(0.075) }
    static var sidebarIdleCircle: NSColor { inkSecondary.withAlphaComponent(inkSecondary.alphaComponent * 0.5) }
    static var sidebarChevron: NSColor { inkSecondary.withAlphaComponent(inkSecondary.alphaComponent * 0.7) }
    static var sidebarDivider: NSColor { ink.withAlphaComponent(0.1) }
    static var rowSelection: NSColor { NSColor.labelColor.withAlphaComponent(0.1) }
    static var rowHover: NSColor { NSColor.labelColor.withAlphaComponent(0.05) }
    static var iconHover: NSColor { NSColor.labelColor.withAlphaComponent(0.12) }
    static var tabPill: NSColor { NSColor.labelColor.withAlphaComponent(0.075) }
    static var scrollerKnob: NSColor { NSColor.labelColor.withAlphaComponent(0.3) }
    static var scrollerKnobActive: NSColor { NSColor.labelColor.withAlphaComponent(0.5) }
    static var modeChipFill: NSColor { NSColor.labelColor.withAlphaComponent(0.1) }
    static var modeChipInk: NSColor { NSColor.labelColor.withAlphaComponent(0.8) }
    static var disabledFill: NSColor { NSColor.labelColor.withAlphaComponent(0.14) }
    static var floatingListHairline: NSColor { NSColor.labelColor.withAlphaComponent(0.12) }
    static var focusStroke: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.5) }
    static var dropPreview: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.3) }
    static var capsuleRing: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.4) }
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
    static var disconnectedHostAlpha: CGFloat { 0.45 }
    static var disabledIconAlpha: CGFloat { 0.35 }
    static var pickerRing: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.55) }
    static var codeFill: NSColor { NSColor.labelColor.withAlphaComponent(NSColor.labelColor.alphaComponent * 0.08) }
    static var capsuleSurface: (fillMix: Double, edgeAlpha: CGFloat) { (0.08, 0.12) }
    static var cardSurface: (fillMix: Double, edgeAlpha: CGFloat) { (0.07, 0.14) }
    static func capsuleEdge(_ foreground: NSColor, alpha: CGFloat) -> NSColor { foreground.withAlphaComponent(alpha) }
    static func bannerVeil(_ background: NSColor) -> NSColor { background.withAlphaComponent(0.85) }
    static func floatingOverlay(_ background: NSColor) -> NSColor { background.withAlphaComponent(0.45) }
    static func matchHighlight(_ foreground: NSColor) -> NSColor { foreground.withAlphaComponent(0.14) }
    // A runtime's colour: the configured one as given, else the hue of its name at the saturation and
    // brightness of the terminal's light or dark theme.
    static func runtimeTint(_ mark: RuntimeMark, dark: Bool) -> NSColor {
        if let rgb = mark.color.flatMap(RuntimeTint.rgb(hex:)) { return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
        return NSColor(hue: CGFloat(RuntimeTint.hue(mark.name)) / 360, saturation: dark ? 0.47 : 0.73, brightness: dark ? 0.84 : 0.66, alpha: 1)
    }
    // The 6pt dot of a runtime: in the pill, the palette and the sidebar.
    static func drawRuntimeSwatch(_ mark: RuntimeMark, at center: NSPoint, dark: Bool) {
        runtimeTint(mark, dark: dark).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
    }
    // The stripe at full strength in the focused pane and dimmed in the others; a starting runtime's gaps
    // between the dashes are at a third of that.
    static func runtimeStripe(_ tint: NSColor, focused: Bool) -> NSColor { tint.withAlphaComponent(focused ? 1 : 0.55) }
    static func runtimeStripeGap(_ stripe: NSColor) -> NSColor { stripe.withAlphaComponent(stripe.alphaComponent * 0.35) }
    static var runtimePillUnfocusedAlpha: CGFloat { 0.7 }
}
