import AppKit
import SwiftUI
import Testing
@testable import PiSurface

@MainActor @Test func historyCursorUsesSnapshotAndPages() throws {
    let session = Session { _ in }
    var sequence = 1
    func receive(_ value: JSON) {
        for frame in Codec.encode(value.text, number: sequence) { session.receive(frame); sequence += 1 }
    }
    let entry: JSON = .object(["id": .string("newest"), "message": .object(["role": .string("user"), "content": .string("Hello")])])
    for cursor in [JSON.null, .string("older")] {
        receive(.object(["type": .string("snapshot"), "hello": .object(["instance": .string("test")]), "generation": .number(1), "before": cursor, "record": .object(["entries": .array([entry])])]))
        #expect(session.historyBefore == cursor)
    }
    for cursor in [JSON.string("oldest"), .null] {
        session.command("history")
        let id = try #require(session.requests.first { $0.value == "history" }?.key)
        receive(.object(["type": .string("history"), "generation": .number(1), "id": .string(id), "entries": .array([]), "before": cursor]))
        #expect(session.historyBefore == cursor)
    }
    session.disconnect()
}

@MainActor @Test func disclosurePreservesViewport() async throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    func table(_ view: NSView) -> NSTableView? { view as? NSTableView ?? view.subviews.lazy.compactMap(table).first }
    for width in [440, 920] {
        let window = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        defer { window.close() }
        var following = false
        let rows = (0..<30).map { index in
            [10, 28].contains(index) ? DisplayRow(id: "activity-\(index)", content: .activity((0..<6).map { .init(id: "thought-\($0)", content: .thinking("Thought \($0)", false)) })) : [11, 29].contains(index) ? DisplayRow(id: "thought-\(index)", content: .thinking((0..<6).map { "Thought paragraph \($0)." }.joined(separator: "\n\n"), false)) : DisplayRow(id: "row-\(index)", content: .markdown("Prose row \(index)\n\nAnother paragraph."))
        }
        let host = NSHostingView(rootView: TranscriptTable(scope: "test", rows: rows, revision: 1, structure: 1, changed: Set(rows.map(\.id)), applied: { _ in }, expanded: false, tailRequest: 0, following: Binding(get: { following }, set: { following = $0 }), loadHistory: {}))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 360); window.contentView = host; window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        let table = try #require(table(host)), scroll = try #require(table.enclosingScrollView)
        let coordinator = try #require(table.dataSource as? TranscriptTable.Coordinator)
        let sizing = NSHostingView(rootView: AnyView(EmptyView()))
        sizing.frame = NSRect(x: -10000, y: 0, width: width, height: 500)
        host.addSubview(sizing)
        for placement in ["above", "at", "below", "tail"] {
            let row = placement == "tail" ? 28 : 10
            for open in [true, false] {
                following = false; coordinator.readAnchor = nil
                let top = table.rect(ofRow: row).minY
                let y = placement == "above" ? top + table.rect(ofRow: row).height + 18 : placement == "at" ? top : placement == "tail" ? table.bounds.height - scroll.contentView.bounds.height : top - 180
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(150))
                following = placement == "tail"
                coordinator.readAnchor = ("row-0", 0)
                let anchor = placement == "above" ? table.row(at: scroll.contentView.bounds.origin) : row
                let offset = table.rect(ofRow: anchor).minY - scroll.contentView.bounds.minY
                let oldHeight = table.rect(ofRow: row).height
                coordinator.beginReading(rows[row].id)
                coordinator.expansionChanged(rows[row].id, open: open)
                sizing.rootView = AnyView(MessageView(row: rows[row], expanded: open).frame(width: CGFloat(width - 24)).fixedSize(horizontal: false, vertical: true).padding(12))
                try await Task.sleep(for: .milliseconds(150)); sizing.layoutSubtreeIfNeeded()
                coordinator.measured(rows[row], width: CGFloat(width), height: ceil(sizing.fittingSize.height))
                try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
                #expect(open ? table.rect(ofRow: row).height > oldHeight + 20 : table.rect(ofRow: row).height < oldHeight - 20)
                #expect(!following)
                #expect(abs(table.rect(ofRow: anchor).minY - scroll.contentView.bounds.minY - offset) <= 1, "\(width) \(placement) \(open ? "expand" : "collapse")")
            }
        }
        sizing.removeFromSuperview()
        for (placement, row) in [("middle activity", 10), ("middle disclosure", 11), ("tail activity", 28), ("tail disclosure", 29)] {
            for open in [true, false] {
                following = false; coordinator.readAnchor = nil
                let y = placement.hasPrefix("tail") ? table.bounds.height - scroll.contentView.bounds.height : table.rect(ofRow: row).minY - 80
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
                following = placement.hasPrefix("tail")
                let headerY = table.rect(ofRow: row).minY - scroll.contentView.bounds.minY
                let oldHeight = table.rect(ofRow: row).height
                let point = table.convert(NSPoint(x: 30, y: table.rect(ofRow: row).minY + 22), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
                #expect(open ? table.rect(ofRow: row).height > oldHeight + 20 : table.rect(ofRow: row).height < oldHeight - 20, "mouse click changed height")
                #expect(!following)
                #expect(abs(table.rect(ofRow: row).minY - scroll.contentView.bounds.minY - headerY) <= 1, "mouse \(width) \(placement) \(open ? "expand" : "collapse")")
            }
        }
        #expect(!window.isKeyWindow && !window.isMainWindow)
        #expect(NSScreen.screens.allSatisfy { !window.frame.intersects($0.frame) })
    }
}
