import AppKit
import GhosttyKit
import KoModel
import XCTest
@testable import Kido

@MainActor final class WebviewThemeTests: KoTestCase {
    func testKoaThemeFixtures() throws {
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "AppleAccentColor"), 4)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("koa-theme-" + UUID().uuidString + ".yaml")
        defer { try? FileManager.default.removeItem(at: config) }
        try "app: {font: {family: .AppleSystemUIFontMonospaced, size: 13, features: [], thicken: false, line_height: 0}, theme: {light: kido-light, dark: kido-dark}}\n".write(to: config, atomically: true, encoding: .utf8)
        let board = NSPasteboard(name: .init("koa-theme-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        NSApp.appearance = NSAppearance(named: .aqua)
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 1), font: 13))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            wait("theme appearance updates") { runtime.background.isDark == (name == "dark") }
            ghostty_surface_set_color_scheme(pane.surface, runtime.colorScheme)
            let resource = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "theme-" + name, withExtension: "json"))
            let expected = try JSONDecoder().decode(WebviewTheme.Payload.self, from: Data(contentsOf: resource))
            XCTAssertEqual(WebviewTheme.data(pane), expected)
        }
    }
}
