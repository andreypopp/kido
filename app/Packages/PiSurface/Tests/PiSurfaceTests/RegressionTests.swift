import AppKit
import SwiftUI
import Markdown
import Testing
@testable import PiSurface

@Test func markdownPreservesInlineContextAndCompletedBlocks() {
    let parser = ParsedMarkdown()
    let first = "Words **with emphasis** and [a link](https://example.com), `code`,\na soft break.\n\n> Quoted **words**.\n\n"
    let blocks = parser.blocks(first + "Tail")
    #expect(String(blocks[0].inline.characters) == "Words with emphasis and a link, code, a soft break.")
    #expect(String(blocks[1].children[0].inline.characters) == "Quoted words.")
    #expect(!String(blocks[1].children[0].inline.characters).contains(">"))
    let streamed = parser.blocks(first + "Tail grows")
    #expect(streamed[0].markup.isIdentical(to: blocks[0].markup))
    #expect(streamed[1].markup.isIdentical(to: blocks[1].markup))
    #expect(String(streamed[2].inline.characters) == "Tail grows")
    #expect(String(parser.blocks("Replacement")[0].inline.characters) == "Replacement")
}

@Test func reorderedProjectionChangesStructureOnly() {
    let rows = [DisplayRow(id: "a", content: .markdown("A")), DisplayRow(id: "b", content: .markdown("B"))]
    var transcript = Transcript()
    transcript.reconcile(rows); transcript.changed.removeAll()
    transcript.reconcile(rows.reversed())
    #expect(transcript.structure == 2)
    #expect(transcript.changed.isEmpty)
}

@MainActor @Test func reconciledToolsAndRepeatedCanonicalEnds() async {
    let session = Session(client: "test") { _ in }
    var seq = 0
    func event(_ text: String) {
        for frame in Codec.encode(text, number: seq + 1) { session.receive(frame); seq += 1 }
    }
    event(#"{"type":"snapshot","hello":{"instance":"test"},"generation":1,"record":{"entries":[],"state":{"isStreaming":true},"models":[{"provider":"one","id":"same","name":"Model"},{"provider":"two","id":"same","name":"Model"}]}}"#)
    #expect(session.models.map(\.id) == ["one/same", "two/same"])
    #expect(session.models.map(\.name) == ["Model · one", "Model · two"])
    event(#"{"type":"message_end","uiId":"user","message":{"role":"user","content":"Hello"}}"#)
    event(#"{"type":"message_end","uiId":"user","message":{"role":"user","content":"Hello"}}"#)
    #expect(session.rows.count == 1)
    event(#"{"type":"tool_execution_start","toolCallId":"tool","toolName":"bash","args":{"command":"ls"}}"#)
    event(#"{"type":"response","command":"get_entries","success":true,"data":{"entries":[{"uiId":"result","id":"persisted","message":{"role":"toolResult","toolCallId":"tool","toolName":"bash","isError":true,"content":[{"type":"text","text":"failed"}]}}]}}"#)
    #expect(session.tools.isEmpty)
    #expect(session.displayRows.count == 2)
    if case .tool(_, let result, _) = session.displayRows[1].content { #expect(result["isError"] == .bool(true)) }
    else { Issue.record("Final tool result missing") }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(session.transcriptRows.changed.contains(session.scope + ":responding"))
    session.disconnect()
}

@MainActor @Test func shiftedRowsExpansionAndLazyResize() async throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let window = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
    var following = false
    let thought = DisplayRow(id: "survivor", content: .thinking("Long thoughts\n\n" + String(repeating: "many words ", count: 80), false))
    var rows = [thought]
    let binding = Binding(get: { following }, set: { following = $0 })
    func root(_ revision: Int, expanded: Bool = false) -> TranscriptTable {
        TranscriptTable(scope: "test", rows: rows, revision: revision, structure: revision, changed: Set(rows.map(\.id)), applied: { _ in }, expanded: expanded, tailRequest: 0, following: binding, loadHistory: {})
    }
    let host = NSHostingView(rootView: root(1)); host.frame = NSRect(x: 0, y: 0, width: 480, height: 700); window.contentView = host; window.orderBack(nil)
    defer { window.close() }
    func table(_ view: NSView) -> NSTableView? { view as? NSTableView ?? view.subviews.lazy.compactMap(table).first }
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    let table = try #require(table(host)), coordinator = try #require(table.dataSource as? TranscriptTable.Coordinator)
    let collapsed = table.rect(ofRow: 0).height
    host.rootView = root(2, expanded: true)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    let expanded = table.rect(ofRow: 0).height
    #expect(expanded > collapsed + 30)
    rows[0].content = .markdown(String(repeating: "changed content\n\n", count: 20))
    rows.insert(.init(id: "prepend", content: .markdown("New first row")), at: 0)
    host.rootView = root(3)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    #expect(coordinator.rows[1].id == "survivor")
    #expect(table.rect(ofRow: 1).height > expanded + 100)
    let cell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: false))
    window.setContentSize(NSSize(width: 440, height: 700)); host.frame.size.width = 440
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    #expect(table.view(atColumn: 0, row: 1, makeIfNecessary: false) === cell)
    #expect(table.bounds.width == 440)
    #expect(coordinator.heights["survivor"]?.count == 2)
    rows.reverse(); host.rootView = root(4)
    try await Task.sleep(for: .milliseconds(150))
    #expect(coordinator.positions["survivor"] == 0)
    rows += (0..<20).map { .init(id: "extra-\($0)", content: .markdown("Extra row")) }; host.rootView = root(5)
    try await Task.sleep(for: .milliseconds(150))
    let scroll = try #require(table.enclosingScrollView)
    following = false; coordinator.readAnchor = nil
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(150))
    #expect(scroll.contentView.bounds.minY < 1)
    let detail = NSHostingView(rootView: MessageView(row: thought))
    detail.frame = host.frame; window.contentView = detail
    try await Task.sleep(for: .milliseconds(150))
    let closed = detail.fittingSize.height
    detail.rootView = MessageView(row: thought, expanded: true)
    try await Task.sleep(for: .milliseconds(150))
    #expect(detail.fittingSize.height > closed + 30)
    #expect(!window.isKeyWindow && !window.isMainWindow)
    #expect(NSScreen.screens.allSatisfy { !window.frame.intersects($0.frame) })
}
