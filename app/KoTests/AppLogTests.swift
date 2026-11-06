import Foundation
import XCTest
@testable import Kido

final class AppLogTests: XCTestCase {
    func testTheLogUsesUtcLinesAndKeepsOnePreviousFileAfterRotation() throws {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("kido-app-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AppLog(destination: .directory(directory), cap: 80)
        log.write("first state\ncontinued")
        let first = try String(contentsOf: directory.appendingPathComponent("app.log"), encoding: .utf8)
        XCTAssertEqual(first.components(separatedBy: "\n").count, 2)
        XCTAssertNotNil(first.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z kido-app\[\d+\] first state\\ncontinued\n$"#, options: .regularExpression))
        log.write("second state")
        log.write("third state")
        let current = try String(contentsOf: directory.appendingPathComponent("app.log"), encoding: .utf8)
        let previous = try String(contentsOf: directory.appendingPathComponent("app.log.1"), encoding: .utf8)
        let prefix = "kido-app[\(ProcessInfo.processInfo.processIdentifier)]"
        XCTAssertTrue(current.hasSuffix("\(prefix) third state\n"))
        XCTAssertTrue(previous.hasSuffix("\(prefix) second state\n"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["app.log", "app.log.1"])
    }
}
