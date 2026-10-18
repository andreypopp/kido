import AppKit
import SidebarFeed
import TmuxControl

final class PanePrompt: PaneCapsule, NSTextViewDelegate {
    final class SendButton: NSButton {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            wantsLayer = true
            image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send prompt")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            contentTintColor = .white
            setAccessibilityLabel("Send prompt")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var isEnabled: Bool { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                (isEnabled ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.14)).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 13, yRadius: 13).fill()
            }
            super.draw(dirtyRect)
        }
    }

    let textView = NSTextView()
    let targetButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let status = NSTextField(labelWithString: "")
    let send = SendButton(frame: .zero)
    let retry = IconButton("arrow.clockwise", "Retry", size: 12, hoverStyle: .text)
    let copyPrompt = IconButton("doc.on.doc", "Copy Prompt", size: 12, hoverStyle: .text)
    let quote = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "Ask about the selection")
    private let quoteBar = NSView()
    private let hint = NSTextField(labelWithString: "↩ send · ⇧↩ newline")
    private let cancelButton = IconButton("xmark", "Cancel", size: 14, hoverStyle: .iconOnly)
    private let selection: String
    private var candidates: [PromptCandidate] = []
    private var target: PromptCandidate?
    private var resolved = false
    private var textHeight: CGFloat = 24
    private var quoteHeight: CGFloat = 30
    private var scrolls = false
    private let request: RPCRequestHandler

    #if KIDO_VISUAL
    @MainActor static var visualRequest: RPCRequestHandler?
    @MainActor static var linger: TimeInterval = 0.8
    #else
    static let linger: TimeInterval = 0.8
    #endif

    private enum State {
        case resolving, ready, noAgent, sending
        case delivered(String), refused(String), unknown(String), invalid(String), failed(String)
    }
    private var state = State.resolving

    init(_ pane: PaneView, runtime: GhosttyRuntime, selection: String) {
        self.selection = selection
        #if KIDO_VISUAL
        request = Self.visualRequest ?? (pane.window?.delegate as? WindowOwner)?.request ?? Feed.unavailable
        #else
        request = (pane.window?.delegate as? WindowOwner)?.request ?? Feed.unavailable
        #endif
        super.init(runtime: runtime, radius: 12, separators: 0)
        self.pane = pane
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Prompt with selection")

        targetButton.isBordered = false
        targetButton.font = .systemFont(ofSize: 12, weight: .semibold)
        targetButton.contentTintColor = .labelColor
        targetButton.target = self
        targetButton.action = #selector(chooseTarget)
        targetButton.setAccessibilityLabel("Send to")
        targetButton.controlSize = .small

        cancelButton.invoke = { [weak self] in self?.cancel() }

        textView.delegate = self
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 3, height: 3)
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
        placeholder.textColor = .placeholderTextColor

        quote.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        quote.textColor = .secondaryLabelColor
        quote.maximumNumberOfLines = 3
        quote.lineBreakMode = .byTruncatingTail
        quoteBar.wantsLayer = true

        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right

        send.target = self
        send.action = #selector(sendComposed)
        retry.title = "Retry"
        retry.font = .systemFont(ofSize: 11, weight: .medium)
        retry.invoke = { [weak self] in self?.retryAction() }
        copyPrompt.title = "Copy Prompt"
        copyPrompt.font = .systemFont(ofSize: 11, weight: .medium)
        copyPrompt.invoke = { [weak self] in self?.copyComposed() }
        for view in [targetButton, cancelButton, scroll, placeholder, quote, quoteBar, status, hint, send, retry, copyPrompt] {
            addSubview(view)
        }
        showQuote()
        _ = updateTextHeight()
        apply(.resolving)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var focused: Bool { window?.firstResponder === textView }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            quoteBar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        }
    }

    private func showQuote() {
        let lines = selection.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(2).joined(separator: "\n")
        let extra = lines.count - min(2, lines.count)
        quote.stringValue = extra > 0 ? "\(shown)\n+\(extra) lines" : shown
        quote.toolTip = selection
        quoteHeight = extra > 0 ? 44 : 30
    }

    private func paneWindow() -> WindowID? { (pane?.superview as? WindowView)?.windowID }

    func resolve() {
        request(.prompt(pane: pane?.pane ?? PaneID(number: 0), text: nil, target: nil)) { [weak self] result in
            guard let self, pane?.prompt === self else { return }
            guard case .success(.prompt(.candidates(let list))) = result else {
                if case .success(.prompt) = result { return apply(.failed("Unexpected prompt reply")) }
                return apply(failureState(result, sending: false) ?? .failed("Unexpected prompt reply"))
            }
            candidates = list
            target = list.first { $0.window == paneWindow() } ?? list.first
            resolved = true
            targetButton.removeAllItems()
            for candidate in list {
                let where_ = candidate.window == paneWindow() ? "this window" : "window \(candidate.window.description)"
                targetButton.addItem(withTitle: "Prompt @\(candidate.title) in \(where_)")
            }
            if let target, let index = candidates.firstIndex(of: target) {
                targetButton.selectItem(at: index)
                targetButton.setAccessibilityLabel("Send to @\(target.title)")
            }
            apply(list.isEmpty ? .noAgent : .ready)
        }
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

    private func apply(_ state: State) {
        self.state = state
        status.stringValue = ""
        status.textColor = .secondaryLabelColor
        spinner.isHidden = true
        retry.isHidden = true
        copyPrompt.isHidden = true
        send.isHidden = false
        send.isEnabled = false
        targetButton.isEnabled = false
        textView.isEditable = false
        hint.isHidden = false
        switch state {
        case .resolving:
            targetButton.removeAllItems()
            targetButton.addItem(withTitle: "Resolving…")
        case .ready:
            targetButton.isEnabled = true
            textView.isEditable = true
            send.isEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .noAgent:
            targetButton.removeAllItems()
            targetButton.addItem(withTitle: "No agent in this window or session")
        case .sending:
            status.stringValue = "Sending…"
            spinner.isHidden = false
            hint.isHidden = true
        case .delivered(let name):
            status.stringValue = "Sent to \(name)"
            status.textColor = .systemGreen
            send.isHidden = true
        case .refused(let message):
            status.stringValue = message
            status.textColor = .systemRed
            send.isHidden = true
            retry.isHidden = false
            textView.isEditable = true
            hint.isHidden = true
        case .unknown(let message):
            status.stringValue = "\(message) It may have arrived; not resent."
            status.textColor = .systemRed
            send.isHidden = true
            copyPrompt.isHidden = false
            hint.isHidden = true
        case .invalid(let message):
            status.stringValue = message
            status.textColor = .systemRed
            targetButton.isEnabled = true
            textView.isEditable = true
            hint.isHidden = true
        case .failed(let message):
            status.stringValue = message
            status.textColor = .systemRed
            targetButton.removeAllItems()
            targetButton.addItem(withTitle: "Prompt unavailable")
            retry.isHidden = false
            hint.isHidden = true
        }
        needsLayout = true
        pane?.promptNeedsLayout()
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        if resolved {
            switch state {
            case .refused, .invalid: apply(.ready)
            case .ready: send.isEnabled = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: break
            }
        }
        if updateTextHeight() {
            needsLayout = true
            pane?.promptNeedsLayout()
        }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            cancel()
        case #selector(NSResponder.insertNewline(_:)):
            newline(shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        default: return false
        }
        return true
    }

    func newline(shift: Bool) {
        if shift { textView.insertNewlineIgnoringFieldEditor(nil) } else { sendComposed() }
    }

    @objc func chooseTarget() {
        let index = targetButton.indexOfSelectedItem
        guard candidates.indices.contains(index) else { return }
        target = candidates[index]
        targetButton.setAccessibilityLabel("Send to @\(target!.title)")
    }

    private func retryAction() {
        if case .failed = state { resolve() } else { sendComposed() }
    }

    @objc func sendComposed() {
        guard resolved, let target, let pane else { return }
        switch state {
        case .ready, .refused: break
        default: return
        }
        apply(.sending)
        request(.prompt(pane: pane.pane, text: RPCRequest.composePrompt(prompt: textView.string, selection: selection), target: target.pane)) { [weak self] result in
            guard let self, pane.prompt === self else { return }
            if case .success(.prompt(.delivered(let delivered))) = result {
                let name = candidates.first { $0.pane == delivered.pane }?.title ?? delivered.pane.description
                apply(.delivered(name))
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger) { [weak self] in
                    guard let self, pane.prompt === self else { return }
                    pane.promptDelivered()
                }
                return
            }
            apply(failureState(result, sending: true) ?? .invalid("Unexpected prompt reply"))
        }
    }

    private func copyComposed() {
        let board = pane?.runtime.pasteboard
        board?.clearContents()
        board?.setString(RPCRequest.composePrompt(prompt: textView.string, selection: selection), forType: .string)
    }

    @objc func cancel() {
        pane?.closePrompt()
    }

    private func updateTextHeight() -> Bool {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return false }
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
        let used = layout.usedRect(for: container).height
        let height = min(max(line, used) + textView.textContainerInset.height * 2, line * 6 + textView.textContainerInset.height * 2)
        let overflow = used + textView.textContainerInset.height * 2 > textHeight
        guard height != textHeight || overflow != scrolls else { return false }
        textHeight = height
        scrolls = overflow
        return true
    }

    var preferredHeight: CGFloat { 32 + 4 + quoteHeight + 4 + textHeight + 6 + 32 }

    override func layout() {
        super.layout()
        let width = bounds.width
        targetButton.frame = NSRect(x: 4, y: bounds.height - 30, width: max(0, width - 42), height: 26)
        cancelButton.frame = NSRect(x: width - 30, y: bounds.height - 30, width: 26, height: 26)
        var y: CGFloat = 32 + 6
        quoteBar.frame = NSRect(x: 10, y: y, width: 2, height: quoteHeight)
        quote.frame = NSRect(x: 17, y: y, width: max(0, width - 27), height: quoteHeight)
        y += quoteHeight + 4
        scroll.frame = NSRect(x: 8, y: y, width: width - 16, height: textHeight)
        textView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: textHeight)
        textView.textContainer?.containerSize = NSSize(width: max(0, scroll.contentSize.width - 6), height: CGFloat.greatestFiniteMagnitude)
        placeholder.frame = NSRect(x: 11, y: y + textHeight - 21, width: max(0, width - 30), height: 18)
        scroll.hasVerticalScroller = scrolls
        send.frame = NSRect(x: width - 32, y: 3, width: 26, height: 26)
        if !copyPrompt.isHidden { copyPrompt.frame = NSRect(x: width - 32 - copyPrompt.fittingSize.width - 6, y: 6, width: copyPrompt.fittingSize.width, height: 20) }
        if !retry.isHidden { retry.frame = NSRect(x: width - 32 - retry.fittingSize.width - 6, y: 6, width: retry.fittingSize.width, height: 20) }
        spinner.frame = CGRect(x: 8, y: 11.5, width: 9, height: 9)
        status.frame = NSRect(x: 8, y: 9, width: max(0, width - 50), height: 16)
        hint.frame = NSRect(x: 8, y: 9, width: max(0, width - 50), height: 16)
        if !hint.isHidden { status.frame.size.width = max(0, width - 16 - hint.fittingSize.width) }
    }
}
