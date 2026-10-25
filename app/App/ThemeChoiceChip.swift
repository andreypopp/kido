import AppKit

final class ThemeChoiceChip: NSView {
    var row: ThemeRow?
    override var isFlipped: Bool { true }
    var width: CGFloat { 56 + ((row?.name ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width }
    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        row.drawSwatch(at: NSPoint(x: 8, y: 2))
        (row.name as NSString).draw(at: NSPoint(x: 50, y: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Chrome.ink])
    }
}
