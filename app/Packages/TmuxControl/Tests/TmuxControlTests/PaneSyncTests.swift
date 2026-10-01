import Foundation
import Testing
@testable import TmuxControl

@Test func paneSyncRestoresHistoryScreenModesAndPending() throws {
    let state = ["1", "0", "2", "1", "0", "2", "1", "1", "0", "0", "0", "bar", "Ext 2", "0,8", "7,25"].joined(separator: "\u{1F}")
    let replies: [Reply] = [
        .success(["1 0"]), .success(["old"]), .success(["-1 - old"]),
        .success(["screen"]), .success([]), .success(["\\033["]), .success([state]),
    ]
    guard case .snapshot(let data, let history) = try #require(PaneSync.restore(replies)) else {
        Issue.record("expected snapshot"); return
    }
    #expect(history == 1)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.hasPrefix("\u{1B}c\u{1B}[3J\u{1B}[mold\r\nscreen"))
    #expect(text.contains("\u{1B}=\u{1B}[4h\u{1B}[6 q\u{1B}[>4;2m"))
    #expect(text.hasSuffix("\u{1B}[2;3H\u{1B}["))
}

@Test func paneSyncRestoresAlternateAndSavedCursor() throws {
    let state = ["0", "1", "1", "0", "0", "1", "0", "0", "2", "1", "1", "block", "", "", "7"].joined(separator: "\u{1F}")
    let replies: [Reply] = [
        .success(["0 1"]), .success([]), .success([]),
        .success(["alternate"]), .success(["primary"]), .success([]), .success([state]),
    ]
    guard case .snapshot(let data, _) = try #require(PaneSync.restore(replies)) else {
        Issue.record("expected snapshot"); return
    }
    #expect(String(decoding: data, as: UTF8.self).hasPrefix("\u{1B}c\u{1B}[3Jprimary\u{1B}[m\u{1B}[2;3H\u{1B}[?1049halternate"))
}

@Test func paneSyncExpandsIncompleteLogicalLine() {
    let replies: [Reply] = [
        .success(["10000 0"]), .success(["partial"]), .success(["-5000 W partial"]),
        .success([]), .success([]), .success([]), .success(["state"]),
    ]
    guard case .expand(let history) = PaneSync.restore(replies) else { Issue.record("expected expansion"); return }
    #expect(history == 10000)
    #expect(PaneSync.restore([Reply.failure(["gone"])]) == nil)
}

@Test func historyMetadataRejectsMalformedState() {
    #expect(HistoryMetadata(.success(["123 1"]))?.history == 123)
    #expect(HistoryMetadata(.success(["123 1"]))?.alternate == true)
    #expect(HistoryMetadata(.success(["-1 0"])) == nil)
    #expect(HistoryMetadata(.success(["12 broken"])) == nil)
}
