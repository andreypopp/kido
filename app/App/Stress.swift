import AppKit
import TmuxControl
import GhosttyKit

#if KIDO_STRESS

final class StressWindow: NSWindow {
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
    }
    private static let actions: [Action] = [
        .wheel, .wheel, .stripPress, .stripWheel, .alternate, .scrollerDrag, .scrollerDrag, .scrollRequest, .find, .findNext, .findCloseResync,
        .resizeBurst, .loadMore, .gripDrag, .gripDragKill, .appearance, .edgeResize, .detachReconnect,
    ]
    private let window: NSWindow
    private let send: ([Command]) -> Void
    private let reconnect: () -> Void
    private let env = ProcessInfo.processInfo.environment
    private let finish: DispatchTime
    private var seed: UInt64
    private var step = 0
    private var counts: [String: Int] = [:]
    private var resizeCompleted = Set<ObjectIdentifier>()

    init(window: NSWindow, send: @escaping ([Command]) -> Void, reconnect: @escaping () -> Void) {
        self.window = window
        self.send = send
        self.reconnect = reconnect
        seed = UInt64(env["STRESS_SEED"] ?? "") ?? 1
        finish = .now() + 3 + (Double(env["STRESS_DURATION"] ?? "") ?? 60)
        window.acceptsMouseMovedEvents = true
    }

    func run() {
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
            surface.historyStrip = 9.5
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
            for surface in surfaces { surface.feed(bytes) }
            DispatchQueue.main.async {
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
                    pane.updateScroller(history: position.history, position: position, alternate: false)
                    pane.requestScroll(21)
                    reference.updateScroller(history: position.history, position: position, alternate: false)
                    reference.requestScroll(21)
                    pane.afterScroll {
                        let before = pane.scrollPosition()
                        guard before.history - before.offset == 21 else { exit(1) }
                        let replayed: @MainActor @Sendable (Bool) -> Void = { rejected in
                            guard rejected else { self.log(["replay-fence-app-validation": "failed"]); exit(1) }
                            pane.updateScroller(history: position.history, position: position, alternate: false)
                            for surface in surfaces { surface.restored(epoch: surface.historyEpoch) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                let after = pane.scrollPosition()
                                let acknowledged = self.resizeCompleted.count == 2
                                let pixels = reference.renderedPixels != nil && pane.renderedPixels == reference.renderedPixels
                                let passed = pane.scrollTarget == 21 && after.history - after.offset == 21 && pixels && acknowledged
                                self.log(["replay-verify": passed ? "passed" : "failed", "target": pane.scrollTarget ?? -1,
                                          "before-distance": before.history - before.offset, "after-distance": after.history - after.offset,
                                          "pixels": pixels, "acknowledged": acknowledged])
                                if !passed { exit(1) }
                                (NSApp.delegate as? AppDelegate)?.quit("replay verification complete")
                            }
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
                                        guard pane.scrollPosition().history == position.history, pane.renderedPixels == expected else {
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

    private func verifySnap(_ index: Int) {
        let cases = [(1, false, false), (2, false, false), (1, true, false), (1, false, true)]
        guard index < cases.count else {
            (NSApp.delegate as? AppDelegate)?.quit("snap verification complete")
            return
        }
        guard let pane = (window.contentView.map(views) ?? []).compactMap({ $0 as? PaneView }).first else { exit(1) }
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
                find.loaded(pane.scrollPosition(), limited: false)
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
                pane.updateScroller(history: position.history, position: position, alternate: false)
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
        let pool = action == .stripPress || action == .stripWheel ? panes.filter { $0.historyStrip > 0 } : panes
        let pane = pool.isEmpty ? nil : pool[random(pool.count)]
        counts[action.rawValue, default: 0] += 1
        log(["step": step, "action": action.rawValue, "pane": pane?.pane.description ?? "", "panes": panes.count,
             "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
             "active": NSApp.isActive, "onScreenWindows": onScreen()])
        if let pane { perform(action, pane, all) }
        log(["tick": step, "counts": counts])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.tick() }
    }

    private func perform(_ action: Action, _ pane: PaneView, _ all: [NSView]) {
        switch action {
        case .stripPress:
            let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.height - pane.historyStrip / 2), to: nil)
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
                        let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.height - pane.historyStrip / 2), to: nil)
                        cg.location = CGPoint(x: cg.location.x + point.x - initial.locationInWindow.x,
                                              y: cg.location.y - point.y + initial.locationInWindow.y)
                    }
                    if let e = NSEvent(cgEvent: cg) {
                        if action == .stripWheel {
                            let local = pane.convert(e.locationInWindow, from: nil)
                            guard pane.bounds.contains(local), pane.bounds.height - local.y < pane.historyStrip else {
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
                view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: p.x + fraction(250) - 50, y: p.y - fraction(120) + 30)))
                view.mouseUp(with: event(.leftMouseUp, p))
            }
        case .detachReconnect:
            send([Command("detach-client")])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.reconnect() }
        case .appearance:
            NSApp.appearance = NSAppearance(named: random(2) == 0 ? .aqua : .darkAqua)
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
typealias AppWindow = NSWindow
#endif
