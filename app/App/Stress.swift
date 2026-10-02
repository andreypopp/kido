import AppKit
import TmuxControl

#if KIDO_STRESS

final class StressWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

typealias AppWindow = StressWindow

@MainActor final class Stress {
    private static let names = [
        "wheel", "wheel", "scroller-drag", "scroller-drag", "scroll-request", "find", "find-next", "find-close-resync",
        "resize-burst", "load-more", "grip-drag", "grip-drag-kill", "appearance", "edge-resize", "detach-reconnect",
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

    func run() { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.tick() } }

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

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                               context: nil, eventNumber: step, clickCount: 1, pressure: pressure)
        }
        guard let e = event(type, pressure: 1) else { return }
        if type == .leftMouseDown, let hit = window.contentView.flatMap({ $0.hitTest($0.convert(point, from: nil)) }),
           hit is NSButton, (hit as? IconButton)?.press == nil, let up = event(.leftMouseUp, pressure: 0) {
            NSApp.postEvent(up, atStart: false)
        }
        window.sendEvent(e)
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
        var n = random(Self.names.count)
        if env["STRESS_NO_FIND"] == "1" && (n == 5 || n == 6) { n = 4 }
        let pane = panes.isEmpty ? nil : panes[random(panes.count)]
        counts[Self.names[n], default: 0] += 1
        log(["step": step, "action": Self.names[n], "pane": pane?.pane.description ?? "", "panes": panes.count,
             "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
             "active": NSApp.isActive, "onScreenWindows": onScreen()])
        if let pane { perform(n, pane, all) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.tick() }
    }

    private func perform(_ n: Int, _ pane: PaneView, _ all: [NSView]) {
        switch n {
        case 0, 1:
            let delta = Int32(random(2) == 0 ? 1500 : -500)
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0),
               let e = NSEvent(cgEvent: cg) {
                pane.scrollWheel(with: e)
            }
        case 2, 3:
            do {
                let scroller = pane.scroller
                let x = scroller.bounds.midX
                let from = scroller.convert(NSPoint(x: x, y: scroller.bounds.height * 0.75), to: nil)
                let to = scroller.convert(NSPoint(x: x, y: CGFloat(random(20)) / 20 * scroller.bounds.height), to: nil)
                mouse(.leftMouseDown, from); mouse(.leftMouseDragged, to); mouse(.leftMouseUp, to)
            }
        case 4:
            pane.requestScroll(random(3) == 0 ? 1000000 : random(1000000))
        case 5, 6:
            pane.showFind()
            pane.find?.field.stringValue = ["ERROR", "999", "INFO", "DEMO-MARKER", "missing"][random(5)]
            pane.find?.search()
            if n == 6 { pane.find?.field.stringValue = "built"; pane.find?.search(); pane.find?.next() }
        case 7:
            pane.find?.close()
            pane.onResync {}
        case 8:
            for _ in 0..<6 { window.setContentSize(NSSize(width: 760 + random(700), height: 430 + random(400))) }
        case 9:
            pane.onLoadMore()
        case 10, 11:
            grip(edge: n == 10, kill: n == 11 && step % 5 == 0, all)
        case 13:
            if let chrome = visible(all, PaneChrome.self).first {
                let p = chrome.convert(NSPoint(x: chrome.bounds.maxX - 14, y: chrome.bounds.midY), to: nil)
                mouse(.leftMouseDown, p); mouse(.leftMouseDragged, NSPoint(x: p.x + 200, y: p.y - 90)); mouse(.leftMouseUp, p)
            }
        case 14:
            send([Command("detach-client")])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.reconnect() }
        default:
            NSApp.appearance = NSAppearance(named: random(2) == 0 ? .aqua : .darkAqua)
        }
    }

    private func grip(edge: Bool, kill: Bool, _ all: [NSView]) {
        let chromes = visible(all, PaneChrome.self)
        guard let chrome = chromes.first else { return }
        let hot = chrome.convert(NSPoint(x: chrome.toolbarFrame.minX + 16, y: chrome.toolbarFrame.midY), to: nil)
        mouse(.mouseMoved, hot)
        guard let button = window.contentView.map(views)?.compactMap({ $0 as? IconButton }).first(where: {
            $0.toolTip == "Drag pane" && !$0.isHiddenOrHasHiddenAncestor && $0.superview?.superview?.alphaValue != 0
        }) else { return }
        mouse(.leftMouseDown, button.convert(NSPoint(x: 13, y: 13), to: nil))
        let target = chromes.count > 1
            ? chromes[1].convert(NSPoint(x: edge ? 5 : chromes[1].bounds.midX, y: chromes[1].bounds.midY), to: nil)
            : NSPoint(x: -100, y: -100)
        mouse(.leftMouseDragged, target)
        if kill {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.send([Command("kill-pane", "-t", chrome.pane)]) }
        }
        let escape = step % 3 == 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if escape, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: self.window.windowNumber, context: nil, characters: "\u{1b}",
                                                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                self.window.sendEvent(e)
            }
            self.mouse(.leftMouseUp, target)
        }
    }
}
#else
typealias AppWindow = NSWindow
#endif
