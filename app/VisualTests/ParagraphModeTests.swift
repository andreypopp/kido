import AppKit
import GhosttyKit
import ParagraphTagger
import SidebarFeed
import TmuxControl
import XCTest
@testable import Kido

extension VisualTests {
    @MainActor
    func paragraphPane(height: CGFloat = 560) async throws -> PaneView {
        let pane = try await rawPane(height: height)
        window.acceptsMouseMovedEvents = true
        try await mouseWindow()
        return pane
    }

    @MainActor
    private func paragraphWrite(_ pane: PaneView, _ text: String, until marker: String) async throws {
        try await emit(pane, text, until: marker)
    }

    @MainActor
    private func paragraphEmit(_ pane: PaneView, _ text: String, until marker: String) async throws {
        try await command(["clear-history", "-t", pane.pane.description])
        try await paragraphWrite(pane, text, until: marker)
    }

    @MainActor
    private func paragraphFlags(_ pane: PaneView, _ flags: NSEvent.ModifierFlags, code: UInt16 = 56) {
        let event = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code)!
        pane.flagsChanged(with: event)
    }

    @MainActor
    private func paragraphMouse(_ pane: PaneView, _ type: NSEvent.EventType, _ point: NSPoint,
                                flags: NSEvent.ModifierFlags = []) {
        window.sendEvent(mouse(pane, type, at: pane.convert(point, from: nil), mods: flags))
    }

    @MainActor
    private func paragraphEnter(_ pane: PaneView, _ point: NSPoint) {
        paragraphMouse(pane, .mouseMoved, point)
        paragraphFlags(pane, [.shift])
    }

    @MainActor
    func paragraphPoint(_ pane: PaneView, row: Int, column: Int = 0) -> NSPoint {
        let viewport = pane.paragraphViewport()!
        let cell = pane.cell
        let y = pane.bounds.height - pane.renderInsets.top
            - (CGFloat(row - viewport.offset) + 0.5 - viewport.fraction) * cell.height
        return pane.convert(NSPoint(x: (CGFloat(column) + 0.5) * cell.width, y: y), to: nil)
    }

    @MainActor
    func paragraphFindBlock(_ pane: PaneView, containing text: String) -> Paragraphs.Block {
        Paragraphs.testBlocks(pane.paragraphRows(0..<pane.paragraphViewport()!.total))
            .first { $0.text.contains(text) }!
    }

    @MainActor
    private func paragraphBlock(_ pane: PaneView, row: Int) -> Paragraphs.Block {
        Paragraphs.testBlocks(pane.paragraphRows(0..<pane.paragraphViewport()!.total))
            .first { $0.rows.contains(row) }!
    }

    @MainActor
    private func paragraphAssertBlock(_ pane: PaneView, _ block: Paragraphs.Block, at point: NSPoint,
                                      _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let frame = pane.paragraphs.visualBlockFrame else {
            return XCTFail("no frame: \(message)", file: file, line: line)
        }
        XCTAssertEqual(frame.height, CGFloat(block.rows.count) * pane.cell.height + 2, accuracy: 0.01, message, file: file, line: line)
        XCTAssertTrue(frame.contains(pane.convert(point, from: nil)), "\(message): frame \(frame) misses the pointer", file: file, line: line)
    }

    func testShiftHoverQuestionOptionsAndClick() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphEmit(pane, "\u{1b}[2J\u{1b}[HWelcome\r\n\r\nWhich approach?\r\n\r\n1. Keep the change\r\n2. Update the docs\r\n", until: "Update the docs")
        let paragraph = paragraphBlock(pane, row: 2)
        XCTAssertEqual(paragraph.text, "Which approach?")
        let gate = ParagraphGate()
        var calls = 0
        ParagraphModel.testAnalyze = { @MainActor text in
            calls += 1
            await gate.wait()
            return ParagraphAnswer(isQuestion: true, options: ["Keep the change", "Update the docs"])
        }

        let point = paragraphPoint(pane, row: 2, column: 4)
        paragraphEnter(pane, point)
        XCTAssertEqual(pane.paragraphs.visualState, "analysing")
        paragraphAssertBlock(pane, paragraph, at: point, "block frame at once")
        XCTAssertTrue(pane.paragraphs.visualShimmering)
        try await wait("analysis started", within: 2) { calls == 1 }
        XCTAssertEqual(pane.paragraphs.visualState, "analysing")
        XCTAssertTrue(pane.paragraphs.visualOptionFrames.isEmpty)

        paragraphMouse(pane, .leftMouseDown, point)
        paragraphMouse(pane, .leftMouseUp, point)
        XCTAssertEqual(pane.paragraphs.visualState, "analysing")

        gate.release()
        try await wait("options located", within: 2) {
            pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing
                && pane.paragraphs.visualOptionFrames.count == 2
        }
        let grown = try XCTUnwrap(pane.paragraphs.visualBlockText)
        XCTAssertEqual(grown, "Which approach?\n\n1. Keep the change\n2. Update the docs")
        let keepPoint = paragraphPoint(pane, row: 4, column: 5)
        XCTAssertTrue(pane.paragraphs.cursorRects.contains { $0.contains(pane.convert(keepPoint, from: nil)) }, "option cursor rect")

        var requests: [RPCRequest] = []
        promptBoxes.request = { request, done in
            requests.append(request)
            switch request {
            case .prompt(_, nil, _):
                done(.success(.prompt(.candidates([
                    PromptCandidate(pane: pane.pane, session: SessionID(number: 0), window: pane.windowID!, title: "agent"),
                ]))))
            case .prompt(_, .some, _):
                done(.success(.prompt(.delivered(PromptDelivered(pane: pane.pane, via: .inbox)))))
            default:
                done(.failure(.terminal("unexpected request")))
            }
        }
        let sentBefore = connection.visualCommands.count
        let click = paragraphPoint(pane, row: 4, column: 5)
        paragraphMouse(pane, .leftMouseDown, click)
        paragraphMouse(pane, .leftMouseUp, click)
        try await wait("prompt resolved and delivered", within: 2) { requests.count == 2 }
        guard requests.count == 2 else { return XCTFail("no prompt requests: \(requests)") }
        XCTAssertEqual(requests[0], .prompt(pane: pane.pane, text: nil, target: nil))
        XCTAssertEqual(requests[1], .prompt(pane: pane.pane,
            text: "> Which approach?\n> \n> 1. Keep the change\n> 2. Update the docs\n\nKeep the change", target: pane.pane))
        try await wait("sent caption", within: 2) { pane.paragraphs.visualCaption == "Sent to @agent" }
        XCTAssertEqual(pane.paragraphs.visualState, "answered")
        XCTAssertNil(pane.copyMode)
        let sent = connection.visualCommands.dropFirst(sentBefore).filter { $0.line.hasPrefix("send-keys") }
        XCTAssertTrue(sent.isEmpty, "a click on an option reaches no program: \(sent.map(\.line))")

        paragraphFlags(pane, [])
        XCTAssertEqual(pane.paragraphs.visualState, "off")
        XCTAssertNil(pane.paragraphs.visualBlockFrame)
    }
}

