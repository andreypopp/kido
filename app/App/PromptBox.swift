import AppKit
import SidebarFeed
import TmuxControl

final class PromptPicker: NSPopUpButton {
    var label = NSAttributedString() { didSet { needsDisplay = true } }
    var showsChevron = true { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        focusRingType = .none
        cell?.lineBreakMode = .byTruncatingTail
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var fittingSize: NSSize {
        NSSize(width: ceil(label.size().width) + (showsChevron ? 30 : 16), height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = label.size()
        label.draw(at: NSPoint(x: showsChevron ? 9 : 14, y: (bounds.height - size.height) / 2 - 0.5))
        guard showsChevron else { return }
        let x = 9 + size.width + 5 + 2.25
        let y = bounds.midY - 0.25
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y - 1.125))
        path.line(to: NSPoint(x: x + 2.25, y: y + 1.125))
        path.line(to: NSPoint(x: x + 4.5, y: y - 1.125))
        path.lineWidth = 1.44
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
    }
}

final class PromptAction: NSButton {
    var invoke: () -> Void = {}

    init(_ title: String) {
        super.init(frame: .zero)
        self.title = title
        font = .systemFont(ofSize: 12)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        target = self
        action = #selector(run)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var fittingSize: NSSize {
        guard let font else { return NSSize(width: 36, height: 22) }
        return NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font]).width) + 18, height: 22)
    }

    @objc private func run() { invoke() }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            guard let font else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 0.5),
                                     withAttributes: attributes)
        }
    }
}

struct PromptAnchor {
    let selection: String?
    let rect: NSRect
}

