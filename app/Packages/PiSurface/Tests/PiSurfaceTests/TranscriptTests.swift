import Foundation
import Testing
@testable import PiSurface

@Test func projectionPreservesBlocksAndJoinsResults() throws {
    let call = try JSONDecoder().decode(JSON.self, from: Data(#"{"role":"assistant","content":[{"type":"thinking","thinking":"Check first"},{"type":"text","text":"Hello"},{"type":"toolCall","id":"one","name":"bash","arguments":{"command":"ls"}}]}"#.utf8))
    let result = try JSONDecoder().decode(JSON.self, from: Data(#"{"role":"toolResult","toolCallId":"one","toolName":"bash","isError":true,"content":[{"type":"text","text":"line one\n\nline two"}]}"#.utf8))
    let orphan = project([Row(id: "result", message: result)], scope: "generation")
    #expect(orphan.count == 1)
    let joined = project([Row(id: "call", message: call), Row(id: "result", message: result)], scope: "generation")
    #expect(joined.count == 3)
    #expect(joined.last?.id == orphan.first?.id)
    if case .tool(let arguments, let output, _) = joined.last?.content {
        #expect(arguments["arguments"]["command"].string == "ls")
        #expect(output["isError"] == .bool(true))
        #expect(output["content"].array[0]["text"].string == "line one\n\nline two")
    } else { Issue.record("Missing joined tool") }
    #expect(project([Row(id: "call", message: call)], scope: "other")[0].id != joined[0].id)
}

@MainActor @Test func executionEndAndCommandResponses() throws {
    let session = Session(client: "test") { _ in }
    var sequence = 1
    func event(_ text: String) {
        for frame in Codec.encode(text, number: sequence) { session.receive(frame); sequence += 1 }
    }
    event(#"{"type":"snapshot","hello":{"instance":"instance"},"generation":1,"record":{"entries":[],"state":{}}}"#)
    event(#"{"type":"message_start","uiId":"live-1","message":{"role":"assistant","content":[]}}"#)
    event(#"{"type":"message_end","uiId":"live-1","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]}}"#)
    #expect(session.rows.first?.id == "live-1")
    event(#"{"type":"tool_execution_start","toolCallId":"one","toolName":"bash","args":{"command":"ls"}}"#)
    event(#"{"type":"tool_execution_update","toolCallId":"one","partialResult":{"content":[{"type":"text","text":"partial"}]}}"#)
    event(#"{"type":"tool_execution_end","toolCallId":"one","result":{"content":[{"type":"text","text":"final"}]},"isError":true}"#)
    #expect(session.tools.count == 1)
    #expect(session.tools["one"]?["ended"] == .bool(true))
    #expect(session.tools["one"]?["result"]["content"].array[0]["text"].string == "final")
    #expect(session.tools["one"]?["args"]["command"].string == "ls")
    session.command("prompt", fields: ["message": .string("draft")])
    event(#"{"type":"response","id":"test:1","command":"prompt","success":false,"error":"Rejected"}"#)
    #expect(session.acceptedPrompt == .null)
    #expect(session.error == "Rejected")
    session.command("clear_queue")
    event(#"{"type":"response","id":"test:2","command":"clear_queue","success":true,"data":{"steering":["new steer"],"followUp":["new follow-up"]}}"#)
    #expect(session.restoredQueue["text"].string == "new steer\n\nnew follow-up")
    #expect(session.requests.values.contains("abort"))
    session.command("history", fields: ["before": .string("old"), "generation": .number(1)])
    event(#"{"type":"history","id":"wrong","generation":1,"entries":[],"before":null}"#)
    #expect(session.historyLoading)
    event(#"{"type":"history","id":"test:4","generation":1,"entries":[],"before":null}"#)
    #expect(!session.historyLoading)
    session.disconnect()
}
