import AppKit

final class IconButton: NSButton {
    var invoke: () -> Void = {}
    private var tracking: NSTrackingArea?

    init(_ symbol: String, _ label: String, size: CGFloat = 17) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular, scale: .medium))
        toolTip = label
        setAccessibilityLabel(label)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .labelColor.withAlphaComponent(0.55)
        wantsLayer = true
        layer?.cornerRadius = 8
        target = self
        action = #selector(invokeAction)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func invokeAction() { invoke() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        contentTintColor = .labelColor.withAlphaComponent(0.9)
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        contentTintColor = .labelColor.withAlphaComponent(0.55)
    }
}
