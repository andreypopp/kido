import AppKit
import SidebarFeed
import XCTest
@testable import Kido

@MainActor
private final class ParagraphOverlayView: NSView {
    private let pane: PaneView

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: pane.bounds)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return }
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let image = NSImage(size: pane.bounds.size)
        image.addRepresentation(bitmap)
        image.draw(in: bounds)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        pane.paragraphs.layer.render(in: context)
    }
}

extension VisualTests {
    @MainActor
    private func paragraphSnapshotText() -> [String] {
        [
            "$ pi",
            "",
            "The fix is small: Prompt.deliver returns Error on an advertised",
            "but unavailable inbox instead of falling back to a paste.",
            "",
            "Should I also update the docs, or keep the change to the code only?",
            "",
            "How do you want the paste fallback handled?",
            "a) Shift-hover an option here to answer",
            "b) Remove the fallback entirely",
            "c) Keep it, but only when no inbox is advertised",
            "d) Ask me again after the tests run",
            "",
            "Which deployment window works for you?",
            "",
            "Waiting for your answer.",
        ]
    }

    @MainActor
    private func paragraphSnapshotOptions() -> [String] {
        ["Shift-hover an option here to answer", "Remove the fallback entirely",
         "Keep it, but only when no inbox is advertised", "Ask me again after the tests run"]
    }

    @MainActor
    private func paragraphSnapshotAnswer(_ pane: PaneView, row: Int, before: Int = 0, count: Int = 1,
                                         options: [String], isQuestion: Bool = true) -> ParagraphAnswer {
        let viewport = pane.paragraphViewport()!
        let context = Paragraphs.context(pane.paragraphRows(0..<viewport.total), first: 0, row: row)!
        let first = max(0, context.hovered - before)
        let last = min(context.paragraphs.count - 1, first + count - 1)
        return ParagraphAnswer(isQuestion: isQuestion, options: options,
                               firstLine: context.ranges[first].lowerBound + 1,
                               lastLine: context.ranges[last].upperBound + 1)
    }

    @MainActor
    private func paragraphFreeze(reduceMotion: Bool = false) {
        PaneParagraphs.visualFrozen = true
        PaneParagraphs.visualReduceMotion = reduceMotion
        PaneParagraphs.visualPhase = 0.5
    }

