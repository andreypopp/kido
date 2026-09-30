import AppKit

final class Sidebar: NSSplitViewController, NSToolbarDelegate {
    let list = SidebarView()
    let content = NSView()
    private let terminalHost = NSView()
    private let showButton = IconButton("sidebar.left", "Show sidebar")
    private var sidebarItem: NSSplitViewItem!
    private var collapseObservation: NSKeyValueObservation?
    static let minSize = NSSize(width: 800, height: 500)
    var isCollapsed: Bool {
        get { sidebarItem.isCollapsed }
        set { sidebarItem.isCollapsed = newValue }
    }
    var changed: () -> Void = {}

    init() {
        super.init(nibName: nil, bundle: nil)
        splitView.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        let controller = NSViewController()
        controller.view = list
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
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: terminalHost.safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            content.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            content.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
        showButton.invoke = { [weak self] in self?.toggleSidebar(nil) }
        terminal.view = terminalHost
        let terminalItem = NSSplitViewItem(viewController: terminal)
        terminalItem.minimumThickness = 200
        terminalItem.automaticallyAdjustsSafeAreaInsets = true
        addSplitViewItem(terminalItem)
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !background { UserDefaults.standard.set(self.isCollapsed, forKey: "sidebarCollapsed") }
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
        let left = terminalHost.safeAreaInsets.left
        if !background, view.window != nil, !isCollapsed, left >= 200 {
            UserDefaults.standard.set(left, forKey: "nativeSidebarWidth")
        }
        for item in view.window?.toolbar?.items ?? [] where item.itemIdentifier != .sidebarTrackingSeparator {
            item.isHidden = isCollapsed
        }
        showButton.isHidden = !isCollapsed
        if isCollapsed, let green = view.window?.standardWindowButton(.zoomButton), let titlebar = green.superview, showButton.superview !== titlebar {
            titlebar.addSubview(showButton)
            showButton.translatesAutoresizingMaskIntoConstraints = false
            let insets = showButton.alignmentRectInsets, greenInsets = green.alignmentRectInsets
            NSLayoutConstraint.activate([
                showButton.leadingAnchor.constraint(equalTo: green.trailingAnchor, constant: 10 + greenInsets.right + insets.left),
                showButton.centerYAnchor.constraint(equalTo: green.centerYAnchor, constant: green.alignmentRect(forFrame: green.frame).midY - showButton.alignmentRect(forFrame: green.frame).midY),
                showButton.widthAnchor.constraint(equalToConstant: 28 - insets.left - insets.right),
                showButton.heightAnchor.constraint(equalToConstant: 28 - insets.top - insets.bottom),
            ])
        }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("newSession"), .init("toggleSidebar"), .sidebarTrackingSeparator] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .sidebarTrackingSeparator { return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 0) }
        if id.rawValue == "newSession" || id.rawValue == "toggleSidebar" {
            let item = NSToolbarItem(itemIdentifier: id)
            let toggle = id.rawValue == "toggleSidebar"
            let button = IconButton(toggle ? "sidebar.left" : "plus.square.on.square", toggle ? "Hide sidebar" : "New session")
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28)])
            button.invoke = { [weak self] in
                if toggle { self?.toggleSidebar(nil) } else { self?.list.newSession() }
            }
            item.view = button
            item.label = button.toolTip ?? ""
            item.isBordered = false
            return item
        }
        return nil
    }
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        view.needsLayout = true
    }
}
