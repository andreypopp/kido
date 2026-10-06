import AppKit
import TmuxControl

enum Side {
    case left, up, right, down

    fileprivate var flag: String {
        switch self {
        case .left: "-L"
        case .up: "-U"
        case .right: "-R"
        case .down: "-D"
        }
    }

    fileprivate var split: String {
        switch self {
        case .left: "-hb"
        case .up: "-vb"
        case .right: "-h"
        case .down: "-v"
        }
    }
}

enum PaneCommand {
    case split(Side)
    case select(Side)
    case resize(Side, points: Double)
    case window(WindowStep)
    case next, previous, zoom, equalize, close, newWindow, clear

    // Ghostty's resize amount is in points.
    func command(_ pane: PaneID, cell: CGSize, model: SessionModel) -> Command? {
        switch self {
        case .split(let side): Command("split-window", side.split, "-t", pane, "-c", "#{pane_current_path}")
        case .select(let side): Command("select-pane", side.flag, "-t", pane)
        case .resize(let side, let points):
            Command(
                "resize-pane", side.flag, "-t", pane,
                max(1, Int((points / max(side == .left || side == .right ? cell.width : cell.height, 1)).rounded())))
        case .window(let step): model.select(step)
        case .next: Command("select-pane", "-t", ":.+")
        case .previous: Command("select-pane", "-t", ":.-")
        case .clear: Command("send-keys", "-R", "-t", pane)
        case .zoom: Command("resize-pane", "-Z", "-t", pane)
        case .equalize: Command("select-layout", "-E", "-t", pane)
        case .close: Command("kill-pane", "-t", pane)
        case .newWindow: model.window.map { Command("new-window", "-a", "-t", $0, "-c", "#{pane_current_path}") }
        }
    }

    @MainActor static var menu: NSMenuItem {
        let menu = NSMenu(title: "Shell")
        func add(_ title: String, _ command: PaneCommand, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: #selector(PaneView.runCommand(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.representedObject = command
        }
        func arrow(_ key: Int) -> String { String(UnicodeScalar(key)!) }
        add("Split Right", .split(.right), "d")
        add("Split Down", .split(.down), "D")
        add("Close Pane", .close, "w")
        menu.addItem(.separator())
        add("Clear", .clear, "k", [.command, .option])
        add("Zoom Pane", .zoom, "\r", [.command, .shift])
        menu.addItem(.separator())
        add("Select Pane Left", .select(.left), arrow(NSLeftArrowFunctionKey), [.command, .option])
        add("Select Pane Above", .select(.up), arrow(NSUpArrowFunctionKey), [.command, .option])
        add("Select Pane Right", .select(.right), arrow(NSRightArrowFunctionKey), [.command, .option])
        add("Select Pane Below", .select(.down), arrow(NSDownArrowFunctionKey), [.command, .option])
        add("Select Pane Left", .select(.left), "h")
        add("Select Pane Below", .select(.down), "j")
        add("Select Pane Above", .select(.up), "k")
        add("Select Pane Right", .select(.right), "l")
        add("Next Pane", .next, "]")
        add("Previous Pane", .previous, "[")
        let item = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
