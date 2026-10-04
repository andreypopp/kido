import AppKit
import SidebarFeed
import TmuxControl

final class WindowTabs: NSView {
    private(set) var model = SessionModel()
    private(set) var snapshot: Snapshot? { didSet { needsDisplay = true; changed() } }

    func update(_ status: Feed.Status, query: String) {
        if case .running(let next) = status, query.isEmpty, next.filter.isEmpty { snapshot = next }
    }
    var changed: () -> Void = {}
    var send: ([Command]) -> Void = { _ in }
    private var offset: CGFloat = 0
    override var mouseDownCanMoveWindow: Bool { false }

    var entries: [(id: WindowID, name: String, active: Bool, status: SidebarRow.Status)] {
        let session = snapshot?.sessions.first(where: { $0.id == model.session })
        let rows = sidebarRows(snapshot, folded: [])
        var known: Set<WindowID> = []
        func remember(_ node: SidebarFeed.Node) {
            switch node { case .window(let group): known.insert(group.window); case .item(let item): known.insert(item.window) }
            node.children.forEach(remember)
        }
        session?.nodes.forEach(remember)
        let projected = (session?.nodes ?? []).map { node in
            var panes: [Item] = []
            func collect(_ node: SidebarFeed.Node) {
                if case .item(let item) = node { panes.append(item) }
                node.children.forEach(collect)
            }
            collect(node)
            let id: WindowID = switch node { case .window(let group): group.window; case .item(let item): item.window }
            let fallback: String = switch node { case .window(let group): group.name; case .item(let item): item.title.map(\.text).joined() }
            let statuses = rows.filter { row in
                row.target?.session == session?.id && panes.contains { $0.pane == row.target?.pane }
            }.map(\.status)
            return (id: id, name: model.windows.first { $0.id == id }?.name ?? fallback, active:
                    panes.contains { $0.window == model.window },
                    status: statuses.contains(.error) ? SidebarRow.Status.error : statuses.contains(.attention) ? .attention : .quiet)
        }
        return model.windows.compactMap { window in
            if let tab = projected.first(where: { $0.id == window.id }) { return tab }
            return known.contains(window.id) ? nil : (window.id, window.name, window.id == model.window, .quiet)
        }
    }

    var navigationModel: SessionModel {
        var next = model
        next.windows = entries.map { .init(id: $0.id, name: $0.name) }
        next.window = entries.first { $0.active }?.id
        return next
    }

    func update(_ model: SessionModel) {
        self.model = model
        if model.session == nil { snapshot = nil }
        needsDisplay = true
        changed()
    }

    private var tabWidth: CGFloat { max(85, min(220, bounds.width / CGFloat(max(1, entries.count)))) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local), local.x + offset < tabWidth * CGFloat(entries.count) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let index = Int((point.x + offset) / tabWidth)
        guard entries.indices.contains(index) else { return }
        send([Command("select-window", "-t", entries[index].id)])
    }

    override func scrollWheel(with event: NSEvent) {
        offset = max(0, min(max(0, tabWidth * CGFloat(entries.count) - bounds.width),
                            offset + (event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            (window?.backgroundColor ?? .windowBackgroundColor).setFill()
            bounds.fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            offset = min(offset, max(0, tabWidth * CGFloat(entries.count) - bounds.width))
            for (index, tab) in entries.enumerated() {
                let rect = NSRect(x: CGFloat(index) * tabWidth - offset + 2, y: 8, width: tabWidth - 3, height: bounds.height - 16)
                guard rect.intersects(bounds) else { continue }
                if tab.active {
                    NSColor.labelColor.withAlphaComponent(0.075).setFill()
                    let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                    path.fill()
                    NSColor.labelColor.withAlphaComponent(0.075).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
                let dot = tab.status == .error || tab.status == .attention
                (tab.name as NSString).draw(in: NSRect(x: rect.minX + 12, y: rect.midY - 8, width: rect.width - (dot ? 38 : 24), height: 16),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: tab.active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                                     .paragraphStyle: paragraph])
                if dot {
                    (tab.status == .error ? NSColor.systemRed : NSColor.systemOrange).setFill()
                    NSBezierPath(ovalIn: NSRect(x: rect.maxX - 18, y: rect.midY - 3, width: 6, height: 6)).fill()
                }
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        entries.enumerated().map { index, tab in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: CGFloat(index) * tabWidth - offset, y: 8, width: tabWidth, height: 28))
            element.setAccessibilityLabel("Window: " + tab.name + (tab.status == .error ? " — error" : tab.status == .attention ? " — attention" : ""))
            element.setAccessibilityValue(tab.active ? "selected" : "")
            return element
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
