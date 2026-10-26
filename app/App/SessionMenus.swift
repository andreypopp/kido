import AppKit
import TmuxControl
import SidebarFeed

final class SessionMenus: NSObject, NSMenuItemValidation {
    var send: (RPCRequest) -> Void = { _ in }
    var canSend: () -> Bool = { true }
    var rename: () -> Void = {}
    var connectionColor: () -> Void = {}
    var close: () -> Void = {}
    let window = NSMenu(title: "Window")
    let session = NSMenu(title: "Session")

    private lazy var color: NSMenuItem = {
        let item = NSMenuItem(title: "Connection Color…", action: #selector(colorItem), keyEquivalent: "")
        item.target = self
        return item
    }()

    func update(_ model: SessionModel) {
        window.items = [
            item("Next Window", "}", .switchWindow(next: true)),
            item("Previous Window", "{", .switchWindow(next: false)),
            .separator(),
        ] + model.windows.enumerated().map { n, w in
            let entry = item(w.name, n < 9 ? "\(n + 1)" : "", model.select(.number(n + 1)))
            entry.state = w.id == model.window ? .on : .off
            return entry
        } + [.separator(), color]
        session.items = [
            item("Next Session", "]", .switchSession(next: true), [.command, .option]),
            item("Previous Session", "[", .switchSession(next: false), [.command, .option]),
            .separator(),
        ] + model.sessions.map { s in
            let entry = item(s.name, "", .selectSession(s.id))
            entry.state = s.id == model.session ? .on : .off
            return entry
        }
        session.addItem(.separator())
        for (title, action) in [("Rename Session…", #selector(renameItem)), ("Close Session", #selector(closeItem))] {
            let item = session.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
    }

    @objc func renameItem() { rename() }
    @objc func colorItem() { connectionColor() }
    @objc func closeItem() { close() }

    private func item(
        _ title: String, _ key: String, _ command: RPCRequest?, _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = command
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { canSend() }

    @objc private func run(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? RPCRequest else { return }
        send(command)
    }
}
