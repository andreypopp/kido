import AppKit
import SwiftUI
import Testing
@testable import PiSurface

@MainActor private final class ScreenshotWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Test func screenshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["PI_SURFACE_SHOTS"] else { return }
    _ = NSApplication.shared
    let output = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for source in ["session", "real-session"] {
    let path = output.appendingPathComponent("\(source).bytes")
    if !FileManager.default.fileExists(atPath: path.path) { continue }
    let bytes = try Data(contentsOf: path)
    var codec = Codec()
    let frames = codec.receive(bytes)
    #expect(!frames.isEmpty)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let session = Session { _ in }
        let host = NSHostingView(rootView: Surface(session: session)
            .environment(\.colorScheme, name == "dark" ? .dark : .light)
            .background(name == "dark" ? Color(nsColor: .windowBackgroundColor) : Color.white))
        let window = ScreenshotWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 800), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        defer { window.close() }
        window.orderBack(nil)
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
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
        var assembly = Data()
        var captured = Set<String>()
        func capture(_ state: String) throws {
            guard captured.insert(state).inserted else { return }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
            if state == "tools" || state == "mid-stream" {
                for y in state == "tools" ? [413.0, 360.0] : [190.0] {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 35, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
                    }
                }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
            host.layoutSubtreeIfNeeded()
            host.display()
            CATransaction.flush()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let context = try #require(CGContext(data: nil, width: 1100, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try #require(bitmap.cgImage), in: CGRect(x: 0, y: 0, width: 1100, height: 800))
            let image = try #require(context.makeImage())
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(state)-\(name).png"))
            if let sheet = window.attachedSheet, let content = sheet.contentView {
                content.layoutSubtreeIfNeeded()
                let dialog = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: dialog)
                if let context = NSGraphicsContext(bitmapImageRep: dialog)?.cgContext {
                    context.setBlendMode(.destinationOver)
                    context.setFillColor((name == "dark" ? NSColor.windowBackgroundColor : NSColor.white).cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: dialog.pixelsWide, height: dialog.pixelsHigh))
                }
                try #require(dialog.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(state)-dialog-\(name).png"))
            }
        }
        for frame in frames {
            let wire = Data("\u{1b}]6767;\(frame.header.joined(separator: ","));\(frame.bytes.base64EncodedString())\u{7}".utf8)
            session.receive(wire)
            assembly.append(frame.bytes)
            guard frame.header.last == "1" else { continue }
            let event = try JSONDecoder().decode(JSON.self, from: assembly)
            assembly.removeAll()
            if source == "real-session", event["type"].string == "snapshot", !session.rows.isEmpty { break }
            if event["type"].string == "message_update", event["assistantMessageEvent"]["delta"].string == "Hello! " { try capture("mid-stream") }
            if event["type"].string == "message_end", event["message"]["toolName"].string == "edit" { try capture("tools") }
            if event["type"].string == "queue_update" { try capture("confirm") }
            if event["type"].string == "agent_end" { try capture("final") }
        }
        if source == "real-session" {
            host.rootView = Surface(session: session)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .background(name == "dark" ? Color(nsColor: .windowBackgroundColor) : Color.white)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            try capture("long-session")
            #expect(!session.rows.isEmpty)
        } else {
            #expect(captured == Set(["mid-stream", "tools", "confirm", "final"]))
        }
    }
    }
}