@MainActor
final class ParagraphGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

@MainActor
final class ParagraphAnalyzer {
    var calls = 0
    var texts: [String] = []
    var gate: ParagraphGate?
    var failure: Error?
    var analysis = ParagraphAnswer(isQuestion: true, options: [])

    func install() {
        ParagraphModel.testAnalyze = { [weak self] text in
            guard let self else { throw CancellationError() }
            self.calls += 1
            self.texts.append(text)
            if let gate = self.gate { await gate.wait() }
            if let failure = self.failure { throw failure }
            return self.analysis
        }
    }
}

extension VisualTests {
    @MainActor
    func paragraphPaint(_ pane: PaneView, _ lines: [String]) async throws {
        try await paragraphEmit(pane, "\u{1b}[2J\u{1b}[H" + lines.joined(separator: "\r\n") + "\r\n", until: lines.last ?? "")
    }

    @MainActor
    func paragraphAnalyzer() -> ParagraphAnalyzer {
        let analyzer = ParagraphAnalyzer()
        analyzer.install()
        return analyzer
    }

    @MainActor
    private func paragraphAnswered(_ pane: PaneView, row: Int) async throws {
        let point = paragraphPoint(pane, row: row, column: 2)
        paragraphEnter(pane, point)
        try await wait("answered", within: 2) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
    }

    @MainActor
    func paragraphScrollTo(_ pane: PaneView, offset: Int) async throws {
        let viewport = pane.paragraphViewport()!
        pane.visualScroll(Double(viewport.total - viewport.len - offset))
        try await wait("row \(offset) visible", within: 2) {
            guard let viewport = pane.paragraphViewport() else { return false }
            return viewport.offset <= offset && offset < viewport.offset + viewport.len
                && pane.wheelDistance.map { $0 == $0.rounded() } == true
        }
    }

