import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime(), let pane = PaneView(runtime: runtime) else {
            fatalError("libghostty failed to initialise")
        }
        self.runtime = runtime
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        pane.onGridChange = { [weak window] grid in window?.title = "Kido — \(grid.cols)×\(grid.rows)" }
        pane.onInput = { [weak pane] data in
            pane?.feed(Data(data.flatMap { $0 == 0x0D ? [0x0D, 0x0A] : [$0] }))
        }
        pane.onClose = { NSApp.terminate(nil) }
        window.contentView = pane
        window.makeFirstResponder(pane)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pane.feed(Data(Self.banner.utf8))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static let banner: String = {
        let e = "\u{1B}["
        let palette = (0..<16).map { "\(e)48;5;\($0)m  " }.joined() + "\(e)0m"
        let gradient = (0..<48).map { i in
            let v = i * 255 / 47
            return "\(e)48;2;\(v);\(80);\(255 - v)m "
        }.joined() + "\(e)0m"
        return [
            "\(e)1;38;5;213m╭──────────────────────────────╮\(e)0m",
            "\(e)1;38;5;213m│\(e)0m  \(e)1mKido\(e)0m · libghostty pane demo \(e)1;38;5;213m│\(e)0m",
            "\(e)1;38;5;213m╰──────────────────────────────╯\(e)0m",
            "",
            "\(e)31mred \(e)32mgreen \(e)33myellow \(e)34mblue \(e)35mmagenta \(e)36mcyan\(e)0m",
            "\(e)1mbold\(e)0m \(e)3mitalic\(e)0m \(e)4munderline\(e)0m \(e)7minverse\(e)0m \(e)9mstrike\(e)0m",
            palette,
            gradient,
            "UTF-8: héllo wörld · λ → ∀x∈ℝ · 日本語 · 한국어 · 🚀✨",
            "",
            "Type: input is echoed locally (CR → CRLF).",
            "",
        ].joined(separator: "\r\n")
    }()
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
