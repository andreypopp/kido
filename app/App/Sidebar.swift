import AppKit

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

    let list = SidebarView()
    let content = NSView()
    let tabs = WindowTabs()
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

    init() {
        super.init(nibName: nil, bundle: nil)
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
    override func viewDidLayout() {
        super.viewDidLayout()
        list.frame = dock.bounds
        if let outside, let root = outside.superview, let glass = dockedGlass {
            let area = content.convert(content.bounds, to: root)
            let left = glass.convert(glass.bounds, to: root).maxX
            outside.frame = NSRect(x: left, y: area.minY, width: max(0, area.maxX - left), height: area.height)
        }
        let left = terminalHost.safeAreaInsets.left
        if !background, view.window != nil, !isCollapsed, !isFloating, left >= 200 {
            UserDefaults.standard.set(left, forKey: "nativeSidebarWidth")
        }
        view.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "newSession" }?.isHidden = isCollapsed || isFloating
        #if KIDO_VISUAL
        dockedGlass?.wantsLayer = true
        dockedGlass?.layer?.backgroundColor = isFloating ? NSColor.windowBackgroundColor.cgColor : nil
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
            let button = NSButton(frame: .zero)
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
