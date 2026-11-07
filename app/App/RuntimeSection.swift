import AppKit
import KoModel

final class RuntimeSection: NSView {
    enum Selection: Equatable {
        case header
        case runtime(RuntimeKey)
    }

    struct Row: Equatable {
        let runtime: KoSchema.ClientRuntime
        let panes: Int
        let stopping: Bool

        var spins: Bool {
            if stopping { return true }
            if case .starting = runtime.state { return true }
            return false
        }

        var canStart: Bool {
            guard !stopping else { return false }
            switch runtime.state {
            case .down, .failed: return true
            case .up, .starting: return false
            }
        }

        var failure: String? { stopping ? nil : runtime.state.failure }

        var detail: String {
            var text = runtime.kind.rawValue + " · " + (stopping ? "stopping" : runtime.state.stateWord)
            if let failure { text += ": " + failure }
            if !stopping, case .up = runtime.state, panes > 0 {
                text += " · \(panes) pane" + (panes == 1 ? "" : "s")
            }
            return text
        }
    }

    var rows: [Row] = [] {
        didSet {
            guard rows != oldValue else { return }
            if case .runtime(let key) = selection, !rows.contains(where: { $0.runtime.key == key }) {
                selection = nil
            }
            rebuild()
        }
    }
    var configError: String? {
        didSet {
            if configError != oldValue { rebuild() }
        }
    }
    var dark = false {
        didSet {
            if dark != oldValue { needsDisplay = true }
        }
    }
    var selection: Selection? {
        didSet {
            if selection != oldValue { needsDisplay = true }
        }
    }
    var collapsed = UserDefaults.standard.bool(forKey: "runtimesCollapsed") {
        didSet {
            guard collapsed != oldValue else { return }
            UserDefaults.standard.set(collapsed, forKey: "runtimesCollapsed")
            if collapsed, selection != nil { selection = .header }
            rebuild()
        }
    }
    var changed: () -> Void = {}
    var selected: () -> Void = {}
    var previous: () -> Void = {}
    var leave: () -> Void = {}
    var start: (RuntimeKey) -> Void = { _ in }
    var stop: (RuntimeKey) -> Void = { _ in }
    var open: (RuntimeKey) -> Void = { _ in }
    var enabled = true
    private var hover: Int?
    private var buttonHover = false
    private var spinners: [(key: RuntimeKey, view: NSProgressIndicator)] = []
    private var renderedHeight: CGFloat = 0
    private var aggregate = ""
    private var narrowAggregate = ""
    private var failedPart: String?
    private let titleFont = NSFont.systemFont(ofSize: 13)
    private let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private let aggregateFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let paragraph: NSMutableParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              event.window === window, !event.modifierFlags.contains(.control) else { return true }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return true }
        return point.y >= 29.5 && (collapsed || !rows.indices.contains { actionRect($0).contains(point) })
    }
    var height: CGFloat {
        rows.isEmpty && configError == nil ? 0 : 29.5 + (collapsed ? 0 : CGFloat(rows.count + (configError == nil ? 0 : 1)) * 28)
    }
    private var rowsTop: CGFloat { 29.5 + (configError == nil ? 0 : 28) }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 8, y: rowsTop + CGFloat(index) * 28, width: bounds.width - 16, height: 28)
    }

    private func actionRect(_ index: Int) -> NSRect {
        let row = rowRect(index)
        return NSRect(x: row.maxX - 28, y: row.midY - 8, width: 16, height: 16)
    }

    private func nameWidth(_ row: Row) -> CGFloat {
        let width = (row.runtime.name as NSString).size(withAttributes: [.font: titleFont]).width
        return min(width, max(96, bounds.width - 112))
    }

    private func rebuild() {
        var up = 0, starting = 0, stopping = 0, failed = 0
        for row in rows {
            if row.stopping { stopping += 1; continue }
            switch row.runtime.state {
            case .up: up += 1
            case .starting: starting += 1
            case .failed: failed += 1
            case .down: break
            }
        }
        let parts = [(up, "up"), (starting, "starting"), (stopping, "stopping"), (failed, "failed")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        aggregate = configError != nil ? "config error" : parts.isEmpty ? "\(rows.count) down" : parts.joined(separator: " · ")
        narrowAggregate = [(failed, "failed"), (stopping, "stopping"), (starting, "starting"), (up, "up")]
            .first { $0.0 > 0 }.map { "\($0.0) \($0.1)" } ?? aggregate
        failedPart = failed > 0 ? "\(failed) failed" : nil
        let spinning = collapsed ? [] : rows.filter { $0.spins }.map { $0.runtime.key }
        for spinner in spinners where !spinning.contains(spinner.key) {
            spinner.view.removeFromSuperview()
        }
        spinners.removeAll { !spinning.contains($0.key) }
        for key in spinning where !spinners.contains(where: { $0.key == key }) {
            let spinner = miniSpinner()
            addSubview(spinner)
            spinner.startAnimation(nil)
            spinners.append((key, spinner))
        }
        needsDisplay = true
        needsLayout = true
        if height != renderedHeight {
            renderedHeight = height
            changed()
        }
    }

    override func layout() {
        super.layout()
        for spinner in spinners {
            guard let index = rows.firstIndex(where: { $0.runtime.key == spinner.key }) else { continue }
            let row = rows[index]
            let rect = rowRect(index)
            let x = 44 + nameWidth(row) + 6
            let width = (row.detail as NSString).size(withAttributes: [.font: titleFont]).width
            let right = rect.maxX - 12 - (hover == index ? 24 : 0) - 14
            spinner.view.frame = NSRect(x: min(x + width, right) + 5, y: rect.midY - 4.5, width: 9, height: 9)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self))
    }

    private func updateHover(_ index: Int?, button: Bool, tooltip: String?) {
        guard hover != index || buttonHover != button || toolTip != tooltip else { return }
        if hover != index, [hover, index].contains(where: { $0.map { rows.indices.contains($0) && rows[$0].spins } ?? false }) {
            needsLayout = true
        }
        hover = index
        buttonHover = button
        toolTip = tooltip
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = collapsed ? nil : rows.indices.first { rowRect($0).contains(point) }
        let button = index.map { actionRect($0).contains(point) } ?? false
        var tooltip: String?
        if let index {
            let row = rows[index]
            tooltip = row.failure
            if button, !row.stopping { tooltip = (row.canStart ? "Start " : "Shut Down ") + row.runtime.name }
        }
        if configError != nil, point.y >= 29.5, point.y < rowsTop { tooltip = configError }
        updateHover(index, button: button, tooltip: tooltip)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(nil, button: false, tooltip: nil)
    }

    override func resignFirstResponder() -> Bool {
        selection = nil
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let focused = window?.firstResponder === self
        if point.y < 29.5 {
            if focused { selected(); selection = .header }
            collapsed.toggle()
            return
        }
        guard !collapsed, let index = rows.indices.first(where: { rowRect($0).contains(point) }) else { return }
        let row = rows[index]
        let action = actionRect(index).contains(point)
        if focused || !action {
            selected()
            window?.makeFirstResponder(self)
            selection = .runtime(row.runtime.key)
        }
        if action {
            act(row)
        } else if event.clickCount == 2 {
            open(row.runtime.key)
        }
    }

    private func act(_ row: Row) {
        guard enabled, !row.stopping else { return }
        if row.canStart { start(row.runtime.key) } else { stop(row.runtime.key) }
    }

    private func copy(_ key: RuntimeKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.name, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard !collapsed, let index = rows.indices.first(where: { rowRect($0).contains(point) }) else { return nil }
        selected()
        selection = .runtime(rows[index].runtime.key)
        window?.makeFirstResponder(self)
        return contextMenu(rows[index])
    }

    private func contextMenu(_ row: Row) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items = [
            ("Start", #selector(startItem), enabled && row.canStart),
            ("Shut Down…", #selector(stopItem), enabled && !row.stopping && !row.canStart),
            ("Copy Name", #selector(copyItem), true),
        ]
        for (title, action, enabled) in items {
            if title == "Copy Name" { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    private var selectedRow: Row? {
        guard case .runtime(let key) = selection else { return nil }
        return rows.first { $0.runtime.key == key }
    }

    @objc private func startItem() {
        if let row = selectedRow { start(row.runtime.key) }
    }

    @objc private func stopItem() {
        if let row = selectedRow { stop(row.runtime.key) }
    }

    @objc private func copyItem() {
        if let row = selectedRow { copy(row.runtime.key) }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let code = Int(event.keyCode)
        let character = event.charactersIgnoringModifiers ?? ""
        if modifiers == .command && character == "c" {
            if let row = selectedRow { copy(row.runtime.key) }
            return
        }
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch code {
        case 53:
            selection = nil
            leave()
        case 124:
            if selection == .header { collapsed = false }
        case 123:
            if selection == .header { collapsed = true } else { selection = .header }
        case 36, 76, 49:
            if selection == .header {
                collapsed.toggle()
            } else if let row = selectedRow {
                if code == 49 { act(row) } else { open(row.runtime.key) }
            }
        case 110:
            if let row = selectedRow, let index = rows.firstIndex(where: { $0.runtime.key == row.runtime.key }) {
                contextMenu(row).popUp(positioning: nil, at: NSPoint(x: 36, y: rowRect(index).maxY), in: self)
            }
        default:
            if code == 125 || character == "j" { step(1) }
            else if code == 126 || character == "k" { step(-1) }
            else { super.keyDown(with: event) }
        }
    }

    private func step(_ delta: Int) {
        if selection == .header {
            if delta < 0 {
                selection = nil
                previous()
            } else if !collapsed, let first = rows.first {
                selection = .runtime(first.runtime.key)
            }
        } else if let row = selectedRow, let index = rows.firstIndex(where: { $0.runtime.key == row.runtime.key }) {
            if index == 0 && delta < 0 { selection = .header }
            else if rows.indices.contains(index + delta) { selection = .runtime(rows[index + delta].runtime.key) }
        }
    }

    private func text(_ value: String, rect: NSRect, font: NSFont, color: NSColor) {
        (value as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func symbol(_ name: String, rect: NSRect, configuration: NSImage.SymbolConfiguration) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard height > 0 else { return }
        Chrome.hairline.setFill()
        NSRect(x: 8, y: 0, width: bounds.width - 16, height: 0.5).fill()
        if selection == .header {
            Chrome.rowSelection.setFill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: 0.5, width: bounds.width - 16, height: 29), xRadius: 7, yRadius: 7).fill()
        }
        text("Runtimes", rect: NSRect(x: 20, y: 8, width: 60, height: 16), font: headerFont, color: Chrome.inkSecondary)
        let available = max(0, bounds.width - 116)
        let shown = (aggregate as NSString).size(withAttributes: [.font: aggregateFont]).width > available && configError == nil ? narrowAggregate : aggregate
        let width = min(available, (shown as NSString).size(withAttributes: [.font: aggregateFont]).width)
        let aggregateText = NSMutableAttributedString(string: shown, attributes: [.font: aggregateFont, .foregroundColor: Chrome.inkSecondary])
        if configError != nil {
            aggregateText.addAttribute(.foregroundColor, value: Chrome.errorText, range: NSRange(location: 0, length: aggregateText.length))
        } else if let failedPart, let range = shown.range(of: failedPart) {
            aggregateText.addAttribute(.foregroundColor, value: Chrome.errorText, range: NSRange(range, in: shown))
        }
        aggregateText.draw(in: NSRect(x: bounds.width - 39 - width, y: 8, width: width, height: 16))
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(hierarchicalColor: Chrome.inkSecondary))
        if let chevron = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let center = NSPoint(x: bounds.width - 8 - 15, y: 15)
            chevron.draw(in: NSRect(x: center.x - chevron.size.width / 2, y: center.y - chevron.size.height / 2, width: chevron.size.width, height: chevron.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        guard !collapsed else { return }
        if let configError {
            symbol("exclamationmark.triangle.fill", rect: NSRect(x: 22, y: 38, width: 12, height: 12), configuration: .init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [Chrome.onError, Chrome.errorText])))
            let message = configError.range(of: ": runtimes:").map { String(configError[$0.lowerBound...].dropFirst(2)) } ?? configError
            text(message, rect: NSRect(x: 44, y: 34.5, width: bounds.width - 64, height: 18), font: titleFont, color: Chrome.errorText)
        }
        for (index, row) in rows.enumerated() {
            let rect = rowRect(index)
            let selected = selection == .runtime(row.runtime.key)
            if selected || hover == index {
                (selected ? Chrome.rowSelection : Chrome.rowHover).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            }
            Chrome.drawRuntimeSwatch(RuntimeMark.known(row.runtime, routed: false), at: NSPoint(x: 28, y: rect.midY), dark: dark)
            let nameWidth = nameWidth(row)
            text(row.runtime.name, rect: NSRect(x: 44, y: rect.minY + 5, width: nameWidth, height: 18), font: titleFont, color: Chrome.ink)
            let x = 44 + nameWidth + 6
            let right = rect.maxX - 12 - (hover == index ? 24 : 0) - (row.spins ? 14 : 0)
            let detail = row.detail
            let detailText = NSMutableAttributedString(string: detail, attributes: [.font: titleFont, .foregroundColor: Chrome.inkSecondary, .paragraphStyle: paragraph])
            if row.failure != nil, let range = detail.range(of: "failed:") {
                let start = NSRange(range, in: detail).location
                detailText.addAttribute(.foregroundColor, value: Chrome.errorText, range: NSRange(location: start, length: detailText.length - start))
            }
            detailText.draw(in: NSRect(x: x, y: rect.minY + 5, width: max(0, right - x), height: 18))
            if hover == index && !row.stopping {
                let action = actionRect(index)
                if buttonHover {
                    Chrome.closeHover.setFill()
                    NSBezierPath(roundedRect: action, xRadius: 4, yRadius: 4).fill()
                }
                symbol(row.canStart ? "play.fill" : "stop.fill", rect: action.insetBy(dx: 3, dy: 3), configuration: .init(pointSize: 10, weight: .regular).applying(.init(hierarchicalColor: buttonHover ? Chrome.ink : Chrome.inkSecondary)))
            }
        }
    }
}
