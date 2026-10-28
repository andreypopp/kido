import AppKit

final class SidebarShadow: NSView {
    var card = NSRect.zero { didSet { if card != oldValue { needsDisplay = true } } }
    override func setFrameSize(_ newSize: NSSize) {
        let previous = bounds.size
        super.setFrameSize(newSize)
        if bounds.size != previous { needsDisplay = true }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bounds.clip()
            let clip = NSBezierPath(rect: bounds)
            clip.append(NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18))
            clip.windingRule = .evenOdd
            clip.addClip()
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let shadowStyle = Chrome.sidebarShadow(dark: dark)
            shadow.shadowBlurRadius = shadowStyle.blur
            shadow.shadowColor = shadowStyle.color
            shadow.set()
            Chrome.shadowMask.setFill()
            NSBezierPath(roundedRect: card.insetBy(dx: 2, dy: 2), xRadius: 16, yRadius: 16).fill()
        }
    }
}

final class Sidebar: NSSplitViewController {
    private let focusEdge = FocusEdge()
    #if KIDO_VISUAL
    var visualFocusEdge: FocusEdge { focusEdge }
    var visualTitle: NSTextField { titleLabel }
    #endif
    private let shadow = SidebarShadow()
    let list = SidebarView()
    let content = NSView()
    let terminalHost = NSView()
    private let slot = NSView()
    private let dock = NSView()
    lazy var newSessionButton = headerButton("New Session", "plus.square.on.square", #selector(newSession))
    lazy var toggleButton = headerButton("Toggle Sidebar", "sidebar.left", #selector(NSSplitViewController.toggleSidebar(_:)))
    private final class Title: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private let titleLabel = Title(labelWithString: "")
    var windowTitle: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue; titleLabel.toolTip = newValue }
    }
    private var top: NSLayoutConstraint!
    var margin: CGFloat = 0 { didSet { view.needsLayout = true } }
    private(set) var isFloating = false
    private var leading: NSLayoutConstraint!
    private var dockedGlass: NSGlassEffectView? {
        var parent = slot.superview
        while let view = parent {
            if let glass = view as? NSGlassEffectView { return glass }
            parent = view.superview
        }
        return nil
    }
    private final class Outside: NSView {
        var dismiss: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { dismiss() }
        override func rightMouseDown(with event: NSEvent) { dismiss() }
    }
    private var outside: Outside?
    private var resignKey: NSObjectProtocol?
    var focusTerminal: () -> Void = {}
    private var sidebarItem: NSSplitViewItem!
    private var collapseObservation: NSKeyValueObservation?
    static let minSize = NSSize(width: 800, height: 500)
    var isCollapsed: Bool {
        get { sidebarItem.isCollapsed }
        set {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                sidebarItem.isCollapsed = newValue
                view.needsLayout = true
                view.window?.contentView?.superview?.layoutSubtreeIfNeeded()
                viewDidLayout()
            }
        }
    }
    var changed: () -> Void = {}
    var listBackground: NSColor? { didSet { view.needsLayout = true } }

    func updateAppearance(runtime: GhosttyRuntime, colors: (text: NSColor, ring: NSColor) = (Chrome.accent, Chrome.accent)) {
        titleLabel.textColor = colors.text
        list.accent = colors.text
        focusEdge.color = colors.ring
        listBackground = runtime.canvas
        list.appearance = NSAppearance(named: runtime.canvas.luminance < 0.179 ? .darkAqua : .aqua)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        splitView.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        let controller = NSViewController()
        slot.addSubview(dock)
        dock.addSubview(list)
        list.autoresizingMask = [.width, .height]
        titleLabel.font = .titleBarFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = Chrome.accent
        dock.addSubview(titleLabel)
        dock.addSubview(newSessionButton)
        dock.addSubview(toggleButton)
        for header in [newSessionButton, toggleButton] { header.autoresizingMask = [.minYMargin] }
        titleLabel.autoresizingMask = [.minYMargin, .width]
        controller.view = slot
        list.leave = { [weak self] in
            guard let self else { return }
            dismissFloating()
            focusTerminal()
        }
        sidebarItem = NSSplitViewItem(sidebarWithViewController: controller)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        addSplitViewItem(sidebarItem)
        let terminal = NSViewController()
        terminalHost.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        leading = content.leadingAnchor.constraint(equalTo: terminalHost.safeAreaLayoutGuide.leadingAnchor)
        top = content.topAnchor.constraint(equalTo: terminalHost.topAnchor)
        NSLayoutConstraint.activate([
            leading,
            top,
            content.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
        terminal.view = terminalHost
        let terminalItem = NSSplitViewItem(viewController: terminal)
        terminalItem.minimumThickness = 200
        terminalItem.automaticallyAdjustsSafeAreaInsets = true
        addSplitViewItem(terminalItem)
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !background, !self.isFloating { UserDefaults.standard.set(self.isCollapsed, forKey: "sidebarCollapsed") }
                if self.isCollapsed, self.list.containsFocus { self.list.leave() }
                self.view.needsLayout = true
                self.changed()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.needsLayout = true
    }
    func updateFocusEdge() {
        focusEdge.isHidden = !list.containsFocus || isCollapsed
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let root = view.window?.contentView?.superview
        if let root, let glass = dockedGlass, !isFloating, !isCollapsed {
            if focusEdge.superview !== root { root.addSubview(focusEdge, positioned: .above, relativeTo: nil) }
            if dock.superview !== root { root.addSubview(dock, positioned: .above, relativeTo: view.window?.contentView) }
            dock.frame = glass.convert(glass.bounds, to: root)
            glass.isHidden = true
        } else {
            if dock.superview !== slot { slot.addSubview(dock) }
            dock.frame = slot.bounds
            dockedGlass?.isHidden = false
        }
        if let root, let glass = dockedGlass {
            if focusEdge.superview !== root { root.addSubview(focusEdge, positioned: .above, relativeTo: nil) }
            focusEdge.frame = glass.convert(glass.bounds, to: root)
            if shadow.superview !== root { root.addSubview(shadow, positioned: .below, relativeTo: focusEdge) }
            shadow.frame = focusEdge.frame.insetBy(dx: -32, dy: -32).intersection(root.bounds)
            shadow.card = focusEdge.convert(focusEdge.bounds, to: shadow)
            shadow.isHidden = !isFloating
            focusEdge.floating = isFloating
            updateFocusEdge()
        }
        list.frame = dock.bounds
        list.layer?.cornerRadius = isFloating ? 18 : 0
        list.layer?.borderWidth = isFloating ? 1 / (view.window?.backingScaleFactor ?? 2) : 0
        if let outside, let root = outside.superview, let glass = dockedGlass {
            let area = content.convert(content.bounds, to: root)
            let left = glass.convert(glass.bounds, to: root).maxX
            outside.frame = NSRect(x: left, y: area.minY, width: max(0, area.maxX - left), height: area.height)
        }
        let left = terminalHost.safeAreaInsets.left
        if !background, view.window != nil, !isCollapsed, !isFloating, left >= 200 {
            UserDefaults.standard.set(left, forKey: "nativeSidebarWidth")
        }
        let fullScreen = view.window?.styleMask.contains(.fullScreen) == true
        let titled = (isCollapsed || isFloating) && !fullScreen
        let inset = titled ? Self.titlebar - margin : 0
        if top.constant != inset { top.constant = inset }
        let center = Self.titlebar / 2
        newSessionButton.isHidden = isCollapsed || isFloating
        newSessionButton.frame = NSRect(x: dock.bounds.maxX - 72, y: dock.bounds.maxY - center - 14, width: 32, height: 28)
        toggleButton.frame = NSRect(x: dock.bounds.maxX - 40, y: dock.bounds.maxY - center - 14, width: 32, height: 28)
        for button in [newSessionButton, toggleButton] { button.appearance = list.appearance }
        if isCollapsed || isFloating {
            if titleLabel.superview !== terminalHost { terminalHost.addSubview(titleLabel) }
            titleLabel.alignment = .center
            titleLabel.appearance = nil
            titleLabel.isHidden = !titled
            titleLabel.frame = NSRect(x: 80, y: terminalHost.bounds.maxY - center - 8, width: max(0, terminalHost.bounds.width - 160), height: 16)
        } else {
            if titleLabel.superview !== dock { dock.addSubview(titleLabel) }
            titleLabel.alignment = .natural
            titleLabel.appearance = list.appearance
            titleLabel.isHidden = false
            let start: CGFloat = fullScreen ? 20 : 80
            let end = (newSessionButton.isHidden ? toggleButton : newSessionButton).frame.minX - 4
            titleLabel.frame = NSRect(x: start, y: dock.bounds.maxY - center - 8, width: max(0, end - start), height: 16)
        }
        for view in splitView.subviews where String(describing: type(of: view)).hasSuffix("ShadowView") { view.isHidden = !isFloating }
        dockedGlass?.cornerRadius = isFloating ? 18 : 0
        dockedGlass?.shadow = nil
        dockedGlass?.layer?.shadowOpacity = 0 // chrome-allow: disable the native glass shadow
        dockedGlass?.layer?.cornerRadius = isFloating ? 18 : 0
        dockedGlass?.layer?.masksToBounds = isFloating
        list.layer?.backgroundColor = listBackground?.cgColor
        #if KIDO_VISUAL
        dockedGlass?.wantsLayer = true
        dockedGlass?.layer?.backgroundColor = isFloating ? listBackground?.cgColor : nil
        dockedGlass?.layer?.cornerRadius = isFloating ? list.layer?.cornerRadius ?? 0 : 0
        #endif
    }
    static let titlebar: CGFloat = 32

    private func headerButton(_ label: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = MouseButton(frame: .zero)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(IconButton.sidebarSymbols)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
    @objc private func newSession() { list.newSession() }

    override func toggleSidebar(_ sender: Any?) {
        if isFloating {
            isFloating = false
            isCollapsed = true
            endFloating()
            isCollapsed = false
        } else { isCollapsed.toggle() }
    }

    @objc func focusSidebar(_ sender: Any?) {
        if isFloating { list.leave(); return }
        if isCollapsed, let root = view.window?.contentView?.superview {
            viewDidLayout()
            root.layoutSubtreeIfNeeded()
            viewDidLayout()
            isFloating = true
            leading.isActive = false
            leading = content.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor)
            leading.isActive = true
            let outside = Outside()
            outside.dismiss = { [weak self] in self?.list.leave() }
            self.outside = outside
            splitView.addSubview(outside, positioned: .above, relativeTo: terminalHost)
            isCollapsed = false
            resignKey = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: view.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.list.leave() }
            }
        }
        list.focus()
    }

    private func endFloating() {
        outside?.removeFromSuperview()
        outside = nil
        if let resignKey { NotificationCenter.default.removeObserver(resignKey) }
        resignKey = nil
        leading.isActive = false
        leading = content.leadingAnchor.constraint(equalTo: terminalHost.safeAreaLayoutGuide.leadingAnchor)
        leading.isActive = true
    }

    func dismissFloating() {
        guard isFloating else { return }
        isFloating = false
        endFloating()
        isCollapsed = true
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        view.needsLayout = true
    }
}
