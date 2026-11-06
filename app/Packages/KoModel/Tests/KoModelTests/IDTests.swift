import Foundation
import Testing
import KoModel

@Test func koIDsUseTheirPrefixAndKeepTheNumber() throws {
    #expect(PaneID(ko: "pane_12") == PaneID(number: 12))
    #expect(WindowID(ko: "window_3")?.description == "window_3")
    #expect(SessionID(ko: "session_0")?.number == 0)
    #expect(PaneID(ko: "%12") == nil && PaneID(ko: "window_12") == nil && PaneID(ko: "pane_x") == nil && PaneID(ko: "pane_") == nil)
    let coded = try JSONEncoder().encode([PaneID(number: 7)])
    #expect(String(decoding: coded, as: UTF8.self) == #"["pane_7"]"#)
    #expect(try JSONDecoder().decode([PaneID].self, from: coded) == [PaneID(number: 7)])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([PaneID].self, from: Data(#"["%7"]"#.utf8)) }
}

@Test func aRuntimeMarkKeepsTheConfiguredColourAndNamesItsStateAndItsFailureOnOneLine() {
    let configured = KoSchema.ClientRuntime(color: "#d08a2a", kind: .ssh, name: "gpu-1", source: .config, state: .failed(.init(message: "ssh: refused\nport 22")))
    let hashed = KoSchema.ClientRuntime(kind: .command, name: "e2e", source: .config, state: .starting)
    #expect(RuntimeMark(configured).color == "#d08a2a" && RuntimeMark(hashed).color == nil)
    #expect(RuntimeMark(configured).failure == "ssh: refused port 22" && RuntimeMark(hashed).failure == nil)
    #expect([RuntimeMark(configured), RuntimeMark(hashed)].map(\.stateWord) == ["failed", "starting"])
    #expect(RuntimeMark(hashed, routed: true).routed)
}
