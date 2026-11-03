import AppKit
import GhosttyKit
import KoClient
import KoModel
import SidebarFeed
import PaneGeometry

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
        case find, findNext = "find-next", findClose = "find-close"
        case resizeBurst = "resize-burst", gripDrag = "grip-drag", gripDragKill = "grip-drag-kill", appearance, edgeResize = "edge-resize"
        case layoutEdit = "layout-edit", hiddenResize = "hidden-resize"
        case tabs, sidebarJump = "sidebar-jump", sidebarMode = "sidebar-mode"
    }
    private static let actions: [Action] = [
        .wheel, .wheel, .stripPress, .stripWheel, .alternate, .scrollerDrag, .scrollerDrag, .scrollRequest, .find, .findNext, .findClose,
        .resizeBurst, .gripDrag, .gripDragKill, .appearance, .edgeResize, .layoutEdit, .layoutEdit, .hiddenResize, .tabs, .sidebarJump,
        .sidebarMode,
    ]
    private let owner: WindowOwner
    private var window: NSWindow { owner.window }
    private let env = ProcessInfo.processInfo.environment
    private let finish: DispatchTime
    private var seed: UInt64
    private var step = 0
    private var waiting: DispatchWorkItem?
    private var counts: [String: Int] = [:]
    private var childWindows = Set<String>()

    init(owner: WindowOwner) {
        self.owner = owner
        seed = UInt64(env["STRESS_SEED"] ?? "") ?? 1
        finish = .now() + 3 + (Double(env["STRESS_DURATION"] ?? "") ?? 60)
        owner.window.acceptsMouseMovedEvents = true
    }

    func run() {
        log(["input-delivery": "Off-screen: view event methods and menu performKeyEquivalent called directly; toolbar toggle invokes its entry point, not an NSToolbar click"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.tick() }
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
        var nodes = owner.stressState.3?.sessions.flatMap(\.nodes) ?? []
        while let node = nodes.popLast() {
            nodes += node.children
            if case .item(let item) = node, item.run != nil, case .live(.terminal) = item.lifecycle {
                let identity = "\(item.window):\(item.started?.timeIntervalSince1970 ?? 0)"
                if childWindows.insert(identity).inserted {
                    counts["child-window-seen", default: 0] += 1
                    log(["event": "child-window-seen", "window": item.window.description, "pane": item.pane.description])
                }
            }
        }
        guard waiting == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.tick() }
            return
        }
        let all = window.contentView.map(views) ?? []
        let panes = visible(all, PaneView.self)
        var action = Self.actions[random(Self.actions.count)]
        if env["STRESS_NO_FIND"] == "1", [.find, .findNext].contains(action) { action = .scrollRequest }
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
        if [.tabs, .sidebarJump, .sidebarMode].contains(action) { performUI(action) }
        else if let pane { perform(action, pane, all) }
        if step % 5 == 0 { verifyUI() }
        log(["tick": step, "counts": counts])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.tick() }
    }

    private func perform(_ action: Action, _ pane: PaneView, _ all: [NSView]) {
        switch action {
        case .tabs, .sidebarJump, .sidebarMode: break
        case .stripPress:
            let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.height - pane.renderInsets.top / 2), to: nil)
            pane.mouseDown(with: event(.leftMouseDown, point))
            pane.mouseUp(with: event(.leftMouseUp, point))
            counts["strip-press-delivered", default: 0] += 1
        case .alternate:
            guard let model = owner.stressModel, let session = model.selection.session ?? model.layout.layout.sessions.first?.id,
                  let last = model.layout.layout.sessions.first(where: { $0.id == session })?.windows.last else { return }
            let script = "while :; do printf '\\033[?1049hALT SCREEN\\n'; sleep 2; printf '\\033[?1049l'; sleep 2; done"
            owner.stressEdit(.addWindow(KoSchema.EditAddWindow(after: last.id, new: KoSchema.CreatePane(command: .shell(.init(command: script))), session: session)))
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
        case .findClose:
            pane.find?.close()
        case .resizeBurst:
            for _ in 0..<6 { window.setContentSize(NSSize(width: 760 + fraction(700), height: 430 + fraction(400))) }
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
        case .layoutEdit:
            layoutEdit(pane)
        case .hiddenResize:
            hiddenResize(all)
        case .appearance:
            NSApp.appearance = NSAppearance(named: random(2) == 0 ? .aqua : .darkAqua)
        }
    }

    // One random edit of the shown window, through the owner's editor as a gesture sends it.
    private func layoutEdit(_ pane: PaneView) {
        guard let window = owner.stressModel?.layout.layout.locate(pane.pane)?.window else { return }
        let other = window.panes[random(window.panes.count)]
        let edges: [KoSchema.Edge] = [.left, .right, .top, .bottom]
        let edit: KoSchema.Edit = switch random(6) {
        case 0: .split(KoSchema.EditSplit(axis: random(2) == 0 ? .h : .v, new: KoSchema.CreatePane(), pane: pane.pane))
        case 1: .toggleZoom(KoSchema.EditToggleZoom(pane: pane.pane))
        case 2: .equalize(KoSchema.EditEqualize(pane: pane.pane))
        case 3: .resizeBy(KoSchema.EditResizeBy(delta: 1 + random(8), edge: edges[random(4)], pane: pane.pane))
        case 4: .swap(KoSchema.EditSwap(other: other, pane: pane.pane))
        default: .float(KoSchema.EditFloat(pane: pane.pane, x: random(60), y: random(20)))
        }
        counts["layout-edit-sent", default: 0] += 1
        log(["tick": step, "event": "layout-edit", "detail": "\(edit)"])
        owner.stressEdit(edit)
    }

    // A pane of a hidden window gets a new size and back, then its window is shown.
    private func hiddenResize(_ all: [NSView]) {
        guard let hidden = all.compactMap({ $0 as? PaneView }).first(where: { $0.isHiddenOrHasHiddenAncestor }),
              let (session, window) = owner.stressModel?.layout.layout.locate(hidden.pane) else { return }
        owner.stressEdit(.resizeBy(KoSchema.EditResizeBy(delta: 3, edge: .right, pane: hidden.pane)))
        owner.stressEdit(.resizeBy(KoSchema.EditResizeBy(delta: 3, edge: .left, pane: hidden.pane)))
        owner.perform(.selectWindow(session.id, window.id))
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

    // The window that the client selected is the one shown, and the tabs and shortcuts follow the navigation.
    private func verifyUI(_ attempt: Int = 0) {
        guard let app = NSApp.delegate as? AppDelegate, let model = owner.stressModel else { return }
        let (current, navigation, session, _) = owner.stressState
        let shown = session?.windows.filter { !$0.value.isHidden }.keys.map { $0 } ?? []
        let matched = model.selection.window == current.window && shown == [current.window].compactMap { $0 }
        if !matched, attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.verifyUI(attempt + 1) }
            return
        }
        check("displayed-window", matched)
        check("tab-order", app.sidebar.tabs.entries.map(\.id) == navigation.windows.map(\.id))
        let menu = NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
        check("shortcut-order", menu?.items.dropFirst(3).enumerated().allSatisfy { index, item in
            (item.representedObject as? Navigation) == navigation.select(.number(index + 1))
                && item.keyEquivalent == (index < 9 ? "\(index + 1)" : "")
        } == true && menu?.items.count == navigation.windows.count + 3)
    }

    // Holds the external actions until the client selected `pane`, with a deadline.
    private func afterSelection(_ pane: PaneID, verification: String) {
        let lock = env["STRESS_UI_LOCK"] ?? ""
        let ownsLock = !FileManager.default.fileExists(atPath: lock)
        if ownsLock { _ = FileManager.default.createFile(atPath: lock, contents: Data()) }
        var finish: ((_ selected: Bool) -> Void)?
        let timeout = DispatchWorkItem { finish?(false) }
        waiting = timeout
        finish = { selected in
            timeout.cancel()
            self.owner.stressModelReceived = nil
            self.waiting = nil
            if ownsLock { try? FileManager.default.removeItem(atPath: lock) }
            self.check(verification, selected)
            self.verifyUI()
        }
        let evaluate = {
            guard let model = self.owner.stressModel else { return }
            if model.selection.pane == pane { finish?(true) }
            else if !model.panes.contains(where: { $0.id == pane }) {
                // The target was deleted before the select reached the core: no selection can follow.
                self.counts["jump-target-gone", default: 0] += 1
                timeout.cancel()
                self.owner.stressModelReceived = nil
                self.waiting = nil
                if ownsLock { try? FileManager.default.removeItem(atPath: lock) }
            }
        }
        owner.stressModelReceived = evaluate
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        evaluate()
    }

    private func performUI(_ action: Action) {
        guard let app = NSApp.delegate as? AppDelegate, owner.stressModel != nil else { return }
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
                let point = tabs.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                tabs.mouseDown(with: event(.leftMouseDown, point))
                tabs.mouseUp(with: event(.leftMouseUp, point))
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
            guard let target = list.stressRows[row].target else { return }
            table.keyDown(with: key("\r", 36))
            afterSelection(target.pane, verification: "jump-selects")
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
                        table.keyDown(with: self.key("\u{1b}", 53))
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
                self.owner.stressDelete(chrome.pane)
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
