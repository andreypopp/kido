import AppKit
import TmuxControl

final class SessionMenus: NSObject {
    var send: ([Command]) -> Void = { _ in }
    let window = NSMenu(title: "Window")
    let session = NSMenu(title: "Session")

    func update(_ model: SessionModel) {
        window.items = [
            item("Next Window", "}", model.select(.next)),
            item("Previous Window", "{", model.select(.previous)),
            .separator(),
        ] + model.windows.enumerated().map { n, w in
            let entry = item(w.name, n < 9 ? "\(n + 1)" : "", model.select(.number(n + 1)))
            entry.state = w.id == model.window ? .on : .off
            return entry
        }
        session.items = [
            item("Next Session", "]", Command("switch-client", "-n"), [.command, .option]),
            item("Previous Session", "[", Command("switch-client", "-p"), [.command, .option]),
            .separator(),
        ] + model.sessions.map { s in
            let entry = item(s.name, "", Command("switch-client", "-t", s.id))
            entry.state = s.id == model.session ? .on : .off
            return entry
        }
    }

    private func item(
        _ title: String, _ key: String, _ command: Command?, _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = command
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command else { return }
        send([command])
    }
}
