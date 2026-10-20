import AppKit
import QuartzCore
import SidebarFeed

@MainActor
final class PaneParagraphs {
    enum State: Equatable {
        case off
        case idle
        case analysing(Paragraphs.Block)
        case tooLong(Paragraphs.Block)
        case unavailable(Paragraphs.Block, String)
        case answered(Paragraphs.Block, [Paragraphs.Option])
        case plain(Paragraphs.Block)
        case failed(Paragraphs.Block)
    }

    private enum Feedback: Equatable {
        case sent(Int, String)
        case failed(Int, String)
    }

    private enum Caption: Equatable {
        case neutral, success, error
    }

    private weak var pane: PaneView?
    let layer = CALayer()
    private let clip = CAShapeLayer()
    private let blockLayer = CALayer()
    private let shimmer = CAGradientLayer()
    private let shimmerMask = CAShapeLayer()
    private var optionLayers: [CALayer] = []
    private let captionBox = CALayer()
    private let captionText = CATextLayer()

    private(set) var state: State = .off
    private var pendingPrompt: String?
    private var currentContext: Paragraphs.Context?
    private var anchor: Int?
    private var growing = false
    private var growthToken = 0
    private var analysisTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var feedback: Feedback?
    private var hoveredOption: Int?
    private var lastPointer: NSPoint?
    private var lastViewport: PaneView.ScrollPosition?
    private var optionRects: [(index: Int, rect: CGRect)] = []
    private var refreshScheduled = false
    private var effectActive = false
    private var availability: ParagraphModel.Availability = .ready
    private var captionKey: (text: String, style: Caption, fg: NSColor, background: NSColor)?
    private var clipPath = CGRect.zero
    private var shimmerSize = CGSize.zero
    private static let margin = 200
    private static let chunk = 16

    #if KIDO_VISUAL
    static var visualFrozen = false
    static var visualReduceMotion = false
    static var visualPhase: CGFloat = 0.5
    #endif

    init(pane: PaneView) {
        self.pane = pane
        layer.masksToBounds = true
        layer.zPosition = 1
        clip.fillColor = NSColor.black.cgColor
        layer.mask = clip
        blockLayer.cornerRadius = 4
        blockLayer.borderWidth = 1
        shimmer.locations = [0.38, 0.5, 0.62]
        shimmer.startPoint = CGPoint(x: 1.2, y: 0.59)
        shimmer.endPoint = CGPoint(x: 2.185, y: 0.416)
        shimmer.mask = shimmerMask
        captionBox.cornerRadius = 5
        captionBox.borderWidth = 0.5
        captionText.fontSize = 10
        captionText.font = NSFont.systemFont(ofSize: 10)
        captionText.alignmentMode = .left
        captionText.isWrapped = false
        captionBox.addSublayer(captionText)
        layer.addSublayer(blockLayer)
        layer.addSublayer(shimmer)
        layer.addSublayer(captionBox)
    }

    var cursorRects: [CGRect] { growing ? [] : optionRects.map(\.rect) }

    func setMode(on: Bool, pointer: NSPoint? = nil) {
        guard on else {
            guard state != .off else { return }
            idle()
            state = .off
            apply()
            return
        }
        guard state == .off, let pane, pane.paragraphEligible else { return }
        lastPointer = pointer
        availability = ParagraphModel.shared.availability()
        state = .idle
        refreshNow()
    }

    func layoutChanged() {
        guard let pane else { return }
        layer.frame = pane.bounds
        clip.frame = layer.bounds
        if state != .off { apply() }
    }

