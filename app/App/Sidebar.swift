import AppKit

final class Sidebar: NSView {
    let view = SidebarView()
    let content = NSView()
    private let divider = Divider()

    private static let defaults: UserDefaults? = background ? nil : .standard
    private static let widthKey = "sidebarWidth"
    private static let collapsedKey = "sidebarCollapsed"
    private static let minWidth: CGFloat = 140
    private static let minContent: CGFloat = 200
    static let minSize = NSSize(width: minWidth + 1 + minContent, height: 200)

    private var width: CGFloat {
        didSet { Self.defaults?.set(width, forKey: Self.widthKey) }
    }
    private(set) var isCollapsed: Bool {
        didSet { Self.defaults?.set(isCollapsed, forKey: Self.collapsedKey) }
    }

    override var isFlipped: Bool { true }

    init() {
        let stored = Self.defaults?.double(forKey: Self.widthKey) ?? 0
        width = max(Self.minWidth, stored == 0 ? 220 : stored)
        isCollapsed = Self.defaults?.bool(forKey: Self.collapsedKey) ?? false
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        divider.dragged = { [weak self] x in
            guard let self else { return }
            width = clamp(x)
            arrange()
        }
        addSubview(view)
        addSubview(content)
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toggle() {
        isCollapsed.toggle()
        if isCollapsed, let focused = window?.firstResponder as? NSView, focused.isDescendant(of: view) { view.leave() }
        arrange()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    private func clamp(_ x: CGFloat) -> CGFloat {
        max(Self.minWidth, min(x, bounds.width - 1 - Self.minContent))
    }

    private func arrange() {
        let w = isCollapsed ? 0 : clamp(width)
        let d: CGFloat = isCollapsed ? 0 : 1
        view.isHidden = isCollapsed
        divider.isHidden = isCollapsed
        view.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        divider.frame = CGRect(x: w - 2, y: 0, width: 5, height: bounds.height)
        content.frame = CGRect(x: w + d, y: 0, width: max(0, bounds.width - w - d), height: bounds.height)
        window?.invalidateCursorRects(for: divider)
    }
}

private final class Divider: NSView {
    var dragged: (CGFloat) -> Void = { _ in }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        CGRect(x: 2, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        dragged(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}
