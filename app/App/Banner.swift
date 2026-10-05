import AppKit

final class Banner: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button: NSButton

    init(target: AnyObject, action: Selector) {
        button = NSButton(title: "", target: target, action: action)
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        updateBackground()
        title.font = .boldSystemFont(ofSize: 15)
        for label in [title, detail] {
            label.textColor = .labelColor
            label.alignment = .center
        }
        let stack = NSStackView(views: [title, detail, button])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        }
    }

    func show(_ title: String, _ detail: String, button: String?) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.button.title = button ?? ""
        self.button.isHidden = button == nil
        isHidden = false
        window?.makeFirstResponder(nil)
    }
}
