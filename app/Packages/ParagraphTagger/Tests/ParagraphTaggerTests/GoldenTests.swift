import Foundation
import XCTest
@testable import ParagraphTagger

final class GoldenTests: XCTestCase {
    private struct Golden: Decodable {
        struct Expected: Decodable {
            let isQuestion: Bool
            let options: [String]
            let firstLine: Int
            let lastLine: Int
        }

        let expected: Expected
        let prompt: String
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var modelURL: URL {
        packageRoot.appendingPathComponent("../../ml/data/output/ParagraphTagger.mlpackage").standardizedFileURL
    }

    private static var tokenizerURL: URL {
        packageRoot.appendingPathComponent("../../ml/data/output/phase2-nobold-s0").standardizedFileURL
    }

    private func tagger() throws -> Tagger {
        guard FileManager.default.fileExists(atPath: Self.modelURL.path) else {
            throw XCTSkip("paragraph model missing: run `make -C app/ml convert`")
        }
        guard FileManager.default.fileExists(atPath: Self.tokenizerURL.appendingPathComponent("tokenizer.json").path) else {
            throw XCTSkip("paragraph tokenizer missing: run `make -C app/ml convert`")
        }
        return Tagger(modelURL: Self.modelURL, tokenizerURL: Self.tokenizerURL)
    }

    func testInventedFixturesMatchTheCoreMLCommandLine() async throws {
        let tagger = try tagger()
        for name in ["list_question", "inline_question", "plain", "tricky"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Golden/\(name).json")
            let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
            let answer = try await tagger.tag(golden.prompt)
            XCTAssertEqual(answer.isQuestion, golden.expected.isQuestion, name)
            XCTAssertEqual(answer.options, golden.expected.options, name)
            XCTAssertEqual(answer.firstLine, golden.expected.firstLine, name)
            XCTAssertEqual(answer.lastLine, golden.expected.lastLine, name)
        }
    }
}
