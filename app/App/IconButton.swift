import AppKit

final class IconButton: NSButton {
    var invoke: () -> Void = {}
    private var hovered = false

    init(_ symbol: String, _ label: String, size: CGFloat = 17) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular, scale: .medium))
        toolTip = label
        setAccessibilityLabel(label)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 8
        target = self
        action = #selector(invokeAction)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func invokeAction() { invoke() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHover()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateHover() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHover() }
    private func updateHover() {
        contentTintColor = hovered ? .labelColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovered ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : nil
        }
    }
}
