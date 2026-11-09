import AppKit

struct TransientNotices {
    enum Clock: Equatable {
        case running(deadline: TimeInterval)
        case paused(remaining: TimeInterval)
    }
    struct Entry: Equatable {
        let id: UUID
        let title: String
        let detail: String
        var clock: Clock
    }
    private(set) var entries: [Entry] = []
    var deadline: TimeInterval? {
        entries.compactMap { if case .running(let deadline) = $0.clock { deadline } else { nil } }.min()
    }
    @discardableResult mutating func show(_ title: String, _ detail: String, duration: TimeInterval, now: TimeInterval) -> (id: UUID, evicted: UUID?) {
        expire(now: now)
        if let index = entries.firstIndex(where: { $0.title == title && $0.detail == detail }) {
            switch entries[index].clock {
            case .running: entries[index].clock = .running(deadline: now + duration)
            case .paused: entries[index].clock = .paused(remaining: duration)
            }
            return (entries[index].id, nil)
        }
        let id = UUID()
        entries.append(Entry(id: id, title: title, detail: detail, clock: .running(deadline: now + duration)))
        return (id, entries.count > 3 ? entries.removeFirst().id : nil)
    }
    mutating func hover(_ id: UUID, inside: Bool, now: TimeInterval) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        switch (entries[index].clock, inside) {
        case (.running(let deadline), true) where deadline > now: entries[index].clock = .paused(remaining: deadline - now)
        case (.paused(let remaining), false): entries[index].clock = .running(deadline: now + remaining)
        default: break
        }
    }
    mutating func dismiss(_ id: UUID) { entries.removeAll { $0.id == id } }
    mutating func expire(now: TimeInterval) {
        entries.removeAll { if case .running(let deadline) = $0.clock { deadline <= now } else { false } }
    }
}

