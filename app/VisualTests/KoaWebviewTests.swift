import AppKit
import WebKit
import SnapshotTesting
import XCTest
@testable import Kido

@MainActor final class KoaWebviewTests: AppWindowCase {
    private func report(_ error: Error) {
        if let failure = error as? KoaFailure { XCTFail(failure.message, file: failure.file, line: failure.line) }
        else { XCTFail(String(describing: error)) }
    }

    private func run(_ fixture: KoaFixture) async throws {
        var replayPane: PaneView?
        let backend = KoaBackend(
            checkout: checkoutRoot,
            diagnostic: { NSLog("%@", $0) },
            start: { module, key, assets, width, height in
                let command = "export PATH=\(SSH.quote(koaPath(self))) TZ=\(SSH.quote(KoaContext.timeZone)); exec node \(SSH.quote(self.checkoutRoot.appendingPathComponent("koa/testdata/replay.ts").path)) \(SSH.quote(module)) \(SSH.quote(key)) \(SSH.quote(assets.path))"
                try await self.start(width: width, height: height, pane: command)
                replayPane = self.terminal?.displayedPanes.first
            },
            window: { self.window },
            pane: { replayPane },
            browser: { replayPane?.webviewView?.browser },
            terminal: { self.terminal },
            prepare: {
                let host = NSView(frame: self.window.contentView?.bounds ?? .zero)
                self.window.contentView = host
                host.addSubview(self.session)
                self.session.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    self.session.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor),
                    self.session.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    self.session.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
                    self.session.bottomAnchor.constraint(equalTo: host.bottomAnchor)
                ])
            },
            documents: { replayPane?.webviewView?.visualDocuments ?? 0 },
            updateTheme: { replayPane?.webviewView?.updateTheme() },
            darken: { try await self.darken($0) },
            split: { try await self.split($0, $1) },
            nativeSnapshot: { pane, name, owner in
                _ = try await self.webviewSnapshot(pane, name, file: #filePath, testName: owner)
            },
            verify: { image, name, owner in
                self.checkSnapshot { verifySnapshot(of: image, as: .pixels, named: name, record: $0, file: #filePath, testName: owner) }
            }
        )
        let driver = KoaDriver(backend: backend, fixture: fixture)
        addTeardownBlock { @MainActor in
            do { try await driver.finish() } catch { self.report(error) }
        }
        do { try await driver.run() } catch { report(error) }
    }
    func testKoaWebviewPlaceInset() async throws { try await run(.placeInset) }
    func testKoaWebviewQuoteSelection() async throws { try await run(.quoteSelection) }
    func testKoaWebviewDots() async throws { try await run(.dots) }
    func testKoaWebviewRunStepsTransitions() async throws { try await run(.runStepsTransitions) }
    func testKoaWebviewScrollbarJumpMountsHistory() async throws { try await run(.scrollbarJumpMountsHistory) }
    func testKoaWebviewSelectAllCopiesTheWholeTranscript() async throws { try await run(.selectAllCopiesTheWholeTranscript) }
    func testKoaWebviewFindSkippedHistory() async throws { try await run(.findSkippedHistory) }
    func testKoaWebviewBangCompletion() async throws { try await run(.bangCompletion) }
    func testKoaWebviewBang() async throws { try await run(.bang) }
    func testKoaWebviewComposerFootResponsive() async throws { try await run(.composerFootResponsive) }
    func testKoaWebviewComposerFootStates() async throws { try await run(.composerFootStates) }
    func testKoaWebviewComposerStateGeometryWide() async throws { try await run(.composerStateGeometryWide) }
    func testKoaWebviewComposerStateGeometryNarrow() async throws { try await run(.composerStateGeometryNarrow) }
    func testKoaWebviewFocusBorderTranscript() async throws { try await run(.focusBorderTranscript) }
    func testKoaWebviewComposerFocus() async throws { try await run(.composerFocus) }
    func testKoaWebviewCommandsNarrow() async throws { try await run(.commandsNarrow) }
    func testKoaWebviewMockupStates() async throws { try await run(.mockupStates) }
    func testKoaWebviewNotices() async throws { try await run(.notices) }
    func testKoaWebviewLatest() async throws { try await run(.latest) }
    func testKoaWebviewErrorState() async throws { try await run(.errorState) }
    func testKoaWebviewShortStates() async throws { try await run(.shortStates) }
    func testKoaWebviewNarrowStates() async throws { try await run(.narrowStates) }
    func testKoaWebviewDialogs() async throws { try await run(.dialogs) }
    func testKoaWebviewControls() async throws { try await run(.controls) }
    func testKoaWebviewNarrowControls() async throws { try await run(.narrowControls) }
    func testKoaWebviewExit() async throws { try await run(.exit) }
    func testKoaWebviewFailed() async throws { try await run(.failed) }
    func testKoaWebviewRhythm() async throws { try await run(.rhythm) }
    func testKoaWebviewThreadsModes() async throws { try await run(.threadsModes) }
    func testKoaWebviewThreads() async throws { try await run(.threads) }
    func testKoaWebviewThreadsFilter() async throws { try await run(.threadsFilter) }
    func testKoaWebviewThreadsFilterPanel() async throws { try await run(.threadsFilterPanel) }
    func testKoaWebviewAgents() async throws { try await run(.agents) }
    func testKoaWebviewSubagentView() async throws { try await run(.subagentView) }
    func testKoaWebviewViewBar() async throws { try await run(.viewBar) }
    func testKoaWebviewJobs() async throws { try await run(.jobs) }
    func testKoaWebviewLightbox() async throws { try await run(.lightbox) }
    func testKoaWebviewPaths() async throws { try await run(.paths) }
    func testKoaWebviewPreviewHover() async throws { try await run(.previewHover) }
    func testKoaWebviewMedia() async throws { try await run(.media) }
    func testKoaWebviewAttachments() async throws { try await run(.attachments) }
    func testKoaWebviewUserMarkdown() async throws { try await run(.userMarkdown) }
    func testKoaWebviewReveal() async throws { try await run(.reveal) }
    func testKoaWebviewThinkingMarkdown() async throws { try await run(.thinkingMarkdown) }
    func testKoaWebviewComposerMarkdown() async throws { try await run(.composerMarkdown) }
    func testKoaWebviewQuestions() async throws { try await run(.questions) }
    func testKoaWebviewCompletion() async throws { try await run(.completion) }
    func testKoaWebviewSessions() async throws { try await run(.sessions) }
}
