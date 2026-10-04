import AppKit
import SwiftUI
import Testing
import Darwin
@testable import PiSurface

@MainActor private final class ProfilePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor @Observable private final class ProfileInput { let composer = ComposerDraft(); var tail = 0 }
@MainActor private final class ProfileRecords { var rows: [[String: Any]] = [] }
@MainActor private struct ProfileRoot: View {
    let session: Session
    @Bindable var input: ProfileInput
    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(session: session, expanded: false, tailRequest: input.tail)
            Divider()
            ComposerView(session: session, draft: input.composer, tailRequest: $input.tail)
                .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
@MainActor @Test func profileUI() async throws {
    guard ProcessInfo.processInfo.environment["PI_SURFACE_PROFILE"] == "1" else { return }
    let root = try #require(ProcessInfo.processInfo.environment["PI_PROFILE_ROOT"])
    let out = URL(fileURLWithPath: root).appendingPathComponent("build/pi-ui-profile")
    try String(getpid()).write(to: out.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let mode = ProcessInfo.processInfo.environment["PI_PROFILE_MODE"] ?? "all"
    let flush = ProcessInfo.processInfo.environment["PI_PROFILE_FLUSH"] == "1"
    let deltas = Int(ProcessInfo.processInfo.environment["PI_PROFILE_DELTAS"] ?? "400") ?? 400
    let input = ProfileInput(), session = Session { _ in }
    let host = NSHostingView(rootView: ProfileRoot(session: session, input: input))
    let window = ProfilePanel(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 800), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false; window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
    window.orderBack(nil)
    defer { window.close(); session.disconnect() }
    #expect(!window.isKeyWindow && !window.isMainWindow)
    #expect(NSScreen.screens.allSatisfy { !window.frame.intersects($0.frame) })
    var codec = Codec(), seq = 0, assembly = Data(), snapshot = JSON.null
    for frame in codec.receive(try Data(contentsOf: URL(fileURLWithPath: root + "/build/pi-ui-shots/real-session.bytes"))) {
        session.receive(Data("\u{1b}]6767;\(frame.header.joined(separator: ","));\(frame.bytes.base64EncodedString())\u{7}".utf8))
        seq = Int(frame.header[0]) ?? seq; assembly.append(frame.bytes)
        if frame.header.last == "1" {
            let event = try JSONDecoder().decode(JSON.self, from: assembly); assembly.removeAll()
            if event["type"].string == "snapshot", !session.rows.isEmpty { snapshot = event; break }
        }
    }
    let logs = ProfileRecords()
    @MainActor func record(_ name: String, _ fields: [String: Any] = [:]) {
        logs.rows.append(fields.merging(["name": name, "time": Date().timeIntervalSince1970, "thread_cpu_s": cpu()]) { a, _ in a })
    }
    @MainActor func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
    @MainActor func measure(_ name: String, _ work: () -> Void) {
        let wall = CFAbsoluteTimeGetCurrent(), start = cpu(); work()
        record(name, ["wall_ms": (CFAbsoluteTimeGetCurrent() - wall) * 1000, "cpu_ms": (cpu() - start) * 1000])
    }
    @MainActor func send(_ value: JSON) {
        for data in Codec.encode(value.text, number: seq + 1) { session.receive(data); seq += 1 }
    }
    @MainActor func layout() { if flush { host.layoutSubtreeIfNeeded(); CATransaction.flush() } }
    var previous = session.models.map(\.id), changes = 0
    for _ in 0..<100 {
        let current = session.models.map(\.id)
        changes += zip(previous, current).filter { $0 != $1 }.count
        previous = current
    }
    record("model_identity", ["models": session.models.count, "trials": 100, "changed_ids": changes])
    if mode == "idle-empty-models" {
        var value = snapshot.object, data = snapshot["record"].object
        data["models"] = .array([]); value["record"] = .object(data); send(.object(value))
    }
    record("loaded", ["rows": session.rows.count, "models": session.models.count, "flush": flush, "mode": mode])
    try await Task.sleep(for: .seconds(8))
    let heartbeat = Task { @MainActor in
        while !Task.isCancelled {
            let start = CFAbsoluteTimeGetCurrent()
            try? await Task.sleep(for: .milliseconds(10))
            let delay = (CFAbsoluteTimeGetCurrent() - start) * 1000 - 10
            record("heartbeat", ["late_ms": delay])
        }
    }
    if mode == "all" || mode.hasPrefix("idle") {
    record("idle_begin")
    for _ in 0..<100 {
        measure("idle_key") { input.composer.text += "a"; layout() }
        try await Task.sleep(for: .milliseconds(50))
    }
    record("idle_end")
    }
    if mode == "all" || mode == "stream" {
    send(.object(["type": .string("agent_start")]))
    send(.object(["type": .string("message_start"), "uiId": .string("profile-stream"), "message": .object(["role": .string("assistant"), "content": .array([])])]))
    record("stream_begin")
    for n in 0..<deltas {
        let delta = "A **bold** example with `code` and [link](https://example.com) for measured streaming. " + (n % 5 == 0 ? "\n\n" : "")
        let event = JSON.object(["type": .string("message_update"), "assistantMessageEvent": .object(["type": .string("text_delta"), "contentIndex": .number(0), "delta": .string(delta)])])
        measure("delta_receive") { send(event) }
        if n % 5 == 0 { measure("stream_key") { input.composer.text += "b"; layout() } }
        try await Task.sleep(for: .milliseconds(10))
    }
    record("stream_end", ["characters": session.partial?.message["content"].array.first?["text"].string.count ?? 0])
    send(.object(["type": .string("agent_end")]))
    try await Task.sleep(for: .seconds(2))
    }
    if mode == "all" || mode == "resize" {
    send(snapshot)
    try await Task.sleep(for: .seconds(1))
    record("resize_begin")
    for width in stride(from: 1100, through: 500, by: -30).map({ $0 }) + stride(from: 530, through: 1100, by: 30).map({ $0 }) {
        measure("resize") { window.setContentSize(NSSize(width: width, height: 800)); host.frame.size = NSSize(width: width, height: 800); layout() }
        try await Task.sleep(for: .milliseconds(100))
    }
    record("resize_end")
    }
    if mode == "pty" {
        var main: Int32 = -1, slave: Int32 = -1
        #expect(openpty(&main, &slave, nil, nil, nil) == 0)
        let master = FileHandle(fileDescriptor: main, closeOnDealloc: true), terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let live = Session { data in try master.write(contentsOf: data) }
        host.rootView = ProfileRoot(session: live, input: input)
        master.readabilityHandler = { handle in
            let received = Date().timeIntervalSince1970
            var readStart = timespec(), readEnd = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &readStart)
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &readEnd)
            let readCPU = (Double(readEnd.tv_sec - readStart.tv_sec) + Double(readEnd.tv_nsec - readStart.tv_nsec) / 1e9) * 1000
            Task { @MainActor in
                var start = timespec(), end = timespec()
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)
                let wall = Date().timeIntervalSince1970
                if data.isEmpty { live.disconnect() } else { live.receive(data) }
                clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
                logs.rows.append(["name": "pty_receive", "time": wall, "bytes": data.count, "read_cpu_ms": readCPU, "queue_ms": (wall - received) * 1000, "wall_ms": (Date().timeIntervalSince1970 - wall) * 1000, "cpu_ms": (Double(end.tv_sec - start.tv_sec) + Double(end.tv_nsec - start.tv_nsec) / 1e9) * 1000])
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root + "/share/pi/kido-pi.ts"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessInfo.processInfo.environment.filter { $0.key != "TMUX" && $0.key != "TMUX_PANE" && !$0.key.hasPrefix("KIDO_AGENT_") }
        env["KIDO_PI_RPC"] = "[\"node\",\"\(root)/build/pi-ui-profile/stress-fake.ts\"]"
        env["PI_PROFILE_DELTAS"] = String(deltas)
        process.environment = env
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        record("pty_begin")
        try process.run(); try terminal.close()
        try await Task.sleep(for: .milliseconds(deltas * 10 + 3000))
        try master.write(contentsOf: Data([4]))
        try await Task.sleep(for: .seconds(1))
        if process.isRunning { process.terminate() }
        master.readabilityHandler = nil; try master.close(); live.disconnect()
        record("pty_end")
    }
    heartbeat.cancel()
    try JSONSerialization.data(withJSONObject: logs.rows, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("metrics-\(mode)-\(flush ? "flush" : "natural").json"))
}
