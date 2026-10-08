import AppKit
import TmuxControl
import GhosttyKit
import SidebarFeed

#if KIDO_STRESS

final class StressWindow: OwnerWindow {
    var resizeRendering = false
    override var occlusionState: NSWindow.OcclusionState { resizeRendering ? [.visible] : super.occlusionState }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

typealias AppWindow = StressWindow

@MainActor final class Stress {
    private enum Action: String {
        case wheel, stripPress = "strip-press", stripWheel = "strip-wheel", alternate
        case scrollerDrag = "scroller-drag", scrollRequest = "scroll-request"
        case find, findNext = "find-next", findCloseResync = "find-close-resync"
        case resizeBurst = "resize-burst", loadMore = "load-more", gripDrag = "grip-drag"
        case gripDragKill = "grip-drag-kill", appearance, edgeResize = "edge-resize", detachReconnect = "detach-reconnect"
        case hiddenResize = "hidden-resize", clearHistory = "clear-history"
        case tabs, sidebarJump = "sidebar-jump", sidebarSearch = "sidebar-search", sidebarMode = "sidebar-mode"
    }
    private static let actions: [Action] = [
        .wheel, .wheel, .stripPress, .stripWheel, .alternate, .scrollerDrag, .scrollerDrag, .scrollRequest, .find, .findNext, .findCloseResync,
        .resizeBurst, .loadMore, .gripDrag, .gripDragKill, .appearance, .edgeResize, .detachReconnect, .hiddenResize, .clearHistory,
        .tabs, .sidebarJump, .sidebarSearch, .sidebarMode,
    ]
    private let window: NSWindow
    private let send: ([Command]) -> Void
    private let reconnect: () -> Void
    private let env = ProcessInfo.processInfo.environment
    private let finish: DispatchTime
    private var seed: UInt64
    private var step = 0
    private var rpcTimeout: DispatchWorkItem?
    private var counts: [String: Int] = [:]
    private var resizeCompleted = Set<ObjectIdentifier>()
    private var resizeAcknowledged: [String: Double] = [:]
    private var childWindows = Set<String>()

    init(window: NSWindow, send: @escaping ([Command]) -> Void, reconnect: @escaping () -> Void) {
        self.window = window
        self.send = send
        self.reconnect = reconnect
        seed = UInt64(env["STRESS_SEED"] ?? "") ?? 1
        finish = .now() + 3 + (Double(env["STRESS_DURATION"] ?? "") ?? 60)
        window.acceptsMouseMovedEvents = true
    }

