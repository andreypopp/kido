import AppKit
import KidoPairing

@MainActor final class PalettePair: NSView, NSTextFieldDelegate {
    let nameField = NSTextField(string: Foundation.Host.current().localizedName ?? "Mac")
    private let nameLabel = NSTextField(labelWithString: "Device name")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    var identities: IdentityStore?
    var session: PairingSession?
    weak var codeField: NSTextField?
    var cancel: () -> Void = {}
    var submit: () -> Void = {}
    var resized: () -> Void = {}
    private var expectedHost: ServerName? { session?.expectedHost }
    var inertChanged: (Bool) -> Void = { _ in }
    private enum Line {
        case empty, hint(NSAttributedString), progress(String), failure(String), retry(String)
        var text: String { switch self { case .empty: ""; case .hint(let text): text.string; case .progress(let text), .failure(let text), .retry(let text): text } }
    }
    private var line = Line.empty
    private var spinning: Bool { if case .progress = line { true } else { false } }
    private var retrying: Bool { if case .retry = line { true } else { false } }
    private var error: Bool { switch line { case .failure, .retry: true; default: false } }
    override var isFlipped: Bool { true }
    var preferredHeight: CGFloat { 36 + (line.text.isEmpty ? 0 : 34) + 30 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = Chrome.inkSecondary
        nameField.font = .systemFont(ofSize: 13)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.delegate = self
        nameField.setAccessibilityLabel("Device name")
        status.font = .systemFont(ofSize: 11)
        retryButton.isBordered = false
        retryButton.font = .systemFont(ofSize: 11, weight: .medium)
        retryButton.contentTintColor = Chrome.linkText
        retryButton.target = self
        retryButton.action = #selector(retryPair)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [nameLabel, nameField, status, retryButton, spinner] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh() {
        line = .empty
        let parsed = try? PairingCode(codeField?.stringValue ?? "", expectedHost: expectedHost)
        switch session?.state ?? .editing {
        case .editing:
            if let parsed { line = .hint(hint(name: parsed.name.value, host: parsed.host, again: false)) }
            else if let expectedHost {
                let name = Host.tls(expectedHost).title(in: identities)
                line = .hint(hint(name: name, host: expectedHost, again: true))
            }
        case .submitting(let code): line = .progress("Pairing with \(code.name.value)…")
        case .waiting(let code): line = .progress("Waiting for \(code.name.value) to activate…")
        case .retryable(let code, _, let message): line = .retry("Could not reach \(code.name.value): \(message)")
        case .uncertain(let code): line = .failure("\(code.name.value) may have paired this Mac; try Connect.")
        case .rejected(let reason):
            let message: String = switch reason {
            case .invalidCode: "Not a pairing code"
            case .usedOrExpired: "This code is used or expired. Run the pairing command again."
            case .refused: "The server refused this pairing. Run the pairing command again."
            case .invalidDeviceName: "Use a device name of 1 to 64 characters, without control characters"
            case .failed(let failure): failure.message
            }
            line = .failure(message)
        case .activationFailed(let code, let reason):
            switch reason {
            case .timedOut: line = .failure("Could not reach \(code.name.value); try Connect.")
            case .serverCertificate(let message): line = .failure(message)
            }
        case .complete: break
        }
        let inert = session?.inert ?? false
        nameLabel.alphaValue = inert ? 0.45 : 1
        nameField.alphaValue = inert ? 0.45 : 1
        if nameField.isEditable == inert { nameField.isEditable = !inert }
        inertChanged(inert)
        status.stringValue = line.text
        status.textColor = error ? Chrome.errorText : Chrome.inkSecondary
        if case .hint(let text) = line { status.attributedStringValue = text }
        retryButton.isHidden = !retrying
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
        needsDisplay = true
        resized()
    }

    private func hint(name: String, host: ServerName, again: Bool) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.inkSecondary]
        let text = NSMutableAttributedString(string: "Pairs this Mac with ", attributes: attributes)
        text.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Chrome.ink]))
        if !again || name != host.value { text.append(NSAttributedString(string: " (\(host.value))", attributes: attributes)) }
        if again { text.append(NSAttributedString(string: " again; the old key stays until this pairing succeeds", attributes: attributes)) }
        return text
    }

    override func layout() {
        super.layout()
        nameLabel.frame = NSRect(x: 16, y: 10, width: 84, height: 18)
        nameField.frame = NSRect(x: 110, y: 9, width: 474, height: 20)
        let inset: CGFloat = spinning || error ? 34 : 16
        status.frame = NSRect(x: inset, y: 45, width: 600 - inset - (retrying ? 65 : 16), height: 26)
        retryButton.frame = NSRect(x: 535, y: 40, width: 50, height: 24)
        spinner.frame = NSRect(x: 16, y: 45, width: 10, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        Chrome.hairline.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 1).fill()
        NSRect(x: 0, y: 36, width: 600, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 30, width: 600, height: 1).fill()
        if error, let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [Chrome.onError, Chrome.errorText]))) {
            image.draw(in: NSRect(x: 16, y: 46, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if nameField.currentEditor() != nil {
            Chrome.pickerRing.setStroke()
            let ring = NSBezierPath(roundedRect: nameField.frame.insetBy(dx: -4, dy: -2), xRadius: 3, yRadius: 3)
            ring.lineWidth = 2
            ring.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Chrome.inkSecondary]
        ("↩ pair    ⇥ device name    esc back" as NSString).draw(at: NSPoint(x: 16, y: bounds.height - 22), withAttributes: attributes)
        if expectedHost == nil {
            let text = "the code the server’s CLI printed, valid about 2 minutes" as NSString
            text.draw(at: NSPoint(x: 584 - text.size(withAttributes: attributes).width, y: bounds.height - 22), withAttributes: attributes)
        }
    }
    func controlTextDidBeginEditing(_ notification: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ notification: Notification) { needsDisplay = true }
    func controlTextDidChange(_ notification: Notification) { session?.edited(); refresh() }
    @objc private func retryPair() { session?.retrySend() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) { window?.makeFirstResponder(codeField); return true }
        return false
    }
}
