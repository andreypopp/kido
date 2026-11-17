import AppKit
import KoClient
@testable import KidoPairing
import XCTest
import SnapshotTesting
@testable import Kido

@MainActor final class PairingTests: VisualTestCase {
    private func image(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        checkSnapshot { verifySnapshot(of: view, as: .pixels, named: name, record: $0, testName: "pairing") }
    }

    func testPairingAlerts() async throws {
        let board = NSPasteboard(name: .init("pair-alerts-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let owner = WindowOwner(host: .local, runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        defer { owner.close() }
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        let host = try ServerName("ko.example.com")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pair-alerts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityStore(root: root)
        try store.commit(store.create(), for: host, name: PairingName("Home VM"))
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            owner.window.appearance = NSAppearance(named: appearance)
            for (name, alert) in [("refused", WindowOwner.securityAlert(host: host, failure: .identity, identities: store)),
                                  ("tls", WindowOwner.securityAlert(host: host, failure: .serverCertificate("the certificate expired on 10 November 2026"), identities: store)),
                                  ("forget", AppDelegate.forgetAlert(host, identities: store))] {
                owner.prepareAlert(alert) { _ in }
                alert.window.appearance = NSAppearance(named: appearance)
                let image = try await sheetImage(alert, attachedTo: owner.window)
                checkSnapshot { verifySnapshot(of: image, as: .pixels, named: "\(theme)-\(name)", record: $0, testName: "testPairingMockupStates") }
                owner.respondToAlert(.alertSecondButtonReturn)
                try await wait("the sheet closes") { owner.window.attachedSheet == nil }
            }
        }
    }

    func testPairingMockupStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pair-visual-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try ServerName("ko.example.com")
        let code = #"kido-pair:{"v":1,"host":"ko.example.com","name":"Home VM","enroll":"https://enroll.example.com/v1/enroll","token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        for (theme, background, foreground) in [("light", "fff9ec", "424242"), ("dark", "171717", "c9c9c9")] {
            let config = root.appendingPathComponent(theme + ".yaml")
            try configYAML(at: config, background: background, foreground: foreground).write(to: config, atomically: true, encoding: .utf8)
            let board = NSPasteboard(name: .init("pair-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
            let store = IdentityStore(root: root.appendingPathComponent(theme))
            let app = AppDelegate(runtime: runtime, identities: store)
            NSApp.mainMenu = app.mainMenu()
            let owner = try XCTUnwrap(app.open(.local, start: false))
            defer { app.closePalette(); owner.close() }
            app.pairServer()
            let panel = try XCTUnwrap(app.palettePanel)
            let palette = panel.palette
            var result = EnrollmentResult.rejected(403)
            var pending: CheckedContinuation<EnrollmentResult, Never>?
            var hold = false
            var tokens: Set<Data> = []
            var activation: CheckedContinuation<PairingSession.ProbeResult, Never>?
            palette.makePair = { expected in
                let session = PairingSession(store: store, expectedHost: expected, defaultDeviceName: Foundation.Host.current().localizedName ?? "Mac", claim: { tokens.insert($0).inserted }, release: { tokens.remove($0) }, enroll: { _, _, _ in
                    if hold { return await withCheckedContinuation { pending = $0 } }
                    return result
                })
                session.probe = { _, _, _ in await withCheckedContinuation { activation = $0 } }
                return session
            }
            func enter() {
                tokens.removeAll()
                palette.enter(.root); palette.enter(.pair(nil))
                palette.pair?.nameField.stringValue = "Andrey’s MacBook Pro"
            }
            func query(_ text: String) {
                palette.field.stringValue = text
                palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                if let editor = palette.field.currentEditor() as? NSTextView {
                    editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
                    editor.scrollRangeToVisible(editor.selectedRange())
                }
            }
            enter()
            panel.makeFirstResponder(palette.field)
            await mainQueueFence()
            (palette.field.currentEditor() as? NSTextView)?.insertionPointColor = .clear
            image(palette, "\(theme)-empty")
            query(code)
            await mainQueueFence()
            image(palette, "\(theme)-payload")
            panel.makeFirstResponder(palette.pair?.nameField)
            await mainQueueFence()
            image(palette, "\(theme)-device-name")
            panel.makeFirstResponder(palette.field)
            query("not a code")
            palette.pair?.submit()
            image(palette, "\(theme)-invalid")
            query(code)
            hold = true
            palette.pair?.submit()
            try await wait("enrollment started") { pending != nil }
            await mainQueueFence()
            image(palette, "\(theme)-progress")
            hold = false
            pending?.resume(returning: result)
            pending = nil
            try await wait("expired code") { if case .rejected? = palette.pair?.session?.state { true } else { false } }
            image(palette, "\(theme)-expired")
            result = .retryable("The network connection was lost.")
            enter(); query(code); palette.pair?.submit()
            try await wait("network failure") { if case .retryable? = palette.pair?.session?.state { true } else { false } }
            image(palette, "\(theme)-network-retry")
            result = .uncertain
            enter(); query(code); palette.pair?.submit()
            try await wait("uncertain pairing") { if case .uncertain? = palette.pair?.session?.state { true } else { false } }
            image(palette, "\(theme)-uncertain")
            result = .accepted
            enter(); query(code); palette.pair?.submit()
            try await wait("activation") { activation != nil }
            image(palette, "\(theme)-waiting")
            activation?.resume(returning: .ready)
            activation = nil
            palette.enter(.root); palette.enter(.pair(host))
            palette.pair?.nameField.stringValue = "Andrey’s MacBook Pro"
            image(palette, "\(theme)-again")
            app.routes.remember(.remote("devbox"))
            app.routes.remember(.tls(host))
            palette.enter(.connect)
            image(palette, "\(theme)-recents")
            let remote = WindowOwner(host: .tls(host), runtime: runtime, start: false, identities: store,
                                     probeTLS: { _, _ in .unreachable(code: KO_ERR_NO_SERVER, detail: "offline") })
            remote.start()
            await remote.testConnection?.value
            remote.testReceive(sidebarFixture())
            XCTAssertEqual(remote.window.title, "Home VM")
            remote.close()
        }
    }
}
