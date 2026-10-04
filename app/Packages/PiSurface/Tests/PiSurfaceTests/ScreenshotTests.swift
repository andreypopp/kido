import AppKit
import SwiftUI
import Testing
@testable import PiSurface

@MainActor private final class ScreenshotWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Test func screenshots() async throws {
    guard let directory = ProcessInfo.processInfo.environment["PI_SURFACE_SHOTS"] else { return }
    _ = NSApplication.shared
    let output = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for source in ["session", "real-session"] {
    let path = output.appendingPathComponent("\(source).bytes")
    #expect(FileManager.default.fileExists(atPath: path.path))
    let bytes = try Data(contentsOf: path)
    var codec = Codec()
    let frames = codec.receive(bytes)
    #expect(!frames.isEmpty)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let session = Session { _ in }
        let host = NSHostingView(rootView: AnyView(Surface(session: session, expanded: source == "session")
            .environment(\.colorScheme, name == "dark" ? .dark : .light)
            .background(name == "dark" ? Color(nsColor: .windowBackgroundColor) : Color.white)))
        let window = ScreenshotWindow(contentRect: NSRect(x: -20000, y: -20000, width: 920, height: 800), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 920, height: 800)
        defer { window.close() }
        window.orderBack(nil)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(200))
        let windows = try #require(CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]])
        let info = try #require(windows.first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber })
        let bounds = try #require(info[kCGWindowBounds as String] as? [String: Any])
        let rect = try #require(CGRect(dictionaryRepresentation: bounds as CFDictionary))
        for screen in NSScreen.screens {
            #expect(!window.frame.intersects(screen.frame))
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let intersects = rect.intersects(CGDisplayBounds(number.uint32Value))
                #expect(intersects == false)
            }
        }
        #expect(!window.isKeyWindow && !window.isMainWindow)
        var assembly = Data(), lastSequence = 0
        var historical: [JSON] = []
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        var captured = Set<String>()
        func capture(_ state: String) async throws {
            guard captured.insert(state).inserted else { return }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            host.display()
            let table = try #require(tables(host).first)
            let visible = table.rows(in: table.visibleRect)
            #expect(visible.length > 0)
            for index in visible.location..<NSMaxRange(visible) {
                let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: false))
                #expect(table.rect(ofRow: index).height + 2 >= cell.fittingSize.height)
            }
            CATransaction.flush()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let context = try #require(CGContext(data: nil, width: Int(host.bounds.width), height: Int(host.bounds.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try #require(bitmap.cgImage), in: host.bounds)
            let image = try #require(context.makeImage())
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(state)-\(name).png"))
            if let sheet = window.attachedSheet, let content = sheet.contentView {
                content.layoutSubtreeIfNeeded()
                let dialog = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: dialog)
                if let context = NSGraphicsContext(bitmapImageRep: dialog)?.cgContext {
                    context.setBlendMode(.destinationOver)
                    window.appearance?.performAsCurrentDrawingAppearance {
                        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: dialog.pixelsWide, height: dialog.pixelsHigh))
                    }
                }
                try #require(dialog.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(state)-dialog-\(name).png"))
            }
        }
        for frame in frames {
            let wire = Data("\u{1b}]6767;\(frame.header.joined(separator: ","));\(frame.bytes.base64EncodedString())\u{7}".utf8)
            session.receive(wire); lastSequence = Int(frame.header[0]) ?? lastSequence
            assembly.append(frame.bytes)
            guard frame.header.last == "1" else { continue }
            let event = try JSONDecoder().decode(JSON.self, from: assembly)
            assembly.removeAll()
            if source == "real-session", event["type"].string == "response", event["command"].string == "get_entries" { historical = event["data"]["entries"].array }
            if source == "real-session", event["type"].string == "snapshot", !session.rows.isEmpty { break }
            if event["type"].string == "message_update", event["assistantMessageEvent"]["delta"].string == "Hello! " { try await capture("mid-stream") }
            if event["type"].string == "message_end", event["message"]["toolName"].string == "edit" { try await capture("tools") }
            if event["type"].string == "queue_update" { try await capture("confirm") }
            if event["type"].string == "agent_end" { try await capture("final") }
        }
        if source == "real-session" {
            host.rootView = AnyView(Surface(session: session)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .background(name == "dark" ? Color(nsColor: .windowBackgroundColor) : Color.white))
            try await Task.sleep(for: .seconds(1))
            try await capture("long-session")
            #expect(!session.rows.isEmpty)
            let table = try #require(tables(host).first), scroll = try #require(table.enclosingScrollView)
            let coordinator = try #require(table.dataSource as? TranscriptTable.Coordinator)
            coordinator.parent.following = false; coordinator.readAnchor = nil
            scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: table.numberOfRows / 2).minY + 7)); scroll.reflectScrolledClipView(scroll.contentView)
            try await capture("long-session-middle")
            #expect(scroll.contentView.bounds.minY > 300)
            coordinator.parent.following = false; coordinator.readAnchor = nil
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            try await capture("long-session-top")
            #expect(abs(scroll.contentView.bounds.minY) < 1)
            let anchor = coordinator.rows[1].id, offset = scroll.contentView.bounds.origin.y - table.rect(ofRow: 1).minY
            let entries = Dictionary(uniqueKeysWithValues: historical.map { ($0["id"].string, $0) })
            var older: [JSON] = [], cursor = entries[session.historyBefore.string]?["parentId"].string ?? ""
            for _ in 0..<200 { guard let entry = entries[cursor] else { break }; older.append(entry); cursor = entry["parentId"].string }
            #expect(!older.isEmpty)
            session.command("history", fields: ["generation": session.generation, "before": session.historyBefore, "limit": .number(200)])
            let request = try #require(session.requests.first { $0.value.command == "history" }?.key)
            let reply = JSON.object(["type": .string("history"), "id": .string(request), "generation": session.generation, "entries": .array(older.reversed()), "before": older.last?["id"] ?? .null])
            for frame in Codec.encode(reply.text, number: lastSequence + 1) { session.receive(frame) }
            try await capture("long-session-after-prepend")
            let restored = try #require(coordinator.rows.firstIndex { $0.id == anchor })
            #expect(abs(scroll.contentView.bounds.origin.y - table.rect(ofRow: restored).minY - offset) <= 2)
            window.setContentSize(NSSize(width: 440, height: 700)); host.frame.size = NSSize(width: 440, height: 700)
            try await capture("long-session-narrow")
            session.disconnect()
        } else {
            #expect(captured == Set(["mid-stream", "tools", "confirm", "final"]))
            let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/pi/testdata/kido-pi-snapshot.json")
            let fixture = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: fixtureURL))["completed"]
            let entries = fixture["record"]["entries"].array
            let journal = try JSONDecoder().decode([JSON].self, from: Data("""
            [{"id":"prompt","message":{"role":"user","content":"The transcript jumps when new tool output arrives. Keep the viewport stable while I’m reading older messages.\\n\\nStart with `TranscriptView.swift`, and add a regression test."}},
             {"id":"answer","message":{"role":"assistant","content":[{"type":"text","text":"I’ll check how the transcript follows live output, then separate that from the scroll position you’ve chosen."},{"type":"thinking","thinking":"Check the existing anchor before changing follow-tail."},{"type":"toolCall","id":"read1","name":"read","arguments":{"path":"app/TranscriptView.swift"}},{"type":"toolCall","id":"read2","name":"read","arguments":{"path":"app/Tests/TranscriptTests.swift"}},{"type":"toolCall","id":"test","name":"bash","arguments":{"command":"swift test --filter ScrollAnchorTests"}}]}}]
            """.utf8))
            let galleries: [(String, [JSON], Bool)] = [
                ("journal-wide", journal, false), ("journal-expanded-wide", journal, true), ("journal-narrow", journal, false), ("journal-expanded-narrow", journal, true),
                ("empty", [], false), ("one-message", Array(entries.prefix(1)), false),
                ("markdown", entries.filter { [.number(1700000000040), .number(1700000000050), .number(1700000000060)].contains($0["message"]["timestamp"]) }, false),
                ("cards", entries.filter { $0["message"]["role"].string == "custom" }, true),
                ("images", entries.filter { $0["message"]["timestamp"] == .number(1700000000120) }, false),
                ("activity-expanded", Array(entries.prefix(4)), true), ("tools-collapsed", Array(entries.prefix(4)), false), ("narrow", Array(entries.prefix(4)), false),
                ("long-user-narrow", [.object(["id": .string("long-user"), "message": .object(["role": .string("user"), "content": .string(String(repeating: "A long user prompt should wrap without clipping at narrow widths.\n", count: 8))])])], false)
            ]
            for (index, gallery) in galleries.enumerated() {
                let replay = Session { _ in }
                var snapshot = fixture.object, record = fixture["record"].object
                record["entries"] = .array(gallery.1); record["dialogs"] = .object([:]); record["queues"] = .object([:]); record["notifications"] = .array([]); record["widgets"] = .object([:])
                if gallery.0.hasPrefix("journal") {
                    record["tools"] = .object(["test": .object(["toolName": .string("bash"), "ended": .bool(false), "partialResult": .object(["content": .array([.object(["type": .string("text"), "text": .string("Earlier output\nTest preservesVisibleAnchor passed\nTest doesNotFollowWhileReading passed\nTesting restoresFollowTailOnSend…")])])])])])
                }
                snapshot["record"] = .object(record); snapshot["generation"] = .number(Double(index + 100))
                for frame in Codec.encode(JSON.object(snapshot).text) { replay.receive(frame) }
                host.rootView = AnyView(Surface(session: replay, expanded: gallery.2).environment(\.colorScheme, name == "dark" ? .dark : .light).background(name == "dark" ? Color(nsColor: .windowBackgroundColor) : Color.white))
                window.setContentSize(NSSize(width: 920, height: 800)); host.frame.size = NSSize(width: 920, height: 800)
                if gallery.0.hasSuffix("narrow") { window.setContentSize(NSSize(width: 440, height: 700)); host.frame.size = NSSize(width: 440, height: 700) }
                try await capture(gallery.0)
            }
            for width in [440, 920] {
                window.setContentSize(NSSize(width: width, height: 700)); host.frame.size = NSSize(width: width, height: 700)
                for (label, text) in [("short", "Check the narrow pane."), ("grown", String(repeating: "Keep the viewport stable while reading older messages. ", count: 5))] {
                    let draft = ComposerDraft(); draft.text = text
                    host.rootView = AnyView(Surface(session: session, draft: draft).environment(\.colorScheme, name == "dark" ? .dark : .light).background(name == "dark" ? Color(nsColor: .windowBackgroundColor) : Color.white).id("composer-\(label)-\(width)"))
                    try await capture("composer-\(label)-\(width)")
                }
            }
            window.setContentSize(NSSize(width: 920, height: 800)); host.frame.size = NSSize(width: 920, height: 800)
            for (index, method) in ["select", "input", "editor"].enumerated() {
                let replay = Session { _ in }
                var snapshot = fixture.object, record = fixture["record"].object
                record["entries"] = .array([]); record["queues"] = .object([:]); record["notifications"] = .array([]); record["widgets"] = .object([:])
                record["dialogs"] = .object([method: .object(["id": .string(method), "method": .string(method), "title": .string(method.capitalized), "message": .string("Choose an exact response."), "prefill": .string("Prefilled response"), "placeholder": .string("Your response"), "options": .array([.string("First option"), .string("Another option with a longer description"), .string("First option")])])])
                snapshot["record"] = .object(record); snapshot["generation"] = .number(Double(index + 200))
                for frame in Codec.encode(JSON.object(snapshot).text) { replay.receive(frame) }
                host.rootView = AnyView(Surface(session: replay).environment(\.colorScheme, name == "dark" ? .dark : .light).background(name == "dark" ? Color(nsColor: .windowBackgroundColor) : Color.white))
                try await capture(method)
            }
        }
    }
    }
}
