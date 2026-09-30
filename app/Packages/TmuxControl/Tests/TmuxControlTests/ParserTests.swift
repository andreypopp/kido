import Foundation
import Testing
@testable import TmuxControl

func fixture(_ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return Array(try Data(contentsOf: url))
}

func parse(_ bytes: [UInt8], chunk: Int = 4096) -> [Event] {
    var parser = Parser()
    var events: [Event] = []
    for start in stride(from: 0, to: bytes.count, by: chunk) {
        parser.feed(bytes[start..<min(start + chunk, bytes.count)]) { events.append($0) }
    }
    return events
}

func notOutput(_ e: Event) -> Bool {
    switch e {
    case .output, .extendedOutput, .layoutChange: false
    default: true
    }
}

func output(_ events: [Event], _ pane: PaneID) -> String {
    let bytes = events.flatMap { e -> [UInt8] in
        switch e {
        case .output(pane, let b), .extendedOutput(pane, _, let b): b
        default: []
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

let p0 = PaneID(number: 0), p1 = PaneID(number: 1)
let w0 = WindowID(number: 0), w1 = WindowID(number: 1), w2 = WindowID(number: 2)
let s0 = SessionID(number: 0), s1 = SessionID(number: 1)

@Test func octal() {
    let decoded = decodeOctal(ArraySlice(#"a\015\012\134\033[1m ✓ \9 \01"#.utf8))
    #expect(decoded == Array("a\r\n\\\u{1b}[1m ✓ \\9 \\01".utf8))
}

@Test func ids() {
    #expect(PaneID("%12") == PaneID(number: 12))
    #expect(PaneID("@12") == nil)
    #expect(SessionID("$3")?.description == "$3")
    #expect(WindowID("@") == nil)
}

@Test func basicTranscript() throws {
    let bytes = try fixture("basic")
    let events = parse(bytes)
    #expect(events.filter(notOutput) == [
        .block(.success([]), .other),
        .sessionChanged(s0, "t"),
        .block(.success(["client-42636"]), .control),
        .block(.success([]), .control),
        .windowPaneChanged(w0, p1),
        .windowRenamed(w0, .linked, "zsh"),
        .block(.success([]), .control),
        .sessionWindowChanged(s0, w1),
        .windowAdd(w1, .linked),
        .block(.success([]), .control),
        .windowRenamed(w1, .linked, "renamed"),
        .block(.success([]), .control),
        .block(.success(["$ echo '✓\\'", "✓\\", "$"] + Array(repeating: "", count: 21)), .control),
        .block(.success(["%0 2,2", "%1 2,1"]), .control),
        .block(.failure(["parse error: unknown command: bogus-command"]), .control),
        .block(.success([]), .control),
        .sessionWindowChanged(s0, w0),
        .block(.success([]), .control),
        .windowAdd(w2, .unlinked),
        .sessionsChanged,
        .windowRenamed(w2, .unlinked, "kido-tmux"),
        .block(.success([]), .control),
        .sessionChanged(s1, "other"),
        .block(.success([]), .control),
        .windowClose(w1, .unlinked),
        .windowRenamed(w2, .linked, "zsh"),
        .block(.success([]), .control),
        .exit(.ended(nil)),
    ])
    #expect(output(events, p0).contains("echo '✓\\'\r\n\u{1b}[?2004l\r✓\\\r\n"))
    #expect(parse(bytes, chunk: 1) == events)
    #expect(parse(bytes, chunk: 7) == events)
}

@Test func splitLayout() throws {
    let layouts = parse(try fixture("basic")).compactMap { e -> Layout? in
        if case .layoutChange(w0, let layout, let visible, "*") = e, layout == visible { layout } else { nil }
    }
    #expect(layouts == [Layout(root: .split(.leftRight, Geometry(x: 0, y: 0, width: 80, height: 24), [
        .pane(Pane(id: p0, index: 0, geometry: Geometry(x: 0, y: 0, width: 40, height: 24), focus: .visited(0), layer: .tiled)),
        .pane(Pane(id: p1, index: 1, geometry: Geometry(x: 41, y: 0, width: 39, height: 24), focus: .active, layer: .tiled)),
    ]))])
}

