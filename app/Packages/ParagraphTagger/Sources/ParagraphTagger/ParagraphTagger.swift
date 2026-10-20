import CoreML
import Foundation
import Tokenizers

public actor Tagger {
    private let modelURL: URL
    private let tokenizerURL: URL
    private var tokenizer: (any Tokenizer)?
    private var tokenizerLoad: Task<any Tokenizer, Error>?
    private var models: [Int: MLModel] = [:]
    private var compiledURL: URL?

    public init(modelURL: URL, tokenizerURL: URL) {
        self.modelURL = modelURL
        self.tokenizerURL = tokenizerURL
    }

    public func tag(_ prompt: String) async throws -> TaggerResult {
        try await detailed(prompt).answer
    }

    func detailed(_ prompt: String) async throws -> Tagged {
        let tokenizer = try await loadedTokenizer()
        return try predict(prompt, tokenizer)
    }

    private func loadedTokenizer() async throws -> any Tokenizer {
        if let tokenizer { return tokenizer }
        if let tokenizerLoad { return try await tokenizerLoad.value }
        let load = Task { try await AutoTokenizer.from(modelFolder: tokenizerURL) }
        tokenizerLoad = load
        do {
            let tokenizer = try await load.value
            self.tokenizer = tokenizer
            tokenizerLoad = nil
            return tokenizer
        } catch {
            tokenizerLoad = nil
            throw ParagraphTaggerError.loadFailed
        }
    }

    private func predict(_ prompt: String, _ tokenizer: any Tokenizer) throws -> Tagged {
        let context = try ContextPrompt(prompt)
        let (low, high) = try Selection.choose(context.blocks, hovered: context.hoveredBlock) { low, high in
            try Encoding.encode(context.assemble(low: low, high: high).prompt, tokenizer: tokenizer).ids.count
        }
        let assembled = context.assemble(low: low, high: high)
        let encoded = try Encoding.encode(assembled.prompt, tokenizer: tokenizer)
        let shape = Selection.shape(encoded.ids.count)
        let tags = try classify(encoded.ids, shape: shape, tokenizer: tokenizer)
        let offsets = Array(encoded.offsets.prefix(encoded.ids.count))
        let classes = Tagging.lineClasses(rows: assembled.rows, tags: tags, offsets: offsets)
        let unit = Tagging.unit(classes: classes, rows: assembled.rows,
                                ranges: assembled.ranges, hovered: assembled.hovered)
        let range = unit ?? assembled.ranges[assembled.hovered]
        let spans = Tagging.spans(tags: tags, offsets: offsets)
        let options = spans.compactMap { span -> String? in
            guard span.kind == .option, let trimmed = Tagging.trim(span, prompt: assembled.prompt) else {
                return nil
            }
            return Tagging.text(trimmed, prompt: assembled.prompt)
        }
        let translated = context.blocks[low].lowerBound
        let answer = TaggerResult(
            isQuestion: unit.map {
                $0.lowerBound <= assembled.ranges[assembled.hovered].lowerBound
                    && $0.upperBound >= assembled.ranges[assembled.hovered].upperBound
            } ?? false,
            options: options,
            firstLine: translated + range.lowerBound + 1,
            lastLine: translated + range.upperBound)
        return Tagged(prompt: assembled.prompt, offsets: offsets, tags: tags, answer: answer)
    }

    private func classify(_ ids: [Int], shape: Int, tokenizer: any Tokenizer) throws -> [Tag] {
        let model = try loadedModel(shape: shape)
        let inputIds = try MLMultiArray(shape: [1, NSNumber(value: shape)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: shape)], dataType: .int32)
        let padId = try Encoding.padId(tokenizer: tokenizer)
        for index in 0..<shape {
            inputIds[index] = NSNumber(value: index < ids.count ? ids[index] : padId)
            mask[index] = NSNumber(value: index < ids.count ? 1 : 0)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let prediction = try model.prediction(from: provider)
        guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue else {
            throw ParagraphTaggerError.loadFailed
        }
        return (0..<ids.count).map { token in
            var best = 0
            var value = logits[token * 5].floatValue
            for candidate in 1..<5 {
                let score = logits[token * 5 + candidate].floatValue
                if score > value {
                    best = candidate
                    value = score
                }
            }
            return Tag(index: best)
        }
    }

    private func loadedModel(shape: Int) throws -> MLModel {
        if let model = models[shape] { return model }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.functionName = "shape_\(shape)"
        do {
            let url: URL
            if modelURL.pathExtension == "mlmodelc" {
                url = modelURL
            } else if let compiledURL {
                url = compiledURL
            } else {
                let compiled = try MLModel.compileModel(at: modelURL)
                compiledURL = compiled
                url = compiled
            }
            let model = try MLModel(contentsOf: url, configuration: configuration)
            models[shape] = model
            return model
        } catch {
            throw ParagraphTaggerError.loadFailed
        }
    }
}

enum Selection {
    static func shape(_ length: Int) -> Int {
        [512, 1024, 2048].first(where: { length <= $0 }) ?? 2048
    }

    static func choose(
        _ blocks: [Range<Int>], hovered: Int, tokens: (Int, Int) throws -> Int
    ) throws -> (low: Int, high: Int) {
        var low = 0
        var high = blocks.count - 1
        while true {
            if try tokens(low, high) <= 2048 { return (low, high) }
            guard low < high else { throw ParagraphTaggerError.hoveredParagraphTooLong }
            if hovered - low >= high - hovered {
                low += 1
            } else {
                high -= 1
            }
        }
    }
}

enum Encoding {
    static func encode(
        _ prompt: String, tokenizer: any Tokenizer
    ) throws -> (ids: [Int], offsets: [(Int, Int)]) {
        guard let cls = tokenizer.convertTokenToId("[CLS]"),
              let sep = tokenizer.convertTokenToId("[SEP]") else {
            throw ParagraphTaggerError.loadFailed
        }
        let map = NFCMap(prompt)
        var ids = [cls]
        var offsets = [(0, 0)]
        var position = 0
        for id in tokenizer.encode(text: prompt, addSpecialTokens: false) {
            let token = tokenizer.convertIdToToken(id) ?? ""
            let length = ByteLevel.bytes(token).count
            ids.append(id)
            offsets.append((map.start(position), map.end(position + length)))
            position += length
        }
        ids.append(sep)
        offsets.append((0, 0))
        return (ids, offsets)
    }

    static func padId(tokenizer: any Tokenizer) throws -> Int {
        guard let pad = tokenizer.convertTokenToId("[PAD]") else {
            throw ParagraphTaggerError.loadFailed
        }
        return pad
    }
}