    func refresh() {
        guard state != .off else { return }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshNow()
        }
    }

    func viewportChanged() {
        guard state != .off, let viewport = pane?.paragraphViewport() else { return }
        let previous = lastViewport
        lastViewport = viewport
        if previous?.offset != viewport.offset || previous?.total != viewport.total || previous?.len != viewport.len {
            refresh()
        } else {
            rehit()
        }
    }

    func screenChanged() {
        guard state != .off else { return }
        idle()
        lastViewport = nil
        apply()
        refreshNow()
    }

    func pointerMoved(_ point: NSPoint) {
        guard state != .off else { return }
        lastPointer = point
        if case .answered(let block, _) = state, let pane,
           let viewport = lastViewport ?? pane.paragraphViewport(),
           let geometry = Geometry(pane: pane, viewport: viewport),
           let row = geometry.row(atY: point.y), block.rows.contains(row) {
            apply()
            return
        }
        select()
    }

    func pointerExited() {
        guard state != .off else { return }
        lastPointer = nil
        idle()
        apply()
    }

    func click(at point: NSPoint) -> Bool {
        guard !growing, case .answered(let block, let options) = state,
              let index = optionRects.first(where: { $0.rect.contains(point) })?.index,
              options.indices.contains(index), let pane, let windowID = pane.windowID else { return false }
        let option = options[index]
        let text = Paragraphs.payload(block, option)
        let request = pane.paragraphRequest
        let source = pane.pane
        let expected = (text: block.text, options: options.map(\.text))
        request(.prompt(pane: source, text: nil, target: nil)) { [weak self] result in
            guard let self else { return }
            guard case .success(.prompt(.candidates(let list))) = result else {
                self.showFailure(index, expected, Self.failureCaption(result))
                return
            }
            guard let target = PromptCandidate.preferred(in: windowID, among: list) else {
                self.showFailure(index, expected, "No agent in this window or session")
                return
            }
            request(.prompt(pane: source, text: text, target: target.pane)) { [weak self] result in
                guard let self else { return }
                if case .success(.prompt(.delivered)) = result {
                    guard self.same(expected) else { return }
                    self.feedback = .sent(index, target.title)
                    self.schedule(1) { [weak self] in
                        guard let self, case .sent(index, _) = self.feedback else { return }
                        self.feedback = nil
                        self.apply()
                    }
                } else {
                    self.showFailure(index, expected, Self.failureCaption(result))
                    return
                }
                self.apply()
            }
        }
        return true
    }

    private static func failureCaption(_ result: Result<RPCEvent.Reply.Value, Failure>) -> String {
        switch RPCRequest.promptFailure(result, sending: true, notReady: Feed.notReady) {
        case .unknown(let message):
            "\(message) It may have arrived; not resent."
        case .refused(let message), .invalid(let message):
            "Not delivered: \(message)"
        case .failed(let message):
            message
        case nil:
            "Not delivered: \(RPCRequest.unexpectedPromptReply)"
        }
    }

    private func showFailure(_ index: Int, _ expected: (text: String, options: [String]), _ caption: String) {
        guard same(expected) else { return }
        feedback = .failed(index, caption)
        schedule(4) { [weak self] in
            guard let self, case .failed(index, _) = self.feedback else { return }
            self.feedback = nil
            self.apply()
        }
        apply()
    }

    private func schedule(_ seconds: Int, _ action: @escaping @MainActor () -> Void) {
        #if KIDO_VISUAL
        if Self.visualFrozen { return }
        #endif
        feedbackTask?.cancel()
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func same(_ expected: (text: String, options: [String])) -> Bool {
        guard case .answered(let block, let options) = state else { return false }
        return block.text == expected.text && options.map(\.text) == expected.options
    }

    private func refreshNow() {
        guard state != .off, let pane, let viewport = pane.paragraphViewport() else { return }
        lastViewport = viewport
        select()
    }

    private func select() {
        guard state != .off, let pane, let viewport = lastViewport ?? pane.paragraphViewport() else { return }
        guard let geometry = Geometry(pane: pane, viewport: viewport),
              let row = geometry.row(atY: lastPointer?.y) else {
            idle()
            apply()
            return
        }
        guard let context = readContext(row, viewport: viewport) else {
            if case .answered = state, let block = state.block, block.rows.contains(row) {
                apply()
            } else {
                idle()
                apply()
            }
            return
        }
        currentContext = context
        let hovered = context.paragraphs[context.hovered]
        if let verdict = ParagraphModel.cache[context.prompt] {
            switch verdict {
            case .plain:
                resetHover()
                state = .plain(hovered)
                apply()
                fade(hovered.text)
                return
            case .question(let unit):
                if let restored = findKnown(unit, row: row, viewport: viewport) {
                    let same = isAnswered && state.block?.text == restored.block.text
                    if !same { resetHover() }
                    anchor = restored.block.rows.lowerBound
                    state = .answered(restored.block, restored.options)
                    apply()
                    return
                }
            }
        }
        if let unit = ParagraphModel.cache.questions.first(where: { $0.paragraphs.contains(hovered.text) }),
           let restored = findKnown(unit, row: row, viewport: viewport) {
            let same = isAnswered && state.block?.text == restored.block.text
            if !same { resetHover() }
            anchor = restored.block.rows.lowerBound
            state = .answered(restored.block, restored.options)
            apply()
            return
        }
        if case .analysing = state, let current = state.block, current.text == hovered.text,
           pendingPrompt == context.prompt {
            update(hovered)
            apply()
            return
        }
        if case .analysing = state {
        } else if let current = state.block, current.text == hovered.text, !isAnswered {
            update(hovered)
            apply()
            return
        }
        resetHover()
        if Paragraphs.isTooLong(hovered) {
            state = .tooLong(hovered)
            apply()
            return
        }
        if case .unavailable(let caption) = availability {
            state = .unavailable(hovered, caption)
            apply()
            return
        }
        state = .analysing(hovered)
        apply()
        start(context)
    }

    private var isAnswered: Bool {
        if case .answered = state { true } else { false }
    }

    private func findKnown(_ unit: Paragraphs.KnownUnit, row: Int, viewport: PaneView.ScrollPosition) -> Paragraphs.Unit? {
        guard let pane else { return nil }
        let low = max(0, viewport.offset - Self.margin)
        let high = min(viewport.total, viewport.offset + viewport.len + Self.margin)
        return Paragraphs.find(unit, in: pane.paragraphRows(low..<high), first: low, row: row, near: anchor)
    }

    private func rehit() {
        if case .answered(let block, _) = state, let pane, let viewport = lastViewport,
           let geometry = Geometry(pane: pane, viewport: viewport),
           let row = geometry.row(atY: lastPointer?.y), block.rows.contains(row) {
            apply()
        } else {
            select()
        }
    }

    private func readContext(_ row: Int, viewport: PaneView.ScrollPosition) -> Paragraphs.Context? {
        guard let pane else { return nil }
        let low = max(0, viewport.offset - Self.margin)
        let high = min(viewport.total, viewport.offset + viewport.len + Self.margin)
        guard low < high, row >= low, row < high else { return nil }
        var first = max(low, row - Self.chunk / 2)
        var last = min(high, first + Self.chunk)
        var rows = pane.paragraphRows(first..<last)
        func growBefore() {
            let next = max(low, first - Self.chunk)
            rows = pane.paragraphRows(next..<first) + rows
            first = next
        }
        func growAfter() {
            let next = min(high, last + Self.chunk)
            rows += pane.paragraphRows(last..<next)
            last = next
        }
        while true {
            guard let context = Paragraphs.context(rows, first: first, row: row) else {
                if Paragraphs.blankRow(rows, first: first, row: row) { return nil }
                if first > low { growBefore(); continue }
                if last < high { growAfter(); continue }
                return nil
            }
            let leading = context.paragraphs.first.map { $0.rows.lowerBound <= first } ?? false
            if (leading || context.needsBefore), first > low {
                growBefore()
                continue
            }
            let trailing = context.paragraphs.last.map { $0.rows.upperBound >= last - 1 } ?? false
            if (trailing || context.needsAfter), last < high {
                growAfter()
                continue
            }
            return context
        }
    }

    private func start(_ context: Paragraphs.Context) {
        pendingPrompt = context.prompt
        analysisTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let answer = try await ParagraphModel.shared.analyze(context.prompt)
                guard !Task.isCancelled, let self else { return }
                self.finish(answer, context: context)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.fail(context)
            }
        }
    }

    private func finish(_ answer: ParagraphAnswer, context oldContext: Paragraphs.Context) {
        analysisTask = nil
        let context = currentContext ?? oldContext
        let hovered = context.paragraphs[context.hovered]
        guard pendingPrompt == context.prompt,
              case .analysing(let block) = state, block.text == hovered.text else { return }
        pendingPrompt = nil
        guard answer.isQuestion else {
            ParagraphModel.cache.insert(.plain, for: context.prompt)
            state = .plain(hovered)
            apply()
            fade(hovered.text)
            return
        }
        let unit = Paragraphs.unit(context, answer) { debug($0) }
        let known = Paragraphs.KnownUnit(paragraphs: context.paragraphs[unit.paragraphs].map(\.text),
                                         options: unit.options.map(\.text))
        ParagraphModel.cache.insert(.question(known), for: context.prompt)
        anchor = unit.block.rows.lowerBound
        let from = blockLayer.frame
        state = .answered(unit.block, unit.options)
        growing = false
        apply()
        guard !reduceMotion else { return }
        growthToken += 1
        let token = growthToken
        growing = true
        optionLayers.forEach { $0.isHidden = true }
        animateGrowth(from: from, to: blockLayer.frame, fg: pane?.runtime.foreground ?? .white)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.growthToken == token, case .answered(let grown, _) = self.state,
                  grown.text == unit.block.text else { return }
            self.growing = false
            self.apply()
            self.pane?.paragraphCursorRectsChanged()
        }
    }

    private var reduceMotion: Bool {
        #if KIDO_VISUAL
        Self.visualFrozen ? Self.visualReduceMotion : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    private func animateGrowth(from: CGRect, to: CGRect, fg: NSColor) {
        let duration = 0.18
        let timing = CAMediaTimingFunction(name: .easeOut)
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = CGRect(origin: .zero, size: from.size)
        bounds.toValue = CGRect(origin: .zero, size: to.size)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = CGPoint(x: from.midX, y: from.midY)
        position.toValue = CGPoint(x: to.midX, y: to.midY)
        let background = CABasicAnimation(keyPath: "backgroundColor")
        background.fromValue = fg.withAlphaComponent(0).cgColor
        background.toValue = fg.withAlphaComponent(0.05).cgColor
        let border = CABasicAnimation(keyPath: "borderColor")
        border.fromValue = fg.withAlphaComponent(0.10).cgColor
        border.toValue = fg.withAlphaComponent(0.12).cgColor
        for (key, animation) in [("grow-bounds", bounds), ("grow-position", position),
                                 ("grow-background", background), ("grow-border", border)] {
            animation.duration = duration
            animation.timingFunction = timing
            blockLayer.add(animation, forKey: key)
        }
    }

    private func fail(_ oldContext: Paragraphs.Context) {
        analysisTask = nil
        let context = currentContext ?? oldContext
        let hovered = context.paragraphs[context.hovered]
        guard pendingPrompt == context.prompt,
              case .analysing(let block) = state, block.text == hovered.text else { return }
        pendingPrompt = nil
        state = .failed(hovered)
        apply()
    }

    private func update(_ block: Paragraphs.Block) {
        switch state {
        case .analysing: state = .analysing(block)
        case .tooLong: state = .tooLong(block)
        case .unavailable(_, let caption): state = .unavailable(block, caption)
        case .answered: break
        case .plain: state = .plain(block)
        case .failed: state = .failed(block)
        case .off, .idle: break
        }
    }

    private func resetHover() {
        cancel()
        endGrowth()
        feedback = nil
        hoveredOption = nil
        pendingPrompt = nil
        currentContext = nil
    }

    private func idle() {
        resetHover()
        state = .idle
    }

    private func endGrowth() {
        growing = false
        growthToken += 1
        for key in ["grow-bounds", "grow-position", "grow-background", "grow-border"] {
            blockLayer.removeAnimation(forKey: key)
        }
        pane?.paragraphCursorRectsChanged()
    }

    private func cancel() {
        analysisTask?.cancel()
        analysisTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
    }

    private func fade(_ text: String) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, case .plain(let block) = self.state, block.text == text else { return }
            self.blockLayer.isHidden = true
            self.shimmer.isHidden = true
        }
        blockLayer.isHidden = false
        blockLayer.add(fade, forKey: "fade")
        if effectActive { shimmer.add(fade, forKey: "fade") }
        CATransaction.commit()
    }

    private func apply() {
        guard let pane else { return }
        let layerBounds = pane.bounds
        layer.frame = layerBounds
        clip.frame = layer.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard state != .off, state != .idle, let block = state.block,
              let viewport = lastViewport ?? pane.paragraphViewport(),
              let geometry = Geometry(pane: pane, viewport: viewport) else {
            clear()
            return
        }
        let fg = pane.runtime.foreground
        if clipPath != geometry.clip {
            clipPath = geometry.clip
            clip.path = CGPath(rect: geometry.clip, transform: nil)
        }
        blockLayer.removeAnimation(forKey: "fade")
        shimmer.removeAnimation(forKey: "fade")
        let rect = geometry.block(block)
        if growing, blockLayer.frame != rect { endGrowth() }
        blockLayer.frame = rect
        if case .plain = state {} else { blockLayer.isHidden = false }
        let analysing = if case .analysing = state { true } else { false }
        blockLayer.backgroundColor = fg.withAlphaComponent(analysing ? 0 : 0.05).cgColor
        blockLayer.borderColor = fg.withAlphaComponent(analysing ? 0.10 : 0.12).cgColor
        blockLayer.borderWidth = 1
        var options: [Paragraphs.Option] = []
        if case .answered(_, let list) = state { options = list }
        var rects: [(index: Int, rect: CGRect)] = []
        for (index, option) in options.enumerated() {
            for span in option.spans {
                let hit = geometry.option(span).intersection(geometry.clip)
                if !hit.isNull, !hit.isEmpty { rects.append((index, hit)) }
            }
        }
        let previous = optionRects
        optionRects = rects
        hoveredOption = lastPointer.flatMap { point in
            rects.first { $0.rect.contains(point) }?.index
        }
        if optionLayers.count < rects.count {
            for _ in optionLayers.count..<rects.count {
                let option = CALayer()
                option.cornerRadius = 3
                option.borderWidth = 1
                layer.insertSublayer(option, above: shimmer)
                optionLayers.append(option)
            }
        }
        for (index, optionLayer) in optionLayers.enumerated() {
            guard index < rects.count else { optionLayer.isHidden = true; continue }
            let entry = rects[index]
            optionLayer.frame = entry.rect
            optionLayer.isHidden = growing
            let mark: NSColor? = switch feedback {
            case .sent(let option, _): option == entry.index ? .systemGreen : nil
            case .failed(let option, _): option == entry.index ? .systemRed : nil
            case nil: nil
            }
            if let mark {
                optionLayer.backgroundColor = mark.withAlphaComponent(0.30).cgColor
                optionLayer.borderColor = mark.withAlphaComponent(0.90).cgColor
            } else {
                let accent = NSColor.controlAccentColor
                let hot = hoveredOption == entry.index
                optionLayer.backgroundColor = accent.withAlphaComponent(hot ? 0.30 : 0.16).cgColor
                optionLayer.borderColor = accent.withAlphaComponent(hot ? 0.90 : 0.65).cgColor
            }
        }
        caption(block, options, geometry, fg: fg, background: pane.runtime.background)
        effect(analysing, rect: rect, fg: fg)
        if previous.map(\.rect) != rects.map(\.rect) { pane.paragraphCursorRectsChanged() }
    }

    private func clear() {
        blockLayer.removeAnimation(forKey: "fade")
        shimmer.removeAnimation(forKey: "fade")
        blockLayer.isHidden = true
        shimmer.isHidden = true
        captionBox.isHidden = true
        optionLayers.forEach { $0.isHidden = true }
        let changed = !optionRects.isEmpty
        optionRects = []
        effect(false, rect: .zero, fg: .clear)
        if changed, let pane { pane.paragraphCursorRectsChanged() }
    }

    private func caption(_ block: Paragraphs.Block, _ options: [Paragraphs.Option], _ geometry: Geometry,
                         fg: NSColor, background: NSColor) {
        var text: String?
        var style = Caption.neutral
        var anchor = geometry.row(block.rows.upperBound, block.firstColumn...block.lastColumn)
        switch state {
        case .tooLong:
            text = "Too long to analyse"
        case .unavailable(_, let caption):
            text = caption
        case .failed:
            text = "Could not analyse this block"
        case .answered:
            switch feedback {
            case .sent(let index, let name):
                text = "Sent to @\(name)"
                style = .success
                anchor = lastSegment(index, options, geometry)
            case .failed(let index, let message):
                text = message
                style = .error
                anchor = lastSegment(index, options, geometry)
            case nil:
                if options.isEmpty { text = "No answer options found" }
            }
        case .off, .idle, .analysing, .plain:
            break
        }
        guard let text else {
            captionBox.isHidden = true
            captionKey = nil
            return
        }
        let width = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width) + 12
        var frame = CGRect(x: anchor.maxX + 8, y: anchor.midY - 8, width: width, height: 16)
        if frame.maxX > geometry.bounds.maxX - 8 {
            frame.origin = CGPoint(x: anchor.minX, y: anchor.minY - 3 - 16)
        }
        captionBox.frame = frame
        captionBox.isHidden = false
        if let key = captionKey, key.text == text, key.style == style,
           key.fg.isEqual(fg), key.background.isEqual(background) { return }
        captionKey = (text, style, fg, background)
        captionText.frame = CGRect(x: 6, y: 1, width: width - 12, height: 14)
        captionText.string = text
        captionText.contentsScale = geometry.scale
        switch style {
        case .neutral:
            captionText.foregroundColor = fg.withAlphaComponent(0.6).cgColor
            captionBox.backgroundColor = (background.blended(withFraction: 0.2, of: fg) ?? background).cgColor
            captionBox.borderColor = fg.withAlphaComponent(0.14).cgColor
            captionBox.borderWidth = 0.5
        case .success:
            captionText.foregroundColor = NSColor.white.cgColor
            captionBox.backgroundColor = NSColor.systemGreen.cgColor
            captionBox.borderWidth = 0
        case .error:
            captionText.foregroundColor = NSColor.white.cgColor
            captionBox.backgroundColor = NSColor.systemRed.cgColor
            captionBox.borderWidth = 0
        }
    }

    private func lastSegment(_ index: Int, _ options: [Paragraphs.Option], _ geometry: Geometry) -> CGRect {
        guard options.indices.contains(index), let span = options[index].spans.last else {
            return geometry.row(0, 0...0)
        }
        return geometry.row(span.row, span.columns)
    }

    private func effect(_ running: Bool, rect: CGRect, fg: NSColor) {
        guard running else {
            if effectActive {
                blockLayer.removeAllAnimations()
                shimmer.removeAllAnimations()
                shimmer.isHidden = true
                effectActive = false
            }
            return
        }
        shimmer.frame = rect
        if shimmerSize != rect.size {
            shimmerSize = rect.size
            shimmerMask.frame = shimmer.bounds
            shimmerMask.path = CGPath(roundedRect: shimmer.bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        }
        if effectActive { return }
        effectActive = true
        #if KIDO_VISUAL
        if Self.visualFrozen {
            if reduceMotion {
                blockLayer.borderColor = fg.withAlphaComponent(0.28).cgColor
                blockLayer.borderWidth = 1.5
            } else {
                shimmer.colors = [NSColor.clear.cgColor, fg.withAlphaComponent(0.09).cgColor, NSColor.clear.cgColor]
                shimmer.startPoint = CGPoint(x: 1.2 - 2 * Self.visualPhase, y: 0.59)
                shimmer.endPoint = CGPoint(x: 2.185 - 2 * Self.visualPhase, y: 0.416)
                shimmer.isHidden = false
            }
            return
        }
        #endif
        if reduceMotion {
            let pulses: [(String, String, Any, Any)] = [
                ("pulse", "borderColor", fg.withAlphaComponent(0.10).cgColor, fg.withAlphaComponent(0.28).cgColor),
                ("pulse-width", "borderWidth", 1.0, 1.5),
            ]
            for (key, path, from, to) in pulses {
                let animation = CABasicAnimation(keyPath: path)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = 1.2
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                blockLayer.add(animation, forKey: key)
            }
            return
        }
        shimmer.colors = [
            NSColor.clear.cgColor,
            fg.withAlphaComponent(0.09).cgColor,
            NSColor.clear.cgColor,
        ]
        for (key, path, from, to) in [
            ("sweep", "startPoint", CGPoint(x: 1.2, y: 0.59), CGPoint(x: -0.8, y: 0.59)),
            ("sweep-end", "endPoint", CGPoint(x: 2.185, y: 0.416), CGPoint(x: 0.185, y: 0.416)),
        ] {
            let animation = CABasicAnimation(keyPath: path)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = 1.6
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shimmer.add(animation, forKey: key)
        }
        shimmer.isHidden = false
    }

    @MainActor
    private struct Geometry {
        let bounds: CGRect
        let clip: CGRect
        let width: CGFloat
        let height: CGFloat
        let offset: Int
        let rows: Int
        let fraction: Double
        let scale: CGFloat

        init?(pane: PaneView, viewport: PaneView.ScrollPosition) {
            let height = pane.cell.height
            guard height > 0 else { return nil }
            bounds = pane.bounds
            width = pane.cell.width
            self.height = height
            offset = viewport.offset
            rows = viewport.rows
            fraction = viewport.fraction
            scale = pane.window?.backingScaleFactor ?? 2
            clip = CGRect(x: 0, y: pane.renderInsets.bottom, width: pane.bounds.width,
                          height: max(0, pane.bounds.height - pane.renderInsets.top - pane.renderInsets.bottom))
        }

        func row(_ row: Int, _ columns: ClosedRange<Int>) -> CGRect {
            CGRect(x: CGFloat(columns.lowerBound) * width,
                   y: clip.maxY - (CGFloat(row - offset + 1) - fraction) * height,
                   width: CGFloat(columns.count) * width, height: height)
        }

        func block(_ block: Paragraphs.Block) -> CGRect {
            let cell = row(block.rows.upperBound, block.firstColumn...block.lastColumn)
            return horizontal(CGRect(x: cell.minX - 3, y: cell.minY - 1, width: cell.width + 6,
                                     height: CGFloat(block.rows.count) * height + 2))
        }

        func option(_ span: Paragraphs.Span) -> CGRect {
            let cell = row(span.row, span.columns)
            return horizontal(CGRect(x: cell.minX - 2, y: cell.minY, width: cell.width + 4, height: height))
        }

        private func horizontal(_ rect: CGRect) -> CGRect {
            var rect = rect
            let minX = clip.minX + 0.5
            let maxX = clip.maxX - 0.5
            if rect.minX < minX {
                rect.size.width -= minX - rect.minX
                rect.origin.x = minX
            }
            if rect.maxX > maxX {
                rect.size.width = maxX - rect.origin.x
            }
            return rect
        }

        func row(atY y: CGFloat?) -> Int? {
            guard let y, y >= clip.minY, y <= clip.maxY else { return nil }
            let index = Int(floor((clip.maxY + CGFloat(fraction) * height - y) / height))
            return offset + min(rows - 1, max(0, index))
        }
    }
}

