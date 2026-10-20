import Foundation
import FoundationModels

@Generable
struct ParagraphAnswer {
    @Guide(description: "True when the numbered lines ask the reader to decide, answer, or choose.")
    var isQuestion: Bool

    @Guide(description: "The question's answer options copied verbatim, without list markers such as a), -, or 1. Return no options when there are none.")
    var options: [String]

    @Guide(description: "The first numbered line of the question unit.")
    var firstLine: Int

    @Guide(description: "The last numbered line of the question unit.")
    var lastLine: Int
}

@MainActor
final class ParagraphModel {
    enum Availability: Equatable {
        case ready
        case unavailable(String)
    }

    static let shared = ParagraphModel()
    static var cache = Paragraphs.Cache(limit: 256)

    #if KIDO_VISUAL
    static var testAnalyze: (@MainActor (String) async throws -> ParagraphAnswer)?
    static var testAvailability: Availability?
    #endif

    private var loggedUnavailable = false

    func availability() -> Availability {
        #if KIDO_VISUAL
        if let testAvailability = Self.testAvailability { return testAvailability }
        #endif
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            let caption = switch reason {
            case .deviceNotEligible: "On-device model not available on this Mac"
            case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence to analyse text"
            case .modelNotReady: "On-device model is still downloading"
            @unknown default: "On-device model unavailable"
            }
            if !loggedUnavailable {
                loggedUnavailable = true
                debug("paragraph model unavailable: \(caption)")
            }
            return .unavailable(caption)
        }
    }

    func analyze(_ text: String) async throws -> ParagraphAnswer {
        #if KIDO_VISUAL
        if let testAnalyze = Self.testAnalyze { return try await testAnalyze(text) }
        #endif
        let session = LanguageModelSession(instructions: """
            Read numbered lines from a terminal. Lines marked ">" are the hovered paragraph.
            Return the question unit that contains it: the question and its answer options.
            Return its first and last line numbers. Copy each option verbatim, without list
            markers such as a), -, or 1. For a non-question, return the hovered lines as the range.
            """)
        return try await session.respond(to: "Lines:\n\(text)", generating: ParagraphAnswer.self).content
    }

    #if KIDO_VISUAL
    static func reset() {
        shared.loggedUnavailable = false
        cache = Paragraphs.Cache(limit: 256)
        testAnalyze = nil
        testAvailability = nil
    }
    #endif
}