final class PromptBox: PaneCapsule, NSTextViewDelegate {
    final class SendButton: NSButton {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            focusRingType = .none
            wantsLayer = true
            image = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { _ in
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 2.34, y: 8))
                path.line(to: NSPoint(x: 11.72, y: 8))
                path.move(to: NSPoint(x: 7.97, y: 3.78))
                path.line(to: NSPoint(x: 12.19, y: 8))
                path.line(to: NSPoint(x: 7.97, y: 12.22))
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                NSColor.black.setStroke()
                path.stroke()
                return true
            }
            image?.isTemplate = true
            imagePosition = .imageOnly
            imageScaling = .scaleNone
            contentTintColor = .white
            toolTip = "Send (Return)"
            setAccessibilityLabel("Send prompt")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var isEnabled: Bool {
            didSet {
                contentTintColor = isEnabled ? .white : .secondaryLabelColor
                needsDisplay = true
            }
        }
        override var acceptsFirstResponder: Bool { isEnabled }
        #if KIDO_VISUAL
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        #endif
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let fill = isEnabled ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.14)
                fill.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            }
            super.draw(dirtyRect)
        }
    }

    let paneID: PaneID
    let windowID: WindowID
    let session: SessionID
    let textView = NSTextView()
    let targetButton = PromptPicker()
    let status = NSTextField(labelWithString: "")
    let send = SendButton(frame: .zero)
    let retry = PromptAction("Retry")
    let copyPrompt = PromptAction("Copy Prompt")
    let quote = NSTextField(wrappingLabelWithString: "")
    weak var host: PromptBoxes?

    private let windowName: String
    private let selection: String?
    private let quoteLines: [String]
    private var quoteWidth: CGFloat = -1
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "")
    private let quoteBar = NSView()
    private let hint = NSTextField(labelWithString: "↩ send · ⇧↩ newline")
    let cancelButton = IconButton("xmark", "Cancel", size: 15, hoverStyle: .background)
    private var candidates: [PromptCandidate] = []
    private var target: PromptCandidate?
    private var textHeight: CGFloat = 18
    private let quoteHeight: CGFloat
    private var scrolls = false
    private let request: RPCRequestHandler
    private var drag: (start: NSPoint, origin: NSPoint)?
    private var sourceGone = false

    #if KIDO_VISUAL
    @MainActor static var linger: TimeInterval = 0.8
    #else
    static let linger: TimeInterval = 0.8
    #endif

    private enum State {
        case resolving, ready, noAgent, sending
        case delivered(String), refused(String), unknown(String), invalid(String), failed(String)
    }
    private var state = State.resolving

    init(anchor: PromptAnchor, pane: PaneID, windowID: WindowID, windowName: String, session: SessionID,
         runtime: GhosttyRuntime, request: @escaping RPCRequestHandler) {
        paneID = pane
        self.windowID = windowID
        self.windowName = windowName
        self.session = session
        self.request = request
        selection = anchor.selection
        var text = anchor.selection ?? ""
        if text.hasSuffix("\n") { text.removeLast() }
        quoteLines = anchor.selection == nil ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        quoteHeight = anchor.selection == nil ? 0 : CGFloat(max(1, min(quoteLines.count, 3))) * 15 + 8
        super.init(runtime: runtime, radius: 12, separators: 0)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowBlurRadius = 40
        self.shadow = shadow
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(selection == nil ? "Prompt" : "Prompt with selection")
        toolTip = selection

        targetButton.target = self
        targetButton.action = #selector(chooseTarget)
        targetButton.setAccessibilityLabel("Send to")

        cancelButton.invoke = { [weak self] in self?.cancel() }
        cancelButton.toolTip = "Cancel (Escape)"
        cancelButton.setAccessibilityLabel("Cancel")
        cancelButton.focusRingType = .none
        cancelButton.image = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4.25, y: 4.25))
            path.line(to: NSPoint(x: 11.75, y: 11.75))
            path.move(to: NSPoint(x: 11.75, y: 4.25))
            path.line(to: NSPoint(x: 4.25, y: 11.75))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        cancelButton.image?.isTemplate = true
        cancelButton.imageScaling = .scaleNone

        textView.delegate = self
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 2, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        paragraph.lineBreakMode = .byClipping
        textView.defaultParagraphStyle = paragraph
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Prompt")

        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = textView
        scroll.setAccessibilityElement(false)

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.attributedStringValue = NSAttributedString(string: selection == nil ? "Ask the agent" : "Ask about the selection",
                                                               attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                            .foregroundColor: NSColor.secondaryLabelColor])

        quote.maximumNumberOfLines = 3
        quote.lineBreakMode = .byClipping
        quote.cell?.wraps = false
        quote.textColor = .secondaryLabelColor
        quote.setAccessibilityLabel("Selected text, \(quoteLines.count) lines")
        quote.toolTip = selection
        quote.isHidden = selection == nil
        quote.attributedStringValue = quoteString(width: 528)
        quoteBar.isHidden = selection == nil
        quoteBar.wantsLayer = true

        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11)
        let hintParagraph = NSMutableParagraphStyle()
        hintParagraph.alignment = .right
        hint.attributedStringValue = NSAttributedString(string: "↩ send · ⇧↩ newline",
                                                        attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                     .foregroundColor: NSColor.secondaryLabelColor,
                                                                     .paragraphStyle: hintParagraph])
        hint.alignment = .right

        send.target = self
        send.action = #selector(sendComposed)
        retry.invoke = { [weak self] in self?.retryAction() }
        copyPrompt.invoke = { [weak self] in self?.copyComposed() }
        for view in [targetButton, cancelButton, scroll, placeholder, quote, quoteBar, status, hint, send, retry, copyPrompt] {
            addSubview(view)
        }
        _ = updateTextHeight()
        apply(.resolving)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var focused: Bool { textView.isEditable && window?.firstResponder === textView }

    #if KIDO_VISUAL
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    #endif

    private var hasPrompt: Bool { !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    override func removeFromSuperview() {
        endDrag()
        super.removeFromSuperview()
    }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            quoteBar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        }
    }

    private func targetTitle(_ candidate: PromptCandidate) -> String {
        if sourceGone, candidate.window == windowID {
            return "Prompt @\(candidate.title) in window \(windowName) (pane closed)"
        }
        if candidate.window == windowID { return "Prompt @\(candidate.title) in this window" }
        return "Prompt @\(candidate.title) in window \(host?.session?.windowName(candidate.window) ?? candidate.window.description)"
    }

    func resolve() {
        request(.prompt(pane: paneID, text: nil, target: nil)) { [weak self] result in
            guard let self, host?.contains(self) == true else { return }
            guard case .success(.prompt(.candidates(let list))) = result else {
                if case .success(.prompt) = result { return apply(.failed("Unexpected prompt reply")) }
                return apply(failureState(result, sending: false) ?? .failed("Unexpected prompt reply"))
            }
            candidates = list
            target = list.first { $0.window == windowID } ?? list.first
            updateTargets()
            apply(list.isEmpty ? .noAgent : .ready)
        }
    }

    func sourceChanged(gone: Bool) {
        guard gone != sourceGone else { return }
        sourceGone = gone
        updateTargets()
        if case .ready = state { apply(.ready) }
    }

    private func updateTargets() {
        targetButton.removeAllItems()
        for candidate in candidates { targetButton.addItem(withTitle: targetTitle(candidate)) }
        guard let target, let index = candidates.firstIndex(of: target) else { return }
        targetButton.selectItem(at: index)
        targetButton.setAccessibilityLabel("Send to @\(target.title)")
        updatePicker()
        needsLayout = true
    }

    private func failureState(_ result: Result<RPCEvent.Reply.Value, Failure>, sending: Bool) -> State? {
        switch result {
        case .success(.promptError(let message, let kind)):
            guard sending else { return .failed(message) }
            return kind == .refused ? .refused(message) : kind == .unknown ? .unknown(message) : .invalid(message)
        case .failure(let error):
            guard sending else { return .failed(error.message) }
            return error.message == Feed.notReady ? .invalid(error.message) : .unknown(error.message)
        default:
            return nil
        }
    }

    private func setField(editable: Bool, muted: Bool) {
        textView.isEditable = editable
        textView.isSelectable = editable
        textView.textColor = muted ? .secondaryLabelColor : .labelColor
    }

    private func updatePicker() {
        let regular = NSFont.systemFont(ofSize: 12)
        let semibold = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let muted: [NSAttributedString.Key: Any] = [.font: regular, .foregroundColor: NSColor.secondaryLabelColor]
        let name: [NSAttributedString.Key: Any] = [.font: semibold, .foregroundColor: NSColor.labelColor]
        let label = NSMutableAttributedString()
        func add(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            label.append(NSAttributedString(string: text, attributes: attributes))
        }
        func gap(_ attributes: [NSAttributedString.Key: Any]) {
            let space = NSMutableAttributedString(string: " ", attributes: attributes)
            let width = (" " as NSString).size(withAttributes: attributes).width
            space.addAttribute(.kern, value: 5 - width, range: NSRange(location: 0, length: 1))
            label.append(space)
        }
        var chevron = true
        switch state {
        case .resolving:
            add("Resolving…", muted)
            chevron = false
        case .noAgent:
            add("No agent in this window or session", muted)
            chevron = false
        case .failed:
            add("Prompt unavailable", muted)
            chevron = false
        default:
            guard let target else {
                add("Prompt unavailable", muted)
                chevron = false
                break
            }
            add("Prompt", muted)
            gap(muted)
            add("@\(target.title)", name)
            gap(muted)
            if sourceGone, target.window == windowID {
                add("in window \(windowName) (pane closed)", muted)
            } else if target.window == windowID {
                add("in this window", muted)
            } else {
                add("in window \(host?.session?.windowName(target.window) ?? target.window.description)", muted)
            }
        }
        targetButton.label = label
        targetButton.showsChevron = chevron
    }

    private func setStatus(_ text: String, color: NSColor) {
        status.attributedStringValue = NSAttributedString(string: text,
                                                          attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                       .foregroundColor: color])
    }

    private func apply(_ state: State) {
        self.state = state
        status.stringValue = ""
        status.textColor = .secondaryLabelColor
        status.isHidden = true
        spinner.isHidden = true
        retry.isHidden = true
        copyPrompt.isHidden = true
        send.isHidden = false
        send.isEnabled = false
        targetButton.isEnabled = false
        setField(editable: false, muted: true)
        hint.isHidden = true
        switch state {
        case .resolving:
            targetButton.removeAllItems()
            targetButton.addItem(withTitle: "Resolving…")
        case .ready:
            targetButton.isEnabled = true
            setField(editable: true, muted: false)
            send.isEnabled = hasPrompt
            if sourceGone {
                setStatus("Source pane closed; agents resolved earlier stay available.", color: .secondaryLabelColor)
                status.isHidden = false
            } else {
                hint.isHidden = false
            }
        case .noAgent:
            targetButton.removeAllItems()
            targetButton.addItem(withTitle: "No agent in this window or session")
        case .sending:
            setStatus("Sending to @\(target?.title ?? "agent")…", color: .secondaryLabelColor)
            status.isHidden = false
            spinner.isHidden = false
        case .delivered(let name):
            setStatus("Sent to \(name)", color: .systemGreen)
            status.isHidden = false
            send.isHidden = true
        case .refused(let message):
            setStatus(message, color: .systemRed)
            status.isHidden = false
            retry.isHidden = false
            setField(editable: true, muted: false)
        case .unknown(let message):
            setStatus("\(message) It may have arrived; not resent.", color: .systemRed)
            status.isHidden = false
            copyPrompt.isHidden = false
            send.isHidden = true
            setField(editable: false, muted: false)
        case .invalid(let message):
            setStatus(message, color: .systemRed)
            status.isHidden = false
            targetButton.isEnabled = true
            setField(editable: true, muted: false)
        case .failed(let message):
            setStatus(message, color: .systemRed)
            status.isHidden = false
            targetButton.removeAllItems()
            targetButton.addItem(withTitle: "Prompt unavailable")
            retry.isHidden = false
        }
        updatePicker()
        needsLayout = true
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        switch state {
        case .refused, .invalid: apply(.ready)
        case .ready: send.isEnabled = hasPrompt
        default: break
        }
        if updateTextHeight() { host?.sizeChanged(self) }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            cancel()
        case #selector(NSResponder.insertNewline(_:)):
            newline(shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        case #selector(NSResponder.insertTab(_:)):
            moveFocus(forward: true)
        case #selector(NSResponder.insertBacktab(_:)):
            moveFocus(forward: false)
        default: return false
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { cancel() }

    func newline(shift: Bool) {
        if shift { textView.insertNewlineIgnoringFieldEditor(nil) } else { sendComposed() }
    }

    @objc func chooseTarget() {
        let index = targetButton.indexOfSelectedItem
        guard candidates.indices.contains(index) else { return }
        target = candidates[index]
        targetButton.setAccessibilityLabel("Send to @\(target!.title)")
        updatePicker()
        needsLayout = true
        if case .invalid = state { apply(.ready) }
    }

    private func moveFocus(forward: Bool) {
        let order = [textView, targetButton, cancelButton, send].filter { view in
            guard !view.isHidden else { return false }
            if let control = view as? NSControl { return control.isEnabled }
            return true
        }
        guard !order.isEmpty else { return }
        let index = order.firstIndex { $0 === window?.firstResponder }
        let next = switch (index, forward) {
        case (nil, true): 0
        case (nil, false): order.count - 1
        case (let index?, true): (index + 1) % order.count
        case (let index?, false): (index + order.count - 1) % order.count
        }
        window?.makeFirstResponder(order[next])
    }

    private func retryAction() {
        if case .failed = state { resolve() } else { sendComposed() }
    }

    @objc func sendComposed() {
        guard let target, hasPrompt else { return }
        switch state {
        case .ready, .refused: break
        default: return
        }
        apply(.sending)
        let source = sourceGone ? target.pane : paneID
        request(.prompt(pane: source, text: composed, target: target.pane)) { [weak self] result in
            guard let self, host?.contains(self) == true else { return }
            if case .success(.prompt(.delivered(let delivered))) = result {
                let name = candidates.first { $0.pane == delivered.pane }?.title ?? delivered.pane.description
                apply(.delivered(name))
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger) { [weak self] in
                    guard let self, host?.contains(self) == true else { return }
                    host?.finish(self, delivered: true)
                }
                return
            }
            apply(failureState(result, sending: true) ?? .invalid("Unexpected prompt reply"))
        }
    }

    private var composed: String {
        guard let selection else { return textView.string }
        return RPCRequest.composePrompt(prompt: textView.string, selection: selection)
    }

    private func copyComposed() {
        let board = runtime.pasteboard
        board.clearContents()
        board.setString(composed, forType: .string)
    }

    func cancel() { host?.finish(self, delivered: false) }

    private func updateTextHeight() -> Bool {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return false }
        layout.ensureLayout(for: container)
        let line: CGFloat = 18
        let used = layout.usedRect(for: container).height
        let height = CGFloat(min(5, max(1, Int(ceil(used / line - 0.001))))) * line
        let overflow = used > height + 0.5
        guard height != textHeight || overflow != scrolls else { return false }
        textHeight = height
        scrolls = overflow
        return true
    }

    var preferredHeight: CGFloat { textHeight + (selection == nil ? 72 : 76 + quoteHeight) }

    private func quoteString(width: CGFloat) -> NSAttributedString {
        guard selection != nil else { return NSAttributedString() }
        let full = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let italic = NSFontManager.shared.convert(.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 15
        paragraph.maximumLineHeight = 15
        paragraph.lineBreakMode = .byClipping
        let rows: [(String, NSFont)] = quoteLines.count <= 3
            ? quoteLines.map { ($0, full) }
            : [(quoteLines[0], full), ("⋯ \(quoteLines.count - 2) lines", italic), (quoteLines[quoteLines.count - 1], full)]
        let result = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph])) }
            result.append(NSAttributedString(string: truncated(row.0, font: row.1, width: width),
                                             attributes: [.font: row.1, .foregroundColor: NSColor.secondaryLabelColor,
                                                          .paragraphStyle: paragraph]))
        }
        return result
    }

    private func truncated(_ text: String, font: NSFont, width: CGFloat) -> String {
        let attributes = [NSAttributedString.Key.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= width { return text }
        var low = 0, high = text.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(text.prefix(middle)) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width { low = middle } else { high = middle - 1 }
        }
        return String(text.prefix(low)) + "…"
    }

    private var sendX: CGFloat { bounds.width - 29 }
    private var quoteTop: CGFloat { 37 + textHeight + 4 }

    private var quoteBlock: CGRect {
        CGRect(x: 11, y: bounds.height - quoteTop - quoteHeight, width: max(0, bounds.width - 22), height: quoteHeight)
    }

    private var arrowRegions: [CGRect] {
        var rects = quoteHeight > 0 ? [quoteBlock] : []
        if !status.isHidden { rects.append(status.frame) }
        if !spinner.isHidden { rects.append(spinner.frame) }
        return rects
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let quoteWidth = max(0, width - 32)
        if quoteWidth != self.quoteWidth {
            self.quoteWidth = quoteWidth
            quote.attributedStringValue = quoteString(width: quoteWidth)
        }
        let targetMax = max(0, sendX - 6)
        targetButton.frame = NSRect(x: 3, y: height - 32, width: min(targetMax, targetButton.fittingSize.width), height: 26)
        cancelButton.frame = NSRect(x: sendX, y: height - 32, width: 26, height: 26)
        scroll.frame = NSRect(x: 11, y: height - 37 - textHeight - 0.5, width: max(0, width - 22), height: textHeight)
        textView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: textHeight)
        textView.textContainer?.containerSize = NSSize(width: max(0, scroll.contentSize.width - 4), height: .greatestFiniteMagnitude)
        placeholder.frame = NSRect(x: 11, y: height - 38 - textHeight, width: max(0, width - 22), height: textHeight)
        scroll.hasVerticalScroller = scrolls

        quoteBar.frame = NSRect(x: 11, y: height - quoteTop - quoteHeight, width: 2, height: quoteHeight)
        quote.frame = NSRect(x: 21, y: height - quoteTop - quoteHeight + 5, width: quoteWidth, height: max(0, quoteHeight - 8))

        send.frame = NSRect(x: sendX, y: 6, width: 26, height: 26)
        if !hint.isHidden {
            hint.frame = NSRect(x: 11, y: 12.5, width: max(0, sendX - 8 - 11), height: 13)
        }
        spinner.frame = CGRect(x: 11, y: 14, width: 11, height: 11)
        if !status.isHidden {
            switch state {
            case .sending:
                status.frame = NSRect(x: 26, y: 13, width: min(status.fittingSize.width, width - 29), height: 13)
            case .refused, .unknown:
                status.frame = NSRect(x: 9, y: 13, width: min(status.fittingSize.width + 2, width - 18), height: 13)
            default:
                status.frame = NSRect(x: 9, y: 13, width: min(status.fittingSize.width + 2, width - 18), height: 13)
            }
        }
        let actionY: CGFloat = 8
        if !retry.isHidden {
            retry.frame = NSRect(x: status.frame.maxX + 8, y: actionY, width: retry.fittingSize.width, height: 22)
            if retry.frame.maxX > width - 3 {
                status.frame.size.width = max(0, width - 9 - 8 - retry.frame.width - 11)
                retry.frame.origin.x = status.frame.maxX + 8
            }
        }
        if !copyPrompt.isHidden {
            copyPrompt.frame = NSRect(x: status.frame.maxX + 8, y: actionY, width: copyPrompt.fittingSize.width, height: 22)
            if copyPrompt.frame.maxX > width - 3 {
                status.frame.size.width = max(0, width - 9 - 8 - copyPrompt.frame.width - 11)
                copyPrompt.frame.origin.x = status.frame.maxX + 8
            }
        }
        window?.invalidateCursorRects(for: self)
    }

    var promptCursorRects: [(CGRect, NSCursor)] {
        let visible = controls.filter { !$0.isHidden }
        let arrows = arrowRegions
        var rects = bounds.subtracting(visible.map(\.frame) + arrows).map { ($0, NSCursor.openHand) }
        for control in visible {
            rects.append((control.frame, control === scroll ? NSCursor.iBeam : NSCursor.arrow))
        }
        for rect in arrows { rects.append((rect, NSCursor.arrow)) }
        return rects
    }

    override func resetCursorRects() {
        for (rect, cursor) in promptCursorRects { addCursorRect(rect, cursor: cursor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        guard let hit = super.hitTest(point) else { return nil }
        if hit === placeholder { return textView }
        if controls.contains(where: { hit === $0 || hit.isDescendant(of: $0) }) { return hit }
        let local = superview.map { convert(point, from: $0) } ?? point
        if let control = controls.last(where: { !$0.isHidden && $0.frame.contains(local) }) { return control }
        if arrowRegions.contains(where: { $0.contains(local) }) { return self }
        return self
    }

    private var controls: [NSView] { [targetButton, cancelButton, scroll, send, retry, copyPrompt] }

    func raiseAndFocus() {
        host?.raise(self)
        window?.makeFirstResponder(textView)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if controls.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return }
        if arrowRegions.contains(where: { $0.contains(point) }) { return }
        raiseAndFocus()
        drag = (superview?.convert(event.locationInWindow, from: nil) ?? .zero, frame.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let point = superview?.convert(event.locationInWindow, from: nil) else { return }
        host?.move(self, to: NSPoint(x: drag.origin.x + point.x - drag.start.x, y: drag.origin.y + point.y - drag.start.y))
    }

    override func mouseUp(with event: NSEvent) { endDrag() }

    private func endDrag() {
        guard drag != nil else { return }
        drag = nil
        NSCursor.pop()
    }
}

final class PromptBoxes: NSView {
    weak var session: SessionView?
    var request: RPCRequestHandler = Feed.unavailable
    private(set) var boxes: [PromptBox] = []
    private var shownSession: SessionID?

    init() {
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func update(session: SessionID, live: Set<SessionID>, panes: Set<PaneID>) {
        boxes.removeAll { box in
            guard !live.contains(box.session) else { return false }
            box.removeFromSuperview()
            return true
        }
        layoutChanged(session: session, panes: panes)
    }

    func layoutChanged(session: SessionID, panes: Set<PaneID>) {
        for box in boxes where box.session == session {
            box.sourceChanged(gone: !panes.contains(box.paneID))
        }
    }

    func show(_ session: SessionID?) {
        shownSession = session
        for box in boxes {
            box.isHidden = box.session != session
            box.window?.invalidateCursorRects(for: box)
        }
        guard let responder = window?.firstResponder as? NSView,
              boxes.contains(where: { $0.isHidden && ($0 === responder || responder.isDescendant(of: $0)) })
        else { return }
        window?.makeFirstResponder(nil)
    }

    func open(_ pane: PaneView, _ anchor: PromptAnchor) {
        guard let sessionID = shownSession, let windowID = pane.windowID, let runtime = session?.runtime else { return }
        let box = PromptBox(anchor: anchor, pane: pane.pane, windowID: windowID, windowName: session?.windowName(windowID) ?? "",
                            session: sessionID, runtime: runtime, request: request)
        box.host = self
        let rect = convert(anchor.rect, from: pane)
        let width = min(560, max(0, bounds.width - 16))
        let height = box.preferredHeight
        var frame = CGRect(x: rect.minX, y: rect.maxY + 6, width: width, height: height)
        if frame.maxY > bounds.height - 8 {
            frame.origin.y = rect.minY - 6 - height
            if frame.minY < 8 { frame.origin.y = bounds.height - 8 - height }
        }
        frame = clamped(frame)
        for _ in 0..<1000 {
            guard boxes.contains(where: { !$0.isHidden && abs($0.frame.minX - frame.minX) <= 4 && abs($0.frame.minY - frame.minY) <= 4 }) else { break }
            let next = clamped(CGRect(origin: CGPoint(x: frame.minX + 16, y: frame.minY + 16), size: frame.size))
            guard next != frame else { break }
            frame = next
        }
        box.frame = frame
        boxes.append(box)
        addSubview(box)
        box.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(box.textView)
        box.resolve()
    }

    func contains(_ box: PromptBox) -> Bool { boxes.contains { $0 === box } }

    func raise(_ box: PromptBox) {
        guard subviews.last !== box else { return }
        addSubview(box, positioned: .above, relativeTo: nil)
        box.window?.invalidateCursorRects(for: box)
    }

    func move(_ box: PromptBox, to origin: NSPoint) {
        box.frame = clamped(CGRect(origin: origin, size: box.frame.size))
        box.window?.invalidateCursorRects(for: box)
    }

    func sizeChanged(_ box: PromptBox) {
        box.frame.size.height = box.preferredHeight
        box.frame = clamped(box.frame)
        box.needsLayout = true
        box.window?.invalidateCursorRects(for: box)
    }

    func finish(_ box: PromptBox, delivered: Bool) {
        guard let index = boxes.firstIndex(where: { $0 === box }) else { return }
        let responder = window?.firstResponder as? NSView
        let held = responder.map { $0 === box || $0.isDescendant(of: box) } ?? false
        boxes.remove(at: index)
        box.removeFromSuperview()
        guard held else { return }
        if delivered, let source = session?.pane(box.paneID) {
            source.promptDelivered()
            if !source.isHiddenOrHasHiddenAncestor {
                source.window?.makeFirstResponder(source)
                return
            }
        } else if !delivered, let source = session?.pane(box.paneID), !source.isHiddenOrHasHiddenAncestor {
            source.onSelect()
            source.window?.makeFirstResponder(source)
            return
        }
        session?.focusActive()
    }

    func closeAll() {
        boxes.forEach { $0.removeFromSuperview() }
        boxes = []
    }

    override func layout() {
        super.layout()
        for box in boxes { box.frame = clamped(box.frame) }
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        var frame = frame
        frame.size.width = min(frame.width, max(0, bounds.width - 16))
        frame.size.height = min(frame.height, max(0, bounds.height - 16))
        frame.origin.x = min(max(8, frame.minX), max(8, bounds.width - 8 - frame.width))
        frame.origin.y = min(max(8, frame.minY), max(8, bounds.height - 8 - frame.height))
        return frame
    }
}
