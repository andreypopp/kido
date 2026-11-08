import AppKit
import KoModel
import SidebarFeed

final class PaneBreadcrumb: PaneCapsule {
    private final class Ancestor: ActionButton {
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    }
    private struct Segment {
        let view: NSView
        let label: NSTextField
        let separator: NSTextField
        let width: CGFloat
    }
    private let font = NSFont.systemFont(ofSize: 11)
    private var segments: [Segment] = []
    private var ellipsis: Segment?
    private var fitted: (available: CGFloat, width: CGFloat)?
    var showAncestor: (Snapshot.Position) -> Void = { _ in }
    private(set) var entries: [ShownPane.Entry] = []
    var minimumWidth: CGFloat {
        guard let first = segments.first, let last = segments.last else { return 0 }
        return 16 + min(60, first.width) + 15 + min(40, last.width)
            + (segments.count > 2 ? measure("…") + 15 : 0)
    }
    override var isFlipped: Bool { true }
    init(runtime: GhosttyRuntime) {
        super.init(runtime: runtime, radius: 8)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pane hierarchy")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func measure(_ title: String) -> CGFloat { ceil((title as NSString).size(withAttributes: [.font: font]).width) }
    func show(_ entries: [ShownPane.Entry]) {
        guard entries != self.entries else { return }
        self.entries = entries
        subviews.forEach { $0.removeFromSuperview() }
        segments = []
        ellipsis = nil
        fitted = nil
        guard !entries.isEmpty else { pane?.needsLayout = true; return }
        func segment(_ title: String, position: Snapshot.Position?, current: Bool) -> Segment {
            let label = NSTextField(labelWithString: title)
            label.font = font
            label.textColor = current ? Chrome.ink : Chrome.inkSecondary
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            let view: NSView
            if let position {
                let button = Ancestor()
                button.setAccessibilityLabel("Show pane: " + title)
                button.invoke = { [weak self] in self?.showAncestor(position) }
                button.addSubview(label)
                view = button
            } else { view = label }
            let separator = NSTextField(labelWithString: "›")
            separator.font = font
            separator.textColor = Chrome.inkSecondary
            separator.setAccessibilityElement(false)
            addSubview(separator)
            addSubview(view)
            return Segment(view: view, label: label, separator: separator, width: measure(title))
        }
        for (index, entry) in entries.enumerated() {
            segments.append(segment(entry.title, position: index == entries.count - 1 ? nil : entry.position, current: index == entries.count - 1))
        }
        ellipsis = segment("…", position: nil, current: false)
        needsLayout = true
        pane?.needsLayout = true
    }
    func fit(_ available: CGFloat) -> CGFloat {
        guard !entries.isEmpty else { return 0 }
        if let fitted, fitted.available == available { return fitted.width }
        guard available >= minimumWidth else { fitted = (available, 0); return 0 }
        var shown = segments
        func total() -> CGFloat { 16 + shown.reduce(0) { $0 + $1.width } + CGFloat(shown.count - 1) * 15 }
        if total() > available, shown.count > 2, let ellipsis { shown = [shown[0], ellipsis, shown[shown.count - 1]] }
        var widths = shown.map(\.width)
        var excess = max(0, total() - available)
        for index in widths.indices.dropLast() {
            let cut = min(excess, max(0, widths[index] - 60))
            widths[index] -= cut
            excess -= cut
        }
        if let last = widths.indices.last { widths[last] -= excess }
        for segment in segments + [ellipsis].compactMap({ $0 }) { segment.view.isHidden = true; segment.separator.isHidden = true }
        var x: CGFloat = 8
        for (index, segment) in shown.enumerated() {
            segment.view.isHidden = false
            if index > 0 {
                segment.separator.isHidden = false
                segment.separator.frame = NSRect(x: x + 3, y: 4, width: 9, height: 14)
                x += 15
            }
            let width = widths[index]
            if segment.view === segment.label {
                segment.view.frame = NSRect(x: x - PaneCapsule.labelInset, y: 4, width: width + 2 * PaneCapsule.labelInset, height: 14)
            } else {
                segment.view.frame = NSRect(x: x, y: 0, width: width, height: 22)
                segment.label.frame = NSRect(x: -PaneCapsule.labelInset, y: 4, width: width + 2 * PaneCapsule.labelInset, height: 14)
            }
            x += width
        }
        fitted = (available, x + 8)
        return x + 8
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), hit is Ancestor else { return nil }
        return hit
    }
}
