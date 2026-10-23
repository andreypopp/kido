import AppKit
import os
import GhosttyKit

@MainActor final class GhosttyRuntime {
    private(set) var app: ghostty_app_t!
    private(set) var config: ghostty_config_t
    private var appearance: NSKeyValueObservation?
    let pasteboard: NSPasteboard
    let sidebarShade: Double?
    nonisolated private static func protectClipboard(_ config: ghostty_config_t) {
        var access: UnsafePointer<CChar>?
        let key = "clipboard-read"
        if ghostty_config_get(config, &access, key, UInt(key.utf8.count)), access.map({ String(cString: $0) }) != "allow" { return }
        let policy = "clipboard-read = ask\n"
        ghostty_config_load_string(config, policy, UInt(policy.utf8.count), "/kido-clipboard")
    }
    var onConfigChange: () -> Void = {}
    var onColorSchemeChange: () -> Void = {}

    var colorScheme: ghostty_color_scheme_e {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }
    nonisolated private let ticking = OSAllocatedUnfairLock(initialState: false)
    #if KIDO_VISUAL
    nonisolated private let wakeups = OSAllocatedUnfairLock(initialState: 0)
    nonisolated var visualWakeups: Int { wakeups.withLock { $0 } }
    #endif
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

    init?(configFile: String? = nil, pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
              let config = ghostty_config_new() else { return nil }
        let themes = Bundle.main.resourceURL!.appendingPathComponent("themes").path
        let defaults = "theme = light:\(themes)/kido-light,dark:\(themes)/kido-dark\ncursor-style-blink = false\nalpha-blending = linear\nscrollback-limit = 536870912\nkeybind = super+k=unbind\nkeybind = super+j=unbind\nkeybind = super+s=unbind\nkeybind = super+shift+s=unbind\n"
        ghostty_config_load_string(config, defaults, UInt(defaults.utf8.count), "/kido-defaults")
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let file = configFile ?? (xdg ?? NSHomeDirectory() + "/.config") + "/kido/kido-app.conf"
        if FileManager.default.fileExists(atPath: file) { ghostty_config_load_file(config, file) }
        ghostty_config_load_recursive_files(config)
        let sidebarKey = "kido-sidebar-shade"
        let sidebarValue = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == sidebarKey ? parts[1] : nil
        }.last
        sidebarShade = sidebarValue.flatMap { value in
            guard let percent = Double(value.hasSuffix("%") ? String(value.dropLast()) : value), (-100...100).contains(percent)
            else { note("\(sidebarKey): not a percentage from -100 to 100: \(value)"); return nil }
            return percent / 100
        }
        let tiling = "window-padding-x = 0\nwindow-padding-y = 0\nscrollbar = never\n"
        ghostty_config_load_string(config, tiling, UInt(tiling.utf8.count), "/kido")
        ghostty_config_finalize(config)
        Self.protectClipboard(config)
        for i in 0..<ghostty_config_diagnostics_count(config) {
            let message = String(cString: ghostty_config_get_diagnostic(config, i).message)
            if message.hasSuffix(":\(sidebarKey): unknown field") { continue }
            note("ghostty config: \(message)")
        }
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            supports_paste_events: true,
            wakeup_cb: { @Sendable userdata in
                let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata!).takeUnretainedValue()
                #if KIDO_VISUAL
                runtime.wakeups.withLock { $0 += 1 }
                #endif
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
            read_clipboard_cb: { @Sendable userdata, location, state, mimes, count, list in
                nonisolated(unsafe) let (userdata, state) = (userdata, state)
                let requested = (0..<count).compactMap { mimes?[$0].map { String(cString: $0) } }
                return MainActor.assumeIsolated {
                    let view = Unmanaged<PaneView>.fromOpaque(userdata!).takeUnretainedValue()
                    guard view.acceptingInput, let state else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
                    switch ghostty_clipboard_request_kind(state) {
                    case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                        let image = location == GHOSTTY_CLIPBOARD_STANDARD && view.pasteImage()
                        let text = image ? "" : view.pasting ?? view.runtime.pasteboard.string(forType: .string) ?? ""
                        GhosttyRuntime.completeClipboard(view.surface, [("text/plain", Data(text.utf8))], available: list ? ["text/plain"] : [], state, confirmed: false)
                    case GHOSTTY_CLIPBOARD_REQUEST_LIST:
                        view.listClipboard(state)
                    case GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ:
                        guard location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
                        view.readClipboard(state, requested, list: list)
                    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
                        view.requestClipboard(state, ["text/plain"], list: false, .clipboard)
                    default: return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
                    }
                    return GHOSTTY_CLIPBOARD_READ_STARTED
                }
            },
            // Ghostty asks from the main thread: from a paste binding, or from
            // its app tick for an OSC 52 read.
            confirm_read_clipboard_cb: { @Sendable userdata, payload, state, request in
                nonisolated(unsafe) let (userdata, state) = (userdata, state)
                var text: String?
                if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let payload = payload?.pointee, let contents = payload.contents,
                   let index = (0..<payload.contents_len).first(where: { String(cString: contents[$0].mime) == "text/plain" }) {
                    let content = contents[index]
                    text = String(decoding: UnsafeRawBufferPointer(start: content.data, count: content.len), as: UTF8.self)
                }
                MainActor.assumeIsolated {
                    let view = Unmanaged<PaneView>.fromOpaque(userdata!).takeUnretainedValue()
                    if let text { view.confirmPaste(text, state) }
                    else if request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ { view.requestClipboard(state, ["text/plain"], list: false, .clipboard) }
                    else { view.deny(state) }
                }
            },
            write_clipboard_cb: { @Sendable userdata, _, content, count, confirm in
                GhosttyRuntime.writeClipboard(userdata, content, count, confirm)
            },
            close_surface_cb: { @Sendable userdata, _ in PaneView.onMain(userdata) { $0.onCommand(.close) } })
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

    var background: NSColor { color("background") }
    var foreground: NSColor { color("foreground") }

    private func color(_ key: String) -> NSColor {
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return .black }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    deinit { MainActor.assumeIsolated { ghostty_config_free(config) } }

    nonisolated static func action(_ app: ghostty_app_t, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ghostty_app_userdata(app)!).takeUnretainedValue()
        if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
            guard target.tag == GHOSTTY_TARGET_APP,
                  let config = ghostty_config_clone(action.action.config_change.config) else { return true }
            protectClipboard(config)
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
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            PaneView.onMain(userdata) { $0.setMouseShape(shape) }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let link = action.action.open_url
            if link.kind != GHOSTTY_ACTION_OPEN_URL_KIND_OSC8,
               Unmanaged<PaneView>.fromOpaque(userdata!)._withUnsafeGuaranteedRef(\.host) == .local { return false }
            guard let bytes = link.url else { return true }
            let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(link.len)), as: UTF8.self)
            PaneView.onMain(userdata) { $0.onURL(text) }
            return true
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
            let value = action.action.search_selected, selected = value.selected
            let start = value.has_start ? (x: Int(value.start_x), y: Int(value.start_y)) : nil
            let generation = ghostty_surface_search_generation(surface)
            nonisolated(unsafe) let userdata = userdata
            let deliver: @Sendable () -> Void = {
                PaneView.onMain(userdata) {
                    guard ghostty_surface_search_generation($0.surface) == generation else { return }
                    $0.find?.ghosttySelected(selected, start: start)
                }
            }
            #if KIDO_VISUAL
            if MainActor.assumeIsolated({ visualHoldSelected.map { $0(start, deliver) } != nil }) { return true }
            #endif
            deliver()
            return true
        default: break
        }
        if action.tag == GHOSTTY_ACTION_SCROLLBAR {
            PaneView.onMain(userdata) { if $0.scrollTarget == nil { $0.refreshScroller() } }
            return true
        }
        if action.tag == GHOSTTY_ACTION_CELL_SIZE {
            PaneView.onMain(userdata) { $0.onCellChange() }
            return true
        }
        if action.tag == GHOSTTY_ACTION_NEW_WINDOW {
            PaneView.onMain(userdata) { ($0.window?.delegate as? WindowOwner)?.newSession() }
            return true
        }
        guard let command = command(action) else { return false }
        PaneView.onMain(userdata) { $0.onCommand(command) }
        return true
    }

    #if KIDO_VISUAL
    static var visualHoldSelected: (((x: Int, y: Int)?, @escaping @Sendable () -> Void) -> Void)?
    #endif

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
        case GHOSTTY_ACTION_NEW_TAB: return .newWindow
        default: return nil
        }
    }

    static func completeClipboard(_ surface: ghostty_surface_t?, _ contents: [(mime: String, data: Data)], available: [String] = [],
                                  _ state: UnsafeMutableRawPointer?, confirmed: Bool) {
        let names = (contents.map(\.mime) + available).map { strdup($0) }
        defer { names.forEach { free($0) } }
        let data = contents.map { $0.data as NSData }
        let items = data.indices.map { i in
            ghostty_clipboard_content_s(mime: names[i], data: data[i].bytes.assumingMemoryBound(to: CChar.self), len: data[i].length)
        }
        let listing = names.dropFirst(contents.count).map { UnsafePointer($0) }
        withExtendedLifetime(data) {
            items.withUnsafeBufferPointer { items in
                listing.withUnsafeBufferPointer { listing in
                    var payload = ghostty_clipboard_complete_s(contents: items.baseAddress, contents_len: items.count,
                        available: listing.baseAddress, available_len: listing.count, confirmed: confirmed, remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &payload, state)
                }
            }
        }
    }

    nonisolated private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ count: Int,
        _ confirm: Bool
    ) -> ghostty_clipboard_write_result_e {
        guard !confirm, let content else { return GHOSTTY_CLIPBOARD_WRITE_EINVAL }
        var items: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        for i in 0..<count {
            let data = content[i].len == 0 ? Data() : Data(bytes: content[i].data, count: content[i].len)
            guard let item = PasteboardMIME.written(String(cString: content[i].mime), data) else { return GHOSTTY_CLIPBOARD_WRITE_EINVAL }
            if !items.contains(where: { $0.type == item.type }) { items.append(item) }
        }
        nonisolated(unsafe) let userdata = userdata
        return MainActor.assumeIsolated { [items] in
            let view = Unmanaged<PaneView>.fromOpaque(userdata!).takeUnretainedValue()
            guard !view.disposed, view.acceptingInput else { return GHOSTTY_CLIPBOARD_WRITE_EIO }
            let items = view.copyingLines ? items.map { $0.type == .string ? ($0.type, $0.data + Data("\n".utf8)) : $0 } : items
            let pasteboard = view.runtime.pasteboard, item = NSPasteboardItem()
            pasteboard.clearContents()
            guard items.allSatisfy({ item.setData($0.data, forType: $0.type) }), pasteboard.writeObjects([item]) else { return GHOSTTY_CLIPBOARD_WRITE_EIO }
            return GHOSTTY_CLIPBOARD_WRITE_OK
        }
    }
}