    @MainActor
    private func paragraphSnapshotStart(_ text: [String], height: CGFloat = 560, width: CGFloat? = nil) async throws -> PaneView {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in
            ParagraphModel.reset()
            PaneParagraphs.visualFrozen = false
            PaneParagraphs.visualReduceMotion = false
        }
        let pane = try await paragraphPane(height: height)
        if let width {
            window.setContentSize(NSSize(width: width, height: height))
            try await settle()
        }
        try await paragraphPaint(pane, text)
        return pane
    }

    @MainActor
    private func paragraphSnapshotPrepare(_ pane: PaneView, _ point: NSPoint) async throws {
        window.orderOut(nil)
        try await wait("snapshot window hidden", within: 2) { !self.window.isVisible }
        pane.paragraphs.setMode(on: true, pointer: pane.convert(point, from: nil))
    }

    @MainActor
    private func paragraphSnapshot(_ state: String, _ pane: PaneView, testName: String) async throws {
        try await wait("growth settled", within: 2) { !pane.paragraphs.visualGrowing }
        for theme in ["light", "dark"] {
            if theme == "dark" { try await darken() }
            if pane.paragraphs.visualState == "plain" {
                try await wait("plain faded", within: 2) { pane.paragraphs.visualBlockFrame == nil }
            }
            let view = ParagraphOverlayView(pane: pane)
            window.contentView?.addSubview(view)
            defer { view.removeFromSuperview() }
            try await snapshot("\(state)-\(theme)", testName: testName, view: view)
        }
    }

    @MainActor
    private func paragraphOptionPoint(_ pane: PaneView, _ option: Paragraphs.Option, segment: Int = 0) -> NSPoint {
        let span = option.spans[segment]
        return paragraphPoint(pane, row: span.row, column: (span.columns.lowerBound + span.columns.upperBound) / 2)
    }

    func testParagraphAnalysing() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        paragraphFreeze()
        let analyzer = paragraphAnalyzer()
        analyzer.gate = ParagraphGate()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 7, options: paragraphSnapshotOptions())
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 7, column: 2))
        try await wait("analysing", within: 2) { pane.paragraphs.visualState == "analysing" && analyzer.calls == 1 }
        try await paragraphSnapshot("analysing", pane, testName: #function)
        analyzer.gate?.release()
    }

    func testParagraphAnalysingReduceMotion() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        paragraphFreeze(reduceMotion: true)
        let analyzer = paragraphAnalyzer()
        analyzer.gate = ParagraphGate()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 7, options: paragraphSnapshotOptions())
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 7, column: 2))
        try await wait("pulse analysing", within: 2) { pane.paragraphs.visualState == "analysing" && analyzer.calls == 1 }
        let view = ParagraphOverlayView(pane: pane)
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        try await snapshot("analysing-pulse-light", view: view)
        analyzer.gate?.release()
    }

    func testParagraphOptions() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 7, options: paragraphSnapshotOptions())
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 7, column: 2))
        try await wait("answered", within: 2) { pane.paragraphs.visualState == "answered" }
        try await paragraphSnapshot("options", pane, testName: #function)
    }

    func testParagraphOptionHovered() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 7, options: paragraphSnapshotOptions())
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 7, column: 2))
        try await wait("answered for hover", within: 2) { pane.paragraphs.visualState == "answered" }
        let block = paragraphFindBlock(pane, containing: "How do you want")
        let option = try XCTUnwrap(Paragraphs.locate("Remove the fallback entirely", in: block))
        pane.paragraphs.pointerMoved(pane.convert(paragraphOptionPoint(pane, option), from: nil))
        try await paragraphSnapshot("option-hovered", pane, testName: #function)
    }

    func testParagraphInlineOptions() async throws {
        let text = [
            "$ pi",
            "",
            "Should I also update the docs, or keep the change to the code only?",
            "",
            "Waiting for your answer.",
        ]
        let pane = try await paragraphSnapshotStart(text)
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 2, options: ["update the docs", "keep the change to the code only"])
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 2, column: 2))
        try await wait("inline answered", within: 2) { pane.paragraphs.visualState == "answered" }
        let block = paragraphFindBlock(pane, containing: "Should I also update")
        let option = try XCTUnwrap(Paragraphs.locate("keep the change to the code only", in: block))
        pane.paragraphs.pointerMoved(pane.convert(paragraphOptionPoint(pane, option), from: nil))
        try await paragraphSnapshot("inline", pane, testName: #function)
    }

    func testParagraphNoOptions() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 13, options: [])
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 13, column: 2))
        try await wait("no options", within: 2) { pane.paragraphs.visualCaption == "No answer options found" }
        try await paragraphSnapshot("no-options", pane, testName: #function)
    }

    func testParagraphNotAQuestion() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 7, options: [], isQuestion: false)
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 7, column: 2))
        try await wait("plain fade", within: 2) { pane.paragraphs.visualBlockFrame == nil }
        try await paragraphSnapshot("not-a-question", pane, testName: #function)
    }

    @MainActor
    private func paragraphClick(_ pane: PaneView, _ option: String) async throws {
        let block = paragraphFindBlock(pane, containing: "How do you want")
        let located = try XCTUnwrap(Paragraphs.locate(option, in: block))
        XCTAssertTrue(pane.paragraphs.click(at: pane.convert(paragraphOptionPoint(pane, located), from: nil)))
    }

    @MainActor
    private func paragraphAnsweredWithProbe(_ pane: PaneView, _ reply: PromptProbe) async throws {
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 7, options: paragraphSnapshotOptions())
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 7, column: 2))
        try await wait("answered for click", within: 2) {
            pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing
        }
        installPrompt(reply)
    }

    func testParagraphSent() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        let probe = PromptProbe()
        probe.candidates = [candidate(pane: pane.pane, window: pane.windowID!, title: "kido-app")]
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: pane.pane, via: .inbox))))
        try await paragraphAnsweredWithProbe(pane, probe)
        try await paragraphClick(pane, "Remove the fallback entirely")
        try await wait("sent caption", within: 2) { pane.paragraphs.visualCaption == "Sent to @kido-app" }
        try await paragraphSnapshot("sent", pane, testName: #function)
    }

    func testParagraphFailed() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        let probe = PromptProbe()
        probe.candidates = [candidate(pane: pane.pane, window: pane.windowID!, title: "kido-app")]
        probe.reply = .success(.promptError("connection reset", .refused))
        try await paragraphAnsweredWithProbe(pane, probe)
        try await paragraphClick(pane, "Remove the fallback entirely")
        try await wait("failed caption", within: 2) { pane.paragraphs.visualCaption == "Not delivered: connection reset" }
        try await paragraphSnapshot("failed", pane, testName: #function)
    }

    func testParagraphNoAgent() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        let probe = PromptProbe()
        probe.candidates = []
        try await paragraphAnsweredWithProbe(pane, probe)
        try await paragraphClick(pane, "Remove the fallback entirely")
        try await wait("no agent caption", within: 2) {
            pane.paragraphs.visualCaption == "No agent in this window or session"
        }
        try await paragraphSnapshot("no-agent", pane, testName: #function)
    }

    func testParagraphTooLong() async throws {
        let pane = try await paragraphSnapshotStart((0..<61).map { "long line \($0)" }, height: 1600)
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 2, column: 2))
        try await wait("too long", within: 2) { pane.paragraphs.visualCaption == "Too long to analyse" }
        try await paragraphSnapshot("too-long", pane, testName: #function)
    }

    func testParagraphUnavailable() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        ParagraphModel.testAvailability = .unavailable("Turn on Apple Intelligence to analyse text")
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 7, column: 2))
        try await wait("unavailable", within: 2) { pane.paragraphs.visualState == "unavailable" }
        try await paragraphSnapshot("unavailable", pane, testName: #function)
    }

    func testParagraphCouldNotAnalyse() async throws {
        let pane = try await paragraphSnapshotStart(paragraphSnapshotText())
        let analyzer = paragraphAnalyzer()
        analyzer.failure = CancellationError()
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 7, column: 2))
        try await wait("could not analyse", within: 3) { pane.paragraphs.visualState == "failed" }
        try await paragraphSnapshot("could-not-analyse", pane, testName: #function)
    }

    func testParagraphWrappedOption() async throws {
        let text = [
            "$ pi",
            "",
            "Which reading of the format should the sidebar use?",
            "1. Keep pane_current_command and accept the confusion",
            "2. Use #{alternate_on} together with the OSC 133 command line",
            "3. Neither; wait for the fork fix",
        ]
        let pane = try await paragraphSnapshotStart(text, width: 460)
        let block = paragraphFindBlock(pane, containing: "Which reading")
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 2, options: [
            "Keep pane_current_command and accept the confusion",
            "Use #{alternate_on} together with the OSC 133 command line",
            "Neither; wait for the fork fix",
        ])
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: max(block.rows.lowerBound, pane.paragraphViewport()!.offset), column: 1))
        try await wait("wrapped answered", within: 2) { pane.paragraphs.visualState == "answered" }
        let wrapped = try XCTUnwrap(Paragraphs.locate("Use #{alternate_on} together with the OSC 133 command line", in: block))
        XCTAssertGreaterThan(wrapped.spans.count, 1)
        pane.paragraphs.pointerMoved(pane.convert(paragraphOptionPoint(pane, wrapped), from: nil))
        try await paragraphSnapshot("wrapped-option", pane, testName: #function)
    }

    func testParagraphCutBlock() async throws {
        var text = (0..<20).map { "preamble \($0)" }
        text += ["", "How do you want the paste fallback handled?"]
        text += paragraphSnapshotOptions().enumerated().map { "\(["a", "b", "c", "d"][$0.offset])) \($0.element)" }
        text += ["", "suffix"]
        text += (0..<40).map { "after \($0)" }
        let pane = try await paragraphSnapshotStart(text)
        try await paragraphScrollTo(pane, offset: 24)
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 24, options: paragraphSnapshotOptions())
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 24, column: 2))
        try await wait("cut unit", within: 2) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
        XCTAssertEqual(analyzer.calls, 1)
        try await paragraphSnapshot("cut-block", pane, testName: #function)
    }
}

