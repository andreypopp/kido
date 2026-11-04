import XCTest
@testable import Kido

final class RuntimeTintTests: XCTestCase {
    func testTheHueIsFnv1aOfTheNameModuloAFullCircle() {
        XCTAssertEqual(["buildbox", "py311", "gpu-1", "e2e"].map(RuntimeTint.hue), [292, 197, 307, 313])
    }

    func testAConfiguredColourParsesInEitherCaseAndAnythingElseDoesNot() throws {
        let lower = try XCTUnwrap(RuntimeTint.rgb(hex: "#d08a2a")), upper = try XCTUnwrap(RuntimeTint.rgb(hex: "#D08A2A"))
        XCTAssertEqual([lower.r, lower.g, lower.b], [upper.r, upper.g, upper.b])
        XCTAssertEqual(try XCTUnwrap(RuntimeTint.rgb(hex: "#ff0000")).r, 1)
        XCTAssertEqual(try XCTUnwrap(RuntimeTint.rgb(hex: "#ff0000")).b, 0)
        for bad in ["", "#abc", "d08a2a", "#d08a2", "#d08a2ab", "#gggggg", "#+abcde", "orange"] {
            XCTAssertNil(RuntimeTint.rgb(hex: bad), bad)
        }
    }
}