    func testNegativeShiftAndClickControls() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["intro 0", "intro 1", "intro 2", "", "Which approach?", "", "1. Keep the change", "2. Update the docs"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Keep the change", "Update the docs"])
        try await paragraphAnswered(pane, row: 4)
        XCTAssertEqual(analyzer.calls, 1)

        var prompted = 0
        promptBoxes.request = { _, done in
            prompted += 1
            done(.success(.prompt(.candidates([PromptCandidate(pane: pane.pane, session: SessionID(number: 0), window: pane.windowID!, title: "agent")]))))
        }
        let before = connection.visualCommands.count
        let question = paragraphPoint(pane, row: 4, column: 2)
        XCTAssertFalse(pane.paragraphs.cursorRects.contains { $0.contains(pane.convert(question, from: nil)) })
        paragraphMouse(pane, .leftMouseDown, question, flags: [.shift])
        paragraphMouse(pane, .leftMouseUp, question, flags: [.shift])
        try await wait("shift press elsewhere enters copy mode", within: 3) { pane.copyMode != nil }
        XCTAssertFalse(pane.paragraphs.isOn)
        XCTAssertEqual(prompted, 0)
        pane.endCopy()

        paragraphEnter(pane, question)
        try await wait("answered again", within: 2) { pane.paragraphs.visualState == "answered" }
        let originalMode = pane.onParagraphMode
        var modes: [Bool] = []
        pane.onParagraphMode = { modes.append($0) }
        paragraphFlags(pane, [])
        paragraphFlags(pane, [.command], code: 55)
        paragraphFlags(pane, [.command, .shift])
        XCTAssertEqual(modes, [false, false, false], "Cmd then Shift starts no mode")
        paragraphFlags(pane, [])
        paragraphFlags(pane, [.shift])
        XCTAssertEqual(modes.last, true, "Shift alone offers the mode")
        pane.onParagraphMode = originalMode
        paragraphEnter(pane, question)
        try await wait("answered for the shifted key", within: 2) { pane.paragraphs.visualState == "answered" }
        let typed = connection.visualCommands.count
        let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "A", charactersIgnoringModifiers: "A",
            isARepeat: false, keyCode: 0)!
        pane.keyDown(with: key)
        XCTAssertFalse(pane.paragraphs.isOn, "Shift+key ends the mode")
        try await wait("the shifted key reached tmux", within: 2) {
            self.connection.visualCommands.dropFirst(typed).contains { $0.line.hasPrefix("send-keys") }
        }
        XCTAssertGreaterThan(connection.visualCommands.count, typed)
        XCTAssertTrue(connection.visualCommands.dropFirst(before).filter { $0.line.hasPrefix("send-keys") }.count > 0)
    }

    func testStaleAnalysisNeverDrawsAfterRelease() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Stale question?", "", "1. An answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.gate = ParagraphGate()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["An answer"])
        let point = paragraphPoint(pane, row: 0, column: 2)
        paragraphEnter(pane, point)
        try await wait("analysis started", within: 2) { analyzer.calls == 1 }
        paragraphFlags(pane, [])
        analyzer.gate?.release()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(pane.paragraphs.visualState, "off")
        XCTAssertNil(pane.paragraphs.visualBlockFrame)
        XCTAssertTrue(pane.paragraphs.visualOptionFrames.isEmpty)
    }

    func testReflowAndFontFollowNewRows() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        let long = "Should the prompt box keep the change to the code only, or also update every design document and the release notes?"
        try await paragraphPaint(pane, [long, "", "1. Keep the change to the code only", "2. Update every design document"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Keep the change to the code only", "Update every design document"])
        try await paragraphAnswered(pane, row: 0)
        XCTAssertEqual(analyzer.calls, 1)
        let text = analyzer.texts[0]
        XCTAssertTrue(text.contains("Should the prompt box"), text)

        window.setContentSize(NSSize(width: 470, height: 560))
        try await settle()
        let block = paragraphFindBlock(pane, containing: "Should the prompt box")
        XCTAssertTrue(block.text.hasPrefix("Should the prompt box"), "wrapped rows join after reflow")
        let point = paragraphPoint(pane, row: max(block.rows.lowerBound, pane.paragraphViewport()!.offset), column: 4)
        paragraphMouse(pane, .mouseMoved, point)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pane.paragraphs.visualState, "answered",
                       "after resize viewport=\(pane.paragraphViewport()!) block=\(block.rows) point=\(pane.convert(point, from: nil)) bounds=\(pane.bounds)")
        XCTAssertTrue(pane.paragraphs.isOn, "the mode survives a resize")
        XCTAssertEqual(analyzer.calls, 1, "reflow reuses the cached analysis")
        let reflowRows = try XCTUnwrap(pane.paragraphs.visualBlockRows)
        let reflowFrame = try XCTUnwrap(pane.paragraphs.visualBlockFrame)
        XCTAssertEqual(reflowFrame.height, CGFloat(reflowRows.count) * pane.cell.height + 2, accuracy: 0.01, "reflowed block frame")
        XCTAssertTrue(reflowFrame.contains(pane.convert(point, from: nil)), "reflowed block misses the pointer")

        let height = pane.cell.height
        _ = ghostty_surface_binding_action(pane.surface, "increase_font_size:1", 20)
        try await wait("font grew", within: 5) { pane.cell.height > height }
        try await settle()
        let fontBlock = paragraphFindBlock(pane, containing: "Should the prompt box")
        paragraphMouse(pane, .mouseMoved, paragraphPoint(
            pane, row: max(fontBlock.rows.lowerBound, pane.paragraphViewport()!.offset), column: 4))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pane.paragraphs.visualState, "answered", "after the font change")
        XCTAssertEqual(analyzer.calls, 1, "a font change reuses the cached analysis")
        let fontPoint = paragraphPoint(pane, row: max(fontBlock.rows.lowerBound, pane.paragraphViewport()!.offset), column: 4)
        let fontRows = try XCTUnwrap(pane.paragraphs.visualBlockRows)
        let fontFrame = try XCTUnwrap(pane.paragraphs.visualBlockFrame)
        XCTAssertEqual(fontFrame.height, CGFloat(fontRows.count) * pane.cell.height + 2, accuracy: 0.01, "font block frame")
        XCTAssertTrue(fontFrame.contains(pane.convert(fontPoint, from: nil)), "font block misses the pointer")
        _ = ghostty_surface_binding_action(pane.surface, "reset_font_size", 15)
    }

    func testHistoryPrependKeepsFramesOnContent() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["", "Prepend question?", "", "1. An answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["An answer"])
        try await paragraphAnswered(pane, row: 1)
        let frame = pane.paragraphs.visualBlockFrame
        let history = pane.scrollPosition().retainedHistoryRows
        guard pane.prepend(Data("\u{1b}[molder-a\r\nolder-b".utf8), epoch: pane.historyEpoch) > 0 else {
            return XCTFail("prepend refused")
        }
        try await wait("history prepended", within: 3) { pane.scrollPosition().retainedHistoryRows == history + 2 }
        try await wait("prepend answered", within: 2) { pane.paragraphs.visualState == "answered" }
        XCTAssertEqual(pane.paragraphs.visualBlockFrame, frame, "prepended history keeps frames on content")
        XCTAssertEqual(analyzer.calls, 1)
    }

    func testAlternateScreenSwitchClearsTheOverlay() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Nothing here"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Alt answer"])
        try await paragraphWrite(pane, "\u{1b}[?1049h", until: "")
        try await wait("alternate screen", within: 3) { pane.alternate }
        try await paragraphWrite(pane, "\u{1b}[2J\u{1b}[HAlternate question?\r\n\r\n1. Alt answer\r\n", until: "Alt answer")
        try await paragraphAnswered(pane, row: 0)
        XCTAssertEqual(pane.paragraphs.visualState, "answered")
        XCTAssertEqual(analyzer.calls, 1)
        try await paragraphWrite(pane, "\u{1b}[?1049l", until: "")
        try await wait("primary screen", within: 3) { !pane.alternate }
        try await wait("screen switch cleared state", within: 2) { pane.paragraphs.visualState == "idle" }
        XCTAssertNil(pane.paragraphs.visualBlockFrame)
        XCTAssertTrue(pane.paragraphs.isOn, "the mode stays on across a screen switch")
    }

    func testPartialBlockQuotesTheWholeBlock() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        var lines = (0..<20).map { "before \($0)" }
        lines += ["", "What is above?", "", "- detail one", "- detail two", "- detail three", "- detail four",
                  "1. First choice", "2. Second choice", "extra detail one", "extra detail two", "extra detail three", ""]
        lines += (0..<40).map { "after \($0)" }
        try await paragraphPaint(pane, lines)
        let analyzer = paragraphAnalyzer()
        let total = pane.paragraphViewport()!.total
        let context = Paragraphs.context(pane.paragraphRows(0..<total), first: 0, row: 23)!
        let question = context.paragraphs.firstIndex { $0.text == "What is above?" }!
        let list = context.paragraphs.firstIndex { $0.text.hasPrefix("- detail one") }!
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["First choice", "Second choice"],
                                             firstLine: context.lineNumbers(question).lowerBound,
                                             lastLine: context.lineNumbers(list).upperBound)
        try await paragraphScrollTo(pane, offset: 22)
        let viewport = pane.paragraphViewport()!
        try await paragraphAnswered(pane, row: 23)
        let unitRows = try XCTUnwrap(pane.paragraphs.visualBlockRows)
        XCTAssertEqual(unitRows, 21...31)
        XCTAssertLessThan(unitRows.lowerBound, viewport.offset, "the unit starts above the viewport")
        XCTAssertTrue(pane.paragraphs.visualBlockText?.hasPrefix("What is above?") == true)
        var requests: [RPCRequest] = []
        promptBoxes.request = { request, done in
            requests.append(request)
            switch request {
            case .prompt(_, nil, _):
                done(.success(.prompt(.candidates([PromptCandidate(pane: pane.pane, session: SessionID(number: 0), window: pane.windowID!, title: "agent")]))))
            case .prompt(_, .some, _):
                done(.success(.prompt(.delivered(PromptDelivered(pane: pane.pane, via: .inbox)))))
            default:
                done(.failure(.terminal("unexpected request")))
            }
        }
        let rect = try XCTUnwrap(pane.paragraphs.cursorRects.first)
        let point = pane.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        paragraphMouse(pane, .leftMouseDown, point)
        paragraphMouse(pane, .leftMouseUp, point)
        try await wait("partial block sent", within: 2) { requests.count == 2 }
        guard requests.count == 2 else { return XCTFail("no prompt requests") }
        let payload = RPCRequest.quote(try XCTUnwrap(pane.paragraphs.visualBlockText)) + "\n\nFirst choice"
        XCTAssertTrue(payload.hasPrefix("> What is above?"), payload)
        XCTAssertEqual(requests[1], .prompt(pane: pane.pane, text: payload, target: pane.pane))
    }

    func testTooLongBlockIsHighlightedButNotAnalysed() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, (0..<61).map { "long line \($0)" })
        let analyzer = paragraphAnalyzer()
        let row = pane.paragraphViewport()!.offset + 2
        paragraphEnter(pane, paragraphPoint(pane, row: row, column: 2))
        try await wait("too long", within: 2) { pane.paragraphs.visualState == "too-long" }
        XCTAssertEqual(pane.paragraphs.visualCaption, "Too long to analyse")
        XCTAssertNotNil(pane.paragraphs.visualBlockFrame)
        XCTAssertTrue(pane.paragraphs.visualOptionFrames.isEmpty)
        XCTAssertEqual(analyzer.calls, 0)
    }

    func testModelLoadFailureHasItsOwnCaption() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Which approach?", "", "1. Keep the change"])
        ParagraphModel.testAnalyze = { _ in throw ParagraphTaggerError.loadFailed }
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 2))
        try await wait("failed load", within: 3) { pane.paragraphs.visualState == "failed" }
        XCTAssertEqual(pane.paragraphs.visualCaption, "Paragraph model failed to load")
    }

    func testFailedAnalysisIsNotCached() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Failing question?", "", "1. An answer", "", "Other question?", "", "1. Another answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.failure = CancellationError()
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 2))
        try await wait("failed analysis", within: 3) { pane.paragraphs.visualState == "failed" }
        XCTAssertEqual(pane.paragraphs.visualCaption, "Could not analyse this block")
        XCTAssertEqual(analyzer.calls, 1)

        paragraphFlags(pane, [])
        paragraphEnter(pane, paragraphPoint(pane, row: 4, column: 2))
        try await wait("second failure", within: 3) { pane.paragraphs.visualState == "failed" && analyzer.calls == 2 }

        paragraphFlags(pane, [])
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 2))
        try await wait("a failure is not cached", within: 3) { analyzer.calls == 3 }
    }
}


