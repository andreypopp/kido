import Testing
@testable import TmuxControl

@Test func quoting() {
    #expect(Command("rename-window", "-t", WindowID(number: 1), "a b").line == #"rename-window -t @1 "a b""#)
    #expect(Command("display-message", "-p", "#{pane_id}").line == ##"display-message -p "#{pane_id}""##)
    #expect(Command("x", "", ";", "~/$HOME", #"a"\b"#, "l1\nl2\u{7f}", "é'✓").line
        == #"x "" ";" "\~/\$HOME" "a\"\\b" "l1\012l2\177" "é'✓""#)
    #expect(Command("refresh-client", "-A", "%0:continue", "-t", PaneID(number: 12)).line
        == #"refresh-client -A "%0:continue" -t %12"#)
}

@Test func sendKeysChunks() {
    let commands = Command.sendKeys(PaneID(number: 3), Array(repeating: 0x0d, count: 301) , chunk: 300)
    #expect(commands.count == 2)
    #expect(commands[0].line.hasPrefix("send-keys -H -t %3 d d "))
    #expect(commands[1].line == "send-keys -H -t %3 d")
    #expect(Command.sendKeys(PaneID(number: 3), [UInt8]()).isEmpty)
}