@MainActor final class Notices: NSView {
    private let runtime: GhosttyRuntime
    private var transients = TransientNotices()
    private var cards: [UUID: Card] = [:]
    private var config: Card?
    private var scheduled: (timer: Timer, deadline: TimeInterval)?
    private var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var cardWidth: CGFloat { max(0, min(360, bounds.width - 32)) }
    #if KIDO_VISUAL
    var testConfigCard: NSView? { config }
    var testCards: [NSView] { transients.entries.compactMap { cards[$0.id] } }
    var testTransients: TransientNotices { transients }
    var testOpenFile: (URL) -> Void { get { openFile } set { openFile = newValue } }
    var testTime: TimeInterval? { didSet { stop() } }
    func testTick() { tick() }
    static func testDuration(_ detail: String, width: CGFloat) -> TimeInterval {
        Card.duration(lines: Card.lines(detail, width: Card.textWidth(width)))
    }
    #endif
    private var now: TimeInterval {
        #if KIDO_VISUAL
        if let testTime { return testTime }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
    private var animates: Bool {
        #if KIDO_VISUAL
        if testTime != nil { return false }
        #endif
        return true
    }
    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        for card in subviews.reversed() {
            if let hit = card.hitTest(convert(point, from: superview)) { return hit }
        }
        return nil
    }
    func show(_ title: String, _ detail: String) {
        let instant = now
        transients.expire(now: instant)
        let existing = transients.entries.first { $0.title == title && $0.detail == detail }.flatMap { cards[$0.id] }
        let card = existing ?? Card(runtime: runtime, title: title, detail: detail, kind: .transient)
        let shown = transients.show(title, detail, duration: Card.duration(lines: card.lineCount(width: cardWidth)), now: instant)
        if let evicted = shown.evicted { cards.removeValue(forKey: evicted)?.removeFromSuperview() }
        if cards[shown.id] == nil {
            card.dismiss = { [weak self] in self?.dismiss(shown.id) }
            card.hover = { [weak self] inside in
                guard let self else { return }
                transients.hover(shown.id, inside: inside, now: now)
                arm()
            }
            cards[shown.id] = card
            addSubview(card)
            announce(card)
            card.alphaValue = animates ? 0 : 1
        }
        refresh()
    }
    func showConfig() {
        let error = runtime.visibleConfigError
        guard config?.identity != error else { return }
        if let error {
            config?.removeFromSuperview()
            let card = Card(runtime: runtime, title: runtime.abbreviate(error.path) + " has an error", detail: error.problem.detail,
                            kind: .config(error))
            card.dismiss = { [weak runtime] in runtime?.dismissConfigError() }
            card.open = { [weak self] in self?.openFile(URL(fileURLWithPath: error.path)) }
            config = card
            addSubview(card)
            announce(card)
        } else {
            config?.removeFromSuperview()
            config = nil
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    func updateAppearance() {
        for card in subviews { card.needsLayout = true; card.needsDisplay = true }
    }
    func stop() { scheduled?.timer.invalidate(); scheduled = nil }
    func dismiss(_ id: UUID) {
        transients.dismiss(id)
        refresh()
    }
    private func refresh() {
        let live = Set(transients.entries.map(\.id))
        for id in Array(cards.keys) where !live.contains(id) {
            guard let card = cards.removeValue(forKey: id) else { continue }
            if animates {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    card.animator().alphaValue = 0
                } completionHandler: { card.removeFromSuperview() }
            } else { card.removeFromSuperview() }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    private func announce(_ card: Card) {
        NSAccessibility.post(element: card, notification: .announcementRequested,
                             userInfo: [.announcement: card.title + ". " + card.detail,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    private func arm() {
        #if KIDO_VISUAL
        if testTime != nil { return }
        #endif
        let deadline = transients.deadline
        guard deadline != scheduled?.deadline else { return }
        stop()
        guard let deadline else { return }
        let timer = Timer(timeInterval: max(0, deadline - now), target: self, selector: #selector(tick), userInfo: nil, repeats: false)
        scheduled = (timer, deadline)
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func tick() {
        stop()
        transients.expire(now: now)
        refresh()
    }
    override func layout() {
        super.layout()
        let width = cardWidth
        var y: CGFloat = 16
        let moves = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let ordered = (config.map { [$0] } ?? []) + transients.entries.reversed().compactMap { cards[$0.id] }
        for card in ordered {
            let height = card.height(width: width)
            let frame = NSRect(x: bounds.width - 16 - width, y: y, width: width, height: height)
            let entering = card.alphaValue == 0
            if entering { card.frame = moves ? frame.offsetBy(dx: 0, dy: -8) : frame }
            if animates && (entering || card.frame != frame) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    if moves { card.animator().frame = frame }
                    else { card.frame = frame }
                    card.animator().alphaValue = 1
                }
            } else { card.frame = frame; card.alphaValue = 1 }
            card.layoutSubtreeIfNeeded()
            y += height + 8
        }
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            for entry in transients.entries {
                transients.hover(entry.id, inside: cards[entry.id]?.frame.contains(point) == true, now: now)
            }
        }
        arm()
    }
    private final class Card: PaneCapsule {
        enum Kind { case transient, config(ConfigError) }
        private let kind: Kind
        let title: String
        let detail: String
        private var measurement: (width: CGFloat, lines: Int)?
        private static let textLeading: CGFloat = 26
        private static let textTrailing: CGFloat = 12
        private let close = IconButton("xmark", "Dismiss", size: 8, hoverStyle: .close)
        private let openButton = NSButton(title: "Open config", target: nil, action: nil)
        var dismiss: () -> Void = {}
        var open: () -> Void = {}
        var hover: (Bool) -> Void = { _ in }
        var identity: ConfigError? { if case .config(let error) = kind { error } else { nil } }
        override var acceptsFirstResponder: Bool { false }
        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        init(runtime: GhosttyRuntime, title: String, detail: String, kind: Kind) {
            self.kind = kind
            self.title = title
            self.detail = detail
            super.init(runtime: runtime, radius: 12, shadowStyle: .float)
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel(title + ". " + detail)
            if identity != nil {
                close.refusesFirstResponder = true
                close.toolTip = nil
                close.invoke = { [weak self] in self?.dismiss() }
                openButton.bezelStyle = .rounded
                openButton.controlSize = .small
                openButton.font = .systemFont(ofSize: 11)
                openButton.refusesFirstResponder = true
                openButton.target = self
                openButton.action = #selector(openConfig)
                addSubview(close)
                addSubview(openButton)
            }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        private static func text(_ value: String) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 16
            paragraph.maximumLineHeight = 16
            paragraph.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Chrome.inkSecondary, .paragraphStyle: paragraph])
        }
        static func lines(_ value: String, width: CGFloat) -> Int {
            let height = text(value).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            return max(1, Int(ceil(height / 16)))
        }
        static func textWidth(_ width: CGFloat, close: Bool = false) -> CGFloat { max(1, width - textLeading - textTrailing - (close ? 18 : 0)) }
        static func duration(lines: Int) -> TimeInterval { lines >= 3 ? 8 : 5 }
        func lineCount(width: CGFloat) -> Int {
            if let measurement, measurement.width == width { return measurement.lines }
            let lines = Self.lines(detail, width: Self.textWidth(width))
            measurement = (width, lines)
            return lines
        }
        func height(width: CGFloat) -> CGFloat { 9 + 16 + 2 + CGFloat(identity == nil ? min(5, lineCount(width: width)) : 1) * 16 + (identity == nil ? 10 : 41) }
        private var titleRect: NSRect { NSRect(x: Self.textLeading, y: 9, width: Self.textWidth(bounds.width, close: identity != nil), height: 16) }
        private var detailRect: NSRect { NSRect(x: Self.textLeading, y: 27, width: Self.textWidth(bounds.width), height: bounds.height - 27 - (identity == nil ? 10 : 41)) }
        override func layout() {
            super.layout()
            close.frame = NSRect(x: bounds.width - 24, y: 8, width: 16, height: 16)
            openButton.frame = NSRect(x: bounds.width - 104, y: bounds.height - 32, width: 94, height: 22)
        }
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                Chrome.statusError.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12, y: 14, width: 6, height: 6)).fill()
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (title as NSString).draw(in: titleRect, withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                       .foregroundColor: Chrome.ink, .paragraphStyle: paragraph])
                Self.text(detail).draw(with: detailRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            }
        }
        override func accessibilityChildren() -> [Any]? {
            let texts: [Any] = [(title, titleRect), (detail, detailRect)].map { text, frame in
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(frame)
                element.setAccessibilityLabel(text)
                return element
            }
            return texts + (identity == nil ? [] : [close, openButton])
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            if identity != nil {
                for button in [close as NSView, openButton] where button.frame.contains(local) { return button }
            }
            return self
        }
        override func mouseDown(with event: NSEvent) { if identity == nil { dismiss() } }
        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }
        @objc private func openConfig() { open() }
    }
}
