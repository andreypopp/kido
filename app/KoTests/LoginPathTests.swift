import Foundation
import XCTest
@testable import Kido

final class LoginPathTests: XCTestCase {
    func testLoginShellOutput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("shell")
        let cases: [(String, String?)] = [
            ("printf 'before'; export PATH='/opt/homebrew/bin:/usr/bin'; /bin/sh -c \"$3\"; printf 'after'", "/opt/homebrew/bin:/usr/bin"),
            ("export PATH=''; exec /bin/sh -c \"$3\"", nil),
            ("printf 'no markers'", nil),
            ("/bin/sh -c \"$3\"; exit 1", nil),
            ("exec /bin/sleep 10", nil),
            ("printf '%s' \"$3\"; export PATH='/good'; /bin/sh -c \"$3\"; printf '%s' \"$3\"", "/good"),
            ("printf '\\377'; export PATH='/valid'; exec /bin/sh -c \"$3\"", "/valid"),
        ]
        for (body, expected) in cases {
            let script = "#!/bin/sh\n[ \"$1\" = -l ] && [ \"$2\" = -c ] || exit 2\n" + body + "\n"
            try script.write(to: shell, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
            let timesOut = body == "exec /bin/sleep 10"
            let start = ProcessInfo.processInfo.systemUptime
            let result = await LoginPath.read(shell: shell.path, deadline: timesOut ? 0.2 : 3)
            XCTAssertEqual(result, expected, body)
            if timesOut {
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
            }
        }
    }
}
