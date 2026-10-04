import Foundation
import Testing
@testable import PiSurface

@Test func goldenFrames() throws {
    struct Vectors: Decodable { var cases: [Vector] }
    struct Vector: Decodable { var direction: String; var json: String; var frames: [String] }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
    var sent: [Data] = []
    let session = Session(client: "test") { sent.append($0) }
    var sequence = 1
    func receive(_ json: String) {
        for frame in Codec.encode(json, number: sequence) { session.receive(frame); sequence += 1 }
    }
    receive(#"{"type":"hello","instance":"one"}"#)
    await Task.yield()
    #expect(sent.count == 1)
    receive(#"{"type":"ack","client":"test","msg":1,"index":0}"#)
    receive(#"{"type":"snapshot","hello":{"instance":"one"},"record":{"entries":[{"id":"u","message":{"role":"user","content":"hello"}}],"state":{"isStreaming":false},"partial":null}}"#)
    receive(#"{"type":"message_start","message":{"role":"assistant","content":[]}}"#)
    receive(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hi"}}"#)
    #expect(session.partial["content"].array[0]["text"].string == "Hi")
    receive(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hi!"}]}}"#)
    #expect(session.rows.count == 2)
    #expect(session.rows[0].message["content"].string == "hello")
    #expect(session.rows[1].message["content"].array[0]["text"].string == "Hi!")
    session.command("prompt", fields: ["message": .string(String(repeating: "x", count: 1000))])
    await Task.yield()
    #expect(sent.count == 2)
    session.command("abort")
    await Task.yield()
    #expect(sent.count == 2)
    receive(#"{"type":"ack","client":"wrong","msg":2,"index":0}"#)
    await Task.yield()
    #expect(sent.count == 2)
    receive(#"{"type":"ack","client":"test","msg":2,"index":0}"#)
    await Task.yield()
    #expect(sent.count == 3)
}