extension VisualTests {
    func testParagraphGrownUnit() async throws {
        let pane = try await paragraphSnapshotStart(["intro", "", "Which approach?", "", "1. Keep the change", "2. Update the docs"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 2, count: 2, options: ["Keep the change", "Update the docs"])
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 2, column: 2))
        try await wait("grown unit", within: 2) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
        try await paragraphSnapshot("grown-unit", pane, testName: #function)
    }

    func testParagraphGrownUpward() async throws {
        let pane = try await paragraphSnapshotStart(["intro", "", "Which approach?", "", "1. Keep the change", "2. Update the docs"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 4, before: 1, count: 2, options: ["Keep the change", "Update the docs"])
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 4, column: 3))
        try await wait("grown upward", within: 2) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
        XCTAssertEqual(pane.paragraphs.visualBlockRows, 2...5)
        try await paragraphSnapshot("grown-upward", pane, testName: #function)
    }

    func testParagraphHoverMoved() async throws {
        let pane = try await paragraphSnapshotStart(
            ["First question?", "", "1. First answer", "", "Second question?", "", "1. Second answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.gate = ParagraphGate()
        analyzer.analysis = paragraphSnapshotAnswer(pane, row: 4, options: ["Second answer"])
        try await paragraphSnapshotPrepare(pane, paragraphPoint(pane, row: 0, column: 2))
        try await wait("first analysing", within: 2) { pane.paragraphs.visualState == "analysing" && analyzer.calls == 1 }
        pane.paragraphs.pointerMoved(pane.convert(paragraphPoint(pane, row: 4, column: 2), from: nil))
        try await wait("second analysing", within: 2) {
            pane.paragraphs.visualState == "analysing" && analyzer.calls == 2
                && pane.paragraphs.visualBlockText == "Second question?"
        }
        try await paragraphSnapshot("hover-moved", pane, testName: #function)
        analyzer.gate?.release()
    }
}