extension PaneParagraphs.State {
    var block: Paragraphs.Block? {
        switch self {
        case .off, .idle: nil
        case .analysing(let block), .tooLong(let block), .plain(let block), .failed(let block): block
        case .unavailable(let block, _), .answered(let block, _): block
        }
    }
}

#if KIDO_VISUAL
extension PaneParagraphs {
    var isOn: Bool { state != .off }

    var visualState: String {
        switch state {
        case .off: "off"
        case .idle: "idle"
        case .analysing: "analysing"
        case .tooLong: "too-long"
        case .unavailable: "unavailable"
        case .answered: "answered"
        case .plain: "plain"
        case .failed: "failed"
        }
    }

    var visualBlockFrame: CGRect? { blockLayer.isHidden ? nil : blockLayer.frame }
    var visualBlockText: String? { state.block?.text }
    var visualBlockRows: ClosedRange<Int>? { state.block?.rows }
    var visualGrowing: Bool { growing }
    var visualPresentationBlockFrame: CGRect { blockLayer.presentation()?.frame ?? blockLayer.frame }
    var visualOptionFrames: [CGRect] { optionLayers.filter { !$0.isHidden }.map(\.frame) }
    var visualCaption: String? { captionBox.isHidden ? nil : captionText.string as? String }
    var visualShimmering: Bool { effectActive && !shimmer.isHidden }
}
#endif
