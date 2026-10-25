import XCTest
@testable import Kido

final class ThemeConfTests: XCTestCase {
    func testText() {
        let pair = ThemeConf.Pair(light: "A", dark: "B")
        XCTAssertEqual(ThemeConf.set("# keep\ntheme=old\nfont-size = 12\n", pair), "# keep\ntheme = light:A,dark:B\nfont-size = 12\n")
        XCTAssertEqual(ThemeConf.set("theme = first\n# theme = no\ntheme = last", pair), "theme = first\n# theme = no\ntheme = light:A,dark:B")
        XCTAssertEqual(ThemeConf.set("font-size = 12", pair), "font-size = 12\ntheme = light:A,dark:B\n")
        XCTAssertEqual(ThemeConf.set("# keep\r\ntheme=old\r\n", pair), "# keep\r\ntheme = light:A,dark:B\r\n")
        XCTAssertEqual(ThemeConf.parse("theme = single").pair, .init(light: "single", dark: "single"))
        XCTAssertEqual(ThemeConf.parse("theme= light: A , dark: B ").pair, pair)
        XCTAssertEqual(ThemeConf.parse("# theme=no").pair, .init())
        XCTAssertEqual(ThemeConf.parse("theme=prior\ntheme=light:foo").pair, .init(light: "prior", dark: "prior"))
        XCTAssertEqual(ThemeConf.parse("theme=prior\ntheme=dark:foo").pair, .init(light: "prior", dark: "prior"))
        XCTAssertEqual(ThemeConf.parse("theme=prior\ntheme=light:A,unknown:B").pair, .init(light: "prior", dark: "prior"))
        XCTAssertEqual(ThemeConf.parse("theme=\"light:A,dark:B\"").pair, pair)
        XCTAssertEqual(ThemeConf.set("theme=prior\ntheme=light:foo", pair), "theme=prior\ntheme = light:A,dark:B")
    }
    func testWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("nested/conf")
        let pair = ThemeConf.Pair(light: "A", dark: "B")
        try ThemeConf.write(to: target.path) { _ in pair }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), ThemeConf.line(pair) + "\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try ThemeConf.write(to: link.path) { _ in .init(light: "C", dark: "D") }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(ThemeConf.parse(try String(contentsOf: target, encoding: .utf8)).pair.light, "C")
        try FileManager.default.removeItem(at: target)
        try ThemeConf.write(to: link.path) { _ in pair }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), ThemeConf.line(pair) + "\n")
    }
}
