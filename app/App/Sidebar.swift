import AppKit

// Lays out sidebar | divider | content, and remembers the sidebar's width
// and collapsed state across launches. `content` is the tmux area's
// container: SessionView keeps computing the client size from its own
// bounds, unaffected by whether it sits in `content` or in a window's
// contentView.
final class Sidebar: NSView {
    let view = SidebarView()
    let content = NSView()
    private let divider = NSView()

    private static let widthKey = "sidebarWidth"
    private static let collapsedKey = "sidebarCollapsed"
    private static let minWidth: CGFloat = 140

    private var width: CGFloat {
        didSet { UserDefaults.standard.set(width, forKey: Self.widthKey) }
    }
    private(set) var isCollapsed: Bool {
        didSet { UserDefaults.standard.set(isCollapsed, forKey: Self.collapsedKey) }
    }

    override var isFlipped: Bool { true }

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.widthKey)
        width = max(Self.minWidth, stored == 0 ? 220 : stored)
        isCollapsed = UserDefaults.standard.bool(forKey: Self.collapsedKey)
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(view)
        addSubview(divider)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toggle() {
        isCollapsed.toggle()
        arrange()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    private func arrange() {
        let w = isCollapsed ? 0 : width
        let d: CGFloat = isCollapsed ? 0 : 1
        view.isHidden = isCollapsed
        view.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        divider.frame = CGRect(x: w, y: 0, width: d, height: bounds.height)
        content.frame = CGRect(x: w + d, y: 0, width: bounds.width - w - d, height: bounds.height)
    }

    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        dragging = !isCollapsed && divider.frame.insetBy(dx: -3, dy: 0).contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        width = min(max(convert(event.locationInWindow, from: nil).x, Self.minWidth), bounds.width - 200)
        arrange()
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    override func resetCursorRects() {
        guard !isCollapsed else { return }
        addCursorRect(divider.frame.insetBy(dx: -3, dy: 0), cursor: .resizeLeftRight)
    }
}