extension VisualTests {
    @MainActor
    private func paragraphSplit(_ pane: PaneView) async throws -> PaneView {
        _ = try await command(["split-window", "-h", "-t", "visual", "exec /bin/cat"])
        try await wait("split pane", within: 2) { self.terminal?.panes.count == 2 }
        try await settle()
        return try XCTUnwrap(terminal?.panes.first { $0 !== pane })
    }

    @MainActor
    private func paragraphDividerPoint() throws -> NSPoint {
        let layout = try XCTUnwrap(terminal).visualLayout
        let rects = layout.split(separator: "\n").filter { $0.hasPrefix("divider=") }.compactMap { line -> CGRect? in
            let values = line.dropFirst("divider=".count).split(separator: ",").compactMap { Double($0) }
            guard values.count == 4, values[3] > values[2] else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        let rect = try XCTUnwrap(rects.first)
        return try XCTUnwrap(terminal).convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    func testPlainTypingDoesNotSuppressTheNextShift() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Typing question?", "", "1. An answer"])
        let original = pane.onParagraphMode
        var modes: [Bool] = []
        pane.onParagraphMode = { modes.append($0) }
        paragraphFlags(pane, [])
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "a",
                                   charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        pane.keyDown(with: key)
        paragraphFlags(pane, [.shift])
        XCTAssertEqual(modes.last, true, "plain typing must not suppress the next Shift")
        pane.onParagraphMode = original
        paragraphFlags(pane, [])
    }

    func testFractionalViewportHitTestsTheSameRow() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        var lines = ["A one", "A two", "", "B one", "B two", ""]
        lines += (0..<40).map { "filler \($0)" }
        try await paragraphPaint(pane, lines)
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: [])
        let retained = pane.paragraphViewport()!.retainedHistoryRows
        pane.visualScroll(Double(retained) - 0.75)
        try await wait("fractional top", within: 2) {
            guard let viewport = pane.paragraphViewport() else { return false }
            return viewport.offset == 0 && abs(viewport.fraction - 0.75) < 0.001
        }
        let point = paragraphPoint(pane, row: 3, column: 1)
        paragraphEnter(pane, point)
        try await wait("the drawn row is selected", within: 2) { pane.paragraphs.visualState == "answered" }
        XCTAssertTrue(analyzer.texts.last?.contains("> 4: B one\n> 5: B two") == true,
                      "the pointer hit-tests the row drawn under it: \(analyzer.texts.last ?? "none")")
    }

    func testShiftFollowsThePointerIntoAnotherPane() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        let other = try await paragraphSplit(pane)
        try await paragraphPaint(pane, ["First question?", "", "1. First answer"])
        try await paragraphPaint(other, ["Second question?", "", "1. Second answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["First answer"])
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 1))
        try await wait("first pane mode", within: 2) { pane.paragraphs.isOn && !other.paragraphs.isOn }
        paragraphMouse(other, .mouseMoved, paragraphPoint(other, row: 0, column: 1))
        try await wait("mode follows the pointer", within: 2) { other.paragraphs.isOn && !pane.paragraphs.isOn }
        paragraphFlags(other, [])
    }

    func testCopyModePaneRefusesTheMode() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        let other = try await paragraphSplit(pane)
        try await paragraphPaint(other, ["Copy mode question?", "", "1. An answer"])
        other.toggleCopyMode(nil)
        try await wait("other pane in copy mode", within: 3) { other.copyMode != nil }
        paragraphMouse(other, .mouseMoved, paragraphPoint(other, row: 0, column: 1))
        paragraphFlags(other, [.shift])
        XCTAssertFalse(other.paragraphs.isOn)
        XCTAssertFalse(pane.paragraphs.isOn)
        paragraphFlags(other, [])
        other.endCopy()
    }

    func testOverlayClipsToTheTerminalRows() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Band question?", "", "1. Band answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Band answer"])
        pane.renderInsets = .init(top: 40, bottom: 30)
        pane.paragraphs.viewportChanged()
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 1))
        try await wait("band answered", within: 2) { pane.paragraphs.visualState == "answered" }
        try await wait("clipped options", within: 2) { !pane.paragraphs.cursorRects.isEmpty }
        let clip = CGRect(x: 0, y: 30, width: pane.bounds.width, height: pane.bounds.height - 70)
        for rect in pane.paragraphs.cursorRects {
            XCTAssertTrue(clip.contains(rect), "option rect \\(rect) outside the terminal rows")
        }
        var prompted = 0
        promptBoxes.request = { _, done in
            prompted += 1
            done(.success(.prompt(.candidates([]))))
        }
        let option = try XCTUnwrap(pane.paragraphs.cursorRects.first)
        let band = pane.convert(NSPoint(x: option.midX, y: clip.maxY + 5), to: nil)
        paragraphMouse(pane, .leftMouseDown, band)
        paragraphMouse(pane, .leftMouseUp, band)
        XCTAssertEqual(prompted, 0, "a click in the top band never hits a clipped option")
    }

    func testPlainFadeDoesNotHideANewBlock() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Plain first", "", "Second question?", "", "1. Second answer"])
        ParagraphModel.testAnalyze = { @MainActor text in
            if text.contains("> 3: Second question?") { return ParagraphAnswer(isQuestion: true, options: ["Second answer"]) }
            return ParagraphAnswer(isQuestion: false, options: [])
        }
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 1))
        try await wait("plain fade", within: 2) { pane.paragraphs.visualState == "plain" }
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 2, column: 1))
        try await wait("new block answered", within: 2) { pane.paragraphs.visualState == "answered" }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(pane.paragraphs.visualState, "answered")
        XCTAssertNotNil(pane.paragraphs.visualBlockFrame, "the old fade completion must not hide the new block")
    }

    func testStartingADividerDragEndsTheMode() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        _ = try await paragraphSplit(pane)
        try await paragraphPaint(pane, ["Drag question?", "", "1. An answer"])
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 1))
        try await wait("mode before drag", within: 2) { pane.paragraphs.isOn }
        let point = try paragraphDividerPoint()
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        let windowView = try XCTUnwrap(terminal)
        windowView.mouseDown(with: down)
        XCTAssertTrue(windowView.visualDividerDragging,
                      "the press starts a divider drag at \(point); \(windowView.visualLayout)")
        XCTAssertFalse(pane.paragraphs.isOn, "a divider drag ends the mode")
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                    clickCount: 1, pressure: 0)!
        try XCTUnwrap(terminal).mouseUp(with: up)
        paragraphFlags(pane, [])
    }

    func testClickCommitsTheSendAcrossShiftRelease() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Committed question?", "", "1. Committed answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Committed answer"])
        try await paragraphAnswered(pane, row: 0)
        let probe = PromptProbe()
        probe.candidates = [candidate(pane: pane.pane, window: pane.windowID!, title: "agent")]
        probe.holdResolve = true
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: pane.pane, via: .inbox))))
        installPrompt(probe)
        let option = pane.paragraphs.cursorRects[0]
        let point = pane.convert(NSPoint(x: option.midX, y: option.midY), to: nil)
        paragraphMouse(pane, .leftMouseDown, point)
        paragraphMouse(pane, .leftMouseUp, point)
        try await wait("resolve held", within: 2) { probe.requests.count == 1 }
        paragraphFlags(pane, [])
        XCTAssertFalse(pane.paragraphs.isOn)
        probe.holdResolve = false
        probe.releaseResolve(.success(.prompt(.candidates(probe.candidates))))
        try await wait("the send survives the release", within: 2) { probe.sends.count == 1 }
        XCTAssertEqual(probe.sends[0], .prompt(pane: pane.pane,
            text: "> Committed question?\n> \n> 1. Committed answer\n\nCommitted answer", target: pane.pane))
        XCTAssertFalse(pane.paragraphs.isOn)
    }

    func testUnknownSendResultSaysItMayHaveArrived() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Unknown question?", "", "1. Unknown answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Unknown answer"])
        try await paragraphAnswered(pane, row: 0)
        let probe = PromptProbe()
        probe.candidates = [candidate(pane: pane.pane, window: pane.windowID!, title: "agent")]
        probe.reply = .success(.promptError("timed out", .unknown))
        installPrompt(probe)
        let option = pane.paragraphs.cursorRects[0]
        let point = pane.convert(NSPoint(x: option.midX, y: option.midY), to: nil)
        paragraphMouse(pane, .leftMouseDown, point)
        paragraphMouse(pane, .leftMouseUp, point)
        try await wait("unknown caption", within: 2) {
            pane.paragraphs.visualCaption == "timed out It may have arrived; not resent."
        }
        paragraphFlags(pane, [])
    }
}

