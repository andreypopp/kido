import XCTest
@testable import Kido

final class WindowFrameTests: XCTestCase {
    func testSavedFramesAreIndependentByServer() throws {
        let name = "WindowFrameTests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let frames = WindowFrames(preferences: preferences, serverDir: "/tmp/server")
        let local = CGRect(x: 120, y: 140, width: 900, height: 600)
        let remote = CGRect(x: 240, y: 160, width: 800, height: 500)
        frames.save(local, for: .local)
        frames.save(remote, for: .remote("host"))
        XCTAssertEqual(frames.frame(for: .local), local)
        XCTAssertEqual(frames.frame(for: .remote("host")), remote)
    }

    func testRestoreClampShrinkCascadeAndCenter() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let second = CGRect(x: 1440, y: 100, width: 1200, height: 800)
        let saved = CGRect(x: 100, y: 200, width: 900, height: 600)
        let centered = CGRect(x: 270, y: 150, width: 900, height: 600)
        XCTAssertEqual(WindowFrames.place(saved: saved, centered: centered, screens: [main, second], main: main, open: []), saved)
        XCTAssertEqual(WindowFrames.place(saved: nil, centered: centered, screens: [main], main: main, open: [centered]), centered)
        XCTAssertEqual(WindowFrames.place(saved: CGRect(x: 3000, y: -100, width: 900, height: 600), centered: centered, screens: [main, second], main: main, open: []), CGRect(x: 540, y: 0, width: 900, height: 600))
        XCTAssertEqual(WindowFrames.place(saved: CGRect(x: -100, y: -100, width: 2000, height: 1200), centered: centered, screens: [main], main: main, open: []), main)
        XCTAssertEqual(WindowFrames.place(saved: saved, centered: centered, screens: [main], main: main, open: [saved]), CGRect(x: 120, y: 180, width: 900, height: 600))
        XCTAssertEqual(WindowFrames.place(saved: CGRect(x: 2500, y: 200, width: 900, height: 600), centered: centered, screens: [main, second], main: main, open: []), CGRect(x: 1740, y: 200, width: 900, height: 600))
    }
}
