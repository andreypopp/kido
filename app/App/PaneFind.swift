import AppKit
import GhosttyKit

final class PaneFind: NSView, NSSearchFieldDelegate {
    private weak var pane: PaneView?
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private var token = UUID()
    private var matches: [Int] = []
    private var index = 0
    private var selected: Int?
    private var total = 0
    private var target: Int?
    private var navigating = false
    private var searchedHistory = 0
    private var autoNavigate = true

    init(_ pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        field.placeholderString = "Find in Terminal"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        addSubview(field)
        addSubview(count)
        for (title, action) in [("↑", #selector(previous)), ("↓", #selector(next)), ("Done", #selector(close))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 8, y: 6, width: max(60, bounds.width - 300), height: 24)
        count.frame = NSRect(x: field.frame.maxX + 8, y: 9, width: 130, height: 18)
        for (index, button) in subviews.dropFirst(2).enumerated() {
            button.frame = NSRect(x: bounds.width - 150 + CGFloat(index) * 46, y: 5, width: index == 2 ? 56 : 40, height: 26)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }

    func controlTextDidChange(_ notification: Notification) { search() }

    func search(navigate: Bool = true) {
        autoNavigate = navigate
        token = UUID()
        matches = []
        index = 0
        target = nil
        count.stringValue = field.stringValue.isEmpty ? "" : "Searching…"
        restartGhostty()
        pane?.onSearch(field.stringValue, token)
    }

    func invalidate() {
        token = UUID()
        matches = []
        target = nil
        navigating = false
        count.stringValue = field.stringValue.isEmpty ? "" : "Searching…"
        action("search:")
    }

    func finished(_ matches: [Int], token: UUID) {
        guard token == self.token else { return }
        self.matches = matches
        if matches.isEmpty { count.stringValue = "No matches" }
        else if autoNavigate { land() }
        else { count.stringValue = "\(matches.count) matches" }
    }

    func failed(_ token: UUID) {
        if token == self.token { count.stringValue = "Search failed" }
    }

    @objc func next() { move(1) }
    @objc func previous() { move(-1) }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        index = (index + delta + matches.count) % matches.count
        land()
    }

    private func land() {
        guard let pane else { return }
        count.stringValue = "\(index + 1) of \(matches.count)"
        target = index
        pane.onFindCoverage(matches[index], token)
        if matches[index] <= pane.scrollPosition().history { navigate() }
    }

    func loaded(_ position: PaneView.ScrollPosition) {
        guard matches.indices.contains(index) else { return }
        if position.history != searchedHistory && matches[index] <= position.history { restartGhostty() }
        guard target != nil else { return }
        if matches[index] <= position.history { pane?.resetScroll(); navigate() }

    }

    func ghosttyTotal(_ total: Int) { self.total = max(0, total); navigate() }
    func ghosttySelected(_ selected: Int) {
        self.selected = selected >= 0 ? selected : nil
        navigating = false
        navigate()
    }

    private func navigate() {
        guard !navigating, let target, total > target, let pane, matches.indices.contains(index),
              matches[index] <= pane.scrollPosition().history else { return }
        if selected == target {
            self.target = nil
            let position = pane.scrollPosition(), row = position.history - matches[index]
            if row < position.offset + 2 { pane.scroll(to: max(0, position.offset - 2)) }
            return
        }
        let forward = selected.map { (target - $0 + total) % total } ?? (target + 1)
        let backward = selected.map { ($0 - target + total) % total } ?? (total - target)
        navigating = true
        pane.resetScroll()
        action(forward <= backward ? "navigate_search:next" : "navigate_search:previous")
    }

    private func restartGhostty() {
        selected = nil
        total = 0
        navigating = false
        searchedHistory = pane?.scrollPosition().history ?? 0
        action("search:")
        action("search:\(field.stringValue)")
    }

    #if KIDO_STRESS
    private var navigationCount = 0
    var stressState: (selected: Int?, total: Int, navigationCount: Int) { (selected, total, navigationCount) }
    func stressMatches(_ matches: [Int]) { finished(matches, token: token) }
    #endif

    private func action(_ name: String) {
        guard let pane else { return }
        #if KIDO_STRESS
        if name.hasPrefix("navigate_search:") { navigationCount += 1 }
        #endif
        _ = ghostty_surface_binding_action(pane.surface, name, UInt(name.utf8.count))
    }

    @objc func close() {
        token = UUID()
        pane?.onSearch("", token)
        action("end_search")
        let pane = pane
        removeFromSuperview()
        pane?.find = nil
        pane?.window?.makeFirstResponder(pane)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous() } else { next() }
        default: return false
        }
        return true
    }
}
