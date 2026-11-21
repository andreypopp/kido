import AppKit

enum CommandScope {
    case application, pane, mainWindow

    init(_ command: PaneCommand) {
        switch command {
        case .newWindow: self = .application
        case .close, .float: self = .pane
        case .split, .select, .resize, .window, .next, .previous, .zoom, .equalize: self = .mainWindow
        }
    }

    @MainActor init(_ item: NSMenuItem) {
        if let command = item.representedObject as? PaneCommand { self.init(command); return }
        switch item.action {
        case #selector(SessionMenus.run(_:)), #selector(SessionMenus.renameItem), #selector(SessionMenus.closeItem),
             #selector(AppDelegate.closeWindow), #selector(AppDelegate.closeSession),
             #selector(WindowOwner.navigateHistoryBack(_:)), #selector(WindowOwner.navigateHistoryForward(_:)),
             #selector(Sidebar.toggleSidebar(_:)), #selector(Sidebar.focusSidebar(_:)), #selector(NSWindow.toggleFullScreen(_:)):
            self = .mainWindow
        case #selector(PaneView.runCommand(_:)), #selector(PaneView.showFind(_:)), #selector(PaneView.findNext(_:)),
             #selector(PaneView.findPrevious(_:)), #selector(PaneView.toggleCopyMode(_:)), #selector(PaneView.reloadPage(_:)),
             #selector(PaneView.promptSelectionItem(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
             #selector(NSText.cut(_:)), #selector(NSText.selectAll(_:)):
            self = .pane
        default: self = .application
        }
    }

    @MainActor static func consumes(_ event: NSEvent, menu: NSMenu?) -> Bool {
        guard !CommandScope.mainWindow.isAvailable, event.type == .keyDown, let menu else { return false }
        func blocked(_ menu: NSMenu) -> Bool {
            menu.items.contains { item in
                if let submenu = item.submenu, blocked(submenu) { return true }
                guard !item.keyEquivalent.isEmpty, CommandScope(item) == .mainWindow,
                      let characters = event.charactersIgnoringModifiers,
                      characters.lowercased() == item.keyEquivalent.lowercased() else { return false }
                var flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
                var expected = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift, .function])
                // AppKit sets .function on every arrow and F-key event, whose characters are in U+F700–U+F8FF.
                if item.keyEquivalent.unicodeScalars.allSatisfy({ (0xF700...0xF8FF).contains($0.value) }) { flags.remove(.function); expected.remove(.function) }
                if item.keyEquivalent != item.keyEquivalent.lowercased() { expected.insert(.shift) }
                if item.keyEquivalent.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }), !expected.contains(.shift) { flags.remove(.shift) }
                return flags == expected
            }
        }
        return blocked(menu)
    }

    @MainActor var isAvailable: Bool { isAvailable(responder: nil) }

    @MainActor func isAvailable(responder: NSResponder?) -> Bool {
        let host = PaneView.owner(responder)?.window ?? (responder as? NSView)?.window ?? (responder as? NSWindow)
            ?? (NSApp.delegate as? AppDelegate)?.commandInputWindow ?? OwnerWindow.inputWindow
        return self != .mainWindow || !(host is FloatWindow)
    }
}

enum Side {
    case left, up, right, down
}

enum PaneFloatState {
    case float, dock, cannotFloat, cannotDock

    var isEnabled: Bool {
        switch self {
        case .float, .dock: true
        case .cannotFloat, .cannotDock: false
        }
    }

    var title: String {
        switch self {
        case .float, .cannotFloat: "Float Pane"
        case .dock, .cannotDock: "Dock Pane"
        }
    }
}

enum PaneCommand {
    case split(Side)
    case select(Side)
    case resize(Side, points: Double)
    case window(WindowStep)
    case newWindow(NewPaneProgram)
    case next, previous, zoom, float, equalize, close

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
        add("Float Pane", .float, "f", [.command, .option])
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
        for (title, action, key) in [("Back", #selector(WindowOwner.navigateHistoryBack(_:)), "["), ("Forward", #selector(WindowOwner.navigateHistoryForward(_:)), "]")] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).keyEquivalentModifierMask = [.command, .control]
        }
        let item = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

extension NewPaneProgram {
    static func clicked(_ event: NSEvent?) -> Self {
        event?.modifierFlags.contains(.option) == true ? .agent : .shell
    }
}
