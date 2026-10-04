import AppKit

final class IconButton: NSButton {
    static let sidebarSymbols = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular, scale: .small)
    var invoke: () -> Void = {}
    var press: ((NSEvent) -> Void)?
    enum HoverStyle { case iconOnly, background }
    private let hoverStyle: HoverStyle
    private var hovered = false

    init(_ symbol: String, _ label: String, size: CGFloat? = nil, hoverStyle: HoverStyle = .background) {
        self.hoverStyle = hoverStyle
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(size.map { .init(pointSize: $0, weight: .regular, scale: .medium) } ?? Self.sidebarSymbols)
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
    override func mouseDown(with event: NSEvent) {
        if let press { window?.makeFirstResponder(self); press(event) } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let press { press(event) } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if let press { press(event) } else { super.mouseUp(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        if let press, event.keyCode == 53 { press(event) } else { super.keyDown(with: event) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHover()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateHover() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHover() }
    private func updateHover() {
        contentTintColor = hovered ? .labelColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovered && hoverStyle == .background ? NSColor.labelColor.withAlphaComponent(0.12).cgColor : nil
        }
    }
}