extension VisualTests {
    func testHeldShiftHeavyOutputKeepsTheAnalysis() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        var lines = (0..<30).map { "preamble \($0)" }
        lines += ["", "Heavy question?", "", "1. Heavy answer", ""]
        lines += (0..<30).map { "suffix \($0)" }
        try await paragraphPaint(pane, lines)
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Heavy answer"])
        try await paragraphScrollTo(pane, offset: 29)
        try await paragraphAnswered(pane, row: 31)
        let reads = pane.paragraphRowReads
        let fullWindow = pane.paragraphViewport()!.len + 400
        try await paragraphWrite(pane, (0..<30).map { "\r\nheavy \($0)" }.joined() + "\r\nheavy-end", until: "heavy-end")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(analyzer.calls, 1, "heavy output starts no new analysis")
        XCTAssertEqual(pane.paragraphs.visualState, "answered", "heavy output keeps the hovered analysis")
        XCTAssertLessThan(pane.paragraphRowReads - reads, fullWindow, "refreshes read outward, not the whole window")
    }
}

extension VisualTests {
    @MainActor
    private func paragraphRender(_ layer: CALayer, scale: CGFloat) -> CGContext? {
        let width = Int((layer.bounds.width * scale).rounded())
        let height = Int((layer.bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context
    }

    @MainActor
    private func paragraphAlpha(_ context: CGContext, _ rect: CGRect, height: CGFloat, scale: CGFloat) -> UInt8 {
        guard let data = context.data else { return 0 }
        var maximum: UInt8 = 0
        for area in [rect, CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)] {
            for y in stride(from: Int(area.minY * scale), through: Int(area.maxY * scale), by: 2) {
                for x in stride(from: Int(area.minX * scale), through: Int(area.maxX * scale), by: 2) {
                    guard x >= 0, y >= 0, x < context.width, y < context.height else { continue }
                    maximum = Swift.max(maximum, data.load(fromByteOffset: y * context.bytesPerRow + x * 4 + 3, as: UInt8.self))
                }
            }
        }
        return maximum
    }

    func testOverlayIsCompositedAboveTheTerminal() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Overlay question?", "", "1. Overlay answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Overlay answer"])
        try await paragraphAnswered(pane, row: 0)
        pane.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let overlay = pane.paragraphs.layer
        let terminal = try XCTUnwrap(pane.subviews.first?.layer)
        let ordered = try XCTUnwrap(pane.layer?.sublayers)
        let mask = try XCTUnwrap(overlay.mask as? CAShapeLayer)
        let block = try XCTUnwrap(pane.paragraphs.visualBlockFrame)
        let option = try XCTUnwrap(pane.paragraphs.visualOptionFrames.first)
        let scale: CGFloat = 2
        let height = overlay.bounds.height

        XCTAssertTrue(ordered.contains { $0 === overlay }, "the overlay is not in the pane's layer")
        XCTAssertTrue(ordered.contains { $0 === terminal }, "the terminal layer is not in the pane's layer")
        XCTAssertGreaterThan(overlay.zPosition, terminal.zPosition,
                             "the overlay is not above the terminal layer: \(ordered.map { "\(type(of: $0)) z=\($0.zPosition)" })")
        XCTAssertGreaterThan(mask.bounds.width, 0, "the clip mask has no width")
        XCTAssertGreaterThan(mask.bounds.height, 0, "the clip mask has no height")
        XCTAssertNotNil(mask.path, "the clip mask has no path")
        XCTAssertEqual(overlay.opacity, 1)
        XCTAssertFalse(overlay.isHidden)

        let context = try XCTUnwrap(paragraphRender(overlay, scale: scale), "the overlay renders no bitmap")
        XCTAssertGreaterThan(paragraphAlpha(context, option, height: height, scale: scale), 0,
                             "the option fill renders transparent")
        XCTAssertGreaterThan(paragraphAlpha(context, block, height: height, scale: scale), 0,
                             "the block fill renders transparent")
    }
}


