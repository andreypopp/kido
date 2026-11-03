import AppKit

enum Side {
    case left, up, right, down
}

enum PaneCommand {
    case split(Side)
    case select(Side)
    case resize(Side, points: Double)
    case window(WindowStep)
    case next, previous, zoom, equalize, close, newWindow

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
