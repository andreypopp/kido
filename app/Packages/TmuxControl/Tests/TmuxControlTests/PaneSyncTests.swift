import Foundation
import Testing
@testable import TmuxControl

private func restore(_ replies: [Reply]) -> PaneSync.Snapshot? {
    guard let state = HistoryMetadata(replies.first),
          let history = HistoryCapture(replies.prefix(3), rows: state.history, initial: true) else { return nil }
    return PaneSync.restore(replies, history: history)
}

@Test func paneSyncRestoresHistoryScreenModesAndPending() throws {
    let state = ["1", "0", "2", "1", "0", "2", "1", "1", "0", "0", "0", "bar", "Ext 2", "0,8", "7,25"].joined(separator: "\u{1F}")
    let replies: [Reply] = [
        .success(["1 0"]), .success(["old"]), .success(["-1 - old"]),
        .success(["screen"]), .success([]), .success(["\\033["]), .success([state]), .success(["0 - screen"]),
    ]
    let snapshot = try #require(restore(replies))
    let (data, history) = (snapshot.data, snapshot.history)
    #expect(history == 1)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.hasPrefix("\u{1B}c\u{1B}[3Joldscreen"))
    #expect(text.contains("\u{1B}=\u{1B}[4h\u{1B}[6 q\u{1B}[>4;2m"))
    #expect(text.hasSuffix("\u{1B}[2;3H\u{1B}["))
}

@Test func paneSyncRestoresAlternateAndSavedCursor() throws {
    let state = ["1", "1", "1", "0", "0", "1", "0", "0", "2", "1", "1", "block", "", "", "7"].joined(separator: "\u{1F}")
    let replies: [Reply] = [
        .success(["1 1"]), .success(["ignored separate history"]), .success(["-1 - ignored"]),
        .success(["alternate"]), .success(["primary"]), .success([]), .success([state]), .success(["0 - alternate"]),
    ]
    let data = try #require(restore(replies)).data
    #expect(String(decoding: data, as: UTF8.self).hasPrefix("\u{1B}c\u{1B}[3Jprimary\u{1B}[2;3H\u{1B}[?1049halternate"))
    #expect(PaneSync.commands(PaneID(number: 0), chunk: 5).contains(Command("capture-pane", "-p", "-r", "-G", "-a", "-q", "-S", "-5", "-t", PaneID(number: 0))))
}

@Test func paneSyncAnchorJoinsHistoryScreenAndPreservesSpaces() throws {
    let state = ["2", "0", "0", "0", "0", "1", "0", "0", "0", "0", "0", "block", "", "", "7"].joined(separator: "\u{1F}")
    let replies: [Reply] = [
        .success(["2 0"]), .success(["old", "wrapped  "]), .success(["-2 - old", "-1 W wrapped  "]),
        .success(["tail", "prompt"]), .success([]), .success([]), .success([state]),
        .success(["0 - tail", "1 - prompt", "2 - "]),
    ]
    let rows = try #require(restore(replies)).anchorRows
    #expect(ScrollAnchor(lines: 2, text: "wrapped  tail").locate(rows) == 1)
}

@Test func paneSyncKeepsInlinePlacementsInByteOrder() throws {
    let placement = "\u{1B}_Ga=p,i=7,p=3,c=8,r=4,C=1,q=2\u{1B}\\"
    let state = ["1", "0", "0", "0", "0", "1", "0", "0", "0", "0", "0", "block", "", "", "7"].joined(separator: "\u{1F}")
    let replies: [Reply] = [
        .success(["1 0"]), .success(["before" + placement + "after"]), .success(["-1 - beforeafter"]),
        .success(["left" + placement + "right"]), .success([]), .success([]), .success([state]), .success(["0 - leftright"]),
    ]
    let snapshot = try #require(restore(replies))
    #expect(String(decoding: snapshot.data, as: UTF8.self).hasPrefix(
        "\u{1B}c\u{1B}[3Jbefore" + placement + "afterleft" + placement + "right"))
}

@Test func historyMetadataRejectsMalformedState() {
    #expect(HistoryMetadata(.success(["123 1"]))?.history == 123)
    #expect(HistoryMetadata(.success(["123 1"]))?.alternate == true)
    #expect(HistoryMetadata(.success(["-1 0"])) == nil)
    #expect(HistoryMetadata(.success(["12 broken"])) == nil)
}
