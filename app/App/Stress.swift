import AppKit
import TmuxControl
import GhosttyKit

#if KIDO_STRESS

final class StressWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

typealias AppWindow = StressWindow

@MainActor final class Stress {
    private enum Action: String {
        case wheel, scrollerDrag = "scroller-drag", scrollRequest = "scroll-request"
        case find, findNext = "find-next", findCloseResync = "find-close-resync"
        case resizeBurst = "resize-burst", loadMore = "load-more", gripDrag = "grip-drag"
        case gripDragKill = "grip-drag-kill", appearance, edgeResize = "edge-resize", detachReconnect = "detach-reconnect"
    }
    private static let actions: [Action] = [
        .wheel, .wheel, .scrollerDrag, .scrollerDrag, .scrollRequest, .find, .findNext, .findCloseResync,
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
            if self.env["KIDO_FLOAT_VERIFY"] == "1" { self.verifyFloat(0) }
            else { self.tick() }
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
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) else { return }
        FileHandle.standardError.write(data + Data("\n".utf8))
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
        let pane = panes.isEmpty ? nil : panes[random(panes.count)]
        counts[action.rawValue, default: 0] += 1
        log(["step": step, "action": action.rawValue, "pane": pane?.pane.description ?? "", "panes": panes.count,
             "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
             "active": NSApp.isActive, "onScreenWindows": onScreen()])
        if let pane { perform(action, pane, all) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.tick() }
    }

    private func perform(_ action: Action, _ pane: PaneView, _ all: [NSView]) {
        switch action {
        case .wheel:
            let delta = Int32(random(2) == 0 ? 1500 : -500)
            let precise = random(2) == 0
            let packets: [(Int64, Int64)] = precise ? [(1, 0), (2, 0), (4, 0), (0, 1), (0, 2), (0, 3)] : [(0, 0)]
            for (phase, momentum) in packets {
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                    wheelCount: 1, wheel1: phase == 4 || momentum == 3 ? 0 : delta, wheel2: 0, wheel3: 0) {
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                    if let e = NSEvent(cgEvent: cg) {
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
            pane.onResync {}
        case .resizeBurst:
            for _ in 0..<6 { window.setContentSize(NSSize(width: 760 + random(700), height: 430 + random(400))) }
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
