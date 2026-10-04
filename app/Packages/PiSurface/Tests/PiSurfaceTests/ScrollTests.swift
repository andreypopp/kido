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
            index == 10 ? DisplayRow(id: "activity", content: .activity((0..<6).map { .init(id: "thought-\($0)", content: .thinking("Thought \($0)", false)) })) : DisplayRow(id: "row-\(index)", content: .markdown("Prose row \(index)\n\nAnother paragraph."))
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
            for open in [true, false] {
                following = false; coordinator.readAnchor = nil
                let top = table.rect(ofRow: 10).minY
                let y = placement == "above" ? top + table.rect(ofRow: 10).height + 18 : placement == "at" ? top : placement == "tail" ? table.bounds.height - scroll.contentView.bounds.height : top - 180
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(150))
                following = placement == "tail"
                coordinator.readAnchor = ("row-0", 0)
                let anchor = placement == "above" ? table.row(at: scroll.contentView.bounds.origin) : 10
                let offset = table.rect(ofRow: anchor).minY - scroll.contentView.bounds.minY
                let oldHeight = table.rect(ofRow: 10).height
                coordinator.expansionChanged("activity", open: open)
                sizing.rootView = AnyView(MessageView(row: rows[10], expanded: open).frame(width: CGFloat(width - 24)).fixedSize(horizontal: false, vertical: true).padding(12))
                try await Task.sleep(for: .milliseconds(150)); sizing.layoutSubtreeIfNeeded()
                coordinator.measured(rows[10], width: CGFloat(width), height: ceil(sizing.fittingSize.height))
                try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
                #expect(open ? table.rect(ofRow: 10).height > oldHeight + 20 : table.rect(ofRow: 10).height < oldHeight - 20)
                if placement == "tail" { #expect(abs(table.bounds.height - scroll.contentView.bounds.maxY) <= 2) }
                else { #expect(abs(table.rect(ofRow: anchor).minY - scroll.contentView.bounds.minY - offset) <= 2, "\(width) \(placement) \(open ? "expand" : "collapse")") }
            }
        }
        #expect(!window.isKeyWindow && !window.isMainWindow)
        #expect(NSScreen.screens.allSatisfy { !window.frame.intersects($0.frame) })
    }
}
