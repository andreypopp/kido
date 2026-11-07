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
    #expect(RuntimeMark.known(configured, routed: false).color == "#d08a2a" && RuntimeMark.known(hashed, routed: false).color == nil)
    #expect(RuntimeMark.known(configured, routed: false).failure == "ssh: refused port 22" && RuntimeMark.known(hashed, routed: false).failure == nil)
    #expect([RuntimeMark.known(configured, routed: false), RuntimeMark.known(hashed, routed: false)].map(\.stateWord) == ["failed", "starting"])
    #expect(RuntimeMark.known(hashed, routed: true).routed)
    let missing = RuntimeMark.unavailable(.init(name: "missing", source: .config), routed: true)
    #expect(missing.name == "missing" && missing.key.source == .config && missing.routed)
    #expect(missing.kind == nil && missing.color == nil && missing.failure == nil)
    #expect(missing.state == .down && missing.stateWord == "down")
}
