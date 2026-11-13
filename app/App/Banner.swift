import AppKit

final class Banner: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button: NSButton

    var changed: () -> Void = {}
    override var isHidden: Bool { didSet { if isHidden != oldValue { changed() } } }

    var background: NSColor { didSet { layer?.backgroundColor = Chrome.bannerVeil(background).cgColor } }

    init(background: NSColor, target: AnyObject, action: Selector) {
        self.background = background
        button = NSButton(title: "", target: target, action: action)
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = Chrome.bannerVeil(background).cgColor
        title.font = .boldSystemFont(ofSize: 15)
        for label in [title, detail] {
            label.textColor = Chrome.ink
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

    func show(_ title: String, _ detail: String, button: String?, action: Selector) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.button.title = button ?? ""
        self.button.action = action
        self.button.isHidden = button == nil
        isHidden = false
        window?.makeFirstResponder(nil)
    }

    #if KIDO_VISUAL || KIDO_STRESS
    var testText: (title: String, detail: String, button: String?) {
        (title.stringValue, detail.stringValue, button.isHidden ? nil : button.title)
    }
    #endif
}