extension VisualTests {
    @MainActor
    private func paragraphUnitAnswer(_ pane: PaneView, row: Int, _ unit: [String], options: [String]) -> ParagraphAnswer {
        let viewport = pane.paragraphViewport()!
        let context = Paragraphs.context(pane.paragraphRows(0..<viewport.total), first: 0, row: row)!
        let indices = unit.map { text in context.paragraphs.firstIndex { $0.text == text }! }
        let first = indices.min()!
        let last = indices.max()!
        return ParagraphAnswer(isQuestion: true, options: options,
                                 firstLine: context.lineNumbers(first).lowerBound,
                                 lastLine: context.lineNumbers(last).upperBound)
    }

    func testUnitGrowsToTheListAfterTheQuestion() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["intro", "", "Which approach?", "", "1. Keep the change", "2. Update the docs"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphUnitAnswer(pane, row: 2, ["Which approach?", "1. Keep the change\n2. Update the docs"],
                                                options: ["Keep the change", "Update the docs"])
        paragraphEnter(pane, paragraphPoint(pane, row: 2, column: 2))
        try await wait("question analysing", within: 2) { pane.paragraphs.visualState == "analysing" }
        let before = try XCTUnwrap(pane.paragraphs.visualBlockFrame)
        XCTAssertEqual(before.height, pane.cell.height + 2, accuracy: 0.01, "the paragraph rect while analysing")
        try await wait("unit answered", within: 2) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
        let after = try XCTUnwrap(pane.paragraphs.visualBlockFrame)
        XCTAssertEqual(pane.paragraphs.visualBlockText, "Which approach?\n\n1. Keep the change\n2. Update the docs")
        XCTAssertEqual(after.height, 4 * pane.cell.height + 2, accuracy: 0.01, "the grown unit rect")
        XCTAssertGreaterThan(after.height, before.height)
        XCTAssertEqual(pane.paragraphs.visualOptionFrames.count, 2)
        XCTAssertEqual(analyzer.calls, 1)
    }

    func testUnitGrowsUpwardWhenTheListParagraphIsHovered() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["intro", "", "Which approach?", "", "1. Keep the change", "2. Update the docs"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphUnitAnswer(pane, row: 4, ["Which approach?", "1. Keep the change\n2. Update the docs"],
                                                options: ["Keep the change", "Update the docs"])
        try await paragraphAnswered(pane, row: 4)
        XCTAssertEqual(pane.paragraphs.visualBlockText, "Which approach?\n\n1. Keep the change\n2. Update the docs")
        XCTAssertEqual(pane.paragraphs.visualBlockRows, 2...5)
        XCTAssertEqual(analyzer.calls, 1)
    }

    func testHoverInsideTheUnitKeepsIt() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["intro", "", "Which approach?", "", "1. Keep the change", "2. Update the docs"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphUnitAnswer(pane, row: 2, ["Which approach?", "1. Keep the change\n2. Update the docs"],
                                                options: ["Keep the change", "Update the docs"])
        try await paragraphAnswered(pane, row: 2)
        XCTAssertEqual(analyzer.calls, 1)
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 5, column: 3))
        try await wait("hover inside the unit", within: 2) { pane.paragraphs.visualState == "answered" }
        XCTAssertEqual(analyzer.calls, 1, "hovering another paragraph of the unit starts no analysis")
        XCTAssertEqual(pane.paragraphs.visualBlockText, "Which approach?\n\n1. Keep the change\n2. Update the docs")
    }

    func testScrollAfterGrowthKeepsFramesOnContent() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        var lines = (0..<30).map { "preamble \($0)" }
        lines += ["", "Still a question?", "", "1. First answer", "2. Second answer", "3. Third answer", "4. Fourth answer", ""]
        lines += (0..<30).map { "suffix \($0)" }
        try await paragraphPaint(pane, lines)
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphUnitAnswer(pane, row: 31, ["Still a question?", "1. First answer\n2. Second answer\n3. Third answer\n4. Fourth answer"],
                                                options: ["First answer", "Second answer"])
        try await paragraphScrollTo(pane, offset: 31)
        try await paragraphAnswered(pane, row: 31)
        let frame = try XCTUnwrap(pane.paragraphs.visualBlockFrame)
        let start = try XCTUnwrap(pane.wheelDistance)
        pane.visualScroll(start + 1)
        try await wait("row scroll applied", within: 2) {
            pane.wheelDistance.map { $0 == $0.rounded() && $0 > start } == true
        }
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 31, column: 2))
        try await wait("scroll keeps the unit", within: 2) { pane.paragraphs.visualState == "answered" }
        let moved = try XCTUnwrap(pane.paragraphs.visualBlockFrame)
        XCTAssertEqual(moved.minY - frame.minY, -(try XCTUnwrap(pane.wheelDistance) - start) * pane.cell.height,
                       accuracy: 0.01, "the frames follow the content")
        XCTAssertEqual(pane.paragraphs.visualBlockText, "Still a question?\n\n1. First answer\n2. Second answer\n3. Third answer\n4. Fourth answer")
        XCTAssertEqual(analyzer.calls, 1)
    }

    func testNumberedQuestionsAreThreeUnitsAndQuoteOnlyTheirOwn() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        let lines = [
            "1. What do you want me to review?",
            "   - a) A design document in docs/. Which one?",
            "   - b) The uncommitted changes in app/, compared with",
            "     docs/design-app.md and docs/design-rpc.md.",
            "",
            "2. What type of review do you want?",
            "   - Correctness: does the design break invariants?",
            "   - Completeness: does it have gaps?",
            "",
            "3. Output: Do you want only a list of findings?",
        ]
        try await paragraphPaint(pane, lines)
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphUnitAnswer(pane, row: 0, ["1. What do you want me to review?\n   - a) A design document in docs/. Which one?\n   - b) The uncommitted changes in app/, compared with\n     docs/design-app.md and docs/design-rpc.md."], options: ["A design document in docs/. Which one?"])
        try await paragraphAnswered(pane, row: 0)
        XCTAssertEqual(analyzer.calls, 1)
        XCTAssertTrue(pane.paragraphs.visualBlockText?.hasPrefix("1. What do you want") == true)
        paragraphFlags(pane, [])
        analyzer.analysis = paragraphUnitAnswer(pane, row: 5, ["2. What type of review do you want?\n   - Correctness: does the design break invariants?\n   - Completeness: does it have gaps?"], options: ["Correctness: does the design break invariants?"])
        paragraphEnter(pane, paragraphPoint(pane, row: 5, column: 2))
        try await wait("second question answered", within: 3) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
        XCTAssertEqual(analyzer.calls, 2)
        let block = try XCTUnwrap(pane.paragraphs.visualBlockText)
        XCTAssertTrue(block.hasPrefix("2. What type"), block)
        XCTAssertFalse(block.contains("1. What do you want"), block)
        let probe = PromptProbe()
        probe.candidates = [candidate(pane: pane.pane, window: pane.windowID!, title: "agent")]
        probe.reply = .success(.prompt(.delivered(PromptDelivered(pane: pane.pane, via: .inbox))))
        installPrompt(probe)
        let option = try XCTUnwrap(pane.paragraphs.cursorRects.first)
        let point = pane.convert(NSPoint(x: option.midX, y: option.midY), to: nil)
        paragraphMouse(pane, .leftMouseDown, point)
        paragraphMouse(pane, .leftMouseUp, point)
        try await wait("second unit sent", within: 2) { probe.sends.count == 1 }
        let expected = RPCRequest.quote(block) + "\n\nCorrectness: does the design break invariants?"
        XCTAssertEqual(probe.sends[0], .prompt(pane: pane.pane, text: expected, target: pane.pane))
        XCTAssertFalse(expected.contains("1. What do you want"), expected)
    }

    func testInvalidRangeFallsBackToTheHoveredParagraph() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["intro", "", "Which approach?", "", "1. Keep the change", "2. Update the docs"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: [], firstLine: 1, lastLine: 2)
        try await paragraphAnswered(pane, row: 2)
        XCTAssertEqual(pane.paragraphs.visualBlockText, "Which approach?")
        XCTAssertEqual(pane.paragraphs.visualBlockRows, 2...2)
        XCTAssertEqual(analyzer.calls, 1)
    }
}

