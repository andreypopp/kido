import Testing
@testable import TmuxControl

@Test func osc52OutputRemainsRawAtEveryTranscriptSplit() {
    let transcript = Array((#"%output %0 \033]52;c;4pyT\007"# + "\n" + #"%extended-output %0 0 : \033]52;p;?\033\134"# + "\n").utf8)
    let expected: [Event] = [
        .output(p0, Array("\u{1b}]52;c;4pyT\u{7}".utf8)),
        .extendedOutput(p0, age: 0, Array("\u{1b}]52;p;?\u{1b}\\".utf8)),
    ]
    #expect(parse(transcript) == expected)
    for split in 0...transcript.count {
        var parser = Parser()
        var events: [Event] = []
        parser.feed(transcript[..<split]) { events.append($0) }
        parser.feed(transcript[split...]) { events.append($0) }
        #expect(events == expected)
    }
}