    func run() {
        log(["input-delivery": "Off-screen: view event methods and menu performKeyEquivalent called directly; toolbar toggle invokes its entry point, not an NSToolbar click"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.env["KIDO_FIND_CLEAR_VERIFY"] == "1" || self.env["KIDO_FIND_INVALIDATE_VERIFY"] == "1" {
                guard let pane = (self.window.contentView.map(self.views) ?? []).compactMap({ $0 as? PaneView }).first else { exit(1) }
                pane.onSearch = { _, _ in }
                pane.showFind()
                self.verifyStoppedFind(pane, phase: self.env["KIDO_FIND_CLEAR_VERIFY"] == "1" ? 0 : 1)
            }
            else if self.env["KIDO_FIND_VERIFY"] == "1" { self.verifyFind() }
            else if self.env["KIDO_SNAP_VERIFY"] == "1" { self.verifySnap(0) }
            else if self.env["KIDO_ALT_VERIFY"] == "1" || self.env["KIDO_INPUT_VERIFY"] == "1" { self.verifyAlternate() }
            else if self.env["KIDO_FLOAT_VERIFY"] == "1" { self.verifyFloat(0) }
            else if self.env["KIDO_RESIZE_VERIFY"] == "1" || self.env["KIDO_GRID_VERIFY"] == "1" || self.env["KIDO_REPLAY_VERIFY"] == "1" || self.env["KIDO_REPLAY_FENCE_VERIFY"] == "1" || self.env["KIDO_VIEWPORT_VERIFY"] == "1" { self.verifyResize() }
            else { self.tick() }
        }
    }

    private func verifyResize() {
        guard let original = (window.contentView.map(views) ?? []).compactMap({ $0 as? PaneView }).first else { exit(1) }
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ghostty_app_userdata(ghostty_surface_app(original.surface)!)!).takeUnretainedValue()
        guard let pane = PaneView(runtime: runtime, pane: original.pane, font: original.font, onInput: { _ in }),
              let reference = PaneView(runtime: runtime, pane: original.pane, font: original.font, onInput: { _ in }) else { exit(1) }
        (window as? StressWindow)?.resizeRendering = true
        let surfaces = [pane, reference]
        for surface in surfaces {
            window.contentView?.addSubview(surface)
            surface.frame = NSRect(x: -10000, y: -10000, width: surface.cell.width * 80, height: surface.cell.height * 12 + 9.5)
            surface.resize(cols: 80, rows: 12)
            surface.renderInsets.top = 9.5
            surface.layoutSubtreeIfNeeded()
            ghostty_surface_set_occlusion(surface.surface, true)
        }
        if env["KIDO_GRID_VERIFY"] == "1" {
            let passed = injectFailedGrid(pane)
            log(["grid-verify": passed ? "passed" : "failed", "ready": pane.gridReady])
            if !passed { exit(1) }
            (NSApp.delegate as? AppDelegate)?.quit("grid verification complete")
            return
        }
        let bytes = Data(("\u{1b}c" + (0..<200).map { "\u{1b}[48;2;255;0;0mrow\($0)\u{1b}[m\r\n" }.joined()
                          + "\u{1b}[48;2;0;0;255mBLUE FINAL\u{1b}[m\u{1b}[?25l").utf8)
        resizeCompleted.removeAll()
        for surface in surfaces {
            let identifier = ObjectIdentifier(surface)
            surface.onFinalRender = { self.resizeCompleted.insert(identifier) }
        }
        DispatchQueue.global().async {
            for surface in surfaces {
                let epoch = surface.historyEpoch
                guard surface.feed(bytes, kind: .snapshot, epoch: epoch), surface.commitSnapshot(epoch: epoch) else { exit(1) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if self.env["KIDO_VIEWPORT_VERIFY"] == "1" {
                    pane.verifyFailedViewport { passed in
                        self.log(["viewport-verify": passed ? "passed" : "failed"])
                        if !passed { exit(1) }
                        (NSApp.delegate as? AppDelegate)?.quit("viewport verification complete")
                    }
                    return
                }
                if self.env["KIDO_REPLAY_VERIFY"] == "1" || self.env["KIDO_REPLAY_FENCE_VERIFY"] == "1" {
                    let position = pane.scrollPosition()
                    pane.updateScroller(sampledTmuxHistoryRows: position.retainedHistoryRows, position: position, alternate: false)
                    pane.requestScroll(21)
                    reference.updateScroller(sampledTmuxHistoryRows: position.retainedHistoryRows, position: position, alternate: false)
                    reference.requestScroll(21)
                    pane.afterScroll {
                        let before = pane.scrollPosition()
                        guard before.retainedHistoryRows - before.offset == 21 else { exit(1) }
                        let replayed: @MainActor @Sendable (Bool) -> Void = { rejected in
                            guard rejected else { self.log(["replay-fence-app-validation": "failed"]); exit(1) }
                            pane.updateScroller(sampledTmuxHistoryRows: position.retainedHistoryRows, position: position, alternate: false)
                            self.resizeAcknowledged.removeAll()
                            let started = ProcessInfo.processInfo.systemUptime
                            for (name, surface) in zip(["pane", "reference"], surfaces) {
                                surface.onFinalRender = {
                                    self.resizeAcknowledged[name] = ProcessInfo.processInfo.systemUptime - started
                                    guard self.resizeAcknowledged.count == 2 else { return }
                                    for surface in surfaces { surface.onFinalRender = nil }
                                    let after = pane.scrollPosition()
                                    let pixels = reference.renderedPixels != nil && pane.renderedPixels == reference.renderedPixels
                                    let passed = pane.scrollTarget == 21 && after.retainedHistoryRows - after.offset == 21 && pixels
                                    self.log(["replay-verify": passed ? "passed" : "failed", "target": pane.scrollTarget ?? -1,
                                              "before-distance": before.retainedHistoryRows - before.offset, "after-distance": after.retainedHistoryRows - after.offset,
                                              "pixels": pixels, "acknowledged": true,
                                              "acknowledgement-seconds": self.resizeAcknowledged])
                                    if !passed { exit(1) }
                                    (NSApp.delegate as? AppDelegate)?.quit("replay verification complete")
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                guard self.resizeAcknowledged.count != 2 else { return }
                                let pending = Dictionary(uniqueKeysWithValues: zip(["pane", "reference"], surfaces)
                                    .filter { self.resizeAcknowledged[$0.0] == nil }
                                    .map { ($0.0, $0.1.finalRenderDiagnostics) })
                                self.log(["replay-verify": "failed", "reason": "acknowledgement deadline 5s",
                                          "acknowledgement-seconds": self.resizeAcknowledged, "pending-surfaces": pending])
                                exit(1)
                            }
                            for surface in surfaces { surface.restored(epoch: surface.historyEpoch) }
                        }
                        if self.env["KIDO_REPLAY_FENCE_VERIFY"] == "1" {
                            for surface in surfaces { surface.restored(epoch: surface.historyEpoch) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                guard self.resizeCompleted.count == 2, pane.renderedPixels != nil,
                                      pane.renderedPixels == reference.renderedPixels else { exit(1) }
                                let rejected = pane.verifySnapReplayRevision()
                                self.log(["snap-replay-app-validation": rejected ? "passed" : "failed"])
                                guard rejected else { exit(1) }
                                self.resizeCompleted.removeAll()
                                pane.afterScroll {
                                    pane.verifyReplayFence(bytes) { rejected in
                                        self.log(["replay-fence-app-validation": rejected ? "passed" : "failed"])
                                        replayed(rejected)
                                    }
                                }
                            }
                        } else {
                            DispatchQueue.global().async {
                                pane.feed(bytes, kind: .snapshot)
                                DispatchQueue.main.async { replayed(true) }
                            }
                        }
                    }
                    return
                }
                let before = pane.renderedPixels
                pane.resize(cols: 73, rows: 9)
                pane.frame.size = NSSize(width: pane.cell.width * 73, height: pane.cell.height * 9 + 9.5)
                pane.layoutSubtreeIfNeeded()
                _ = ghostty_surface_set_renderer_realized(pane.surface, false)
                pane.resizeAnchor = nil
                pane.resetScroll()
                pane.restored(epoch: pane.historyEpoch)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard self.resizeCompleted.isEmpty else { self.log(["resize-verify": "failed", "reason": "premature completion"]); exit(1) }
                    self.log(["resize-verify": "wrong-inset frame rejected", "old-pixels": before?.count ?? 0])
                    _ = ghostty_surface_set_renderer_realized(pane.surface, true)
                    reference.resize(cols: 73, rows: 9)
                    reference.frame.size = pane.frame.size
                    reference.layoutSubtreeIfNeeded()
                    DispatchQueue.global().async {
                        for surface in surfaces { surface.feed(bytes) }
                        DispatchQueue.main.async {
                            for surface in surfaces {
                                surface.resizeAnchor = nil
                                surface.resetScroll()
                                surface.restored(epoch: surface.historyEpoch)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                guard self.resizeCompleted.count == 2, let expected = reference.renderedPixels,
                                      pane.renderedPixels == expected else {
                                    self.log(["resize-verify": "failed", "reason": "snapshot pixels", "completed": self.resizeCompleted.count]); exit(1)
                                }
                                let colors = Array(expected)
                                var red = 0, blue = 0
                                for i in stride(from: 0, to: colors.count, by: 4) {
                                    if Int(colors[i + 2]) > Int(colors[i]) + 80 && Int(colors[i + 2]) > Int(colors[i + 1]) + 80 { red += 1 }
                                    if Int(colors[i]) > Int(colors[i + 2]) + 80 && Int(colors[i]) > Int(colors[i + 1]) + 80 { blue += 1 }
                                }
                                guard red > 100, blue > 100 else {
                                    self.log(["resize-verify": "failed", "reason": "expected colors", "red": red, "blue": blue]); exit(1)
                                }
                                guard self.injectFailedGrid(pane) else {
                                    self.log(["resize-verify": "failed", "reason": "grid failure confirmed"]); exit(1)
                                }
                                let position = pane.scrollPosition()
                                DispatchQueue.global().async {
                                    pane.feed(Data("MUST NOT FEED\r\n".utf8))
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        guard pane.scrollPosition().retainedHistoryRows == position.retainedHistoryRows, pane.renderedPixels == expected else {
                                            self.log(["resize-verify": "failed", "reason": "failed grid feed or late stale frame"]); exit(1)
                                        }
                                        self.log(["resize-verify": "passed", "snapshot-bytes": expected.count, "grid-failure-rejected": true])
                                        (NSApp.delegate as? AppDelegate)?.quit("resize verification complete")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func injectFailedGrid(_ pane: PaneView) -> Bool {
        var failures = 0
        pane.onGridFailure = { failures += 1 }
        pane.failGridInstall = true
        let epoch = pane.historyEpoch
        pane.resize(cols: 74, rows: 10)
        return !pane.gridReady && pane.historyEpoch > epoch && failures == 1
    }

    private var snapFixture: PaneView?
    private var wheelInputs = Data()

    private func wheel(_ pane: PaneView, y: Int32, x: Int32 = 0, precise: Bool = true, shift: Bool = false, band: Int = 0, momentum: Int64 = 0) {
        guard let event = pane.wheelEvent(y: y, x: x, precise: precise, shift: shift, band: band, momentum: momentum) else { exit(1) }
        pane.mouseMoved(with: event)
        pane.scrollWheel(with: event)
    }

    private func verifyWheelOwnership(_ pane: PaneView, completion: @escaping @MainActor () -> Void) {
        pane.updateScroller(sampledTmuxHistoryRows: 0, position: pane.scrollPosition(), alternate: false)
        guard pane.scrollPosition().retainedHistoryRows == 0 else { exit(1) }
        guard pane.wheelRowHeight > 1 else {
            self.log(["wheel-setup": "failed", "row-height": pane.wheelRowHeight]); exit(1)
        }
        for precise in [true, false] {
            for y: Int32 in [-1, 1] {
                for momentum: Int64 in [0, 1, 2, 3] {
                    for band in [0, 1, -1] { wheel(pane, y: y, precise: precise, band: band, momentum: momentum) }
                }
            }
        }
        guard pane.scrollTarget == nil else { exit(1) }
        pane.resetScroll()
        pane.updateScroller(sampledTmuxHistoryRows: 10, position: pane.scrollPosition(), alternate: false, mayHaveOlderHistory: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard pane.visualPill else { self.log(["wheel-empty-pill": "failed"]); exit(1) }
            pane.updateScroller(sampledTmuxHistoryRows: 0, position: pane.scrollPosition(), alternate: false, mayHaveOlderHistory: false)
            DispatchQueue.global().async {
                let text = (0..<200).map { "live\($0)\r\n" }.joined()
                guard pane.feed(Data(text.utf8), kind: .live, epoch: pane.historyEpoch) else { exit(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard pane.scrollPosition().retainedHistoryRows > 0 else { exit(1) }
                    let before = pane.renderedPixels
                    self.wheel(pane, y: 1)
                    guard let target = pane.wheelDistance, target > 0, target < 1 else {
                        self.log(["wheel-new-pane": "failed", "reason": "sample 0 live history first sub-row wheel has no fractional target", "target": pane.wheelDistance ?? -1])
                        exit(1)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let diagnostics = pane.finalRenderDiagnostics
                        guard diagnostics["revision"] as? Int == diagnostics["applied-revision"] as? Int,
                              self.wheelInputs.isEmpty, pane.renderedPixels != nil, pane.renderedPixels != before else {
                            self.log(["wheel-new-pane": "failed", "reason": "missing applied revision, fractional rendered frame or unwanted input", "diagnostics": diagnostics]); exit(1)
                        }
                        self.log(["wheel-new-pane": "passed", "target": target, "rendered-fraction": "passed", "input": "empty"])
                        pane.resetScroll()
                        self.verifyWheelPrograms(pane, index: 0, completion: completion)
                    }
                }
            }
        }
    }

    private func verifyWheelPrograms(_ pane: PaneView, index: Int, completion: @escaping @MainActor () -> Void) {
        let size = ghostty_surface_size(pane.surface)
        let cases: [(String, String, Int32, Int32, Bool, Int, Bool)] = [
            ("\u{1b}[?1049h\u{1b}[?1007h\u{1b}[?1l", "\u{1b}[A", Int32(size.cell_height_px), 0, false, 0, false),
            ("", "\u{1b}[B", -Int32(size.cell_height_px), 0, false, 0, false),
            ("\u{1b}[?1h", "\u{1b}OB", -Int32(size.cell_height_px), 0, false, 0, false),
            ("", "\u{1b}OA", Int32(size.cell_height_px), 0, false, 0, false),
            ("\u{1b}[?1007l", "", Int32(size.cell_height_px), 0, false, 0, false),
            ("", "", Int32(size.cell_height_px), 0, false, 1, false),
            ("\u{1b}[?1007h", "", Int32(size.cell_height_px), 0, false, -1, false),
            ("\u{1b}[?1049l\u{1b}[?1000h\u{1b}[?1006h", "\u{1b}[<68;1;1M", Int32(size.cell_height_px), 0, true, 0, false),
            ("", "\u{1b}[<66;1;1M", 0, Int32(size.cell_width_px), false, 0, false),
            ("\u{1b}[?1049h", "\u{1b}[<64;1;1M", Int32(size.cell_height_px), 0, false, 0, false),
            ("", "", Int32(size.cell_height_px), 0, true, 1, false),
            ("", "", Int32(size.cell_height_px), 0, false, -1, false),
            ("\u{1b}[?1049l", "", 1, 0, false, 1, true),
            ("", "", 1, 0, false, -1, true),
            ("", "", 1, 0, false, 0, true)
        ]
        guard index < cases.count else {
            pane.resetScroll()
            self.log(["wheel-programs": "passed", "shift-report": "passed", "horizontal-report": "passed", "bands": "passed", "reporting-disabled": "passed", "empty-pane": "passed"])
            completion()
            return
        }
        let (output, expected, y, x, shift, band, viewport) = cases[index]
        if index == 0 || index == cases.count - 1 {
            guard let config = ghostty_config_new() else { exit(1) }
            let text = "mouse-reporting = \(index == cases.count - 1 ? "false" : "true")\nmouse-scroll-multiplier = 1\nmouse-shift-capture = never\n"
            text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "wheel-test") }
            ghostty_config_finalize(config)
            ghostty_surface_update_config(pane.surface, config)
            ghostty_config_free(config)
        }
        pane.resetScroll()
        wheelInputs.removeAll()
        guard pane.commitSnapshot(epoch: pane.historyEpoch),
              output.isEmpty || pane.feed(Data(output.utf8), kind: .live, epoch: pane.historyEpoch) else {
            self.log(["wheel-programs": "failed", "case": index, "reason": "fixture feed admission"]); exit(1)
        }
        DispatchQueue.main.async {
            let before = pane.scrollPosition()
            self.wheel(pane, y: y, x: x, shift: shift, band: band)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let after = pane.scrollPosition()
                let state = viewport ? (pane.scrollTarget ?? 0) > 0 : (pane.scrollTarget ?? 0) == 0 && before.offset == after.offset
                guard self.wheelInputs == Data(expected.utf8), state else {
                    self.log(["wheel-programs": "failed", "case": index, "input": self.wheelInputs.base64EncodedString(), "expected": Data(expected.utf8).base64EncodedString(), "target": pane.scrollTarget ?? -1]); exit(1)
                }
                self.log(["wheel-case": index, "result": "passed"])
                self.verifyWheelPrograms(pane, index: index + 1, completion: completion)
            }
        }
    }

    private func verifySnap(_ index: Int) {
        if snapFixture == nil {
            guard let original = (window.contentView.map(views) ?? []).compactMap({ $0 as? PaneView }).first else { exit(1) }
            guard original.wheelRowHeight > 1 else {
                self.log(["wheel-production-layout": "failed", "row-height": original.wheelRowHeight]); exit(1)
            }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ghostty_app_userdata(ghostty_surface_app(original.surface)!)!).takeUnretainedValue()
            guard let fixture = PaneView(runtime: runtime, pane: original.pane, font: original.font,
                                         onInput: { [weak self] in self?.wheelInputs.append($0) }) else { exit(1) }
            window.contentView?.addSubview(fixture)
            fixture.renderInsets = PaneLayout.RenderInsets(top: 8, bottom: 8)
            fixture.frame = NSRect(x: -10000, y: -10000, width: fixture.cell.width * 80, height: fixture.cell.height * 24 + 16)
            fixture.resize(cols: 80, rows: 24)
            fixture.needsLayout = true
            fixture.layout()
            ghostty_surface_set_occlusion(fixture.surface, true)
            snapFixture = fixture
            DispatchQueue.global().async {
                let epoch = fixture.historyEpoch
                guard fixture.feed(Data("\u{1b}c".utf8), kind: .snapshot, epoch: epoch), fixture.commitSnapshot(epoch: epoch) else { exit(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.verifyWheelOwnership(fixture) { self.verifySnap(index) } }
            }
            return
        }
        if index == 0 {
            for pane in (window.contentView.map(views) ?? []).compactMap({ $0 as? PaneView }).filter({ $0 !== snapFixture }) {
                let position = pane.scrollPosition(), loaded = position.retainedHistoryRows
                guard loaded > 0 else { exit(1) }
                for total in [loaded + 10000, loaded, max(1, loaded - 100)] {
                    pane.updateScroller(sampledTmuxHistoryRows: total, position: position, alternate: false)
                    pane.requestScroll(loaded + 9000)
                    guard pane.scrollTarget == loaded else { exit(1) }
                    pane.requestScroll(loaded)
                    for precise in [true, false] {
                        for _ in 0..<30 {
                            guard let event = pane.wheelEvent(y: 7, precise: precise) else { exit(1) }
                            pane.scrollWheel(with: event)
                            guard pane.scrollTarget == loaded else { exit(1) }
                        }
                    }
                }
                self.log(["wheel-top": "passed", "loaded": loaded, "absolute-stale-total": "passed", "live-past-total": "passed"])
            }
        }
        let cases = [(1, false, false), (2, false, false), (1, true, false), (1, false, true)]
        guard index < cases.count else {
            (NSApp.delegate as? AppDelegate)?.quit("snap verification complete")
            return
        }
        guard let pane = snapFixture else { exit(1) }
        let (snaps, bottom, retry) = cases[index]
        pane.verifySnapAccounting(snaps: snaps, bottom: bottom, retry: retry) { passed in
            self.log(["snap-verify": passed ? "passed" : "failed", "snaps": snaps, "bottom": bottom, "revision-retry": retry])
            guard passed else { exit(1) }
            self.verifySnap(index + 1)
        }
    }

    private func verifyFind() {
        guard let pane = (window.contentView.map(views) ?? []).compactMap({ $0 as? PaneView }).first else { exit(1) }
        pane.onSearch = { _, _ in }
        pane.showFind()
        pane.find?.field.stringValue = "row"
        pane.find?.search()
        let old = ghostty_surface_search_generation(pane.surface)
        GhosttyRuntime.verifyDeferredSearchAction(pane.surface)
        pane.find?.search()
        let current = ghostty_surface_search_generation(pane.surface)
        guard current > old else { exit(1) }
        DispatchQueue.main.async {
            guard let find = pane.find else { exit(1) }
            let state = find.stressState
            let rejected = state.selected == nil && state.total == 0
            self.log(["find-deferred": rejected ? "passed" : "failed", "total": state.total, "selected": state.selected ?? -1])
            guard rejected else { exit(1) }
            find.stressMatches([0])
            self.waitForSelection(pane, stage: 0, deadline: .now() + 5)
        }
    }

    private func waitForSelection(_ pane: PaneView, stage: Int, deadline: DispatchTime) {
        guard let find = pane.find else { exit(1) }
        let state = find.stressState
        if state.selected == 0 && state.total > 0 && state.navigationCount > stage {
            self.log(["find-current": "passed", "total": state.total, "selected": state.selected!, "navigations": state.navigationCount])
            GhosttyRuntime.verifyDeferredSearchAction(pane.surface)
            if stage == 0 {
                let previous = ghostty_surface_search_generation(pane.surface)
                let inserted = pane.prepend(Data(String(repeating: "prepended row\r\n", count: 10).utf8), epoch: pane.historyEpoch)
                guard inserted > 0 else { exit(1) }
                find.loaded(pane.scrollPosition())
                guard ghostty_surface_search_generation(pane.surface) > previous else { exit(1) }
                DispatchQueue.main.async {
                    let rejected = find.stressState.selected == nil && find.stressState.total != 999
                    self.log(["find-prepend": rejected ? "passed" : "failed", "inserted": inserted])
                    guard rejected else { exit(1) }
                    find.stressMatches([0])
                    self.waitForSelection(pane, stage: 1, deadline: .now() + 5)
                }
                return
            }
            find.close()
            pane.showFind()
            pane.find?.field.stringValue = "row"
            pane.find?.search()
            DispatchQueue.main.async {
                let rejected = pane.find != nil && pane.find?.stressState.selected == nil && pane.find?.stressState.total != 999
                self.log(["find-reopen": rejected ? "passed" : "failed", "find-exists": pane.find != nil,
                          "total": pane.find?.stressState.total ?? -1])
                guard rejected else { exit(1) }
                GhosttyRuntime.verifyDeferredSearchAction(pane.surface)
                pane.find?.close()
                pane.showFind()
                DispatchQueue.main.async {
                    let state = pane.find?.stressState
                    let passed = pane.find != nil && state?.selected == nil && state?.total == 0
                    self.log(["find-empty-reopen": passed ? "passed" : "failed", "find-exists": pane.find != nil,
                              "selected": state?.selected ?? -1, "total": state?.total ?? -1])
                    guard passed else { exit(1) }
                    self.verifyStoppedFind(pane, phase: 0)
                }
            }
        } else {
            guard DispatchTime.now() < deadline else {
                self.log(["find-current": "failed", "total": state.total, "selected": state.selected ?? -1, "navigations": state.navigationCount])
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.waitForSelection(pane, stage: stage, deadline: deadline) }
        }
    }

    private func verifyStoppedFind(_ pane: PaneView, phase: Int) {
        guard phase < 2 else {
            (NSApp.delegate as? AppDelegate)?.quit("find verification complete")
            return
        }
        guard let find = pane.find else { exit(1) }
        find.field.stringValue = "row"
        find.search()
        GhosttyRuntime.verifyDeferredSearchAction(pane.surface)
        if phase == 0 { find.field.stringValue = ""; find.search() }
        else { find.invalidate() }
        DispatchQueue.main.async {
            let state = find.stressState
            let rejected = state.selected == nil && state.total == 0
            self.log(["find-stop": rejected ? "passed" : "failed", "phase": phase == 0 ? "clear" : "invalidate",
                      "selected": state.selected ?? -1, "total": state.total])
            guard rejected else { exit(1) }
            self.verifyStoppedFind(pane, phase: phase + 1)
        }
    }

    private func verifyAlternate() {
        guard let pane = (window.contentView.map(views) ?? []).compactMap({ $0 as? PaneView }).first else {
            log(["alternate-verify": "no pane"])
            exit(1)
        }
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            pane.feed(Data(("\u{1b}c" + (0..<500).map { "row\($0)\r\n" }.joined()).utf8))
            DispatchQueue.main.async {
                let position = pane.scrollPosition()
                pane.updateScroller(sampledTmuxHistoryRows: position.retainedHistoryRows, position: position, alternate: false)
                guard pane.verifyFractionalClick() else {
                    self.log(["fractional-click": "failed"])
                    exit(1)
                }
                self.log(["fractional-click": "passed"])
                pane.verifyMailboxPressure(ready)
                DispatchQueue.global().async {
                    let output = "\u{1b}[?1049h" + String(repeating: "\u{1b}]2;mailbox pressure\u{7}ALT\r\n", count: 20000) + "\u{1b}[?1049l"
                    pane.feed(Data(output.utf8))
                    DispatchQueue.main.async {
                        pane.finishMailboxPressure()
                        pane.resetScroll()
                        self.log(["alternate-verify": "passed", "worker-completed": true])
                        (NSApp.delegate as? AppDelegate)?.quit("alternate verification complete")
                    }
                }
                guard ready.wait(timeout: .now() + 2) == .success else { exit(1) }
                self.log(["alternate-verify": "snap under mailbox pressure", "producer-wakes": 65])
                if self.env["KIDO_INPUT_VERIFY"] == "1" {
                    let passed = pane.verifySearchInputPressure()
                    self.log(["input-verify": passed ? "passed" : "failed", "commands": 259, "search-send-reached": passed])
                    guard passed else { exit(1) }
                }
                pane.snapScroll()
            }
        }
    }

    private var expected: CGRect?
    private var fixed: CGPoint?
    private var verificationFailures = 0

    private func verifyFloat(_ phase: Int) {
        let all = window.contentView.map(views) ?? []
        guard let view = visible(all, WindowView.self).first,
              let float = view.stressFloats.first,
              let chrome = view.subviews.compactMap({ $0 as? PaneChrome }).first(where: { $0.pane == float.pane.id }),
              let pane = view.panes.first(where: { $0.pane == float.pane.id }) else {
            log(["verification": phase, "error": "missing float"])
            NSApp.terminate(nil); return
        }
        view.stressEvent = { [weak self] event, detail in
            self?.counts[event, default: 0] += 1
            self?.log(["event": event, "detail": detail, "phase": phase])
        }
        var passed = !window.isVisible && !window.isKeyWindow && !window.isMainWindow && !NSApp.isActive && onScreen() == 0
        if let expected { passed = passed && abs(float.frame.minX - expected.minX) < 0.01 && abs(float.frame.minY - expected.minY) < 0.01 && abs(float.frame.width - expected.width) < 0.01 && abs(float.frame.height - expected.height) < 0.01 }
        if let fixed { passed = passed && abs(float.frame.minX - fixed.x) < 0.01 && abs(float.frame.minY - fixed.y) < 0.01 }
        var metrics = ghostty_surface_grid_metrics_s()
        passed = passed && ghostty_surface_grid_metrics(pane.surface, &metrics)
            && Int(metrics.columns) == float.pane.geometry.width && Int(metrics.rows) == float.pane.geometry.height
            && abs(pane.frame.width - CGFloat(float.pane.geometry.width) * pane.cell.width) < 0.01
            && abs(pane.frame.height - CGFloat(float.pane.geometry.height) * pane.cell.height) < 0.01
            && chrome.frame.maxX >= pane.frame.maxX && chrome.frame.maxY >= pane.frame.maxY
        log(["verification": phase, "passed": passed, "free": float.free,
             "geometry": "\(float.pane.geometry)", "frame": "\(float.frame)", "cell": "\(pane.cell)",
             "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
             "active": NSApp.isActive, "onScreenWindows": onScreen()])
        if !passed { verificationFailures += 1 }
        expected = nil; fixed = nil
        switch phase {
        case 0, 6, 8, 10:
            let hot = chrome.convert(NSPoint(x: chrome.toolbarFrame.minX + 16, y: chrome.toolbarFrame.midY), to: nil)
            chrome.mouseMoved(with: event(.mouseMoved, hot))
            guard let button = views(chrome).compactMap({ $0 as? IconButton }).first(where: { $0.toolTip == "Drag pane" }), let press = button.press else { NSApp.terminate(nil); return }
            let from = button.convert(NSPoint(x: 13, y: 13), to: nil)
            let to = NSPoint(x: from.x + 13.3, y: from.y - 3.1)
            press(event(.leftMouseDown, from)); press(event(.leftMouseDragged, to)); press(event(.leftMouseUp, to))
            expected = phase == 0 ? float.frame.offsetBy(dx: 13.3, dy: 3.1) : chrome.frame
        case 1, 2, 3, 4:
            let local: NSPoint = switch phase {
            case 2: NSPoint(x: chrome.bounds.midX, y: chrome.bounds.maxY - 2)
            case 3: NSPoint(x: 2, y: 2)
            default: NSPoint(x: chrome.bounds.maxX - 2, y: chrome.bounds.midY)
            }
            let from = chrome.convert(local, to: nil)
            let to = NSPoint(x: from.x + (phase == 1 ? 2000 : phase == 3 ? 17.3 : phase == 4 ? -11.7 : 0),
                             y: from.y - (phase == 2 ? 2000 : phase == 3 ? 11.7 : 0))
            view.mouseDown(with: event(.leftMouseDown, from))
            let windows = counts["place-window", default: 0], floats = counts["place-float", default: 0]
            view.mouseDragged(with: event(.leftMouseDragged, to))
            let firstWindows = counts["place-window", default: 0] - windows
            let firstFloats = counts["place-float", default: 0] - floats
            if phase == 1 || phase == 2 { fixed = float.frame.origin }
            expected = chrome.frame
            if phase == 4 { expected = CGRect(origin: float.frame.origin, size: CGSize(width: float.frame.width - 11.7, height: float.frame.height)) }
            view.mouseDragged(with: event(.leftMouseDragged, to))
            view.mouseUp(with: event(.leftMouseUp, to))
            let repeated = counts["place-float", default: 0] - floats - firstFloats
            log(["pointerPlacement": phase, "wholeWindow": firstWindows, "affectedFloat": firstFloats,
                 "repeatedAndUp": repeated, "panes": view.panes.count, "floats": view.stressFloats.count])
            if firstWindows != 0 || firstFloats != 1 || repeated != 0 { verificationFailures += 1 }
        case 5: break
        case 7: pane.onFontChange(pane.font + 2)
        case 9: window.setContentSize(NSSize(width: 1100, height: 670))
        case 11:
            view.isHidden = true
            pane.onFontChange(pane.font + 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                view.isHidden = false
                _ = view.present(DispatchGroup())
            }
        default:
            log(["done": true, "verificationFailures": verificationFailures, "counts": counts])
            NSApp.terminate(nil); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.verifyFloat(phase + 1) }
    }

    private func random(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(n))
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private func visible<T: NSView>(_ all: [NSView], _: T.Type) -> [T] {
        all.compactMap { $0 as? T }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private func log(_ fields: [String: Any]) {
        var fields = fields
        fields.merge(["visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
                      "active": NSApp.isActive, "onScreenWindows": onScreen()]) { _, current in current }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) else { return }
        FileHandle.standardError.write(data + Data("\n".utf8))
        if window.isVisible || window.isKeyWindow || window.isMainWindow || NSApp.isActive || fields["onScreenWindows"] as? Int != 0 { exit(1) }
    }

    private func onScreen() -> Int {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.count { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    private func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil, eventNumber: step, clickCount: 1,
                          pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func tick() {
        step += 1
        if DispatchTime.now() > finish {
            log(["done": true, "counts": counts, "steps": step])
            NSApp.terminate(nil)
            return
        }
        if let app = NSApp.delegate as? AppDelegate {
            var nodes = app.stressState.4?.sessions.flatMap(\.nodes) ?? []
            while let node = nodes.popLast() {
                nodes += node.children
                if case .item(let item) = node, item.run == .bash {
                    let identity = "\(item.window):\(item.started?.timeIntervalSince1970 ?? 0)"
                    if childWindows.insert(identity).inserted {
                        counts["child-window-seen", default: 0] += 1
                        log(["event": "child-window-seen", "window": item.window.description, "pane": item.pane.description])
                    }
                }
            }
        }
        guard rpcTimeout == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.tick() }
            return
        }
        let all = window.contentView.map(views) ?? []
        let panes = visible(all, PaneView.self)
        var action = Self.actions[random(Self.actions.count)]
        if env["STRESS_NO_FIND"] == "1" {
            switch action {
            case .find, .findNext: action = .scrollRequest
            default: break
            }
        }
        for view in visible(all, WindowView.self) {
            view.stressEvent = { [weak self] event, detail in
                guard let self else { return }
                self.counts[event, default: 0] += 1
                self.log(["tick": self.step, "event": event, "detail": detail])
            }
        }
        counts["alternate-pane-steps", default: 0] += panes.filter(\.alternate).count
        let pool = action == .stripPress || action == .stripWheel ? panes.filter { $0.renderInsets.top > 0 } : panes
        let pane = pool.isEmpty ? nil : pool[random(pool.count)]
        counts[action.rawValue, default: 0] += 1
        log(["step": step, "action": action.rawValue, "pane": pane?.pane.description ?? "", "panes": panes.count,
             "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
             "active": NSApp.isActive, "onScreenWindows": onScreen()])
        if [.tabs, .sidebarJump, .sidebarSearch, .sidebarMode].contains(action) { performUI(action) }
        else if let pane { perform(action, pane, all) }
        if step % 5 == 0 { verifyUI() }
        log(["tick": step, "counts": counts])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.tick() }
    }

    private func perform(_ action: Action, _ pane: PaneView, _ all: [NSView]) {
        switch action {
        case .tabs, .sidebarJump, .sidebarSearch, .sidebarMode: break
        case .stripPress:
            let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.height - pane.renderInsets.top / 2), to: nil)
            pane.mouseDown(with: event(.leftMouseDown, point))
            pane.mouseUp(with: event(.leftMouseUp, point))
            counts["strip-press-delivered", default: 0] += 1
        case .alternate:
            send([Command("new-window", "-n", "stress-alt", "while :; do printf '\\033[?1049hALT SCREEN\\n'; sleep 2; printf '\\033[?1049l'; sleep 2; done")])
        case .wheel, .stripWheel:
            let delta = Int32(random(2) == 0 ? 1500 : -500)
            let precise = random(2) == 0
            let packets: [(Int64, Int64)] = precise ? [(1, 0), (2, 0), (4, 0), (0, 1), (0, 2), (0, 3)] : [(0, 0)]
            for (phase, momentum) in packets {
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                    wheelCount: 1, wheel1: phase == 4 || momentum == 3 ? 0 : delta, wheel2: 0, wheel3: 0) {
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                    if action == .stripWheel, let initial = NSEvent(cgEvent: cg) {
                        let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.height - pane.renderInsets.top / 2), to: nil)
                        cg.location = CGPoint(x: cg.location.x + point.x - initial.locationInWindow.x,
                                              y: cg.location.y - point.y + initial.locationInWindow.y)
                    }
                    if let e = NSEvent(cgEvent: cg) {
                        if action == .stripWheel {
                            let local = pane.convert(e.locationInWindow, from: nil)
                            guard pane.bounds.contains(local), pane.bounds.height - local.y < pane.renderInsets.top else {
                                counts["strip-wheel-missed", default: 0] += 1
                                continue
                            }
                            counts["strip-wheel-delivered", default: 0] += 1
                        }
                        counts[e.hasPreciseScrollingDeltas ? "wheel-precise-packet" : "wheel-discrete-packet", default: 0] += 1
                        if !e.momentumPhase.isEmpty { counts["wheel-momentum-packet", default: 0] += 1 }
                        pane.scrollWheel(with: e)
                    }
                }
            }
        case .scrollerDrag:
            do {
                let scroller = pane.scroller
                let x = scroller.bounds.midX
                let thumb = random(2) == 0
                let from = scroller.convert(thumb ? scroller.stressThumb : NSPoint(x: x, y: scroller.bounds.height * 0.75), to: nil)
                if thumb { counts["scroller-thumb-drag", default: 0] += 1 }
                let to = scroller.convert(NSPoint(x: x, y: CGFloat(random(20)) / 20 * scroller.bounds.height), to: nil)
                scroller.mouseDown(with: event(.leftMouseDown, from))
                scroller.mouseDragged(with: event(.leftMouseDragged, to))
                scroller.mouseUp(with: event(.leftMouseUp, to))
            }
        case .scrollRequest:
            pane.requestScroll(random(3) == 0 ? 1000000 : random(1000000))
            guard (pane.scrollTarget ?? 0) <= pane.scrollPosition().retainedHistoryRows else { exit(1) }
        case .find, .findNext:
            pane.showFind()
            pane.find?.field.stringValue = ["ERROR", "999", "INFO", "DEMO-MARKER", "missing"][random(5)]
            pane.find?.search()
            if action == .findNext { pane.find?.field.stringValue = "built"; pane.find?.search(); pane.find?.next() }
        case .findCloseResync:
            pane.find?.close()
            _ = pane.onResync()
        case .resizeBurst:
            for _ in 0..<6 { window.setContentSize(NSSize(width: 760 + fraction(700), height: 430 + fraction(400))) }
        case .loadMore:
            pane.onLoadMore()
        case .gripDrag, .gripDragKill:
            grip(edge: action == .gripDrag, kill: action == .gripDragKill, all)
        case .edgeResize:
            let chromes = visible(all, PaneChrome.self)
            let floats = floatChromes(chromes, all)
            if let chrome = (random(3) > 0 && !floats.isEmpty ? floats : chromes).first, let view = chrome.superview as? WindowView {
                let p = chrome.convert(NSPoint(x: chrome.bounds.maxX - 2, y: chrome.bounds.midY), to: nil)
                view.mouseDown(with: event(.leftMouseDown, p))
                let end = NSPoint(x: p.x + fraction(250) - 50, y: p.y - fraction(120) + 30)
                for i in 1...8 {
                    view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: p.x + (end.x - p.x) * CGFloat(i) / 8,
                                                                          y: p.y + (end.y - p.y) * CGFloat(i) / 8)))
                }
                view.mouseUp(with: event(.leftMouseUp, end))
            }
        case .detachReconnect:
            send([Command("detach-client")])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.reconnect() }
        case .hiddenResize:
            if let hidden = all.compactMap({ $0 as? PaneView }).first(where: { $0.isHiddenOrHasHiddenAncestor }) {
                let size = ghostty_surface_size(hidden.surface)
                send([Command("resize-pane", "-t", hidden.pane, "-x", Int(size.columns) + 3),
                      Command("resize-pane", "-t", hidden.pane, "-x", Int(size.columns)),
                      Command("select-window", "-t", hidden.pane)])
            }
        case .clearHistory:
            send([Command("clear-history", "-t", pane.pane)])
        case .appearance:
            NSApp.appearance = NSAppearance(named: random(2) == 0 ? .aqua : .darkAqua)
        }
    }

    private func key(_ text: String, _ code: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: code)!
    }

    private func check(_ kind: String, _ passed: Bool) {
        counts[kind + "-verified", default: 0] += 1
        log(["verification": kind, "passed": passed])
        if !passed { exit(1) }
    }

    private func verifyUI(_ attempt: Int = 0) {
        guard let app = NSApp.delegate as? AppDelegate, let connection = app.stressState.3 else { return }
        let before = app.stressState.0
        connection.send([Command("display-message", "-p", "#{window_id}")]) { replies in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let (model, navigation, session, current, _) = app.stressState
                guard current === connection, model == before else { return }
                guard case .success(let lines)? = replies?.first else { return }
                let shown = session?.windows.filter { !$0.value.isHidden }.keys.map(\.description) ?? []
                let matched = lines.first == model.window?.description && shown == [model.window?.description ?? ""]
                if !matched, attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.verifyUI(attempt + 1) }
                    return
                }
                self.check("displayed-window", matched)
                self.check("tab-order", app.sidebar.tabs.entries.map(\.id) == navigation.windows.map(\.id))
                let menu = NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
                self.check("shortcut-order", menu?.items.dropFirst(3).enumerated().allSatisfy { index, item in
                    (item.representedObject as? RPCRequest) == navigation.select(.number(index + 1))
                        && item.keyEquivalent == (index < 9 ? "\(index + 1)" : "")
                } == true && menu?.items.count == navigation.windows.count + 3)
            }
        }
    }

    private func afterSidebarReply(_ list: SidebarView, verification: String, action: () -> Void, completed: @escaping @MainActor @Sendable () -> Void) {
        let timeout = DispatchWorkItem { self.check("rpc-completion-deadline", false) }
        rpcTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        let original = list.request
        var requests = 0
        list.request = { request, done in
            requests += 1
            original(request) { result in
                done(result)
                timeout.cancel()
                self.rpcTimeout = nil
                if case .failure(let error) = result { self.log(["rpc-error": error.message]); self.check("rpc-completion", false) }
                else { completed() }
            }
        }
        action()
        list.request = original
        check(verification, requests == 1)
    }

    private func performUI(_ action: Action) {
        guard let app = NSApp.delegate as? AppDelegate, app.stressState.3 != nil else { return }
        let sidebar = app.sidebar, list = sidebar.list
        let all = views(list)
        guard let table = all.compactMap({ $0 as? Table }).first else { return }
        counts[action.rawValue + "-delivered", default: 0] += 1
        switch action {
        case .tabs:
            let tabs = sidebar.tabs
            guard !tabs.entries.isEmpty else { return }
            switch random(3) {
            case 0:
                let children = tabs.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
                let rects = children.map { $0.accessibilityFrameInParentSpace() }.filter { tabs.bounds.contains(NSPoint(x: $0.midX, y: $0.midY)) }
                guard !rects.isEmpty else { return }
                let rect = rects[random(rects.count)]
                tabs.mouseDown(with: event(.leftMouseDown, tabs.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)))
                counts["tab-mouse-down", default: 0] += 1
            case 1:
                _ = NSApp.mainMenu?.performKeyEquivalent(with: key("\(random(9) + 1)", 0, .command))
                counts["tab-cmd-number", default: 0] += 1
            default:
                _ = NSApp.mainMenu?.performKeyEquivalent(with: key(random(2) == 0 ? "}" : "{", 0, .command))
                counts["tab-cmd-brace", default: 0] += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.verifyUI() }
        case .sidebarJump:
            let rows = (0..<table.numberOfRows).filter { list.tableView(table, shouldSelectRow: $0) }
            guard !rows.isEmpty else { return }
            let row = rows[random(rows.count)]
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            afterSidebarReply(list, verification: "one-rpc-jump", action: { table.keyDown(with: key("\r", 36)) }) {
                self.verifyUI()
            }
        case .sidebarSearch:
            table.keyDown(with: key("/"))
            guard let field = all.compactMap({ $0 as? NSSearchField }).first else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.selectAll(nil)
                editor.insertText(["s1", "log", "missing"][random(3)], replacementRange: editor.selectedRange())
            } else { field.stringValue = "s1" }
            field.sendAction(field.action, to: field.target)
            _ = list.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            check("search-escape", list.query.isEmpty)
        case .sidebarMode:
            let lock = env["STRESS_UI_LOCK"] ?? ""
            let generation = app.stressGeneration
            let interrupted: @MainActor @Sendable () -> Bool = {
                guard app.stressGeneration != generation else { return false }
                self.counts["floating-frame-interrupted", default: 0] += 1
                self.log(["floating-probe": "interrupted", "generation": generation, "current-generation": app.stressGeneration])
                try? FileManager.default.removeItem(atPath: lock)
                return true
            }
            _ = FileManager.default.createFile(atPath: lock, contents: Data())
            sidebar.dismissFloating()
            sidebar.isCollapsed = true
            window.contentView?.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
            let frame = sidebar.content.convert(sidebar.content.bounds, to: nil)
            let cell = app.stressState.2?.cell
            let pixel = 1 / window.backingScaleFactor
            let size = cell.map {
                "\(max(1, Int(floor((frame.width - 8 - $0.width + pixel) / $0.width))))x\(max(1, Int(floor((floor((frame.height - 12) / pixel) * pixel - pixel) / $0.height))))"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard !interrupted() else { return }
                self.log(["floating-probe": "begin", "collapsed-size": size ?? "unknown", "generation": generation])
                _ = NSApp.mainMenu?.performKeyEquivalent(with: self.key("s", 1, .command))
                self.window.contentView?.layoutSubtreeIfNeeded()
                sidebar.viewDidLayout()
                guard sidebar.isFloating && sidebar.content.convert(sidebar.content.bounds, to: nil) == frame else {
                    self.check("floating-frame", false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard !interrupted() else { return }
                    self.check("floating-frame", sidebar.isFloating && sidebar.content.convert(sidebar.content.bounds, to: nil) == frame)
                    self.log(["floating-probe": "end"])
                    let dismissed: @MainActor @Sendable () -> Void = {
                        self.check("floating-dismiss", !sidebar.isFloating)
                        for _ in 0..<3 {
                            if self.random(2) == 0 { sidebar.toggleSidebar(nil); self.counts["toolbar-toggle-equivalent", default: 0] += 1 }
                            else { _ = NSApp.mainMenu?.performKeyEquivalent(with: self.key("S", 1, [.command, .shift])); self.counts["sidebar-cmd-shift-s", default: 0] += 1 }
                        }
                        try? FileManager.default.removeItem(atPath: lock)
                    }
                    switch self.random(3) {
                    case 0:
                        self.counts["floating-escape", default: 0] += 1
                        self.afterSidebarReply(list, verification: "one-rpc-release", action: { table.keyDown(with: self.key("\u{1b}", 53)) }, completed: dismissed)
                        return
                    case 1:
                        let point = sidebar.content.convert(NSPoint(x: sidebar.content.bounds.maxX - 10, y: 20), to: nil)
                        self.views(sidebar.splitView).first { String(describing: type(of: $0)) == "Outside" }?
                            .mouseDown(with: self.event(.leftMouseDown, point))
                        self.counts["floating-outside-click", default: 0] += 1
                    default: _ = NSApp.mainMenu?.performKeyEquivalent(with: self.key("s", 1, .command))
                    }
                    dismissed()
                }
            }
        default: break
        }
    }

    private func fraction(_ n: Int) -> CGFloat { CGFloat(random(n * 100)) / 100 + 0.37 }

    private func floatChromes(_ chromes: [PaneChrome], _ all: [NSView]) -> [PaneChrome] {
        let ids = Set(visible(all, WindowView.self).flatMap { $0.stressFloats.map(\.pane.id) })
        return chromes.filter { ids.contains($0.pane) }
    }

    private func grip(edge: Bool, kill: Bool, _ all: [NSView]) {
        let chromes = visible(all, PaneChrome.self)
        guard !chromes.isEmpty else { counts["drag-skipped", default: 0] += 1; return }
        let floats = floatChromes(chromes, all)
        let pool = random(2) == 0 && !floats.isEmpty ? floats : chromes
        let chrome = pool[random(pool.count)]
        let hot = chrome.convert(NSPoint(x: chrome.toolbarFrame.minX + 16, y: chrome.toolbarFrame.midY), to: nil)
        chrome.mouseMoved(with: event(.mouseMoved, hot))
        guard let button = visible(views(chrome), IconButton.self).first(where: {
            $0.toolTip == "Drag pane" && $0.isEnabled
        }), let press = button.press else { counts["drag-skipped", default: 0] += 1; return }
        press(event(.leftMouseDown, button.convert(NSPoint(x: 13, y: 13), to: nil)))
        let other = chromes.first { $0 !== chrome }
        var target = other.map {
            $0.convert(NSPoint(x: edge ? $0.bounds.width * 0.15 : $0.bounds.midX, y: $0.bounds.midY), to: nil)
        } ?? NSPoint(x: -100, y: -100)
        if edge, random(2) == 0, let view = chrome.superview {
            let area = chromes.reduce(CGRect.null) { $0.union($1.frame) }
            let point: NSPoint = switch random(4) {
            case 0: NSPoint(x: area.minX + 10, y: area.midY)
            case 1: NSPoint(x: area.maxX - 10, y: area.midY)
            case 2: NSPoint(x: area.midX, y: area.minY + 10)
            default: NSPoint(x: area.midX, y: area.maxY - 10)
            }
            target = view.convert(point, to: nil)
        }
        target.x += fraction(40) - 20
        target.y += fraction(40) - 20
        press(event(.leftMouseDragged, target))
        if kill {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.counts["drag-killed", default: 0] += 1
                self.log(["tick": self.step, "event": "drag-killed", "detail": chrome.pane.description])
                self.send([Command("kill-pane", "-t", chrome.pane)])
            }
        }
        let escape = !kill && step % 3 == 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if escape, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: self.window.windowNumber, context: nil, characters: "\u{1b}",
                                                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                press(e)
            }
            press(self.event(.leftMouseUp, target))
            self.log(["tick": self.step, "event": "drag-released", "source": chrome.pane.description, "killed": kill])
        }
    }
}
#else
typealias AppWindow = OwnerWindow
#endif