extension VisualTests {
    func testKnownUnitRestoresWithoutARequest() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Intro", "", "Which approach?", "", "1. Keep the change", "2. Update the docs", "", "Later paragraph"])
        var calls = 0
        ParagraphModel.testAnalyze = { @MainActor text in
            calls += 1
            if text.contains("> 3: Which approach?") {
                return ParagraphAnswer(isQuestion: true, options: ["Keep the change"], firstLine: 3, lastLine: 6)
            }
            return ParagraphAnswer(isQuestion: false, options: [])
        }
        try await paragraphAnswered(pane, row: 2)
        XCTAssertEqual(calls, 1)
        try await paragraphWrite(pane, "\r\nappended\r\n", until: "appended")
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 7, column: 2))
        try await wait("later paragraph is plain", within: 2) { pane.paragraphs.visualState == "plain" }
        XCTAssertEqual(calls, 2)
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 2, column: 2))
        try await wait("the known unit returns", within: 2) {
            pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing
        }
        XCTAssertEqual(calls, 2, "a known unit restores without a request")
        XCTAssertEqual(pane.paragraphs.visualBlockText, "Which approach?\n\n1. Keep the change\n2. Update the docs")
    }
}

extension VisualTests {
    func testEditingAUnitParagraphStartsANewAnalysis() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Which approach?", "", "1. Keep the change"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Keep the change"])
        try await paragraphAnswered(pane, row: 0)
        XCTAssertEqual(analyzer.calls, 1)
        try await paragraphWrite(pane, "\u{1b}[H\u{1b}[2KEdited question?", until: "Edited question?")
        try await wait("edited unit paragraph analysed again", within: 3) { analyzer.calls == 2 }
        try await wait("edited unit shown", within: 2) { pane.paragraphs.visualBlockText == "Edited question?\n\n1. Keep the change" }
    }
}

