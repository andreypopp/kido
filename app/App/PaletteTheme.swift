import AppKit
import GhosttyKit

enum ThemeStep: Equatable {
    case pick, save(ThemeRow)
}

struct ThemeRow: Equatable {
    enum Problem: Equatable {
        case missing, invalid(String)
        var text: String { switch self { case .missing: "theme file not found"; case .invalid(let line): "invalid: " + line } }
    }
    let name: String
    let value: String
    let path: String
    let background: NSColor
    let foreground: NSColor
    let colors: [NSColor]
    var problem: Problem?

    func drawSwatch(at point: NSPoint) {
        let box = NSBezierPath(roundedRect: NSRect(origin: point, size: NSSize(width: 18, height: 18)), xRadius: 4, yRadius: 4)
        if problem == nil { background.setFill(); box.fill() }
        Chrome.themeSwatchEdge.setStroke(); box.lineWidth = 0.5; box.stroke()
        guard problem == nil else { return }
        ("Aa" as NSString).draw(at: NSPoint(x: point.x + 2, y: point.y + 3), withAttributes: [.font: NSFont(name: "Menlo-Bold", size: 10)!, .foregroundColor: foreground])
        for (i, color) in colors.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x + 21 + CGFloat(i % 2) * 6.5, y: point.y + 3 + CGFloat(i / 2) * 6.5, width: 5, height: 5)).fill()
        }
    }
}

