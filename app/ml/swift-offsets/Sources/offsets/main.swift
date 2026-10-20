import Foundation
import Tokenizers

struct Case: Codable {
    let name: String
    let text: String
    let ids: [Int]
    let offsets: [[Int]]
}

struct Input: Codable {
    let cases: [Case]
}

struct Mismatch: Codable {
    let name: String
    let token: Int
    let expected: [Int]
    let actual: [Int]
}

struct Output: Codable {
    let cases: Int
    let tokens: Int
    let matching: Int
    let ids_matching: Int
    let mismatches: [Mismatch]
}

func bytesToUnicode() -> [UInt8: Character] {
    var bytes = Array(33...126) + Array(161...172) + Array(174...255)
    var characters = bytes.map { Character(UnicodeScalar($0)!) }
    var extra = 0
    for byte in 0...255 where !bytes.contains(byte) {
        bytes.append(byte)
        characters.append(Character(UnicodeScalar(256 + extra)!))
        extra += 1
    }
    var table: [UInt8: Character] = [:]
    for (byte, character) in zip(bytes, characters) {
        table[UInt8(byte)] = character
    }
    return table
}

let reverse = Dictionary(uniqueKeysWithValues: bytesToUnicode().map { ($1, $0) })

func tokenBytes(_ token: String) -> [UInt8] {
    var output: [UInt8] = []
    for character in token {
        if let byte = reverse[character] {
            output.append(byte)
        } else {
            output.append(contentsOf: String(character).utf8)
        }
    }
    return output
}

let arguments = CommandLine.arguments
let input = try JSONDecoder().decode(
    Input.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let tokenizer = try await AutoTokenizer.from(
    modelFolder: URL(fileURLWithPath: arguments[2]))
var totalTokens = 0
var matching = 0
var idsMatching = 0
var mismatches: [Mismatch] = []
for testCase in input.cases {
    let originalScalars = Array(testCase.text.unicodeScalars)
    let normalized = testCase.text.precomposedStringWithCanonicalMapping
    let normalizedScalars = Array(normalized.unicodeScalars)
    var originalBoundaries = [0]
    for scalar in originalScalars {
        originalBoundaries.append(originalBoundaries.last! + String(scalar).utf8.count)
    }
    var normalizedBoundaries = [0]
    for scalar in normalizedScalars {
        normalizedBoundaries.append(normalizedBoundaries.last! + String(scalar).utf8.count)
    }
    var originalPrefixNFC: [String] = []
    for index in 0...originalScalars.count {
        originalPrefixNFC.append(
            String(String.UnicodeScalarView(originalScalars[0..<index]))
                .precomposedStringWithCanonicalMapping)
    }
    var mapping = [Int](repeating: 0, count: normalizedScalars.count + 1)
    var previous = 0
    for index in 0...normalizedScalars.count {
        let prefix = String(String.UnicodeScalarView(normalizedScalars[0..<index]))
        var found = false
        for candidate in previous...originalScalars.count {
            if originalPrefixNFC[candidate] == prefix {
                mapping[index] = originalBoundaries[candidate]
                previous = candidate
                found = true
                break
            }
        }
        if !found {
            mapping[index] = originalBoundaries[originalScalars.count]
        }
    }
    func boundary(_ value: Int, upward: Bool) -> Int {
        if upward {
            return normalizedBoundaries.first(where: { $0 >= value }) ?? normalizedBoundaries.last!
        }
        return normalizedBoundaries.last(where: { $0 <= value }) ?? 0
    }
    func mapStart(_ value: Int) -> Int {
        let index = normalizedBoundaries.firstIndex(of: boundary(value, upward: false)) ?? 0
        return mapping[index]
    }
    func mapEnd(_ value: Int) -> Int {
        let index = normalizedBoundaries.firstIndex(of: boundary(value, upward: true))
            ?? normalizedBoundaries.count - 1
        return mapping[index]
    }
    let ids = tokenizer.encode(text: testCase.text, addSpecialTokens: false)
    if ids == testCase.ids { idsMatching += 1 }
    var position = 0
    for (index, id) in ids.enumerated() {
        let token = tokenizer.convertIdToToken(id) ?? ""
        let length = tokenBytes(token).count
        let actual = [mapStart(position), mapEnd(position + length)]
        let expected = index < testCase.offsets.count ? testCase.offsets[index] : [-1, -1]
        totalTokens += 1
        if actual == expected {
            matching += 1
        } else if mismatches.count < 20 {
            mismatches.append(
                Mismatch(name: testCase.name, token: index, expected: expected, actual: actual))
        }
        position += length
    }
}
let output = Output(
    cases: input.cases.count, tokens: totalTokens, matching: matching,
    ids_matching: idsMatching, mismatches: mismatches)
let data = try JSONEncoder().encode(output)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