extension VisualTests {
    func testCacheIsSharedAcrossPanes() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        let other = try await paragraphSplit(pane)
        try await paragraphPaint(pane, ["Which approach?", "", "1. Keep the change"])
        try await paragraphPaint(other, ["Which approach?", "", "1. Keep the change"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Keep the change"], firstLine: 1, lastLine: 3)
        try await paragraphAnswered(pane, row: 0)
        XCTAssertEqual(analyzer.calls, 1)
        paragraphMouse(other, .mouseMoved, paragraphPoint(other, row: 0, column: 2))
        try await wait("second pane restores from the cache", within: 2) {
            other.paragraphs.visualState == "answered" && !other.paragraphs.visualGrowing
        }
        XCTAssertEqual(analyzer.calls, 1, "the process cache serves another pane")
        XCTAssertEqual(other.paragraphs.visualBlockText?.hasPrefix("Which approach?"), true)
        paragraphFlags(other, [])
    }
}

extension VisualTests {
    func testPendingAnalysisRestartsWhenTheContextChanges() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["First question?", "", "1. An answer", "", "Neighbour paragraph"])
        let analyzer = paragraphAnalyzer()
        analyzer.gate = ParagraphGate()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["An answer"], firstLine: 1, lastLine: 3)
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 2))
        try await wait("first analysis held", within: 2) { analyzer.calls == 1 }
        try await paragraphWrite(pane, "\u{1b}[3;1H\u{1b}[2K1. Changed answer", until: "Changed answer")
        try await wait("pane sees the edit", within: 2) {
            pane.paragraphRows(0..<10).contains { $0.text.contains("Changed answer") }
        }
        let debugContext = Paragraphs.context(pane.paragraphRows(0..<pane.paragraphViewport()!.total), row: 0)!
        print("PROMPT", debugContext.prompt, "LINES", debugContext.lines.count, "PARAS", debugContext.paragraphs.count, "TOTAL", pane.paragraphViewport()!.total)
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 0, column: 2))
        try await wait("context change restarts", within: 3) { analyzer.calls == 2 }
        analyzer.gate?.release()
        try await wait("fresh result", within: 2) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
        XCTAssertEqual(pane.paragraphs.visualBlockText, "First question?\n\n1. Changed answer")
    }

    func testClickDuringGrowthSendsNothing() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Which approach?", "", "1. Keep the change"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Keep the change"], firstLine: 1, lastLine: 3)
        paragraphEnter(pane, paragraphPoint(pane, row: 0, column: 2))
        try await wait("growing", within: 2) { pane.paragraphs.visualState == "answered" && pane.paragraphs.visualGrowing }
        var requested = 0
        promptBoxes.request = { _, done in requested += 1; done(.failure(.terminal("unexpected"))) }
        let point = paragraphPoint(pane, row: 2, column: 4)
        XCTAssertFalse(pane.paragraphs.click(at: pane.convert(point, from: nil)))
        XCTAssertTrue(pane.paragraphs.cursorRects.isEmpty)
        XCTAssertEqual(requested, 0)
        try await wait("growth finished", within: 2) { !pane.paragraphs.visualGrowing }
    }

    func testScrollDuringGrowthRemovesTheOldAnimation() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        var lines = (0..<10).map { "preamble \($0)" }
        lines += ["", "Which approach?", "", "1. Keep the change", ""]
        lines += (0..<30).map { "suffix \($0)" }
        try await paragraphPaint(pane, lines)
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphAnswerFor(pane, row: 11, options: ["Keep the change"])
        paragraphEnter(pane, paragraphPoint(pane, row: 11, column: 2))
        try await wait("growing", within: 2) { pane.paragraphs.visualState == "answered" && pane.paragraphs.visualGrowing }
        let start = pane.wheelDistance ?? 0
        pane.visualScroll(start + 0.5)
        try await wait("fractional scroll applied", within: 2) {
            pane.wheelDistance.map { $0 > start && $0 < start + 1 } == true
        }
        try await wait("growth cancelled", within: 2) { !pane.paragraphs.visualGrowing }
        let final = try XCTUnwrap(pane.paragraphs.visualBlockFrame)
        try await wait("presentation reaches the final rect", within: 2) {
            pane.paragraphs.visualPresentationBlockFrame == final
        }
    }

    func testPointerMoveInsideTheUnitReadsNoRows() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Which approach?", "", "1. Keep the change", "2. Update the docs"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = paragraphAnswerFor(pane, row: 0, options: ["Keep the change", "Update the docs"])
        try await paragraphAnswered(pane, row: 0)
        let reads = pane.paragraphRowReads
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 3, column: 3))
        XCTAssertEqual(pane.paragraphRowReads, reads, "a pointer move inside the answered unit reads no rows")
    }

    func testBlankRowHoverReadsOneChunk() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["First", "", "Second"])
        let reads = pane.paragraphRowReads
        paragraphEnter(pane, paragraphPoint(pane, row: 1, column: 1))
        try await wait("blank row idle", within: 2) { pane.paragraphs.visualState == "idle" }
        XCTAssertLessThanOrEqual(pane.paragraphRowReads - reads, 16)
    }

    func testBudgetStopsContextReads() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        var lines: [String] = []
        for paragraph in 0..<5 {
            if !lines.isEmpty { lines.append("") }
            lines += (0..<25).map { "paragraph \(paragraph) line \($0)" }
        }
        try await paragraphPaint(pane, lines)
        try await paragraphScrollTo(pane, offset: 54)
        let reads = pane.paragraphRowReads
        paragraphEnter(pane, paragraphPoint(pane, row: 54, column: 2))
        try await wait("budget analysis", within: 2) { pane.paragraphs.visualState == "analysing" || pane.paragraphs.visualState == "answered" }
        XCTAssertLessThan(pane.paragraphRowReads - reads, 100)
    }

    @MainActor
    private func paragraphAnswerFor(_ pane: PaneView, row: Int, options: [String], count: Int = 2) -> ParagraphAnswer {
        let viewport = pane.paragraphViewport()!
        let context = Paragraphs.context(pane.paragraphRows(0..<viewport.total), first: 0, row: row)!
        let last = min(context.paragraphs.count - 1, context.hovered + count - 1)
        return ParagraphAnswer(isQuestion: true, options: options,
                               firstLine: context.ranges[context.hovered].lowerBound + 1,
                               lastLine: context.ranges[last].upperBound + 1)
    }
}

extension VisualTests {
    func testKnownUnitEndpointRestoresWithoutARequest() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Question?", "", "1. One", "", "2. Two", "", "3. Three", "", "Outside"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["One"], firstLine: 1, lastLine: 7)
        try await paragraphAnswered(pane, row: 2)
        XCTAssertEqual(analyzer.calls, 1)
        analyzer.analysis = ParagraphAnswer(isQuestion: false, options: [], firstLine: 1, lastLine: 1)
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 8, column: 2))
        try await wait("outside is plain", within: 2) { pane.paragraphs.visualState == "plain" }
        XCTAssertEqual(analyzer.calls, 2)
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 6, column: 2))
        try await wait("endpoint restores", within: 2) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
        XCTAssertEqual(analyzer.calls, 2, "an endpoint of the known unit starts no request")
        XCTAssertEqual(pane.paragraphs.visualBlockText, "Question?\n\n1. One\n\n2. Two\n\n3. Three")
    }

    func testDuplicateUnitTextRestoresTheHoveredBlock() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, ["Dup question?", "", "1. Same answer", "", "Outside", "", "Dup question?", "", "1. Same answer"])
        let analyzer = paragraphAnalyzer()
        analyzer.analysis = ParagraphAnswer(isQuestion: true, options: ["Same answer"], firstLine: 1, lastLine: 3)
        try await paragraphAnswered(pane, row: 0)
        XCTAssertEqual(analyzer.calls, 1)
        analyzer.analysis = ParagraphAnswer(isQuestion: false, options: [], firstLine: 1, lastLine: 1)
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 4, column: 2))
        try await wait("outside is plain", within: 2) { pane.paragraphs.visualState == "plain" }
        XCTAssertEqual(analyzer.calls, 2)
        paragraphMouse(pane, .mouseMoved, paragraphPoint(pane, row: 6, column: 2))
        try await wait("second duplicate restores", within: 2) { pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing }
        XCTAssertEqual(analyzer.calls, 2, "the duplicate restores without a request")
        let rows = try XCTUnwrap(pane.paragraphs.visualBlockRows)
        XCTAssertTrue(rows.contains(6))
        XCTAssertFalse(rows.contains(0))
    }
}

extension VisualTests {
    func testParagraphTaggerAnswersTheShiftGesture() async throws {
        ParagraphModel.reset()
        addTeardownBlock { @MainActor in ParagraphModel.reset() }
        let pane = try await paragraphPane()
        try await paragraphPaint(pane, [
            "The deploy script copies the files to the server.",
            "",
            "Which colour should the banner use?",
            "",
            "1. Teal",
            "2. Amber",
            "3. Slate",
            "",
            "The footer keeps the colour until the next deploy.",
        ])
        paragraphEnter(pane, paragraphPoint(pane, row: 2, column: 4))
        try await wait("the tagger answers", within: 10) {
            pane.paragraphs.visualState == "answered" && !pane.paragraphs.visualGrowing
                && pane.paragraphs.visualOptionFrames.count == 3
        }
        XCTAssertEqual(pane.paragraphs.visualBlockText, "Which colour should the banner use?\n\n1. Teal\n2. Amber\n3. Slate")
    }
}
