import AppKit
import KoModel

// Where a pane runs, at the pane's top-right: the runtime's swatch and name, then the state.
final class RuntimePill: PaneCapsule {
    #if KIDO_VISUAL
    @MainActor static var spins = true
    #else
    static let spins = true
    #endif
    static let height: CGFloat = 22
    private static let maximumWidth: CGFloat = 300
    private let swatch = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private(set) var mark: RuntimeMark?

    init(runtime: GhosttyRuntime) {
        super.init(runtime: runtime, radius: 8)
        wantsLayer = true
        appearance = NSAppearance(named: runtime.background.isDark ? .darkAqua : .aqua)
        swatch.cornerRadius = 3
        layer?.addSublayer(swatch)
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.textColor = Chrome.ink
        state.font = .systemFont(ofSize: 11)
        state.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = true
        for view in [name, state, spinner] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { toolTip == nil ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) { pane?.onSelect() }

    // The state after the name, when there is one.
    static func stateText(_ mark: RuntimeMark) -> String? {
        switch mark.state {
        case .starting: mark.stateWord
        case .failed: mark.stateWord + ": " + (mark.failure ?? "")
        case .up, .down: mark.routed ? "tools" : nil
        }
    }

    func show(_ mark: RuntimeMark?, focused: Bool) {
        alphaValue = focused ? 1 : Chrome.runtimePillUnfocusedAlpha
        guard self.mark != mark else { return }
        self.mark = mark
        guard let mark else { return }
        name.stringValue = mark.name
        let text = Self.stateText(mark)
        state.stringValue = text.map { " · " + $0 } ?? ""
        state.textColor = mark.failure == nil ? Chrome.inkSecondary : Chrome.errorText
        state.isHidden = text == nil
        toolTip = mark.failure
        let starting = mark.state == .starting
        spinner.isHidden = !starting
        if starting, Self.spins { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        setAccessibilityLabel(["Runtime", mark.name, text].compactMap { $0 }.joined(separator: " "))
        needsLayout = true
        needsDisplay = true
    }

    // A label draws its text 2pt inside its frame on each side; the frames below cancel that, so the
    // visible gaps are 8pt before the swatch, 6pt after it and 9pt after the last text.
    private static let labelInset: CGFloat = 2

    private var textEnd: CGFloat {
        let inset = Self.labelInset
        let name = ceil(self.name.fittingSize.width)
        guard !state.isHidden else { return 18 + name - inset }
        return 18 + name - 2 * inset + ceil(state.fittingSize.width) - inset
    }

    var fittingWidth: CGFloat {
        guard mark != nil else { return 0 }
        return min(Self.maximumWidth, textEnd + (spinner.isHidden ? 0 : 15) + 9)
    }

    override func updateLayer() {
        super.updateLayer()
        guard let mark else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            swatch.backgroundColor = Chrome.runtimeTint(mark, dark: runtime.background.isDark).cgColor
        }
    }

    override func layout() {
        super.layout()
        guard mark != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swatch.frame = CGRect(x: 8, y: (bounds.height - 6) / 2, width: 6, height: 6)
        CATransaction.commit()
        let nameSize = name.fittingSize
        name.frame = NSRect(x: 18, y: (bounds.height - nameSize.height) / 2, width: ceil(nameSize.width), height: nameSize.height)
        let spinnerWidth: CGFloat = spinner.isHidden ? 0 : 15
        let stateX = name.frame.maxX - 2 * Self.labelInset
        let stateSize = state.fittingSize
        state.frame = NSRect(x: stateX, y: (bounds.height - stateSize.height) / 2,
                             width: max(0, min(ceil(stateSize.width), bounds.width - stateX - 7 - spinnerWidth)), height: stateSize.height)
        spinner.frame = NSRect(x: bounds.width - 9 - 9, y: (bounds.height - 9) / 2, width: 9, height: 9)
    }
}
