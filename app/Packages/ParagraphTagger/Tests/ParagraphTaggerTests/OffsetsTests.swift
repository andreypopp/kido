import Testing
@testable import ParagraphTagger

struct OffsetCase {
    let name: String
    let text: String
    let lengths: [Int]
    let offsets: [(Int, Int)]
}

let phase0: [OffsetCase] = [
    OffsetCase(name: "box-drawing", text: "┌─────┬─────┐\n│ a   │ b   │\n└─────┴─────┘",
               lengths: [2, 1, 12, 3, 2, 1, 12, 3, 2, 1, 1, 2, 1, 2, 3, 2, 1, 2, 3, 2, 1, 1, 2, 1, 12, 3, 2, 1, 12, 3, 2, 1],
               offsets: [[0, 3], [0, 3], [3, 15], [15, 18], [18, 21], [18, 21], [21, 33], [33, 36], [36, 39], [36, 39], [39, 40], [40, 43], [40, 43], [43, 45], [45, 48], [48, 51], [48, 51], [51, 53], [53, 56], [56, 59], [56, 59], [59, 60], [60, 63], [60, 63], [63, 75], [75, 78], [78, 81], [78, 81], [81, 93], [93, 96], [96, 99], [96, 99]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "emoji-zwj", text: "family 👨‍👩‍👧‍👦 and flag 🇵🇱 and skin 👍🏽",
               lengths: [6, 3, 1, 1, 2, 1, 2, 1, 1, 2, 1, 2, 1, 1, 2, 1, 2, 1, 1, 4, 5, 3, 1, 1, 2, 1, 1, 4, 5, 3, 1, 1, 2, 1, 1],
               offsets: [[0, 6], [6, 11], [7, 11], [7, 11], [11, 14], [11, 14], [14, 18], [14, 18], [14, 18], [18, 21], [18, 21], [21, 25], [21, 25], [21, 25], [25, 28], [25, 28], [28, 32], [28, 32], [28, 32], [32, 36], [36, 41], [41, 46], [42, 46], [42, 46], [46, 50], [46, 50], [46, 50], [50, 54], [54, 59], [59, 64], [60, 64], [60, 64], [64, 68], [64, 68], [64, 68]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "cjk", text: "日本語のテキストと中文混合",
               lengths: [6, 2, 1, 3, 3, 3, 6, 3, 3, 3, 2, 1, 3],
               offsets: [[0, 6], [6, 9], [6, 9], [9, 12], [12, 15], [15, 18], [18, 24], [24, 27], [27, 30], [30, 33], [33, 36], [33, 36], [36, 39]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "combining", text: "e\u{301} cafe\u{301} n\u{303}",
               lengths: [2, 6, 2, 1],
               offsets: [[0, 3], [3, 10], [10, 14], [11, 14]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "combining-option", text: "e\u{301} cafe\u{301}\n1. option",
               lengths: [2, 6, 1, 1, 1, 7],
               offsets: [[0, 3], [3, 10], [10, 11], [11, 12], [12, 13], [13, 20]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "tabs", text: "a\tb\t\tc",
               lengths: [1, 1, 1, 1, 1, 1],
               offsets: [[0, 1], [1, 2], [2, 3], [3, 4], [4, 5], [5, 6]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "crlf", text: "first\r\nsecond\r\n",
               lengths: [5, 1, 1, 6, 2],
               offsets: [[0, 5], [5, 6], [6, 7], [7, 13], [13, 15]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "bold-markers", text: "**alpha** and **beta** with `code`",
               lengths: [2, 5, 2, 4, 3, 4, 2, 5, 2, 4, 1],
               offsets: [[0, 2], [2, 7], [7, 9], [9, 13], [13, 16], [16, 20], [20, 22], [22, 27], [27, 29], [29, 33], [33, 34]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "code", text: "func main() {\n    print(\"héllo\")\n}",
               lengths: [4, 5, 2, 2, 1, 4, 5, 2, 1, 2, 3, 2, 1, 1],
               offsets: [[0, 4], [4, 9], [9, 11], [11, 13], [13, 14], [14, 18], [18, 23], [23, 25], [25, 26], [26, 28], [28, 31], [31, 33], [33, 34], [34, 35]].map { ($0[0], $0[1]) }),
    OffsetCase(name: "markers", text: "> 12: 1. **Red**\n  13: - blue",
               lengths: [1, 3, 1, 2, 1, 3, 3, 2, 1, 2, 2, 1, 2, 5],
               offsets: [[0, 1], [1, 4], [4, 5], [5, 7], [7, 8], [8, 11], [11, 14], [14, 16], [16, 17], [17, 19], [19, 21], [21, 22], [22, 24], [24, 29]].map { ($0[0], $0[1]) }),
]

@Test(arguments: phase0.indices)
func phase0Offsets(_ index: Int) {
    let value = phase0[index]
    let map = NFCMap(value.text)
    var position = 0
    var actual: [(Int, Int)] = []
    for length in value.lengths {
        actual.append((map.start(position), map.end(position + length)))
        position += length
    }
    #expect(actual.map { $0.0 } == value.offsets.map { $0.0 }, "\(value.name) starts")
    #expect(actual.map { $0.1 } == value.offsets.map { $0.1 }, "\(value.name) ends")
}
