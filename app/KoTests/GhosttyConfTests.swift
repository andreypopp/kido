import AppKit
import CoreText
import GhosttyKit
import KoModel
import XCTest
@testable import Kido

@MainActor final class GhosttyConfTests: KoTestCase {
    private func fixture(_ text: String = "") throws -> String {
        let directory = try stateDir()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/config.yaml"
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    func testEverySettingMapsToGhosttyWithoutDiagnostics() throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        let file = try fixture("""
        app:
          font: {family: Menlo, size: 15, features: [ss13, -ss17, +liga], thicken: true, line_height: 12}
          keyboard: {option_as_alt: left}
          mouse: {scroll_multiplier: {precision: 2, discrete: 4}, hide_while_typing: true}
          clipboard: {read: allow, write: deny, copy_on_select: true, paste_protection: false, trim_trailing_spaces: false}
          window: {sidebar_shade: -30, unfocused_shift: -10}
          keys: {ctrl+e: 'text:X', ctrl+v: paste_from_clipboard}
          theme: {light: solarized-light, dark: solarized-dark}
        """)
        let loaded = try XCTUnwrap(GhosttyRuntime.loadConfig(file: file))
        defer { ghostty_config_free(loaded.config) }
        let paths = ThemePaths(light: ThemePaths.path("solarized-light", configFile: file), dark: ThemePaths.path("solarized-dark", configFile: file))
        XCTAssertEqual(loaded.text, """
        alpha-blending = linear
        scrollback-limit-bytes = 536870912
        cursor-style-blink = false
        keybind = super+k=unbind
        keybind = super+j=unbind
        keybind = super+s=unbind
        keybind = super+shift+s=unbind
        font-family = Menlo
        font-size = 15.0
        font-feature = ss13
        font-feature = -ss17
        font-feature = +liga
        font-thicken = true
        adjust-cell-height = 12.0%
        macos-option-as-alt = left
        mouse-scroll-multiplier = precision:2.0,discrete:4.0
        mouse-hide-while-typing = true
        copy-on-select = clipboard
        clipboard-paste-protection = false
        clipboard-trim-trailing-spaces = false
        keybind = ctrl+e=text:X
        keybind = ctrl+v=paste_from_clipboard
        theme = light:"\(paths.light)",dark:"\(paths.dark)"
        window-padding-x = 0
        window-padding-y = 0
        scrollbar = never
        clipboard-read = deny
        clipboard-write = deny

        """)
        XCTAssertEqual(loaded.diagnostics, [])
        XCTAssertNil(loaded.error)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file, pasteboard: board))
        XCTAssertEqual(runtime.sidebarShade, 0.3)
        XCTAssertEqual(runtime.unfocusedShift, 0.1)
        XCTAssertEqual(runtime.clipboard.read, .allow)
        XCTAssertEqual(runtime.clipboard.write, .deny)
        XCTAssertEqual(loaded.values.mouse.scrollMultiplier.precision, 2)
        XCTAssertEqual(loaded.values.mouse.scrollMultiplier.discrete, 4)
    }

    func testDefaultsAndAllEnumAlternativesHaveNoDiagnostics() throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        for option in ["off", "on", "left", "right"] {
            for copy in ["false", "true"] {
                let file = try fixture("app: {keyboard: {option_as_alt: \(option)}, clipboard: {copy_on_select: \(copy)}}\n")
                let loaded = try XCTUnwrap(GhosttyRuntime.loadConfig(file: file))
                XCTAssertEqual(loaded.diagnostics, [], loaded.text)
                XCTAssertNil(loaded.error)
                ghostty_config_free(loaded.config)
            }
        }
        let file = try fixture()
        let loaded = try XCTUnwrap(GhosttyRuntime.loadConfig(file: file))
        defer { ghostty_config_free(loaded.config) }
        XCTAssertEqual(loaded.diagnostics, [])
        XCTAssertTrue(loaded.text.contains("font-family = \(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName!)\n"))
        XCTAssertTrue(loaded.text.contains("copy-on-select = none\n"))
        XCTAssertTrue(loaded.text.contains("macos-option-as-alt = false\n"))
        XCTAssertTrue(loaded.text.hasSuffix("clipboard-read = deny\nclipboard-write = deny\n"))
    }

    func testEveryKeyActionIsAcceptedByGhostty() throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        for action in ["text:X", "csi:1;5A", "esc:b", "unbind", "paste_from_clipboard", "copy_to_clipboard", "increase_font_size:1.5", "decrease_font_size:0.5", "reset_font_size"] {
            let data = try JSONSerialization.data(withJSONObject: ["app": ["keys": ["ctrl+e": action]]])
            let file = try fixture(String(decoding: data, as: UTF8.self))
            let loaded = try XCTUnwrap(GhosttyRuntime.loadConfig(file: file))
            XCTAssertEqual(loaded.diagnostics, [], action)
            XCTAssertTrue(loaded.text.contains("keybind = ctrl+e=\(action)\n"))
            ghostty_config_free(loaded.config)
        }
    }

    func testSystemMonospacedFamilyMatchesCoreTextDiscovery() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let family = try XCTUnwrap(font.familyName)
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = try XCTUnwrap(CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor])
        let regular = try XCTUnwrap(matches.first { (CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String) == "Regular" })
        let face = CTFontCreateWithFontDescriptor(regular, 13, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(face) as String, font.fontName)
        let weight = try XCTUnwrap((CTFontCopyTraits(face) as NSDictionary)[kCTFontWeightTrait] as? NSNumber)
        XCTAssertEqual(weight.doubleValue, 0)
        let light = try XCTUnwrap(matches.first { (CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String) == "Light" })
        let lightWeight = try XCTUnwrap((CTFontCopyTraits(CTFontCreateWithFontDescriptor(light, 13, nil)) as NSDictionary)[kCTFontWeightTrait] as? NSNumber)
        XCTAssertLessThan(lightWeight.doubleValue, weight.doubleValue)
    }

    func testThemeChecksAndResolution() throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        let file = try fixture()
        let directory = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ThemePaths.bundled {
            let path = ThemePaths.path(name, configFile: file)
            XCTAssertTrue(path.hasPrefix(Bundle.main.resourceURL!.path))
            XCTAssertNil(ThemeFile(path).problem, name)
            try "font-family = wrong\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            XCTAssertEqual(ThemePaths.path(name, configFile: file), path)
        }
        let user = directory.appendingPathComponent("custom")
        try "background = #123456\nforeground = white\n".write(to: user, atomically: true, encoding: .utf8)
        XCTAssertEqual(ThemePaths.path("custom", configFile: file), user.path)
        XCTAssertNil(ThemeFile(user.path).problem)
        try "font-family = x\n".write(to: user, atomically: true, encoding: .utf8)
        XCTAssertEqual(ThemeFile(user.path).problem, .invalid("unsupported key \"font-family\""))
        try "unknown-key = x\n".write(to: user, atomically: true, encoding: .utf8)
        XCTAssertTrue(ThemeFile(user.path).problem?.text.contains("unknown-key") == true)
        try "app: {theme: custom}\n".write(toFile: file, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(GhosttyRuntime.loadConfig(file: file))
        defer { ghostty_config_free(loaded.config) }
        XCTAssertEqual(loaded.error?.path, user.path)
        XCTAssertTrue(loaded.text.contains(GhosttyConf.theme(ThemePaths(light: ThemePaths.path("kido-light", configFile: file), dark: ThemePaths.path("kido-dark", configFile: file)))))
    }

    func testThemesCannotLoadOtherFiles() throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        let file = try fixture("app: {theme: custom}\n")
        let directory = ThemePaths.directory(configFile: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let theme = directory.appendingPathComponent("custom")
        let other = directory.appendingPathComponent("other")
        try "nested-file-was-read = true\n".write(to: other, atomically: true, encoding: .utf8)
        for key in ["theme", "config-file"] {
            for value in [other.path, "example"] {
                try "\(key) = \(value)\n".write(to: theme, atomically: true, encoding: .utf8)
                XCTAssertEqual(ThemeFile(theme.path).problem, .invalid("unsupported key \"\(key)\""))
                let loaded = try XCTUnwrap(GhosttyRuntime.loadConfig(file: file))
                defer { ghostty_config_free(loaded.config) }
                XCTAssertEqual(loaded.diagnostics, [])
                XCTAssertEqual(loaded.error?.path, theme.path)
                XCTAssertNil(loaded.error?.problem.line)
                XCTAssertNil(loaded.error?.problem.column)
            }
            try "\(key) = \(other.path)\n".write(to: theme, atomically: true, encoding: .utf8)
            let config = try XCTUnwrap(ghostty_config_new())
            defer { ghostty_config_free(config) }
            let text = GhosttyConf.theme(ThemePaths(light: theme.path, dark: theme.path)) + "\n"
            ghostty_config_load_string(config, text, UInt(text.utf8.count), "/kido")
            ghostty_config_finalize(config)
            XCTAssertEqual(ghostty_config_diagnostics_count(config), 0)
        }
    }

    func testThemePathsQuoteDelimitersAndKeepTrailingWhitespace() throws {
        XCTAssertEqual(ghostty_init(0, nil), GHOSTTY_SUCCESS)
        let root = try stateDir()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        let directory = URL(fileURLWithPath: root).appendingPathComponent("comma,colon:")
        let themes = directory.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let theme = themes.appendingPathComponent("custom ")
        try "background = #123456\n".write(to: theme, atomically: true, encoding: .utf8)
        let file = directory.appendingPathComponent("config.yaml")
        try "app: {theme: 'custom '}\n".write(to: file, atomically: true, encoding: .utf8)
        for override in [nil, "custom "] as [String?] {
            let loaded = try XCTUnwrap(GhosttyRuntime.loadConfig(file: file.path, override: override))
            defer { ghostty_config_free(loaded.config) }
            XCTAssertTrue(loaded.text.contains("theme = light:\"\(theme.path)\",dark:\"\(theme.path)\"\n"))
            XCTAssertEqual(loaded.diagnostics, [])
            XCTAssertNil(loaded.error)
            let background = try XCTUnwrap(GhosttyRuntime.color("background", config: loaded.config).usingColorSpace(.sRGB))
            XCTAssertEqual(background.redComponent, 18.0 / 255, accuracy: 0.000001)
            XCTAssertEqual(background.greenComponent, 52.0 / 255, accuracy: 0.000001)
            XCTAssertEqual(background.blueComponent, 86.0 / 255, accuracy: 0.000001)
        }
    }

    func testBadLaunchUsesDefaultsAndReloadKeepsLastSettings() throws {
        let file = try fixture("app: {font: {size: bad}}\n")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file, pasteboard: board))
        XCTAssertEqual(runtime.values.font.size, 13)
        XCTAssertTrue(runtime.configError?.problem.message.contains("size") == true)
        func reload(_ text: String) {
            let done = expectation(description: "reload")
            runtime.onConfigChange = { done.fulfill() }
            do { try text.write(toFile: file, atomically: true, encoding: .utf8) } catch { XCTFail("\(error)") }
            wait(for: [done], timeout: 5)
            runtime.onConfigChange = {}
        }
        reload("app: {font: {size: 20}, window: {sidebar_shade: 30}}\n")
        XCTAssertEqual(runtime.values.font.size, 20)
        XCTAssertEqual(runtime.sidebarShade, 0.3)
        XCTAssertNil(runtime.configError)
        reload("app: {font: {size: wrong}}\n")
        XCTAssertEqual(runtime.values.font.size, 20)
        XCTAssertEqual(runtime.sidebarShade, 0.3)
        XCTAssertNotNil(runtime.configError)
        reload("")
        XCTAssertNil(runtime.configError)
        XCTAssertEqual(runtime.values.font.size, 13)
    }

    func testConfigBannerAndLinkFailurePrecedence() throws {
        let file = try fixture("app: {font: {size: bad}}\n")
        let dir = try stateDir()
        let process = try ko(["server"], dir: dir)
        addTeardownBlock { @MainActor in
            let stop = try? self.ko(["kill-server"], dir: dir)
            stop?.waitUntilExit()
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }
        wait("server socket") { FileManager.default.fileExists(atPath: dir + "/socket") }
        try put(#"{"revision":0,"layout":{"sessions":[{"name":"main","windows":[{"name":"shell","tree":{"pane":{"new":{"command":{"type":"argv","argv":["/bin/cat"]}}}}}]}]}}"#, dir: dir)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(configFile: file, pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = dir
        runtime.onConfigChange = { owner.updateAppearance() }
        addTeardownBlock { @MainActor in owner.close(); board.releaseGlobally() }
        owner.start()
        let strip = owner.sidebar.configBanner
        wait("config error strip") { !strip.isHidden && owner.testBanner.isHidden }
        XCTAssertEqual(strip.testText.title, file + " has an error")
        XCTAssertEqual(strip.testText.detail, runtime.configError?.problem.detail)
        let pane = try XCTUnwrap(owner.testSession?.windows.values.first?.panes.first)
        owner.window.makeFirstResponder(pane)
        let height = owner.sidebar.content.bounds.height
        try "".write(toFile: file, atomically: true, encoding: .utf8)
        wait("successful load hides strip") { runtime.configError == nil && strip.isHidden }
        XCTAssertTrue(owner.window.firstResponder === pane)
        XCTAssertEqual(owner.sidebar.content.bounds.height, height + ConfigBanner.height, accuracy: 0.1)
        try "app: {font: {size: bad}}\n".write(toFile: file, atomically: true, encoding: .utf8)
        wait("error returns") { !strip.isHidden }
        XCTAssertTrue(owner.window.firstResponder === pane)
        XCTAssertTrue(owner.testBanner.isHidden)
        XCTAssertEqual(owner.sidebar.content.bounds.height, height, accuracy: 0.1)
        try run(["kill-server"], dir: dir)
        wait("link failure wins") { !owner.testBanner.isHidden && strip.isHidden }
        owner.updateAppearance()
        XCTAssertTrue(strip.isHidden)
    }

    func testActualMenuShortcutsAreReserved() throws {
        let app = AppDelegate()
        let menu = app.mainMenu()
        let window = try XCTUnwrap(menu.items.first { $0.title == "Window" }?.submenu)
        let menus = try XCTUnwrap(window.items.first?.target as? SessionMenus)
        menus.update(SessionModel(session: SessionID(number: 0),
                                  windows: (1...9).map { .init(id: WindowID(number: UInt32($0)), name: "Window \($0)") },
                                  window: WindowID(number: 1)))
        var visited: Set<String> = []
        func visit(_ menu: NSMenu) throws {
            for item in menu.items {
                if let submenu = item.submenu { try visit(submenu) }
                guard !item.keyEquivalent.isEmpty else { continue }
                let flags = item.keyEquivalentModifierMask
                var parts: [String] = []
                if flags.contains(.command) { parts.append("super") }
                if flags.contains(.control) { parts.append("ctrl") }
                if flags.contains(.option) { parts.append("alt") }
                if flags.contains(.shift) { parts.append("shift") }
                let names = ["\r": "enter", "\u{f700}": "up", "\u{f701}": "down", "\u{f702}": "left", "\u{f703}": "right"]
                parts.append(names[item.keyEquivalent] ?? item.keyEquivalent.lowercased())
                let trigger = parts.joined(separator: "+")
                visited.insert(trigger)
                let file = try fixture("app: {keys: {\"\(trigger)\": unbind}}\n")
                XCTAssertThrowsError(try AppConfig.load(file), "Menu shortcut is not reserved: \(item.title): \(trigger)") {
                    XCTAssertTrue(($0 as? ConfigProblem)?.message.contains("belongs to a menu of the app") == true, "\($0)")
                }
            }
        }
        try visit(menu)
        XCTAssertTrue(Set((1...9).map { "super+\($0)" }).isSubset(of: visited))
    }
}
