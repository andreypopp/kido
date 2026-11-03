import AppKit
import GhosttyKit
import XCTest
@testable import Kido

nonisolated(unsafe) private var tickedApp: ghostty_app_t?

// The smallest host for a surface of the app's Ghostty fork: no window, no clipboard.
@MainActor final class KoGhostty {
    static let shared = KoGhostty()
    let app: ghostty_app_t

    private init() {
        precondition(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)
        let config = ghostty_config_new()!
        let text = "window-padding-x = 0\nwindow-padding-y = 0\nscrollbar = never\ncursor-style-blink = false\ncustom-shader-animation = false\nscrollback-limit = 536870912\n"
        ghostty_config_load_string(config, text, UInt(text.utf8.count), "/kido-ko-tests")
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            supports_paste_events: false,
            wakeup_cb: { @Sendable _ in DispatchQueue.main.async { tickedApp.map { ghostty_app_tick($0) } } },
            action_cb: { @Sendable _, _, _ in false },
            read_clipboard_cb: { @Sendable _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE },
            confirm_read_clipboard_cb: { @Sendable _, _, _, _ in },
            write_clipboard_cb: { @Sendable _, _, _, _, _ in GHOSTTY_CLIPBOARD_WRITE_EIO },
            close_surface_cb: { @Sendable _, _ in })
        app = ghostty_app_new(&runtime, config)!
        tickedApp = app
    }
}

@MainActor final class KoSurface {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    nonisolated(unsafe) let surface: ghostty_surface_t

    init(cols: Int, rows: Int) {
        host.wantsLayer = true
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(host).toOpaque()))
        config.scale_factor = 2
        config.font_size = 13
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.kitty_image_media = GHOSTTY_IMAGE_MEDIA_DIRECT
        config.io_write_cb = { _, _, _ in }
        surface = ghostty_surface_new(KoGhostty.shared.app, &config)!
        XCTAssertTrue(ghostty_surface_set_grid_size(surface, UInt16(cols), UInt16(rows), nil))
    }

    deinit { ghostty_surface_free(surface) }

    var grid: (cols: Int, rows: Int) {
        var metrics = ghostty_surface_grid_metrics_s()
        XCTAssertTrue(ghostty_surface_grid_metrics(surface, &metrics))
        return (Int(metrics.columns), Int(metrics.rows))
    }

    func feed(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ghostty_surface_process_output(surface, $0, UInt(buffer.count))
            }
        }
    }

    var pendingFrames: [ghostty_kitty_pending_frame_s] { surface.kittyPendingFrames }

    // The stamp of a frame of the primary screen, nil when the image or the frame does not exist.
    func generation(image: UInt32, frame: UInt32) -> UInt64? {
        // GhosttyKittyGraphicsFrameData.generation, which ghostty.h does not name.
        var key: Int32 = 5
        var value: UInt64 = 0
        let result = withUnsafeMutablePointer(to: &value) { pointer -> Int32 in
            var out: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(pointer)
            return ghostty_surface_kitty_frame_get_multi(surface, GHOSTTY_KITTY_SCREEN_E_PRIMARY, image, frame, 1, &key, &out, nil)
        }
        return result == GHOSTTY_SUCCESS ? value : nil
    }

    var text: String {
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text), let bytes = text.text else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }
}
