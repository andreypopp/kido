import Foundation
import Testing
@testable import PiSurface

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func goldenFrames() throws {
    struct Vectors: Decodable { var cases: [Vector] }
    struct Vector: Decodable { var direction: String; var json: String; var frames: [String] }
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: repo.appendingPathComponent("share/pi/testdata/kido-pi-frames.json")))
    for vector in vectors.cases {
        let header = vector.frames[0].components(separatedBy: ";")[1].components(separatedBy: ",")
        let frames = Codec.encode(vector.json, client: vector.direction == "in" ? header[0] : nil, number: Int(header[vector.direction == "in" ? 1 : 0])!)
        #expect(frames == vector.frames.map { Data($0.utf8) })
        for fragmented in [false, true] {
            var codec = Codec(), decoded = Data()
            let wire = Data(("plain" + vector.frames.joined() + "trailer").utf8)
            for bytes in fragmented ? wire.map({ Data([$0]) }) : [wire] { for frame in codec.receive(bytes) { decoded.append(frame.bytes) } }
            #expect(try JSONDecoder().decode(JSON.self, from: decoded) == JSONDecoder().decode(JSON.self, from: Data(vector.json.utf8)))
        }
    }
}

@MainActor @Test func snapshotEventsAndCredits() async throws {
    let fixture = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: repo.appendingPathComponent("share/pi/testdata/kido-pi-snapshot.json")))
    var sent: [Data] = []
    let session = Session(client: "test") { sent.append($0) }
    var sequence = 1
    func receive(_ value: JSON) {
        for frame in Codec.encode(value.text, number: sequence) { session.receive(frame); sequence += 1 }
    }
    func event(_ text: String) throws { receive(try JSONDecoder().decode(JSON.self, from: Data(text.utf8))) }
    receive(fixture["completed"]["hello"])
    await Task.yield()
    #expect(sent.count == 1)
    try await Task.sleep(for: .milliseconds(650))
    #expect(sent.count == 2)
    #expect(sent[0] == sent[1])
    try event(#"{"type":"ack","client":"test","msg":1,"index":0}"#)
    receive(fixture["completed"])
    #expect(session.rows.count == 18)
    #expect(session.models.count == 1)
    #expect(session.thinkingLevels == ["off", "low", "medium", "high"])
    #expect(session.title == "Fake pi")
    receive(fixture["streaming"])
    #expect(session.rows.isEmpty)
    #expect(session.partial?.message["content"].array[1]["text"].string == "Hello! I’ll inspect the project.")
    #expect(session.tools.keys.sorted() == ["bash-1", "edit-1"])
    #expect(session.tools["bash-1"]!["partialResult"]["content"].array[0]["text"].string == "README.md\nhello.ts\n")
    #expect(session.dialogs.first?["method"].string == "confirm")
    try event(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":" More"}}"#)
    #expect(session.partial?.message["content"].array[1]["text"].string.hasSuffix(" More") == true)
    try event(#"{"type":"tool_execution_update","toolCallId":"bash-1","partialResult":{"content":[{"type":"text","text":"new"}]}}"#)
    #expect(session.tools["bash-1"]?["toolName"].string == "bash")
    #expect(session.tools["bash-1"]?["partialResult"]["content"].array[0]["text"].string == "new")
    try event(#"{"type":"dialog_closed","generation":1,"id":"fixture-confirm"}"#)
    #expect(session.dialogs.isEmpty)
    var reset = fixture["reset"].object; reset["generation"] = .number(2)
    receive(.object(reset))
    #expect(session.generation == .number(2))
    #expect(session.partial == nil && session.tools.isEmpty && session.dialogs.isEmpty)
    #expect(session.status.orderedValues.isEmpty && session.notifications.isEmpty)
    session.command("prompt", fields: ["message": .string(String(repeating: "x", count: 1000))])
    await Task.yield()
    let count = sent.count
    session.command("abort")
    await Task.yield()
    #expect(sent.count == count)
    try event(#"{"type":"ack","client":"wrong","msg":2,"index":0}"#)
    await Task.yield()
    #expect(sent.count == count)
    try event(#"{"type":"ack","client":"test","msg":2,"index":0}"#)
    await Task.yield()
    #expect(sent.count == count + 1)
    session.disconnect()
    try event(#"{"type":"hello","instance":"new"}"#)
    await Task.yield()
    #expect(sent.count == count + 2)
    session.disconnect()
}

@MainActor @Test func realSessionCapture() throws {
    let path = repo.appendingPathComponent("build/pi-real-capture.wire")
    guard FileManager.default.fileExists(atPath: path.path) else { return }
    let session = Session { _ in }
    let bytes = try Data(contentsOf: path)
    var codec = Codec(), assembly = Data(), sequence = 1
    for frame in codec.receive(bytes) {
        assembly.append(frame.bytes)
        guard frame.header.last == "1" else { continue }
        var value = try JSONDecoder().decode(JSON.self, from: assembly).object
        assembly.removeAll()
        if value["type"] == .string("history") {
            session.command("history", fields: ["generation": session.generation, "before": session.historyBefore, "limit": .number(200)])
            value["id"] = .string(try #require(session.requests.first { $0.value == "history" }?.key))
        }
        for wire in Codec.encode(JSON.object(value).text, number: sequence) { session.receive(wire); sequence += 1 }
    }
    let report = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: repo.appendingPathComponent("build/pi-real-report.json")))
    guard case .number(let count) = report["rows"] else { Issue.record("Missing real-session row count"); return }
    #expect(session.rows.count == Int(count))
    #expect(Set(session.rows.map(\.id)).count == session.rows.count)
    #expect(session.historyBefore == .null)
    print("Real capture decoded: \(session.rows.count) rows, \(bytes.count) wire bytes")
}
