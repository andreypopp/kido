import AppKit
import os
import GhosttyKit

final class GhosttyRuntime {
    let app: ghostty_app_t
    let config: ghostty_config_t

    init?() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
              let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        let tiling = "window-padding-x = 0\nwindow-padding-y = 0\n"
        ghostty_config_load_string(config, tiling, UInt(tiling.utf8.count), "kido")
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                guard GhosttyRuntime.ticking.withLock({ ticking in
                    defer { ticking = true }
                    return !ticking
                }) else { return }
                DispatchQueue.main.async {
                    GhosttyRuntime.ticking.withLock { $0 = false }
                    GhosttyRuntime.tick()
                }
            },
            action_cb: { _, target, action in GhosttyRuntime.action(target, action) },
            read_clipboard_cb: { userdata, location, state in
                GhosttyRuntime.readClipboard(PaneView.from(userdata), location, state)
            },
            confirm_read_clipboard_cb: { userdata, string, state, request in
                guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let string,
                      let surface = PaneView.from(userdata).surface else { return }
                ghostty_surface_complete_clipboard_request(surface, string, state, true)
            },
            write_clipboard_cb: { _, location, content, count, confirm in
                GhosttyRuntime.writeClipboard(location, content, count, confirm)
            },
            close_surface_cb: { userdata, _ in
                let pane = PaneView.from(userdata)
                DispatchQueue.main.async { pane.window?.close() }
            },
            tmux_control_cb: nil)
        guard let new = ghostty_app_new(&runtime, config) else { return nil }
        nonisolated(unsafe) let app = new
        self.app = app
        GhosttyRuntime.shared = self

        ghostty_app_set_focus(app, MainActor.assumeIsolated { NSApp.isActive })
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

    nonisolated(unsafe) private static var shared: GhosttyRuntime?
    private static let ticking = OSAllocatedUnfairLock(initialState: false)

    private static func tick() {
        if let app = shared?.app { ghostty_app_tick(app) }
    }

    private static func action(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return false }
            let pane = PaneView.from(ghostty_surface_userdata(surface))
            DispatchQueue.main.async { pane.onCellChange() }
            return true
        default:
            return false
        }
    }

    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        location == GHOSTTY_CLIPBOARD_STANDARD ? .general : nil
    }

    private static func readClipboard(
        _ pane: PaneView, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let surface = pane.surface,
              let text = pasteboard(location)?.string(forType: .string) else { return false }
        ghostty_surface_complete_clipboard_request(surface, text, state, false)
        return true
    }

    private static func writeClipboard(
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
