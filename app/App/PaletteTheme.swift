import AppKit
import GhosttyKit
import KoModel

enum ThemeStep: Equatable {
    case pick, save(ThemeRow)
}

struct ThemeRow: Equatable {
    let name: String
    let value: String
    let path: String
    let background: NSColor
    let foreground: NSColor
    let colors: [NSColor]
    let file: ThemeFile
    var problem: ThemeFile.Problem? { file.problem }

    @MainActor static func load(_ path: String, file: ThemeFile? = nil) -> ThemeRow {
        let file = file ?? ThemeFile(path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let config = ghostty_config_new()!
        defer { ghostty_config_free(config) }
        if let data = file.contents {
            let text = String(decoding: data, as: UTF8.self)
            ghostty_config_load_string(config, text, UInt(data.count), path)
        }
        var palette = ghostty_config_palette_s()
        _ = ghostty_config_get(config, &palette, "palette", 7)
        let colors = withUnsafePointer(to: &palette.colors) { pointer in
            pointer.withMemoryRebound(to: ghostty_config_color_s.self, capacity: 256) { p in [4, 2, 1, 3].map { GhosttyRuntime.color(p[$0]) } }
        }
        return ThemeRow(name: name, value: name, path: path, background: GhosttyRuntime.color("background", config: config), foreground: GhosttyRuntime.color("foreground", config: config), colors: colors, file: file)
    }

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
    let runtime: GhosttyRuntime
    let directory: String
    let pair: KoSchema.ThemePair
    var rows: [ThemeRow]
    var query = ""
    var selection = 0
    private(set) var dark = false
    private(set) var radio = 0
    private var savePair: KoSchema.ThemePair
    private(set) var status: Status?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        directory = ThemePaths.directory(configFile: runtime.configFile).path
        pair = AppConfig.pair(runtime.values.theme)
        savePair = pair
        rows = ThemePaths.bundled.map { ThemeRow.load(ThemePaths.path($0, configFile: runtime.configFile)) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        rows += files.filter { name in
            // Use the ThemeName rule in ko_config/src/values.rs.
            guard !name.hasPrefix("."),
                  !name.unicodeScalars.contains(where: { "/,:=".unicodeScalars.contains($0) || $0.properties.generalCategory == .control }),
                  !ThemePaths.bundled.contains(name) else { return false }
            var info = stat()
            return stat(directory + "/" + name, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ThemeRow.load(ThemePaths.path($0, configFile: runtime.configFile)) }
        dark = runtime.colorScheme == GHOSTTY_COLOR_SCHEME_DARK
        selection = rows.firstIndex { $0.value == (dark ? pair.dark : pair.light) } ?? 0
        status = fileStatus()
    }
    private func fileStatus() -> Status? {
        guard let error = runtime.configError else { return nil }
        if error.path != runtime.configFile {
            let sides = runtime.colorScheme == GHOSTTY_COLOR_SCHEME_DARK ? [("Dark", pair.dark), ("Light", pair.light)] : [("Light", pair.light), ("Dark", pair.dark)]
            if let (side, name) = sides.first(where: { ThemePaths.path($0.1, configFile: runtime.configFile) == error.path }) {
                return .fileError("\(name): \(error.problem.message). The current config names it for \(side); Kido's default theme is shown instead.")
            }
        }
        return .fileError("\(runtime.abbreviate(error.path)): \(error.problem.detail)")
    }
    func entries(_ step: ThemeStep = .pick) -> [(entry: PaletteEntry, offsets: [[Int]])] {
        if case .save = step {
            return [(dark ? "Dark mode" : "Light mode", " · the current appearance"), (dark ? "Light mode" : "Dark mode", ""), ("Both", " · one theme whatever the appearance"), ("This session only", " · not saved to config.yaml")].enumerated().map { index, item in
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
        rows[index] = ThemeRow.load(rows[index].path)
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
    func preview(_ row: ThemeRow) {
        runtime.previewTheme(row.value)
        status = .preview("Previewing \(row.name). ↩ chooses where to use it, esc restores the current theme.")
    }
    func configChanged() -> Bool {
        guard case .preview(let value) = runtime.themeOverride else {
            if case .writeError = status { return false }
            status = fileStatus()
            return false
        }
        guard let index = rows.firstIndex(where: { $0.value == value }), let file = runtime.themeFiles[rows[index].path] else { return false }
        let previous = rows
        rows[index] = ThemeRow.load(rows[index].path, file: file)
        if rows[index].problem != nil { applyPreview(rows[index]) }
        return previous != rows
    }
    func beginSave(_ row: ThemeRow) {
        dark = runtime.colorScheme == GHOSTTY_COLOR_SCHEME_DARK
        selectRadio(0, row: row)
    }
    func selectRadio(_ index: Int, row: ThemeRow) {
        radio = index
        guard index != 3 else { return }
        savePair = merged(row, current: (try? AppConfig.load(runtime.configFile)).map { AppConfig.pair($0.theme) } ?? pair)
    }
    private func merged(_ row: ThemeRow, current: KoSchema.ThemePair) -> KoSchema.ThemePair {
        var pair = current
        if radio == 2 || (radio == 0 ? !dark : dark) { pair.light = row.value }
        if radio == 2 || (radio == 0 ? dark : !dark) { pair.dark = row.value }
        return pair
    }
    func foot(_ row: ThemeRow? = nil) -> String {
        if row != nil, radio == 3 { return "applies until quit; \(runtime.abbreviate(runtime.configFile)) is not changed" }
        if row != nil { return "writes theme: light: \(savePair.light), dark: \(savePair.dark) to \(runtime.abbreviate(runtime.configFile))" }
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
            let current = AppConfig.pair(try AppConfig.load(runtime.configFile).theme)
            try AppConfig.setTheme(runtime.configFile, merged(row, current: current))
            runtime.saveThemeOverride(nil, reload: true)
            return true
        } catch {
            runtime.saveThemeOverride(row.value)
            let message = (error as? ConfigProblem)?.detail ?? error.localizedDescription
            status = .writeError("Could not write \(runtime.abbreviate(runtime.configFile)): \(message). \(row.name) is applied for this session only.")
            return false
        }
    }
}
