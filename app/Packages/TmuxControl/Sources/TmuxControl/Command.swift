public struct Command: Equatable, Sendable {
    public let line: String

    public init(_ name: String, _ args: any CustomStringConvertible...) {
        self.init(words: [name] + args.map(\.description))
    }

    init(words: [String]) {
        line = words.map(quote).joined(separator: " ")
    }

    public static func sendKeys(_ pane: PaneID, _ bytes: some Collection<UInt8>, chunk: Int = 300) -> [Command] {
        let hex = bytes.map { String($0, radix: 16) }
        return stride(from: 0, to: hex.count, by: chunk).map {
            Command(words: ["send-keys", "-H", "-t", pane.description] + hex[$0..<min($0 + chunk, hex.count)])
        }
    }
}

private func quote(_ word: String) -> String {
    let safe = !word.isEmpty && word.utf8.allSatisfy {
        switch $0 {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default: "-_.,:/=+@%".utf8.contains($0)
        }
    }
    if safe { return word }
    var out = "\""
    for c in word.unicodeScalars {
        switch c {
        case "\\", "\"", "$", "~":
            out += "\\\(c)"
        case "\0"..<" ", "\u{7F}":
            let o = String(c.value, radix: 8)
            out += "\\" + String(repeating: "0", count: 3 - o.count) + o
        default:
            out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}
