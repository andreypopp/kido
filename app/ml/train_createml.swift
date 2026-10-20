import Foundation
import CreateML

struct Example: Codable {
    let tokens: [String]
    let labels: [String]
}

let args = CommandLine.arguments
let train = try JSONDecoder().decode(
    [Example].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let eval = try JSONDecoder().decode(
    [Example].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let started = Date()
let data = train.map { (tokens: $0.tokens, labels: $0.labels) }
var parameters = MLWordTagger.ModelParameters()
parameters.maxIterations = 100
let model = try MLWordTagger(trainingData: data, parameters: parameters)
try model.write(to: URL(fileURLWithPath: args[3]))
let predictions = try eval.map { try model.prediction(from: $0.tokens) }
try JSONEncoder().encode(predictions).write(to: URL(fileURLWithPath: args[4]))
let seconds = Date().timeIntervalSince(started)
print("trained \(train.count) evaluated \(eval.count) in \(String(format: "%.2f", seconds))s")
