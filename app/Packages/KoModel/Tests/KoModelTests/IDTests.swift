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
