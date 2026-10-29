public struct FuzzyMatch: Equatable, Sendable {
    public let score: Int
    public let offsets: [Int]
}

public func fuzzyMatch(_ pattern: String, _ text: String) -> FuzzyMatch? {
    let pattern = pattern.map { $0.lowercased() }
    var score = 0, run = 0, offsets: [Int] = []
    for (offset, character) in text.map({ $0.lowercased() }).enumerated() where offsets.count < pattern.count {
        if character == pattern[offsets.count] {
            score += 1 + run
            run += 2
            offsets.append(offset)
        } else {
            score -= 1
            run = 0
        }
    }
    return offsets.count == pattern.count ? FuzzyMatch(score: score, offsets: offsets) : nil
}

public func fuzzyMatch(_ query: String, fields: [String]) -> (score: Int, offsets: [[Int]])? {
    fuzzyMatch(words: query.split(whereSeparator: { $0.isWhitespace || $0 == ">" || $0 == "›" }), fields: fields)
}

public func fuzzyMatch(words: [Substring], fields: [String]) -> (score: Int, offsets: [[Int]])? {
    var score = 0, offsets = fields.map { _ in Set<Int>() }
    for word in words {
        let best = fields.enumerated().compactMap { index, field in
            fuzzyMatch(String(word), field).map { (score: $0.score - index, index: index, offsets: $0.offsets) }
        }.max { ($0.score, -$0.index) < ($1.score, -$1.index) }
        guard let best else { return nil }
        score += best.score
        offsets[best.index].formUnion(best.offsets)
    }
    return (score, offsets.map { $0.sorted() })
}
