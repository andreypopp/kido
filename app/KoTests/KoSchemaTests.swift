import KoModel
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

    func testAnIntegerOutsideItsSchemaBoundsFailsToDecodeAndNamesTheField() throws {
        func leaf(_ cols: Int) throws -> KoSchema.Leaf {
            try JSONDecoder().decode(KoSchema.Leaf.self, from: Data(#"{"pane":"pane_1","cols":\#(cols),"rows":5}"#.utf8))
        }
        func float(x: Int) throws -> KoSchema.Float {
            try JSONDecoder().decode(KoSchema.Float.self, from: Data(#"{"border":false,"cols":10,"pane":"pane_1","rows":5,"title":"","x":\#(x),"y":0,"z":0}"#.utf8))
        }
        XCTAssertEqual(try leaf(4096).cols, 4096)
        XCTAssertEqual(try float(x: 65535).x, 65535)
        let refused: [(field: String, decode: () throws -> Void)] = [
            ("cols", { _ = try leaf(0) }), ("cols", { _ = try leaf(4097) }), ("x", { _ = try float(x: 65536) }), ("x", { _ = try float(x: -1) }),
        ]
        for (field, decode) in refused {
            XCTAssertThrowsError(try decode()) { error in
                guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(context.codingPath.map(\.stringValue), [field], context.debugDescription)
            }
        }
    }
}
