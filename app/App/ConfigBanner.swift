import AppKit

final class ConfigBanner: NSView {
    static let height: CGFloat = 62
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    var reveal: () -> Void = {}
    var background: NSColor = Chrome.defaultPaper { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        isHidden = true
        title.font = .boldSystemFont(ofSize: 12)
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let button = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealFile))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [labels, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
            detail.widthAnchor.constraint(equalTo: labels.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func revealFile() { reveal() }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.configErrorPaper(background).setFill()
        bounds.fill()
        Chrome.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func show(_ title: String, _ detail: String) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        self.title.textColor = Chrome.ink
        self.detail.textColor = Chrome.inkSecondary
        isHidden = false
        needsDisplay = true
    }

    #if KIDO_VISUAL || KIDO_STRESS
    var testText: (title: String, detail: String) { (title.stringValue, detail.stringValue) }
    #endif
}
