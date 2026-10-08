import AppKit
import TmuxControl
import SidebarFeed

final class SessionMenus: NSObject {
    var send: (RPCRequest) -> Void = { _ in }
    let window = NSMenu(title: "Window")
    let session = NSMenu(title: "Session")

    func update(_ model: SessionModel) {
        window.items = [
            item("Next Window", "}", .switchWindow(next: true)),
            item("Previous Window", "{", .switchWindow(next: false)),
            .separator(),
        ] + model.windows.enumerated().map { n, w in
            let entry = item(w.name, n < 9 ? "\(n + 1)" : "", model.select(.number(n + 1)))
            entry.state = w.id == model.window ? .on : .off
            return entry
        }
        session.items = [
            item("Next Session", "]", .switchSession(next: true), [.command, .option]),
            item("Previous Session", "[", .switchSession(next: false), [.command, .option]),
            .separator(),
        ] + model.sessions.map { s in
            let entry = item(s.name, "", .selectSession(s.id))
            entry.state = s.id == model.session ? .on : .off
            return entry
        }
    }

    private func item(
        _ title: String, _ key: String, _ command: RPCRequest?, _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = command
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? RPCRequest else { return }
        send(command)
    }
}
