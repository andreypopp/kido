import AppKit

final class SidebarSeparator: NSView {
    var color = Chrome.hairline { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

final class SidebarShadow: NSView {
    static let dockedWidth: CGFloat = 48
    enum Shape: Equatable { case docked, floating(NSRect) }
    var shape = Shape.docked { didSet { if shape != oldValue { needsDisplay = true } } }
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
            let shadow = NSShadow()
            let path: NSBezierPath
            switch shape {
            case .docked:
                shadow.shadowOffset = NSSize(width: 4, height: 0)
                path = NSBezierPath(rect: NSRect(x: -66, y: 2, width: 64, height: max(0, bounds.height - 4)))
            case .floating(let rect):
                let clip = NSBezierPath(rect: bounds)
                clip.append(NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18))
                clip.windingRule = .evenOdd
                clip.addClip()
                shadow.shadowOffset = NSSize(width: 0, height: -4)
                path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 16, yRadius: 16)
            }
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let shadowStyle = Chrome.sidebarShadow(dark: dark)
            shadow.shadowBlurRadius = shadowStyle.blur
            shadow.shadowColor = shadowStyle.color
            shadow.set()
            Chrome.shadowMask.setFill()
            path.fill()
        }
    }
}

final class Sidebar: NSSplitViewController, NSToolbarDelegate {
    private final class ToolbarButtonCell: NSButtonCell {
        override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
            guard isEnabled, cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
            return [.contentArea, .trackableArea]
        }
    }

    private final class ToolbarTabsHost: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 10000, height: 36) }
    }

    private let focusEdge = FocusEdge()
    #if KIDO_VISUAL
    var visualFocusEdge: FocusEdge { focusEdge }
    var visualSeparator: NSView { separator }
    #endif
    private let separator = SidebarSeparator()
    private let shadow = SidebarShadow()
    var separatorColor: NSColor = Chrome.hairline {
        didSet {
            separator.color = separatorColor
            tabs.refreshHeader()
        }
    }
    let list = SidebarView()
    let content = NSView()
    let tabs = WindowTabs()
    private var lastTabActivity = false
    let terminalHost = NSView()
    private let dock = NSView()
    private(set) var isFloating = false
    private var leading: NSLayoutConstraint!
    private var dockedGlass: NSGlassEffectView? {
        var parent = dock.superview
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

    func updateAppearance(runtime: GhosttyRuntime) {
        let background = runtime.background
        tabs.theme = (runtime.unfocusedPaper, NSAppearance(named: background.isDark ? .darkAqua : .aqua))
        let shade = background.shifted(runtime.settings.sidebarShade)
        listBackground = shade
        separatorColor = runtime.sidebarSeparator
        list.appearance = NSAppearance(named: shade.luminance < 0.179 ? .darkAqua : .aqua)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        tabs.sidebar = self
        splitView.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        let controller = NSViewController()
        dock.addSubview(list)
        list.autoresizingMask = [.width, .height]
        controller.view = dock
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
        NSLayoutConstraint.activate([
            leading,
            content.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            content.topAnchor.constraint(equalTo: terminalHost.safeAreaLayoutGuide.topAnchor),
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
    var separatorWidth: CGFloat { 1 / (view.window?.backingScaleFactor ?? 2) }

    func headerDivider(in host: NSWindow) -> CGFloat? {
        guard let window = view.window, !isCollapsed, let glass = dockedGlass else { return nil }
        let edge = glass.convert(NSPoint(x: glass.bounds.maxX, y: glass.bounds.maxY), to: nil)
        return host.convertPoint(fromScreen: window.convertPoint(toScreen: edge)).x
    }
    func updateFocusEdge() {
        focusEdge.isHidden = !list.containsFocus || isCollapsed
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tabs.refreshHeader()
        if let root = view.window?.contentView?.superview, let glass = dockedGlass {
            if focusEdge.superview !== root { root.addSubview(focusEdge, positioned: .above, relativeTo: nil) }
            focusEdge.frame = glass.convert(glass.bounds, to: root)
            if separator.superview !== root {
                root.addSubview(separator, positioned: .above, relativeTo: nil)
            }
            separator.frame = NSRect(x: focusEdge.frame.maxX, y: focusEdge.frame.minY,
                                     width: separatorWidth, height: focusEdge.frame.height)
            separator.isHidden = isCollapsed || isFloating
            if shadow.superview !== root { root.addSubview(shadow, positioned: .below, relativeTo: focusEdge) }
            if isFloating {
                shadow.frame = focusEdge.frame.insetBy(dx: -32, dy: -32).intersection(root.bounds)
                shadow.shape = .floating(focusEdge.convert(focusEdge.bounds, to: shadow))
            } else {
                shadow.frame = NSRect(x: separator.frame.maxX, y: separator.frame.minY,
                                      width: min(SidebarShadow.dockedWidth, max(0, root.bounds.maxX - separator.frame.maxX)), height: separator.frame.height)
                shadow.shape = .docked
            }
            shadow.isHidden = isCollapsed
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
        let tabActivity = tabs.showsActivity
        if tabActivity != lastTabActivity {
            lastTabActivity = tabActivity
            tabs.needsDisplay = true
        }
        view.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "newSession" }?.isHidden = isCollapsed || isFloating
        for item in view.window?.toolbar?.items ?? [] where ["newSession", "toggleSidebar"].contains(item.itemIdentifier.rawValue) {
            item.view?.appearance = !isCollapsed || isFloating ? list.appearance : nil
        }
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
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("newSession"), .init("toggleSidebar"), .sidebarTrackingSeparator, .init("windowTabs")] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id.rawValue == "windowTabs" {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Windows"
            item.isBordered = false
            let host = ToolbarTabsHost()
            host.setContentHuggingPriority(.init(1), for: .horizontal)
            host.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(tabs)
            tabs.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(greaterThanOrEqualToConstant: 85),
                host.widthAnchor.constraint(lessThanOrEqualToConstant: 10000),
                host.heightAnchor.constraint(equalToConstant: 36),
                tabs.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                tabs.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                tabs.topAnchor.constraint(equalTo: host.topAnchor),
                tabs.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            item.view = host
            return item
        }
        if id == .sidebarTrackingSeparator { return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 0) }
        if id.rawValue == "newSession" || id.rawValue == "toggleSidebar" {
            let toggle = id.rawValue == "toggleSidebar"
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = toggle ? "Toggle Sidebar" : "New Session"
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.isBordered = false
            let button = MouseButton(frame: .zero)
            button.cell = ToolbarButtonCell()
            button.image = NSImage(systemSymbolName: toggle ? "sidebar.left" : "plus.square.on.square", accessibilityDescription: item.label)?
                .withSymbolConfiguration(IconButton.sidebarSymbols)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = toggle ? #selector(NSSplitViewController.toggleSidebar(_:)) : #selector(newSession)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.toolTip = item.label
            button.setAccessibilityLabel(item.label)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 32),
                button.heightAnchor.constraint(equalToConstant: 28),
            ])
            item.view = button
            return item
        }
        return nil
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
