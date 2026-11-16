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
    // Ghostty searches the pane's mirror, which holds the whole history.
    private enum Status: Equatable { case none, matches(Int), at(Int, of: Int), found(Bool), searching }
    private var status = Status.none { didSet { showStatus() } }
    private var selected: Int?
    private var start: (x: Int, y: Int)?
    private var total = 0
    private var navigating = false
    private var autoNavigate = true
    private var generation = 0
    private var retry: Task<Void, Never>?
    private static let searchAttempts = 600

    init(_ pane: PaneView, runtime: GhosttyRuntime) {
        super.init(runtime: runtime, radius: 12, separators: 2)
        self.pane = pane
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.init(rawValue: "AXLandmarkSearch"))
        setAccessibilityLabel("Find in Terminal")
        magnifier.contentTintColor = Chrome.inkSecondary
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderAttributedString = NSAttributedString(string: "Find in Terminal", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Chrome.inkSecondary])
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
        let text: NSColor = focused ? Chrome.ink : Chrome.inkSecondary
        if field.textColor != text { field.textColor = text }
    }

    private func showStatus() {
        let compact = bounds.width < 300
        let (text, navigable) = switch status {
        case .none: ("", false)
        case .found(let found): (found ? "Match" : "No matches", found)
        case .searching: ("Searching…", false)
        case .matches(0): (compact ? "0" : "No matches", false)
        case .matches(let total): (compact ? "\(total)" : "\(total) matches", true)
        case .at(let index, let total): (compact ? "\(index)/\(total)" : "\(index) of \(total)", true)
        }
        count.textColor = Chrome.inkSecondary
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
        let left = count.frame.minX - 2
        magnifier.frame = NSRect(x: 3, y: 3, width: 22, height: 26)
        let height = field.fittingSize.height
        field.frame = NSRect(x: 25, y: (bounds.height - height) / 2, width: max(0, left - 25), height: height)
        super.layout()
    }

    func controlTextDidChange(_ notification: Notification) { search() }

    func search(navigate: Bool = true) {
        autoNavigate = navigate
        if pane?.webviewView != nil { findInWebview(backwards: false) } else { restartGhostty() }
    }

    @objc func next() { move(1) }
    @objc func previous() { move(-1) }

    private func move(_ delta: Int) {
        if pane?.webviewView != nil { findInWebview(backwards: delta < 0); return }
        guard total > 0 else { return }
        if total == 1, let start, pane?.copyMode != nil { pane?.copyMove("", to: start); return }
        pane?.resetScroll()
        action(delta > 0 || selected == nil ? "navigate_search:next" : "navigate_search:previous")
    }

    // The page answers from its model while the bar keeps its last status; the count and the highlight appear together after the native find.
    private func findInWebview(backwards: Bool, attempt: Int = 0, mine: Int? = nil) {
        guard let webview = pane?.webviewView else { return }
        let query = field.stringValue
        guard !query.isEmpty else { retry?.cancel(); generation += 1; status = .none; return }
        if mine == nil { retry?.cancel(); generation += 1 }
        let request = mine ?? generation
        func current() -> Bool { generation == request && field.stringValue == query && pane?.webviewView === webview }
        webview.prepareFind(query, backwards: backwards) { [weak self] answer in
            guard let self, current() else { return }
            let found: Status
            switch answer {
            case .cancelled: return
            case .failed: status = .found(false); return
            case .answered(_, _, true):
                status = .searching
                guard attempt < Self.searchAttempts else { status = .found(false); return }
                retry = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    self?.findInWebview(backwards: backwards, attempt: attempt + 1, mine: request)
                }
                return
            case .answered(_, 0, false): status = .matches(0); return
            case .answered(let index, let count, false): found = .at(index, of: count)
            case .missing: found = .found(true)
            }
            webview.find(query, backwards: backwards) { [weak self] matched in
                guard let self, current() else { return }
                status = matched ? found : .found(false)
            }
        }
    }

    // Copy mode moves its cursor to a match and shows the count; outside it the selected match shows.
    private func showMatches() {
        status = field.stringValue.isEmpty ? .none : pane?.copyMode != nil ? .matches(total) : selected.map { .at($0 + 1, of: total) } ?? .matches(total)
    }

    func ghosttyTotal(_ total: Int) {
        self.total = max(0, total)
        showMatches()
        guard autoNavigate, total > 0, selected == nil, !navigating else { return }
        navigating = true
        pane?.resetScroll()
        action("navigate_search:next")
    }

    func ghosttySelected(_ selected: Int, start: (x: Int, y: Int)?) {
        self.selected = selected >= 0 ? selected : nil
        self.start = self.selected == nil ? nil : start
        navigating = false
        showMatches()
        if pane?.copyMode != nil, let start = self.start { pane?.copyMove("", to: start) }
    }

    private func restartGhostty() {
        selected = nil
        start = nil
        total = 0
        navigating = false
        showMatches()
        action("search:")
        if case .entering = pane?.copyMode { return }
        action("search:\(field.stringValue)")
    }

    #if KIDO_STRESS
    private var navigationCount = 0
    var stressState: (selected: Int?, total: Int, navigationCount: Int) { (selected, total, navigationCount) }
    #endif

    private func action(_ name: String) {
        guard let pane else { return }
        #if KIDO_STRESS
        if name.hasPrefix("navigate_search:") { navigationCount += 1 }
        #endif
        _ = ghostty_surface_binding_action(pane.surface, name, UInt(name.utf8.count))
    }

    @objc func close() {
        retry?.cancel()
        generation += 1
        pane?.webviewView?.cancelFind()
        action("end_search")
        if pane?.copyMode != nil, !field.stringValue.isEmpty { pane?.copyFind.query = field.stringValue }
        if (window?.firstResponder as? NSView)?.isDescendant(of: self) == true { window?.makeFirstResponder(pane?.inputResponder) }
        let pane = pane
        removeFromSuperview()
        pane?.find = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.insertNewline(_:)):
            if pane?.copyMode != nil { window?.makeFirstResponder(pane) }
            else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous() } else { next() }
        default: return false
        }
        return true
    }
}
