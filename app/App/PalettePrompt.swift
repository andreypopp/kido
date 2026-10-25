import AppKit
import SidebarFeed
import TmuxControl
import PromptMarkdown

struct PromptSource: Equatable {
    let owner: WindowOwner
    let instance: ServerInstance
    let session: SessionID
    let window: WindowID
    let pane: PaneID
    let windowName: String
    var quote: String?
    var preselect: PaneID?
    @MainActor var current: Bool { Self.current(in: owner)(instance) }
    @MainActor var paneExists: Bool { Self.paneExists(in: owner, session: session)(pane) }
    @MainActor var valid: Bool { current && paneExists }

    @MainActor static func current(in owner: WindowOwner) -> (ServerInstance) -> Bool {
        let instance = owner.snapshot?.serverInstance
        return { owner.alive && $0 == instance }
    }

    @MainActor static func paneExists(in owner: WindowOwner, session: SessionID? = nil) -> (PaneID) -> Bool {
        let panes = Set(owner.snapshot?.promptPanes.filter { session == nil || $0.session == session }.map(\.pane) ?? [])
        return { panes.contains($0) }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.owner === b.owner && a.instance == b.instance && a.pane == b.pane
    }
}

struct PromptDraft {
    struct Key: Hashable {
        let host: Host
        let instance: ServerInstance
        let pane: PaneID
    }
    var text: String
}

