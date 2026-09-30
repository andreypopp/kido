import AppKit
import SidebarFeed

final class SidebarView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.stringValue = "Starting…"
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        label.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    func update(_ status: Feed.Status) {
        switch status {
        case .starting:
            label.stringValue = "Starting…"
        case .failed(let message):
            label.stringValue = "Feed stopped, restarting…\n\(message)"
        case .running(let snapshots, let last):
            var lines = ["\(snapshots) snapshot\(snapshots == 1 ? "" : "s")"]
            for session in last?.sessions ?? [] {
                lines.append((session.current ? "▸ " : "  ") + session.name)
                for row in session.rows {
                    let text = (row.title + row.tail).map(\.text).joined()
                    lines.append("    " + row.tree + (text.isEmpty ? "(untitled)" : text))
                }
            }
            label.stringValue = lines.joined(separator: "\n")
        }
    }
}
