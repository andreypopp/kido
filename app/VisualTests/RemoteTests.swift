import AppKit
import XCTest
import PaneGeometry
import SidebarFeed
@testable import Kido

@MainActor final class RemoteTests: VisualTestCase {
    func testHostAndRouting() throws {
        XCTAssertEqual(try Host("user@my-alias"), .remote("user@my-alias"))
        for invalid in ["", "-option", "a b", "a;id", "a$(id)", "a\u{0}", "a\nb", "a/../b"] { XCTAssertThrowsError(try Host(invalid)) }
        XCTAssertEqual(SSH.quote("a'b $c"), "'a'\"'\"'b $c'")
        let cold = WindowRoutes(), warm = WindowRoutes()
        var requests: [Kido.Host] = []
        cold.connect(.remote("localhost"))
        cold.ordinaryOpen()
        cold.ready(isDefaultLaunch: false) { host, _ in requests.append(host) }
        cold.connect(.remote("localhost"))
        XCTAssertEqual(requests, [.remote("localhost"), .remote("localhost")])
        requests = []
        warm.ordinaryOpen()
        warm.ready(isDefaultLaunch: true) { host, _ in requests.append(host) }
        warm.connect(.remote("localhost"))
        XCTAssertEqual(requests, [.local, .remote("localhost")])
    }

    func testConnectURLs() throws {
        for (url, host) in [("kido-app://localhost", "localhost"),
                            ("kido-app://localhost/", "localhost"),
                            ("kido-app://user@my-alias", "user@my-alias"),
                            ("kido-app://%75ser@%6Dy-alias", "user@my-alias")] {
            XCTAssertEqual(try Host(url: XCTUnwrap(URL(string: url))), .remote(host))
        }
        for url in ["kido-app://", "https://localhost", "kido-app://-option",
                    "kido-app://%20localhost", "kido-app://localhost%20", "kido-app://a%09b",
                    "kido-app://a%00b", "kido-app://a%0Ab", "kido-app://a%20b",
                    "kido-app://localhost/session", "kido-app://localhost//", "kido-app://connect/localhost",
                    "kido-app://localhost?", "kido-app://localhost#", "kido-app://localhost:22",
                    "kido-app://user:password@localhost", "kido-app://user%20name@localhost"] {
            let parsed = try XCTUnwrap(URL(string: url))
            XCTAssertThrowsError(try Host(url: parsed), url)
        }
    }

    func testURLLaunchOrdering() throws {
        let host = try Host(url: XCTUnwrap(URL(string: "kido-app://localhost")))
        for beforeReady in [false, true] {
            let routes = WindowRoutes()
            var requests: [Kido.Host] = []
            routes.ordinaryOpen()
            if beforeReady { routes.connect(host) }
            routes.ready(isDefaultLaunch: false) { host, _ in requests.append(host) }
            if !beforeReady {
                routes.ordinaryOpen()
                XCTAssertTrue(requests.isEmpty)
                routes.connect(host)
            }
            routes.connect(host)
            XCTAssertEqual(requests, [host, host])
        }
    }

    func testIntentLaunchBeforePerform() {
        for earlyOrdinaryOpen in [false, true] {
            let routes = WindowRoutes()
            var requests: [Kido.Host] = []
            if earlyOrdinaryOpen { routes.ordinaryOpen() }
            routes.ready(isDefaultLaunch: false) { host, _ in requests.append(host) }
            routes.ordinaryOpen()
            routes.ordinaryOpen()
            XCTAssertTrue(requests.isEmpty, "untitled/reopen before perform must not open Local")
            routes.connect(.remote("localhost"))
            routes.connect(.remote("localhost"))
            XCTAssertEqual(requests, [.remote("localhost"), .remote("localhost")])
            requests.removeAll()
            routes.ordinaryOpen()
            XCTAssertEqual(requests, [.local], "Dock reopen after all windows close opens Local")
        }
        let routes = WindowRoutes()
        var requests: [Kido.Host] = []
        routes.ready(isDefaultLaunch: true) { host, _ in requests.append(host) }
        routes.ordinaryOpen()
        XCTAssertEqual(requests, [.local], "plain launch with untitled after ready opens Local")
    }

    func testSealedDrainRejectsLateLaunch() throws {
        let drain = Drain()
        drain.close()
        XCTAssertThrowsError(try Child("/usr/bin/true", [], stdout: Pipe(), drain: drain))
        XCTAssertEqual(drain.ended.wait(timeout: .now()), .success)
    }

    func testCancelledOneShotRemainsInDrainUntilReaped() async throws {
        let marker = "/tmp/kr-cancel-" + UUID().uuidString
        let drain = Drain()
        let task = Task {
            try? await Child.run("/bin/sh", ["-c", "trap '' TERM; echo $$ > " + SSH.quote(marker) + "; exec /bin/sleep 60"], drain: drain)
        }
        defer { task.cancel(); drain.close(); try? FileManager.default.removeItem(atPath: marker) }
        try await wait("one-shot launches", within: 4) { FileManager.default.fileExists(atPath: marker) }
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        kill(pid, SIGSTOP)
        task.cancel()
        drain.close()
        let reaped = expectation(description: "cancelled one-shot drain")
        drain.ended.notify(queue: .global()) { @Sendable in
            XCTAssertNotEqual(kill(pid, 0), 0, "drain completes only after the cancelled child is reaped")
            reaped.fulfill()
        }
        await fulfillment(of: [reaped], timeout: 5)
    }

    func testStoppedChildIsReaped() async throws {
        let marker = "/tmp/kr-child-" + UUID().uuidString
        let child = try Child("/bin/sh", ["-c", "trap '' TERM; : > " + SSH.quote(marker) + "; exec /bin/cat"], stdin: Pipe(), stdout: Pipe())
        defer {
            if child.process.isRunning { kill(child.process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(atPath: marker)
        }
        try await wait("TERM trap is installed", within: 4) { FileManager.default.fileExists(atPath: marker) }
        kill(child.process.processIdentifier, SIGSTOP)
        child.stop()
        try await wait("SIGSTOP child must be killed and reaped", within: 4) { !child.process.isRunning }
        XCTAssertEqual(child.process.terminationStatus, SIGKILL)
    }

    // Remote hosts wait for the ko remote transport: the window says so and starts nothing.
    func testARemoteHostShowsThatItIsDisabled() async throws {
        let board = NSPasteboard(name: .init("kr-remote-" + UUID().uuidString))
        let owner = WindowOwner(host: .remote("devbox"), runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        addTeardownBlock { @MainActor in owner.close(); board.releaseGlobally() }
        owner.start()
        try await wait("the disabled message", within: 5) { owner.testBanner.testText.title == "Remote hosts return with the ko remote transport" }
        XCTAssertEqual(owner.testBanner.testText.detail, "devbox")
        XCTAssertNil(owner.testBanner.testText.button)
        XCTAssertNil(owner.ssh)
        XCTAssertNil(owner.testClient)
    }
}