@Test func floatingAndZoom() throws {
    let changes = parse(try fixture("floating")).compactMap { e -> (Layout, Layout, String)? in
        if case .layoutChange(w0, let l, let v, let f) = e { (l, v, f) } else { nil }
    }
    try #require(changes.count == 3)
    guard case .split(.topBottom, _, let children) = changes[1].0.root else { Issue.record("not a split"); return }
    #expect(children[1] == .pane(Pane(
        id: PaneID(number: 2), index: 2, geometry: Geometry(x: 6, y: 4, width: 28, height: 8),
        focus: .active, layer: .floating(z: 0))))
    #expect(changes[2].2 == "*Z")
    #expect(changes[2].1 == Layout(root: .pane(Pane(
        id: p0, index: 0, geometry: Geometry(x: 0, y: 0, width: 80, height: 24), focus: .active, layer: .tiled))))
    #expect(throws: DecodingError.self) { try Layout(json: #"{"V":1,"L":{}}"#) }
    #expect(changes[1].0.root.panes.map(\.id) == [p0, PaneID(number: 2), p1])
    #expect(changes[1].0.root.dividers.map(\.geometry) == [Geometry(x: 0, y: 12, width: 80, height: 1)])
    #expect(changes[2].1.root.dividers == [])
}

@Test func pauseAndContinue() throws {
    let events = parse(try fixture("pause"))
    #expect(events.filter(notOutput) == [
        .block(.success([]), .other),
        .sessionChanged(s0, "t"),
        .block(.success([]), .control),
        .pause(p0),
        .block(.success([]), .control),
        .continue(p0),
        .block(.success([]), .control),
        .block(.success([]), .control),
        .exit(.ended(nil)),
    ])
    let text = output(events, p0)
    #expect(text.hasPrefix("yes | head -c 200000\r\n\u{1b}[?2004l\ry\r\ny\r\n"))
    #expect(text.hasSuffix("echo hi\r\n\u{1b}[?2004l\rhi\r\n\u{1b}]0;/tmp/tc-rec\u{07}\u{1b}[?2004h$ "))
}

@Test func lostServer() throws {
    #expect(parse(try fixture("lost")).last == .exit(.ended("server exited unexpectedly")))
}

@Test func exitReasons() {
    #expect(parse(Array("%exit\n%exit detached (from session a b)\n%exit detached and SIGHUP (from session 0)\n%exit too far behind\n".utf8)) == [
        .exit(.ended(nil)), .exit(.detached("detached (from session a b)")),
        .exit(.detached("detached and SIGHUP (from session 0)")), .exit(.ended("too far behind")),
    ])
}

@Test func attachFailure() throws {
    #expect(parse(try fixture("attach-fail")) == [
        .block(.failure(["can't find session: nope"]), .other), .exit(.ended(nil)),
    ])
}

@Test func malformed() {
    #expect(parse(Array("%output 0 x\n%extended-output %1 2 x\n%layout-change @1 x y *\n%pane-mode-changed %1\n%window-add\n".utf8)) == [
        .unrecognized("%output 0 x"), .unrecognized("%extended-output %1 2 x"),
        .unrecognized("%layout-change @1 x y *"), .unrecognized("%pane-mode-changed %1"), .unrecognized("%window-add"),
    ])
    #expect(parse(Array("%extended-output %1 20 future : a : b\n%client-session-changed client-9 $2 a b\n".utf8)) == [
        .extendedOutput(p1, age: 20, Array("a : b".utf8)), .clientSessionChanged(client: "client-9", SessionID(number: 2), "a b"),
    ])
}
