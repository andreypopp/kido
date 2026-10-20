import Foundation
import XCTest
@testable import ParagraphTagger

final class ParityTests: XCTestCase {
    private struct Record: Decodable {
        struct Label: Decodable {
            struct Option: Decodable {
                let line: Int
                let text: String
            }

            let lines: [String]
            let options: [Option]
        }

        let prompt: String
        let label: Label
    }

    private struct Reference: Decodable {
        struct Score: Decodable {
            let f1: Double
        }

        let token_f1: [String: Score]
        let option: Score
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var output: URL {
        packageRoot.appendingPathComponent("../../ml/data/output").standardizedFileURL
    }

    private static var data: URL {
        packageRoot.appendingPathComponent("../../ml/data").standardizedFileURL
    }

    private func tagger() throws -> Tagger {
        let model = Self.output.appendingPathComponent("ParagraphTagger.mlpackage")
        let tokenizer = Self.output.appendingPathComponent("phase2-nobold-s0")
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw XCTSkip("paragraph model missing: run `make -C app/ml convert`")
        }
        guard FileManager.default.fileExists(atPath: Self.data.appendingPathComponent("eval.jsonl").path) else {
            throw XCTSkip("eval data missing: app/ml/data/eval.jsonl")
        }
        guard FileManager.default.fileExists(atPath: Self.data.appendingPathComponent("eval-coreml.json").path) else {
            throw XCTSkip("Core ML eval missing: run `make -C app/ml data/eval-coreml.json`")
        }
        return Tagger(modelURL: model, tokenizerURL: tokenizer)
    }

    private func records() throws -> [Record] {
        let text = try String(contentsOf: Self.data.appendingPathComponent("eval.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONDecoder().decode(Record.self, from: Data($0.utf8))
        }
    }

    private func stripBold(_ prompt: String) -> (String, [Int]) {
        let bytes = Array(prompt.utf8)
        var output: [UInt8] = []
        var positions = [Int](repeating: 0, count: bytes.count + 1)
        var index = 0
        while index < bytes.count {
            positions[index] = output.count
            if bytes[index] == 0x2A, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                positions[index + 1] = output.count
                index += 2
            } else {
                output.append(bytes[index])
                index += 1
                positions[index] = output.count
            }
        }
        positions[bytes.count] = output.count
        return (String(decoding: output, as: UTF8.self), positions)
    }

    private func goldSpans(_ record: Record) -> [(Int, Int, String)] {
        let rows = Prompt.rows(record.prompt)
        var spans: [(Int, Int, String)] = []
        for (index, value) in record.label.lines.enumerated() where value == "question" {
            spans.append((rows[index].start, rows[index].end, "question"))
        }
        for option in record.label.options {
            let row = rows[option.line - 1]
            guard let range = row.text.range(of: option.text) else { continue }
            let start = row.start + row.text[..<range.lowerBound].utf8.count
            spans.append((start, start + option.text.utf8.count, "option"))
        }
        return spans.sorted { $0.0 < $1.0 }
    }

    private func goldTags(_ offsets: [(Int, Int)], _ spans: [(Int, Int, String)]) -> [String] {
        var labels = offsets.map { $0.0 == $0.1 ? "IGNORE" : "O" }
        var assigned = [(Int, String)?](repeating: nil, count: offsets.count)
        for (spanIndex, span) in spans.enumerated() {
            for (index, offset) in offsets.enumerated() {
                if offset.0 == offset.1 || offset.1 <= span.0 || offset.0 >= span.1 { continue }
                if assigned[index] == nil || span.2 == "option" && assigned[index]!.1 != "option" {
                    assigned[index] = (spanIndex, span.2)
                }
            }
        }
        var previous: Int?
        for (index, value) in assigned.enumerated() {
            guard let value else {
                previous = nil
                continue
            }
            labels[index] = "\(value.0 == previous ? "I" : "B")-\(value.1.uppercased())"
            previous = value.0
        }
        return labels
    }

    func testEvalMatchesThePythonCoreMLScores() async throws {
        let tagger = try tagger()
        let reference = try JSONDecoder().decode(
            Reference.self,
            from: Data(contentsOf: Self.data.appendingPathComponent("eval-coreml.json")))
        var question = (tp: 0, fp: 0, fn: 0)
        var predictedOptions: [String: Int] = [:]
        var goldOptions: [String: Int] = [:]
        for record in try records() {
            let (stripped, positions) = stripBold(record.prompt)
            let spans = goldSpans(record).map { (positions[$0.0], positions[$0.1], $0.2) }
            let predicted = try await tagger.detailed(stripped)
            let gold = goldTags(predicted.offsets, spans)
            for (predictedTag, goldTag) in zip(predicted.tags, gold) where goldTag != "IGNORE" {
                let hit = predictedTag.rawValue.hasSuffix("QUESTION")
                let wanted = goldTag.hasSuffix("QUESTION")
                if hit && wanted { question.tp += 1 }
                else if hit { question.fp += 1 }
                else if wanted { question.fn += 1 }
            }
            let predictedSpans = Tagging.spans(tags: predicted.tags, offsets: predicted.offsets)
                .filter { $0.kind == .option }
                .compactMap { Tagging.trim($0, prompt: predicted.prompt) }
            for span in predictedSpans {
                predictedOptions["\(span.start):\(span.end)", default: 0] += 1
            }
            for span in spans where span.2 == "option" {
                guard let trimmed = Tagging.trim(Span(start: span.0, end: span.1, kind: .option),
                                                 prompt: stripped) else { continue }
                goldOptions["\(trimmed.start):\(trimmed.end)", default: 0] += 1
            }
        }
        let questionF1 = 2.0 * Double(question.tp)
            / Double(2 * question.tp + question.fp + question.fn)
        let optionTP = goldOptions.reduce(0) { $0 + min($1.value, predictedOptions[$1.key, default: 0]) }
        let optionPredicted = predictedOptions.values.reduce(0, +)
        let optionGold = goldOptions.values.reduce(0, +)
        let optionF1 = 2.0 * Double(optionTP) / Double(optionPredicted + optionGold)
        print("swift question F1 \(questionF1) tp=\(question.tp) fp=\(question.fp) fn=\(question.fn)")
        print("swift option F1 \(optionF1) tp=\(optionTP) predicted=\(optionPredicted) gold=\(optionGold)")
        XCTAssertEqual(questionF1, reference.token_f1["question"]!.f1, accuracy: 0.005)
        XCTAssertEqual(optionF1, reference.option.f1, accuracy: 0.005)
    }
}