final class PalettePrompt: NSView, NSTextViewDelegate {
    enum State {
        case ready, noAgent, sending
        case refused(String), unknown(String), invalid(String), failed(String)
    }
    let source: PromptSource
    final class Field: NSTextView {
        var rendering = PromptMarkdown.render("")
        convenience init() {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 568, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            self.init(frame: .zero, textContainer: container)
        }
        override func draw(_ dirtyRect: NSRect) {
            if let layout = layoutManager, let container = textContainer {
                let glyphs = layout.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: container)
                NSColor.labelColor.withAlphaComponent(NSColor.labelColor.alphaComponent * 0.08).setFill()
                for rect in codeFillRects(ranges: rendering.codeRanges, layoutManager: layout, textContainer: container, glyphRange: glyphs, origin: textContainerOrigin) {
                    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                }
                NSColor.secondaryLabelColor.withAlphaComponent(NSColor.secondaryLabelColor.alphaComponent * 0.45).setFill()
                for rect in quoteBarRects(lines: rendering.quoteLines, layoutManager: layout, glyphRange: glyphs, origin: textContainerOrigin) { rect.fill() }
            }
            super.draw(dirtyRect)
        }
        var committed: () -> Void = {}
        override func unmarkText() { super.unmarkText(); committed() }
        var shift = false
        override func keyDown(with event: NSEvent) {
            shift = event.modifierFlags.contains(.shift)
            defer { shift = false }
            super.keyDown(with: event)
        }
    }

    let textView = Field()
    let scroll = NSScrollView()
    let targetButton = Picker()
    let status = Label(labelWithString: "")
    let send = SendButton(frame: .zero)
    let retry = NSButton(title: "Retry", target: nil, action: nil)
    let copyPrompt = NSButton(title: "Copy Prompt", target: nil, action: nil)
    private let hint = Label(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let warning = NSImageView()
    private let fieldRule = NSBox()
    private let footRule = NSBox()
    private(set) var candidates: [PromptCandidate] = []
    private(set) var target: PromptCandidate?
    private(set) var state = State.noAgent
    private(set) var sourceGone = false
    private let editingUndoManager = UndoManager()
    private var restored = false
    private var textHeight = lineHeight
    private let runtime: GhosttyRuntime
    var active: () -> Bool = { false }
    var dismiss: () -> Void = {}
    var delivered: () -> Void = {}
    var load: (PromptDraft.Key) -> PromptDraft? = { _ in nil }
    var save: (PromptDraft.Key, PromptDraft?) -> Void = { _, _ in }
    var resized: () -> Void = {}
    var resolved: () -> Void = {}
    #if KIDO_VISUAL
    static var resolveTimeout: TimeInterval = 5
    #else
    static let resolveTimeout: TimeInterval = 5
    #endif
    private var resolving: UUID?
    private var resolveTimer: DispatchWorkItem?

    var key: PromptDraft.Key? { target.map { PromptDraft.Key(host: source.owner.host, instance: source.instance, pane: $0.pane) } }
    private var statusHeight: CGFloat { status.isHidden ? 0 : 30 }
    var preferredHeight: CGFloat { 21 + textHeight + 1 + statusHeight + 40 }
    private var hasPrompt: Bool { !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(source: PromptSource, runtime: GhosttyRuntime) {
        self.source = source
        self.runtime = runtime
        super.init(frame: .zero)
        textView.delegate = self
        textView.committed = { [weak self] in self?.styleText() }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.typingAttributes = baseAttributes
        textView.defaultParagraphStyle = baseAttributes[.paragraphStyle] as? NSParagraphStyle
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 568, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        warning.contentTintColor = .systemRed
        for rule in [fieldRule, footRule] { rule.boxType = .separator }
        send.target = self
        send.action = #selector(sendComposed)
        send.nextKeyView = textView
        send.back = { [weak self] in guard let self else { return }; window?.makeFirstResponder(targetButton.isEnabled ? targetButton : textView) }
        for button in [retry, copyPrompt] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .controlAccentColor
            button.target = self
            button.setAccessibilityLabel(button.title)
        }
        retry.action = #selector(retryAction)
        copyPrompt.action = #selector(copyComposed)
        targetButton.choose = { [weak self] in self?.chooseTarget($0); self?.window?.makeFirstResponder(self?.textView) }
        targetButton.cycle = { [weak self] delta in
            guard let self, let target, let index = candidates.firstIndex(of: target), !candidates.isEmpty else { return }
            chooseTarget((index + delta + candidates.count) % candidates.count)
        }
        targetButton.back = { [weak self] in self?.window?.makeFirstResponder(self?.textView) }
        targetButton.forward = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(send.isEnabled ? send : textView)
        }
        targetButton.close = { [weak self] in self?.dismiss() }
        for view in [scroll, status, hint, spinner, warning, send, retry, copyPrompt, fieldRule, footRule] { addSubview(view) }
        apply(.noAgent)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func storeDraft() {
        guard let key else { return }
        save(key, hasPrompt ? PromptDraft(text: textView.string) : nil)
    }

    private func restoreTarget(_ draft: PromptDraft?, carry: Bool = false, selection: String? = nil) {
        editingUndoManager.removeAllActions()
        if let draft {
            textView.string = draft.text
        } else if !carry {
            textView.string = ""
        }
        restored = draft != nil
        var caret = textView.string.utf16.count
        if let selection {
            let appended = appendQuote(to: textView.string, selection: selection)
            textView.string = appended.text
            caret = appended.caret
        }
        styleText()
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    func resolve() {
        guard resolving == nil else { return }
        let id = UUID()
        resolving = id
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, resolving == id else { return }
            resolving = nil
            apply(.failed("kido did not reply"))
            resolved()
        }
        resolveTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resolveTimeout, execute: timeout)
        source.owner.request(.prompt(pane: source.pane, text: nil, target: nil)) { [weak self] result in
            guard let self, resolving == id else { return }
            resolving = nil
            resolveTimer?.cancel()
            if case .success(.prompt(.candidates(let list))) = result {
                candidates = list
                target = list.first { $0.pane == source.preselect } ?? list.first { $0.pane == source.pane } ?? list.first { $0.window == source.window } ?? list.first
                restoreTarget(key.flatMap(load), selection: source.quote)
                apply(list.isEmpty ? .noAgent : .ready)
            } else {
                apply(failureState(result, sending: false) ?? .failed("Unexpected prompt reply"))
            }
            resolved()
        }
    }

    func sourceChanged(gone: Bool) {
        guard gone != sourceGone else { return }
        sourceGone = gone
        apply(state)
    }

    private func failureState(_ result: Result<RPCEvent.Reply.Value, Failure>, sending: Bool) -> State? {
        switch result {
        case .success(.promptError(let message, let kind)):
            guard sending else { return .failed(message) }
            return kind == .refused ? .refused(message) : kind == .unknown ? .unknown(message) : .invalid(message)
        case .failure(let error):
            guard sending else { return .failed(error.message) }
            return error.message == Feed.notReady ? .invalid(error.message) : .unknown(error.message)
        default: return nil
        }
    }

    private func place(_ candidate: PromptCandidate) -> String {
        candidate.window == source.window ? (sourceGone ? "window \(source.windowName) (pane closed)" : "this window") : "window \(source.owner.windowName(candidate.window))"
    }

    private func updatePicker() {
        let title: String
        switch state {
        case .noAgent: title = "No agent in this window or session"
        case .failed: title = "Prompt unavailable"
        default: title = target.map { "Prompt @\($0.title) in \(place($0))" } ?? "Prompt unavailable"
        }
        let label = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        if title.hasPrefix("Prompt @") { label.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: 6)) }
        if let target, let range = title.range(of: "@\(target.title)") {
            let nameRange = NSRange(range, in: title)
            label.addAttributes([.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor], range: nameRange)
            label.addAttribute(.kern, value: 2, range: NSRange(location: nameRange.location - 1, length: 1))
            label.addAttribute(.kern, value: 2, range: NSRange(location: NSMaxRange(nameRange), length: 1))
        }
        targetButton.label = label
        switch state { case .noAgent, .failed: targetButton.showsChevron = false; default: targetButton.showsChevron = true }
        targetButton.setAccessibilityLabel(target.map { "Send to @\($0.title)" } ?? title)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sessionName = source.owner.snapshot?.sessions.first { $0.id == source.session }?.name ?? source.session.description
        for (heading, list) in [("This window", candidates.enumerated().filter { $0.element.window == source.window }), ("Session \(sessionName)", candidates.enumerated().filter { $0.element.window != source.window })] {
            let header = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if list.isEmpty {
                let none = NSMenuItem(title: "No agents", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for (index, candidate) in list {
                let item = NSMenuItem(title: "@\(candidate.title)  \(place(candidate))", action: #selector(Picker.pick(_:)), keyEquivalent: "")
                item.tag = index
                item.target = targetButton
                item.state = candidate == target ? .on : .off
                menu.addItem(item)
            }
        }
        targetButton.menu = menu
        targetButton.needsDisplay = true
    }

    private func apply(_ state: State) {
        let pickerFocused = window?.firstResponder === targetButton
        defer { if pickerFocused && targetButton.isEnabled { window?.makeFirstResponder(targetButton) } }
        self.state = state
        status.stringValue = ""
        status.isHidden = true
        warning.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        retry.isHidden = true
        copyPrompt.isHidden = true
        send.isHidden = false
        send.isEnabled = false
        targetButton.isEnabled = false
        textView.isEditable = false
        textView.textColor = .secondaryLabelColor
        status.textColor = .secondaryLabelColor
        switch state {
        case .noAgent: break
        case .ready:
            targetButton.isEnabled = true
            textView.isEditable = true
            textView.textColor = .labelColor
            send.isEnabled = hasPrompt
            if sourceGone { status.stringValue = "Source pane closed; agents resolved earlier stay available." }
        case .sending:
            textView.textColor = .labelColor
            status.stringValue = "Sending to @\(target?.title ?? "agent")…"
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .refused(let message):
            status.stringValue = message
            retry.isHidden = false
            textView.isEditable = true
            textView.textColor = .labelColor
            send.isEnabled = hasPrompt
            warning.isHidden = false
        case .unknown(let message):
            status.stringValue = message + " It may have arrived; not resent."
            copyPrompt.isHidden = false
            send.isHidden = true
            warning.isHidden = false
            storeDraft()
        case .invalid(let message):
            status.stringValue = message
            targetButton.isEnabled = true
            textView.isEditable = true
            textView.textColor = .labelColor
            warning.isHidden = false
        case .failed(let message):
            status.stringValue = message
            retry.isHidden = false
            warning.isHidden = false
        }
        styleText()
        if !warning.isHidden { status.textColor = .systemRed }
        status.isHidden = status.stringValue.isEmpty
        if !status.isHidden {
            NSAccessibility.post(element: status, notification: .announcementRequested, userInfo: [.announcement: status.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        updatePicker()
        updateContent()
        _ = measureText()
        resized()
    }

    func chooseTarget(_ index: Int) {
        guard targetButton.isEnabled, candidates.indices.contains(index), candidates[index] != target else { return }
        let previous = key
        storeDraft()
        target = candidates[index]
        let draft = key.flatMap(load)
        if draft == nil, let previous { save(previous, nil) }
        restoreTarget(draft, carry: true)
        apply(.ready)
    }

    @objc func sendComposed() {
        guard let target, hasPrompt else { return }
        switch state { case .ready, .refused: break; default: return }
        apply(.sending)
        source.owner.request(.prompt(pane: sourceGone ? target.pane : source.pane, text: textView.string, target: target.pane)) { [weak self] result in
            guard let self, active() else { return }
            if case .success(.prompt(.delivered)) = result {
                if let key { save(key, nil) }
                textView.string = ""
                delivered()
            } else { apply(failureState(result, sending: true) ?? .invalid("Unexpected prompt reply")) }
        }
    }
    @objc private func retryAction() {
        if case .failed = state { resolve() } else { sendComposed() }
    }
    @objc func copyComposed() {
        runtime.pasteboard.clearContents()
        runtime.pasteboard.setString(textView.string, forType: .string)
    }

    func textDidChange(_ notification: Notification) {
        styleText()
        switch state {
        case .refused, .invalid: apply(.ready)
        default: if measureText() { resized() }
        }
        if case .ready = state { send.isEnabled = hasPrompt }
    }
    private func updateContent() {
        textView.setAccessibilityLabel("Prompt")
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let hintText = NSMutableAttributedString()
        for part in ["↩ send", "⇧↩ new line", "⇥ agent", "esc close, keeps draft"] + (restored ? ["· draft restored"] : []) {
            if hintText.length > 0 {
                let gap = NSMutableAttributedString(string: " ", attributes: hintAttributes)
                gap.addAttribute(.kern, value: 14 - (" " as NSString).size(withAttributes: hintAttributes).width, range: NSRange(location: 0, length: 1))
                hintText.append(gap)
            }
            hintText.append(NSAttributedString(string: part, attributes: hintAttributes))
        }
        hint.attributedStringValue = hintText
    }

    private func styleText() {
        guard let storage = textView.textStorage else { return }
        let marked = textView.hasMarkedText() ? textView.markedRange() : NSRange(location: NSNotFound, length: 0)
        let rendering = PromptMarkdown.render(textView.string)
        let registration = editingUndoManager.isUndoRegistrationEnabled
        if registration { editingUndoManager.disableUndoRegistration() }
        storage.beginEditing()
        rendering.text.enumerateAttributes(in: NSRange(location: 0, length: rendering.text.length)) { attributes, range, _ in
            var desired = attributes
            if case .unknown = state { desired[.foregroundColor] = NSColor.secondaryLabelColor }
            storage.enumerateAttributes(in: range) { current, span, _ in
                guard !NSDictionary(dictionary: current).isEqual(to: desired) else { return }
                if NSIntersectionRange(span, marked).length == 0 { storage.setAttributes(desired, range: span) }
                else {
                    let before = NSRange(location: span.location, length: max(0, marked.location - span.location))
                    let end = max(span.location, NSMaxRange(marked))
                    let after = NSRange(location: end, length: max(0, NSMaxRange(span) - end))
                    if before.length > 0 { storage.setAttributes(desired, range: before) }
                    if after.length > 0 { storage.setAttributes(desired, range: after) }
                }
            }
        }
        storage.endEditing()
        if registration { editingUndoManager.enableUndoRegistration() }
        textView.rendering = rendering
        textView.needsDisplay = true
    }

    private func measureText() -> Bool {
        let before = preferredHeight
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + (textView.string.hasSuffix("\n") ? lineHeight : 0)
            let lines = max(1, Int(ceil(used / lineHeight - 0.001)))
            textView.frame.size.height = CGFloat(lines) * lineHeight
            textHeight = CGFloat(min(6, lines)) * lineHeight
            scroll.hasVerticalScroller = lines > 6
        }
        needsLayout = true
        return before != preferredHeight
    }
    func newline(shift: Bool) {
        if shift, textView.isEditable { textView.insertNewlineIgnoringFieldEditor(nil) } else { sendComposed() }
    }
    func undoManager(for view: NSTextView) -> UndoManager? { editingUndoManager }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): newline(shift: self.textView.shift)
        case #selector(NSResponder.insertTab(_:)): window?.makeFirstResponder(targetButton)
        case #selector(NSResponder.insertBacktab(_:)): window?.makeFirstResponder(send)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func layout() {
        super.layout()
        let width = bounds.width
        var y = bounds.height - 9 - textHeight
        scroll.frame = NSRect(x: 8, y: y, width: width - 16, height: textHeight)
        textView.frame.size = NSSize(width: scroll.contentSize.width, height: max(textHeight, textView.frame.height))
        y -= 12
        fieldRule.frame = NSRect(x: 0, y: y, width: width, height: 1)
        y -= statusHeight
        spinner.frame = NSRect(x: 16, y: y + 9, width: 11, height: 11)
        warning.frame = NSRect(x: 16, y: y + 9, width: 12, height: 12)
        let action = !retry.isHidden ? retry : copyPrompt
        action.sizeToFit()
        action.frame = NSRect(x: width - 14 - action.frame.width, y: y + 4, width: action.frame.width, height: 22)
        let left: CGFloat = warning.isHidden && spinner.isHidden ? 14 : 34
        status.frame = NSRect(x: left, y: y + 8, width: (action.isHidden ? width - 16 : action.frame.minX - 8) - left, height: 14)
        footRule.frame = NSRect(x: 0, y: 40, width: width, height: 1)
        hint.frame = NSRect(x: 14, y: 14, width: width - 60, height: 14)
        send.frame = NSRect(x: width - 36, y: 8, width: 26, height: 26)
    }

    final class SendButton: NSButton {
        var back: () -> Void = {}
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
                NSColor.white.setStroke()
                path.stroke()
                return true
            }
            image?.isTemplate = false
            imagePosition = .imageOnly
            imageScaling = .scaleNone
            contentTintColor = .white
            toolTip = "Send (Return)"
            setAccessibilityLabel("Send prompt")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var isEnabled: Bool {
            didSet {
                contentTintColor = .white
                needsDisplay = true
            }
        }
        override var acceptsFirstResponder: Bool { isEnabled }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48 {
                if event.modifierFlags.contains(.shift) { back() }
                else { window?.makeFirstResponder(nextKeyView) }
            }
            else { super.keyDown(with: event) }
        }
        #if KIDO_VISUAL
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        #endif
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let fill = isEnabled ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.14)
                fill.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            }
            image?.draw(in: NSRect(x: (bounds.width - 15) / 2, y: (bounds.height - 15) / 2, width: 15, height: 15))
        }
    }


    final class Label: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            attributedStringValue.draw(with: bounds.insetBy(dx: 2, dy: 0), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    final class Picker: NSControl {
        var label = NSAttributedString()
        var showsChevron = false
        var choose: (Int) -> Void = { _ in }
        var cycle: (Int) -> Void = { _ in }
        var back: () -> Void = {}
        var forward: () -> Void = {}
        var close: () -> Void = {}
        override var acceptsFirstResponder: Bool { isEnabled }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
        override var fittingSize: NSSize { NSSize(width: ceil(label.size().width) + 30, height: 22) }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.popUpButton)
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        @objc func pick(_ item: NSMenuItem) { choose(item.tag) }
        private func popup() {
            guard isEnabled, let menu else { return }
            menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: 0, y: 0), in: self)
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); popup() }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 49, 36: popup()
            case 123: cycle(-1)
            case 124: cycle(1)
            case 48: if event.modifierFlags.contains(.shift) { back() } else { forward() }
            case 53: close()
            default: super.keyDown(with: event)
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            if window?.firstResponder === self {
                NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
                let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
                ring.lineWidth = 2
                ring.stroke()
            }
            label.draw(at: NSPoint(x: 8, y: (bounds.height - label.size().height) / 2))
            if showsChevron {
                let x = min(bounds.width - 16, label.size().width + 14)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x, y: 13))
                path.line(to: NSPoint(x: x + 3, y: 10))
                path.line(to: NSPoint(x: x + 6, y: 13))
                path.lineWidth = 1.6
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
            }
        }
    }
}

