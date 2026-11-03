import XCTest

final class KoSchemaTests: XCTestCase {
    func testTheCommittedSwiftTypesAreWhatTheGeneratorWritesFromTheCurrentSchemas() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let checkout = try XCTUnwrap(ProcessInfo.processInfo.environment["KO_CHECKOUT"].flatMap { $0.isEmpty ? nil : $0 }, "KO_CHECKOUT")
        let committed = app.appendingPathComponent("Packages/KoModel/Sources/KoModel/KoSchema.swift")
        let regenerated = FileManager.default.temporaryDirectory.appendingPathComponent("KoSchema-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: regenerated) }
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", app.appendingPathComponent("scripts/gen-ko-model.py").path, checkout + "/share/ko/openapi.json", checkout + "/share/ko/client-model.json", regenerated.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(try String(contentsOf: regenerated, encoding: .utf8), try String(contentsOf: committed, encoding: .utf8), "run make ko-model")
    }
}
