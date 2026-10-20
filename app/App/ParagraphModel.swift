import Foundation
import ParagraphTagger

struct ParagraphAnswer: Equatable, Sendable {
    var isQuestion: Bool
    var options: [String]
    var firstLine: Int = 0
    var lastLine: Int = 0
}

@MainActor
final class ParagraphModel {
    static let shared = ParagraphModel()
    static var cache = Paragraphs.Cache(limit: 256)

    #if KIDO_VISUAL
    static var testAnalyze: (@MainActor (String) async throws -> ParagraphAnswer)?
    #endif

    private var tagger: Tagger?

    private init() {}

    func analyze(_ text: String) async throws -> ParagraphAnswer {
        #if KIDO_VISUAL
        if let testAnalyze = Self.testAnalyze { return try await testAnalyze(text) }
        #endif
        let tagger = try loadedTagger()
        let answer = try await tagger.tag(text)
        return ParagraphAnswer(isQuestion: answer.isQuestion, options: answer.options,
                               firstLine: answer.firstLine, lastLine: answer.lastLine)
    }

    private func loadedTagger() throws -> Tagger {
        if let tagger { return tagger }
        guard let model = Bundle.main.url(forResource: "ParagraphTagger", withExtension: "mlmodelc") else {
            throw ParagraphTaggerError.missingModel
        }
        guard let tokenizer = Bundle.main.url(forResource: "tokenizer", withExtension: nil) else {
            throw ParagraphTaggerError.missingTokenizer
        }
        let tagger = Tagger(modelURL: model, tokenizerURL: tokenizer)
        self.tagger = tagger
        return tagger
    }

    #if KIDO_VISUAL
    static func reset() {
        cache = Paragraphs.Cache(limit: 256)
        testAnalyze = nil
        shared.tagger = nil
    }
    #endif
}