@MainActor final class PaletteTheme {
    enum Status {
        case preview(String), fileError(String), writeError(String)
        var message: String { switch self { case .preview(let value), .fileError(let value), .writeError(let value): value } }
        var isError: Bool { if case .preview = self { false } else { true } }
        var canReveal: Bool { if case .writeError = self { true } else { false } }
    }
    static let bundled = ["kido-light", "kido-dark", "ahrefs-light", "ahrefs-dark", "solarized-light", "solarized-dark"]
    let runtime: GhosttyRuntime
    let directory: String
    let pair: ThemeConf.Pair
    var rows: [ThemeRow]
    var query = ""
    var selection = 0
    private(set) var dark = false
    private(set) var radio = 0
    private var savePair = ThemeConf.Pair()
    private(set) var status: Status?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        directory = URL(fileURLWithPath: runtime.configFile).deletingLastPathComponent().appendingPathComponent("themes").path
        let parsed = (try? ThemeConf.read(runtime.configFile))?.pair ?? .init()
        pair = ThemeConf.Pair(light: runtime.expand(parsed.light), dark: runtime.expand(parsed.dark))
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("ghostty/themes")
        rows = Self.bundled.map { Self.load(name: $0, value: $0, path: bundled.appendingPathComponent($0).path) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        rows += files.filter { name in
            guard !name.hasPrefix("."), ThemeConf.isBareName(name) else { return false }
            var info = stat()
            return stat(directory + "/" + name, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { Self.load(name: $0, value: directory + "/" + $0, path: directory + "/" + $0) }
        dark = runtime.colorScheme == GHOSTTY_COLOR_SCHEME_DARK
        selection = rows.firstIndex { $0.value == (dark ? pair.dark : pair.light) } ?? 0
        status = fileStatus()
    }
    private func fileStatus() -> Status? {
        let dark = runtime.colorScheme == GHOSTTY_COLOR_SCHEME_DARK
        for (side, value) in dark ? [("Dark", pair.dark), ("Light", pair.light)] : [("Light", pair.light), ("Dark", pair.dark)] {
            guard let diagnostic = runtime.fileDiagnostics.first(where: { message in
                if message.contains("theme"), message.contains("\"\(value)\"") { return true }
                if value.hasPrefix("/") { return message.hasPrefix(value + ":") }
                return message.hasPrefix("/") && message.prefix(while: { $0 != ":" }).hasSuffix("/themes/" + value)
            }) else { continue }
            let missing = diagnostic.contains("not found") || (value.hasPrefix("/") && !FileManager.default.fileExists(atPath: value))
            let problem = missing ? "not found" : "invalid: " + diagnostic
            return .fileError("\(runtime.abbreviate(value)): \(problem). The current config names it for \(side); Ghostty's default colours are shown instead.")
        }
        return nil
    }
    private static func load(name: String, value: String, path: String) -> ThemeRow {
        let config = ghostty_config_new()!
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, path)
        ghostty_config_finalize(config)
        var palette = ghostty_config_palette_s()
        _ = ghostty_config_get(config, &palette, "palette", 7)
        let colors = withUnsafePointer(to: &palette.colors) { pointer in
            pointer.withMemoryRebound(to: ghostty_config_color_s.self, capacity: 256) { p in [4, 2, 1, 3].map { GhosttyRuntime.color(p[$0]) } }
        }
        var problem: ThemeRow.Problem?
        if !FileManager.default.fileExists(atPath: path) { problem = .missing }
        else if ghostty_config_diagnostics_count(config) > 0 { problem = .invalid(String(cString: ghostty_config_get_diagnostic(config, 0).message)) }
        return ThemeRow(name: name, value: value, path: path, background: GhosttyRuntime.color("background", config: config), foreground: GhosttyRuntime.color("foreground", config: config), colors: colors, problem: problem)
    }
    func entries(_ step: ThemeStep = .pick) -> [(entry: PaletteEntry, offsets: [[Int]])] {
        if case .save = step {
            return [(dark ? "Dark mode" : "Light mode", " · the current appearance"), (dark ? "Light mode" : "Dark mode", ""), ("Both", " · one theme whatever the appearance"), ("This session only", " · not saved to kido-app.conf")].enumerated().map { index, item in
                (PaletteEntry(id: .themeUse(index), title: item.0, detail: item.1, operation: .themeUse), [[], []])
            }
        }
        return PaletteEntry.ranked(rows.map { row in
            var marks: [String] = []
            if row.value == pair.light { marks.append("✓ Light") }
            if row.value == pair.dark { marks.append("✓ Dark") }
            return PaletteEntry(id: .theme(row.value), title: row.name, detail: "", shortcut: marks.joined(separator: "  "), theme: row, operation: .themeChoose)
        }, query: query)
    }
    func check(_ value: String) -> ThemeRow {
        let index = rows.firstIndex { $0.value == value }!
        var info = stat()
        if stat(rows[index].path, &info) != 0 || info.st_mode & S_IFMT != S_IFREG { rows[index].problem = .missing }
        else if rows[index].problem == nil, let diagnostic = runtime.diagnostics.first(where: { $0.contains(rows[index].path) || ($0.contains("theme") && $0.contains(value)) }) {
            rows[index].problem = .invalid(diagnostic)
        }
        return rows[index]
    }
    private func applyPreview(_ row: ThemeRow) {
        if row.problem != nil {
            runtime.previewTheme(nil)
            status = fileStatus()
        } else {
            runtime.previewTheme(row.value)
            status = .preview("Previewing \(row.name). ↩ chooses where to use it, esc restores the current theme.")
        }
    }
    @discardableResult func preview(_ row: ThemeRow) -> Bool {
        let previous = rows
        applyPreview(check(row.value))
        return previous != rows
    }
    func configChanged() -> Bool {
        guard case .preview(let value) = runtime.themeOverride else {
            if case .writeError = status { return false }
            status = fileStatus()
            return false
        }
        let previous = rows
        let row = check(value)
        if row.problem != nil { applyPreview(row) }
        return previous != rows
    }
    func beginSave(_ row: ThemeRow) {
        dark = runtime.colorScheme == GHOSTTY_COLOR_SCHEME_DARK
        selectRadio(0, row: row)
    }
    func selectRadio(_ index: Int, row: ThemeRow) {
        radio = index
        guard index != 3 else { return }
        savePair = merged(row, current: (try? ThemeConf.read(runtime.configFile))?.pair ?? .init())
    }
    private func merged(_ row: ThemeRow, current: ThemeConf.Pair) -> ThemeConf.Pair {
        var pair = current
        if radio == 2 || (radio == 0 ? !dark : dark) { pair.light = row.value }
        if radio == 2 || (radio == 0 ? dark : !dark) { pair.dark = row.value }
        return pair
    }
    func foot(_ row: ThemeRow? = nil) -> String {
        if row != nil, radio == 3 { return "applies until quit; \(runtime.abbreviate(runtime.configFile)) is not changed" }
        if row != nil { return "writes \(ThemeConf.line(savePair)) to \(runtime.abbreviate(runtime.configFile))" }
        return "themes: bundled + \(runtime.abbreviate(directory))"
    }
    func reveal() {
        let file = URL(fileURLWithPath: runtime.configFile)
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()])
    }
    func write(_ row: ThemeRow) -> Bool {
        let row = check(row.value)
        guard row.problem == nil else { applyPreview(row); return false }
        if radio == 3 {
            runtime.saveThemeOverride(row.value)
            status = nil
            return true
        }
        runtime.flushTheme()
        do {
            let changed = try ThemeConf.write(to: runtime.configFile) { merged(row, current: $0) }
            runtime.saveThemeOverride(nil, reload: !changed)
            return true
        } catch {
            runtime.saveThemeOverride(row.value)
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            let code = Int32(underlying?.code ?? failure.code)
            status = .writeError("Could not write \(runtime.abbreviate(runtime.configFile)): \(String(cString: strerror(code)).lowercased()). \(row.name) is applied for this session only.")
            return false
        }
    }
}
