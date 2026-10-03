import AppKit
import os
import GhosttyKit

@MainActor final class GhosttyRuntime {
    private(set) var app: ghostty_app_t!
    private(set) var config: ghostty_config_t
    private var appearance: NSKeyValueObservation?
    var onConfigChange: () -> Void = {}
    var onColorSchemeChange: () -> Void = {}

    var colorScheme: ghostty_color_scheme_e {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }
    nonisolated private let ticking = OSAllocatedUnfairLock(initialState: false)
    #if KIDO_STRESS
    private final class WakeProbe: Sendable {
        let run: @Sendable () -> Void
        init(_ run: @escaping @Sendable () -> Void) { self.run = run }
    }
    nonisolated private let wakeProbe = OSAllocatedUnfairLock<WakeProbe?>(initialState: nil)
    static func observeWakeups(_ surface: ghostty_surface_t, _ probe: (@Sendable () -> Void)?) {
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ghostty_app_userdata(ghostty_surface_app(surface)!)!).takeUnretainedValue()
        runtime.wakeProbe.withLock { $0 = probe.map(WakeProbe.init) }
    }
    #endif

    init?() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
              let config = ghostty_config_new() else { return nil }
        let themes = Bundle.main.resourceURL!.appendingPathComponent("themes").path
        let defaults = "theme = light:\(themes)/kido-light,dark:\(themes)/kido-dark\ncursor-style-blink = false\nalpha-blending = linear\nscrollback-limit = 536870912\nkeybind = super+k=unbind\n"
        ghostty_config_load_string(config, defaults, UInt(defaults.utf8.count), "/kido-defaults")
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let file = (xdg ?? NSHomeDirectory() + "/.config") + "/kido/kido-app.conf"
        if FileManager.default.fileExists(atPath: file) { ghostty_config_load_file(config, file) }
        ghostty_config_load_recursive_files(config)
        let tiling = "window-padding-x = 0\nwindow-padding-y = 0\nscrollbar = never\n"
        ghostty_config_load_string(config, tiling, UInt(tiling.utf8.count), "/kido")
        ghostty_config_finalize(config)
        for i in 0..<ghostty_config_diagnostics_count(config) {
            note("ghostty config: \(String(cString: ghostty_config_get_diagnostic(config, i).message))")
        }
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { @Sendable userdata in
                let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata!).takeUnretainedValue()
                #if KIDO_STRESS
                let probe = runtime.wakeProbe.withLock { $0 }
                probe?.run()
                #endif
                guard runtime.ticking.withLock({ ticking in
                    defer { ticking = true }
                    return !ticking
                }) else { return }
                DispatchQueue.main.async {
                    runtime.ticking.withLock { $0 = false }
                    if let app = runtime.app { ghostty_app_tick(app) }
                }
            },
            action_cb: { @Sendable app, target, action in
                GhosttyRuntime.action(app!, target, action)
            },
            read_clipboard_cb: { @Sendable userdata, location, state in
                GhosttyRuntime.readClipboard(PaneView.surface(userdata), location, state)
            },
            // Ghostty asks from the main thread: from a paste binding, or from
            // its app tick for an OSC 52 read.
            confirm_read_clipboard_cb: { @Sendable userdata, string, state, request in
                nonisolated(unsafe) let (userdata, state) = (userdata, state)
                let text = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? string.map { String(cString: $0) } : nil
                MainActor.assumeIsolated {
                    let view = Unmanaged<PaneView>.fromOpaque(userdata!).takeUnretainedValue()
                    guard let text else { return view.deny(state) }
                    view.confirmPaste(text, state)
                }
            },
            write_clipboard_cb: { @Sendable _, location, content, count, confirm in
                GhosttyRuntime.writeClipboard(location, content, count, confirm)
            },
            close_surface_cb: { @Sendable userdata, _ in PaneView.onMain(userdata) { $0.onCommand(.close) } },
            tmux_control_cb: nil)
        guard let new = ghostty_app_new(&runtime, config) else { return nil }
        nonisolated(unsafe) let app = new
        self.app = app
        ghostty_app_set_color_scheme(app, colorScheme)
        appearance = NSApp.observe(\.effectiveAppearance) { @Sendable [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ghostty_app_set_color_scheme(app, self.colorScheme)
                self.onColorSchemeChange()
            }
        }

        ghostty_app_set_focus(app, NSApp.isActive)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            ghostty_app_set_focus(app, true)
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            ghostty_app_set_focus(app, false)
        }
        center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { _ in
            ghostty_app_keyboard_changed(app)
        }
    }

    var background: NSColor {
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return .black }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    deinit { MainActor.assumeIsolated { ghostty_config_free(config) } }

    nonisolated private static func action(_ app: ghostty_app_t, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ghostty_app_userdata(app)!).takeUnretainedValue()
        if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
            guard target.tag == GHOSTTY_TARGET_APP,
                  let config = ghostty_config_clone(action.action.config_change.config) else { return true }
            nonisolated(unsafe) let owned = config
            DispatchQueue.main.async {
                ghostty_config_free(runtime.config)
                runtime.config = owned
                runtime.onConfigChange()
            }
            return true
        }
        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
            if target.tag == GHOSTTY_TARGET_APP {
                DispatchQueue.main.async { ghostty_app_update_config_without_surface_propagation(runtime.app, runtime.config) }
            } else if let surface = target.target.surface {
                PaneView.onMain(ghostty_surface_userdata(surface)) { pane in
                    pane.reflow { ghostty_surface_update_config(pane.surface, runtime.config) }
                }
            }
            return true
        }
        if action.tag == GHOSTTY_ACTION_QUIT {
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.quit("Ghostty's quit action") }
            return true
        }
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return false }
        let userdata = ghostty_surface_userdata(surface)
        switch action.tag {
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            PaneView.onMain(userdata) {
                $0.showFind()
                if let needle { $0.find?.field.stringValue = needle; $0.find?.search() }
            }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            let generation = ghostty_surface_search_generation(surface)
            let view = Unmanaged<PaneView>.fromOpaque(userdata!)
            let find = MainActor.assumeIsolated { view._withUnsafeGuaranteedRef(\.find) }
            PaneView.onMain(userdata) {
                guard ghostty_surface_search_generation($0.surface) == generation, $0.find === find else { return }
                $0.find?.close()
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            let generation = ghostty_surface_search_generation(surface)
            PaneView.onMain(userdata) {
                guard ghostty_surface_search_generation($0.surface) == generation else { return }
                $0.find?.ghosttyTotal(total)
            }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            let generation = ghostty_surface_search_generation(surface)
            PaneView.onMain(userdata) {
                guard ghostty_surface_search_generation($0.surface) == generation else { return }
                $0.find?.ghosttySelected(selected)
            }
            return true
        default: break
        }
        if action.tag == GHOSTTY_ACTION_SCROLLBAR {
            PaneView.onMain(userdata) { $0.refreshScroller() }
            return true
        }
        if action.tag == GHOSTTY_ACTION_CELL_SIZE {
            PaneView.onMain(userdata) { $0.onCellChange() }
            return true
        }
        guard let command = command(action) else { return false }
        PaneView.onMain(userdata) { $0.onCommand(command) }
        return true
    }

    #if KIDO_STRESS
    static func verifyDeferredSearchAction(_ surface: ghostty_surface_t) {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = surface
        var notification = ghostty_action_s()
        notification.tag = GHOSTTY_ACTION_SEARCH_SELECTED
        notification.action.search_selected.selected = 0
        _ = action(ghostty_surface_app(surface)!, target, notification)
        notification.tag = GHOSTTY_ACTION_SEARCH_TOTAL
        notification.action.search_total.total = 999
        _ = action(ghostty_surface_app(surface)!, target, notification)
    }
    #endif

    nonisolated private static func command(_ action: ghostty_action_s) -> PaneCommand? {
        let a = action.action
        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            return switch a.new_split {
            case GHOSTTY_SPLIT_DIRECTION_LEFT: .split(.left)
            case GHOSTTY_SPLIT_DIRECTION_UP: .split(.up)
            case GHOSTTY_SPLIT_DIRECTION_DOWN: .split(.down)
            default: .split(.right)
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            return switch a.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: .previous
            case GHOSTTY_GOTO_SPLIT_NEXT: .next
            case GHOSTTY_GOTO_SPLIT_LEFT: .select(.left)
            case GHOSTTY_GOTO_SPLIT_UP: .select(.up)
            case GHOSTTY_GOTO_SPLIT_DOWN: .select(.down)
            default: .select(.right)
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let side: Side = switch a.resize_split.direction {
            case GHOSTTY_RESIZE_SPLIT_LEFT: .left
            case GHOSTTY_RESIZE_SPLIT_UP: .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: .down
            default: .right
            }
            return .resize(side, points: Double(a.resize_split.amount))
        case GHOSTTY_ACTION_GOTO_TAB:
            return switch a.goto_tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS: .window(.previous)
            case GHOSTTY_GOTO_TAB_NEXT: .window(.next)
            case GHOSTTY_GOTO_TAB_LAST: .window(.last)
            case let n where n.rawValue >= 1: .window(.number(Int(n.rawValue)))
            default: nil
            }
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM: return .zoom
        case GHOSTTY_ACTION_EQUALIZE_SPLITS: return .equalize
        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW: return .newWindow
        default: return nil
        }
    }

    nonisolated private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        location == GHOSTTY_CLIPBOARD_STANDARD ? .general : nil
    }

    nonisolated private static func readClipboard(
        _ surface: ghostty_surface_t?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let surface,
              let text = pasteboard(location)?.string(forType: .string) else { return false }
        ghostty_surface_complete_clipboard_request(surface, text, state, false)
        return true
    }

    nonisolated private static func writeClipboard(
        _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ count: Int,
        _ confirm: Bool
    ) {
        guard !confirm, let content, let pasteboard = pasteboard(location) else { return }
        let text = (0..<count).first { String(cString: content[$0].mime) == "text/plain" }
            .map { String(cString: content[$0].data) }
        guard let text else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
