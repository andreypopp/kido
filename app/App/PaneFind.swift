import AppKit
import GhosttyKit

final class PaneFind: PaneCapsule, NSTextFieldDelegate {
    let field = NSTextField()
    private let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))!)
    private let count = NSTextField(labelWithString: "")
    private let previousButton = IconButton("chevron.up", "Previous match", size: 15)
    private let nextButton = IconButton("chevron.down", "Next match", size: 15)
    private let done = IconButton("xmark", "Done", size: 15)
    private enum Status: Equatable { case none, searching, matches(Int), at(Int, of: Int), failed, loaded(Int) }
    private var status = Status.none { didSet { showStatus() } }
    private var token = UUID()
    private var matches: [Int] = []
    private var index = 0
    private var selected: Int?
    private var start: (x: Int, y: Int)?
    private var total = 0
    private var target: Int?
    private var navigating = false
    private var searchedHistory = 0
    private var autoNavigate = true
    private var loaded: Bool { pane?.copyMode != nil }

    init(_ pane: PaneView, runtime: GhosttyRuntime) {
        super.init(runtime: runtime, radius: 12, separators: 2)
        self.pane = pane
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.init(rawValue: "AXLandmarkSearch"))
        setAccessibilityLabel("Find in Terminal")
        magnifier.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderAttributedString = NSAttributedString(string: "Find in Terminal", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        field.setAccessibilityLabel("Find in Terminal")
        field.delegate = self
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        previousButton.toolTip = "Previous match (Shift-Return)"
        nextButton.toolTip = "Next match (Return)"
        done.toolTip = "Done (Escape)"
        previousButton.invoke = { [weak self] in self?.previous() }
        nextButton.invoke = { [weak self] in self?.next() }
        done.invoke = { [weak self] in self?.close() }
        for view in [magnifier, field, count, previousButton, nextButton, done] { addSubview(view) }
        field.nextKeyView = previousButton
        previousButton.nextKeyView = nextButton
        nextButton.nextKeyView = done
        done.nextKeyView = pane
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var focused: Bool { field.currentEditor() != nil }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    override func updateLayer() {
        super.updateLayer()
        let text: NSColor = focused ? .labelColor : .secondaryLabelColor
        if field.textColor != text { field.textColor = text }
    }

    private func showStatus() {
        let compact = bounds.width < 300
        let (text, navigable) = switch status {
        case .none: ("", false)
        case .searching: (compact ? "…" : "Searching…", false)
        case .matches(0): (compact ? "0" : "No matches", false)
        case .matches(let total): (compact ? "\(total)" : "\(total) matches", total > 0)
        case .at(let index, let total): (compact ? "\(index)/\(total)" : "\(index) of \(total)", true)
        case .failed: (compact ? "Failed" : "Search failed", false)
        case .loaded(let total): (compact ? "\(total) (loaded)" : total > 0 ? "\(total) matches (loaded)" : "No matches (loaded)", total > 0)
        }
        count.textColor = status == .failed ? .systemRed : .secondaryLabelColor
        previousButton.isEnabled = navigable
        nextButton.isEnabled = navigable
        guard count.stringValue != text else { return }
        count.stringValue = text
        NSAccessibility.post(element: count, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        needsLayout = true
    }

    override func layout() {
        showStatus()
        let width = bounds.width
        for (button, x) in [(previousButton, width - 91), (nextButton, width - 65), (done, width - 29)] {
            button.frame = NSRect(x: x, y: 3, width: 26, height: 26)
        }
        separatorX = [width - 96.5, width - 34.5]
        let label = count.fittingSize
        count.frame = NSRect(x: width - 105 - label.width, y: (bounds.height - label.height) / 2, width: label.width, height: label.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.isHidden = status != .searching
        spinner.frame = CGRect(x: count.frame.minX - 12, y: 11.5, width: 9, height: 9)
        CATransaction.commit()
        let left = spinner.isHidden ? count.frame.minX - 2 : spinner.frame.minX - 4
        magnifier.frame = NSRect(x: 3, y: 3, width: 22, height: 26)
        let height = field.fittingSize.height
        field.frame = NSRect(x: 25, y: (bounds.height - height) / 2, width: max(0, left - 25), height: height)
        super.layout()
    }

    func controlTextDidChange(_ notification: Notification) { search() }

    func search(navigate: Bool = true) {
        autoNavigate = navigate
        token = UUID()
        matches = []
        index = 0
        target = nil
        status = field.stringValue.isEmpty || loaded ? .none : .searching
        restartGhostty()
        pane?.onSearch(loaded ? "" : field.stringValue, token)
    }

    func invalidate() {
        guard !loaded else { return }
        token = UUID()
        matches = []
        target = nil
        navigating = false
        status = field.stringValue.isEmpty ? .none : .searching
        action("search:")
    }

    func finished(_ matches: [Int], token: UUID) {
        guard token == self.token else { return }
        self.matches = matches
        if autoNavigate, !matches.isEmpty { land() } else { status = .matches(matches.count) }
    }

    func failed(_ token: UUID) {
        if token == self.token { status = .failed }
    }

    @objc func next() { move(1) }
    @objc func previous() { move(-1) }

    private func move(_ delta: Int) {
        if loaded {
            guard total > 0 else { return }
            if total == 1, let start { pane?.copyMove("", to: start); return }
            pane?.resetScroll()
            return action(delta > 0 || selected == nil ? "navigate_search:next" : "navigate_search:previous")
        }
        guard !matches.isEmpty else { return }
        index = (index + delta + matches.count) % matches.count
        land()
    }

    private func land() {
        guard let pane else { return }
        status = .at(index + 1, of: matches.count)
        target = index
        pane.onFindCoverage(matches[index], token)
        if matches[index] <= pane.scrollPosition().retainedHistoryRows { navigate() }
    }

    func loaded(_ position: PaneView.ScrollPosition) {
        guard matches.indices.contains(index) else { return }
        if position.retainedHistoryRows != searchedHistory && matches[index] <= position.retainedHistoryRows { restartGhostty() }
        guard target != nil else { return }
        if matches[index] <= position.retainedHistoryRows { pane?.resetScroll(); navigate() }

    }

    func ghosttyTotal(_ total: Int) {
        self.total = max(0, total)
        guard loaded else { return navigate() }
        status = .loaded(total)
        guard autoNavigate, total > 0, selected == nil, !navigating else { return }
        navigating = true
        pane?.resetScroll()
        action("navigate_search:next")
    }

    func ghosttySelected(_ selected: Int, start: (x: Int, y: Int)?) {
        self.selected = selected >= 0 ? selected : nil
        self.start = self.selected == nil ? nil : start
        navigating = false
        guard loaded else { return navigate() }
        if let start = self.start { pane?.copyMove("", to: start) }
    }

    private func navigate() {
        guard !navigating, let target, total > target, let pane, matches.indices.contains(index),
              matches[index] <= pane.scrollPosition().retainedHistoryRows else { return }
        if selected == target {
            self.target = nil
            let position = pane.scrollPosition(), row = position.retainedHistoryRows - matches[index]
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
        start = nil
        total = 0
        navigating = false
        searchedHistory = pane?.scrollPosition().retainedHistoryRows ?? 0
        action("search:")
        if case .entering = pane?.copyMode { return }
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
        if loaded, !field.stringValue.isEmpty { pane?.copyFind.query = field.stringValue }
        if (window?.firstResponder as? NSView)?.isDescendant(of: self) == true { window?.makeFirstResponder(pane) }
        let pane = pane
        removeFromSuperview()
        pane?.find = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.insertNewline(_:)):
            if loaded { window?.makeFirstResponder(pane) }
            else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous() } else { next() }
        default: return false
        }
        return true
    }
}
