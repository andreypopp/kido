import Foundation

struct NFCMap {
    private let identity: Bool
    private let originalBoundaries: [Int]
    private let normalizedBoundaries: [Int]
    private let normalizedToOriginal: [Int]

    init(_ text: String) {
        let originalScalars = Array(text.unicodeScalars)
        let normalized = text.precomposedStringWithCanonicalMapping
        identity = Array(normalized.utf8) == Array(text.utf8)
        var originalBoundaries = [0]
        for scalar in originalScalars {
            originalBoundaries.append(originalBoundaries[originalBoundaries.count - 1] + String(scalar).utf8.count)
        }
        self.originalBoundaries = originalBoundaries
        let normalizedScalars = Array(normalized.unicodeScalars)
        var normalizedBoundaries = [0]
        for scalar in normalizedScalars {
            normalizedBoundaries.append(
                normalizedBoundaries[normalizedBoundaries.count - 1] + String(scalar).utf8.count)
        }
        self.normalizedBoundaries = normalizedBoundaries
        guard !identity else {
            normalizedToOriginal = originalBoundaries
            return
        }
        var prefixes: [String] = []
        for index in 0...originalScalars.count {
            prefixes.append(
                String(String.UnicodeScalarView(originalScalars[0..<index]))
                    .precomposedStringWithCanonicalMapping)
        }
        var mapping = [Int](repeating: 0, count: normalizedScalars.count + 1)
        var previous = 0
        for index in 0...normalizedScalars.count {
            let prefix = String(String.UnicodeScalarView(normalizedScalars[0..<index]))
            var found = false
            for candidate in previous...originalScalars.count where prefixes[candidate] == prefix {
                mapping[index] = originalBoundaries[candidate]
                previous = candidate
                found = true
                break
            }
            if !found {
                mapping[index] = originalBoundaries[originalScalars.count]
            }
        }
        normalizedToOriginal = mapping
    }

    func start(_ byte: Int) -> Int {
        let boundary = normalizedBoundaries.last(where: { $0 <= byte }) ?? 0
        let index = normalizedBoundaries.firstIndex(of: boundary) ?? 0
        return normalizedToOriginal[index]
    }

    func end(_ byte: Int) -> Int {
        let boundary = normalizedBoundaries.first(where: { $0 >= byte }) ?? normalizedBoundaries[normalizedBoundaries.count - 1]
        let index = normalizedBoundaries.firstIndex(of: boundary) ?? normalizedBoundaries.count - 1
        return normalizedToOriginal[index]
    }
}

enum ByteLevel {
    private static let reverse: [Character: UInt8] = {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var characters = bytes.map { Character(UnicodeScalar($0)!) }
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte)
            characters.append(Character(UnicodeScalar(256 + extra)!))
            extra += 1
        }
        var table: [Character: UInt8] = [:]
        for (byte, character) in zip(bytes, characters) {
            table[character] = UInt8(byte)
        }
        return table
    }()

    static func bytes(_ token: String) -> [UInt8] {
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
}
