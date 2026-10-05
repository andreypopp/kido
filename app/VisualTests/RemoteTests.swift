import AppKit
import XCTest
import TmuxControl
@testable import Kido

@MainActor final class RemoteTests: VisualTestCase {
    func testHostAndRouting() throws {
        XCTAssertEqual(try Host("user@my-alias"), .remote("user@my-alias"))
        for invalid in ["", "-option", "a b", "a;id", "a$(id)", "a\u{0}", "a\nb", "a/../b"] { XCTAssertThrowsError(try Host(invalid)) }
        XCTAssertTrue(Server.validPath("/tmp/state space $literal/socket"))
        XCTAssertFalse(Server.validPath("relative/socket"))
        XCTAssertFalse(Server.validPath("/tmp/a\n/socket"))
        XCTAssertEqual(SSH.quote("a'b $c"), "'a'\"'\"'b $c'")
        let cold = WindowRoutes(), warm = WindowRoutes()
        var requests: [Kido.Host] = []
        cold.connect(.remote("localhost"))
        cold.ordinaryOpen()
        cold.ready(isDefaultLaunch: false) { requests.append($0) }
        cold.connect(.remote("localhost"))
        XCTAssertEqual(requests, [.remote("localhost"), .remote("localhost")])
        requests = []
        warm.ordinaryOpen()
        warm.ready(isDefaultLaunch: true) { requests.append($0) }
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
            routes.ready(isDefaultLaunch: false) { requests.append($0) }
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
            routes.ready(isDefaultLaunch: false) { requests.append($0) }
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
        routes.ready(isDefaultLaunch: true) { requests.append($0) }
        routes.ordinaryOpen()
        XCTAssertEqual(requests, [.local], "plain launch with untitled after ready opens Local")
    }

    func testCloseBeforeDiscoveryTaskRuns() async throws {
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)")), grants: nil))
        let owner = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        owner.testRemoteEnvironment = ["HOME": "/tmp/kr-queued-unused/home", "XDG_STATE_HOME": "/tmp/kr-queued-unused/state", "PATH": "/usr/bin:/bin"]
        defer { owner.ssh?.stop() }
        owner.start()
        owner.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(owner.ssh, "a cancelled queued discovery must not allocate a transport after window close")
        XCTAssertNil(owner.testConnection)
        XCTAssertFalse(owner.window.isVisible || NSApp.isActive)
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
        try await until("one-shot launches", seconds: 4) { FileManager.default.fileExists(atPath: marker) }
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
        try await until("TERM trap is installed", seconds: 4) { FileManager.default.fileExists(atPath: marker) }
        kill(child.process.processIdentifier, SIGSTOP)
        child.stop()
        try await until("SIGSTOP child must be killed and reaped", seconds: 4) { !child.process.isRunning }
        XCTAssertEqual(child.process.terminationStatus, SIGKILL)
    }

    func testOSC52LocalhostRemoteWindow() async throws {
        let trust = try await Child.run("/usr/bin/ssh", SSH.options + ["-o", "ControlMaster=no", "-S", "none", "-T", "--", "localhost", "exec /usr/bin/true"])
        guard trust.status == 0 else { throw XCTSkip("Prepared BatchMode localhost unavailable: \(trust.err)") }
        let root = "/tmp/kr-osc52-" + UUID().uuidString.prefix(8)
        let fm = FileManager.default
        for path in [root, root + "/home", root + "/state", root + "/bin"] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try ("#!/bin/sh\nexec " + SSH.quote(tools.kido) + " \"$@\"\n").write(toFile: root + "/bin/kido", atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/bin/kido")
        let env = ["HOME": root + "/home", "XDG_STATE_HOME": root + "/state", "PATH": root + "/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        let board = NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board, grants: nil))
        let owner = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        owner.testRemoteEnvironment = env
        addTeardownBlock { @MainActor in
            owner.close()
            _ = try? await Child.run(tools.tmux, ["-S", root + "/state/kido-app/socket", "kill-server"])
            try? fm.removeItem(atPath: root)
            board.releaseGlobally()
        }
        owner.start()
        try await until("OSC52 private SSH window connected") { owner.testConnection != nil && owner.testBanner.isHidden }
        let pane = try XCTUnwrap(owner.testSession?.windows.values.first?.panes.first)
        runtime.allowAlways(owner.host)
        board.clearContents()
        board.setString("before remote copy", forType: .string)
        let copy = Data("remote copy ✓".utf8).base64EncodedString()
        let ready = root + "/ready", result = root + "/reply", script = root + "/clipboard.py"
        try """
        import os, select, time, tty
        tty.setraw(0)
        deadline = time.monotonic() + 5
        while not os.path.exists('\(ready)') and time.monotonic() < deadline: time.sleep(0.02)
        os.write(1, bytes.fromhex('1b5d35323b733b3f1b5c'))
        deadline = time.monotonic() + 8
        reply = b''
        while time.monotonic() < deadline:
            ready, _, _ = select.select([0], [], [], 0.4 if reply else 0.1)
            if ready: reply += os.read(0, 65536)
            elif reply: break
        open('\(result)', 'wb').write(reply)
        time.sleep(3)
        """.write(toFile: script, atomically: true, encoding: .utf8)
        _ = await replies(owner, [Command("set-option", "-s", "set-clipboard", "on"), Command("set-option", "-s", "get-clipboard", "request"), Command("respawn-pane", "-k", "-t", pane.pane, "printf '\\033]52;c;\(copy)\\007'; exec /usr/bin/python3 " + script)])
        try await until("OSC52 SSH live write changed named board") { board.string(forType: .string) == "remote copy ✓" }
        _ = await replies(owner, [Command("set-buffer", "remote stale tmux buffer")])
        let text = "SSH named board ✓\ntext"
        board.clearContents()
        board.setString(text, forType: .string)
        try Data().write(to: URL(fileURLWithPath: ready))
        try await until("OSC52 SSH pane received reply") { fm.fileExists(atPath: result) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result)), Data("\u{1b}]52;s;\(Data(text.utf8).base64EncodedString())\u{1b}\\".utf8))
        XCTAssertNil(owner.preparedAlert)
        print("OSC52 SSH localhost private remote window: named-board copy and exactly one preauthorized s read reply")
    }

    func testLocalhostWindowsAndRecovery() async throws {
        let trust = try await Child.run("/usr/bin/ssh", SSH.options + ["-o", "ControlMaster=no", "-S", "none", "-T", "--", "localhost", "exec /usr/bin/true"])
        guard trust.status == 0 else { throw XCTSkip("Prepared BatchMode localhost unavailable: \(trust.err)") }
        let root = "/tmp/kr-" + UUID().uuidString.prefix(8)
        let fm = FileManager.default
        let state = root + "/state space $literal"
        for directory in [root, root + "/home", state, root + "/bin"] {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let wrapper = "#!/bin/sh\nprintf '%s\\n' \"$1\" >> " + SSH.quote(root + "/commands") + "\nexec " + SSH.quote(tools.kido) + " \"$@\"\n"
        try wrapper.write(toFile: root + "/bin/kido", atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root + "/bin/kido")
        let env = ["HOME": root + "/home", "XDG_STATE_HOME": state, "PATH": root + "/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        var owners: [WindowOwner] = []
        var transports: [SSH] = []
        let cleanup = SSH.options + ["-S", "none", "-o", "ControlMaster=no", "-T", "--", "localhost"]
        addTeardownBlock { @MainActor in
            owners.forEach { $0.close() }
            for socket in [state + "/kido-app/socket", root + "/local/socket"] {
                let command = "exec /usr/bin/env " + env.map { SSH.quote("\($0.key)=\($0.value)") }.joined(separator: " ")
                    + " " + [tools.tmux, "-u", "-S", socket, "kill-server"].map(SSH.quote).joined(separator: " ")
                _ = try? await Child.run("/usr/bin/ssh", cleanup + [command])
            }
            let deadline = Date().addingTimeInterval(5)
            while transports.contains(where: { fm.fileExists(atPath: $0.directory) }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(transports.contains { fm.fileExists(atPath: $0.directory) }, "owned masters and ControlPaths must be cleaned")
            try? fm.removeItem(atPath: root)
        }
        let refusal = root + "/bin/outage"
        try ("#!/bin/sh\necho attempt >> " + SSH.quote(root + "/attempts") + "\nexit 1\n").write(toFile: refusal, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: refusal)
        let config = root + "/ssh.conf"
        let normal = "Host localhost\n  HostName localhost\n"
        try normal.write(toFile: config, atomically: true, encoding: .utf8)
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)")), grants: nil))
        let routes = WindowRoutes()
        routes.connect(.remote("localhost"))
        routes.ready(isDefaultLaunch: false) { host in
            let owner = WindowOwner(host: host, runtime: runtime, start: false)
            owner.testRemoteEnvironment = env
            owner.testSSHConfiguration = config
            owners.append(owner)
            owner.start()
        }
        routes.connect(.remote("localhost"))
        let localDir = root + "/local"
        let localResult = try await Child.run(tools.kido, ["server", "--server", localDir], env: tools.environment.merging(env) { _, new in new })
        XCTAssertEqual(localResult.status, 0, localResult.err)
        let localServer = try JSONDecoder().decode(Server.self, from: Data(localResult.out.utf8))
        let local = WindowOwner(host: .local, runtime: runtime, start: false)
        local.testEndpoint = Endpoint(server: localServer, kido: tools.kido)
        owners.append(local)
        local.start()
        try await until("two Remote plus Local connect") { owners.allSatisfy { $0.testConnection != nil && $0.testBanner.isHidden } }
        let first = owners[0], second = owners[1]
        transports += owners.compactMap(\.ssh)
        XCTAssertEqual(owners.count, 3)
        XCTAssertNotEqual(first.ssh?.directory, second.ssh?.directory)
        XCTAssertTrue(first.window.title.hasPrefix(first.testIdentity + " / main"))
        let a = try XCTUnwrap(first.testSession?.windows.values.first?.panes.first)
        let b = try XCTUnwrap(second.testSession?.windows.values.first?.panes.first)
        let c = try XCTUnwrap(local.testSession?.windows.values.first?.panes.first)
        XCTAssertEqual(a.pane, b.pane)
        XCTAssertEqual(a.pane, c.pane)
        XCTAssertFalse(a === b || a === c || b === c)
        let firstClient = await replies(first, [Command("display-message", "-p", "#{client_name}")])
        let secondClient = await replies(second, [Command("display-message", "-p", "#{client_name}")])
        XCTAssertNotEqual(firstClient, secondClient)
        let before = first.generation
        let oldConnection = first.testConnection
        let fallbackLaunch = first.ssh!.launch(["/usr/bin/printf", "%s", "DIRECT-FALLBACK"])
        let commands = try String(contentsOfFile: root + "/commands", encoding: .utf8)
        var stalePublished = false
        first.send([Command("run-shell", "/bin/sleep 0.4"), Command("display-message", "-p", "old-generation")]) { _ in stalePublished = true }
        try (normal + "  ProxyCommand " + refusal + "\n").write(toFile: config, atomically: true, encoding: .utf8)
        kill(try XCTUnwrap(first.ssh?.master?.process.processIdentifier), SIGKILL)
        try await until("outage spans at least three failed SSH reopen attempts", seconds: 8) { ((try? String(contentsOfFile: root + "/attempts", encoding: .utf8))?.split(separator: "\n").count ?? 0) >= 3 }
        try normal.write(toFile: config, atomically: true, encoding: .utf8)
        try await until("master loss redials the remembered endpoint") { first.generation > before && first.testConnection != nil && first.testConnection !== oldConnection && first.testBanner.isHidden }
        transports += owners.compactMap(\.ssh)
        XCTAssertFalse(first.accepts(before), "late callbacks from the lost generation must be ignored")
        XCTAssertFalse(stalePublished, "an old-generation command completion must not publish into the new window")
        XCTAssertFalse(oldConnection?.active ?? true)
        let fallback = try await Child.run(fallbackLaunch)
        XCTAssertEqual(fallback.status, 0, fallback.err)
        XCTAssertEqual(fallback.out, "DIRECT-FALLBACK", "OpenSSH can bypass a dead master; its stale generation must remain invalid")
        XCTAssertFalse(first.accepts(before))
        let after = try String(contentsOfFile: root + "/commands", encoding: .utf8)
        XCTAssertEqual(commands.components(separatedBy: "\n").filter { $0 == "server" }.count,
                       after.components(separatedBy: "\n").filter { $0 == "server" }.count, "automatic redial must never start a server")
        _ = await replies(first, [Command("new-window", "-d", "-n", "Second", "/bin/cat")])
        try await until("new remote window reaches both models") { first.navigation.windows.count == 2 && second.navigation.windows.count == 2 }
        first.nextWindow()
        try await until("remote switch-window uses feed client") { first.navigation.window?.number == 1 && second.navigation.window?.number == 1 }
        first.window.setContentSize(NSSize(width: 1000, height: 600))
        second.window.setContentSize(NSSize(width: 640, height: 400))
        _ = await replies(second, [Command("refresh-client", "-C", "160x60"), Command("switch-client", "-t", "$0:@1")])
        first.window.close()
        XCTAssertFalse(first.accepts(first.generation))
        XCTAssertTrue(second.alive && local.alive)
        let secondAlive = await replies(second, [Command("display-message", "-p", "#{session_name}")])
        let localAlive = await replies(local, [Command("display-message", "-p", "#{session_name}")])
        XCTAssertNotNil(secondAlive)
        XCTAssertNotNil(localAlive)
        second.send([Command("detach-client")])
        try await until("deliberate detach stays down") { second.testConnection == nil && second.ssh == nil }
        let detachedGeneration = second.generation
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(second.generation, detachedGeneration)
        XCTAssertTrue(labels(second.testBanner).contains { $0.contains("Detached") })
        let transport = try SSH("localhost")
        transports.append(transport)
        transport.testEnvironment(env)
        try await transport.start { _ in }
        let quoted = try await Child.run(transport.launch(["/usr/bin/printf", "%s", "space $literal ' quote ☃"]))
        XCTAssertEqual(quoted.out, "space $literal ' quote ☃")
        let socket = state + "/kido-app/socket"
        _ = try await Child.run(transport.launch([tools.tmux, "-u", "-S", socket, "set-environment", "-g", "KIDO_PROTOCOL", "9.9"]))
        let mismatch = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        mismatch.testRemoteEnvironment = env
        owners.append(mismatch)
        mismatch.start()
        try await until("remote mismatch alert") { mismatch.preparedAlert != nil }
        XCTAssertNil(mismatch.window.attachedSheet)
        let mismatchAlert = try XCTUnwrap(mismatch.preparedAlert?.alert)
        let mismatchContent = try XCTUnwrap(mismatchAlert.window.contentView)
        XCTAssertTrue(mismatchAlert.window.defaultButtonCell === mismatchAlert.buttons[0].cell)
        XCTAssertTrue(labels(mismatchContent).contains { $0 == "Update Kido.app to connect" })
        XCTAssertTrue(labels(mismatchContent).contains { $0.contains("Server: 9.9.") })
        XCTAssertTrue(buttons(mismatchContent).contains { $0.title == "Reconnect" })
        XCTAssertFalse(buttons(mismatchContent).contains { $0.title == "Restart…" })
        XCTAssertNil(mismatch.testConnection)
        mismatch.respondToAlert(.alertSecondButtonReturn)
        XCTAssertNil(mismatch.preparedAlert)
        XCTAssertNil(mismatch.testConnection)
        XCTAssertTrue(buttons(mismatch.testBanner).contains { $0.title == "Reconnect" && !$0.isHidden })
        _ = try await Child.run(transport.launch([tools.tmux, "-u", "-S", socket, "set-environment", "-g", "KIDO_PROTOCOL", "0.9"]))
        mismatch.start()
        try await until("upgraded binary mismatch alert") { mismatch.preparedAlert != nil }
        let upgradedAlert = try XCTUnwrap(mismatch.preparedAlert?.alert)
        let upgradedContent = try XCTUnwrap(upgradedAlert.window.contentView)
        XCTAssertTrue(labels(upgradedContent).contains { $0 == "Restart kido on localhost" })
        XCTAssertTrue(labels(upgradedContent).contains { $0.contains("Server: 0.9. Host binary: 1.0.") })
        XCTAssertNil(mismatch.testConnection)
        _ = try await Child.run(transport.launch([tools.tmux, "-u", "-S", socket, "set-environment", "-g", "KIDO_PROTOCOL", "1.0"]))
        mismatch.respondToAlert(.alertFirstButtonReturn)
        try await until("Reconnect rediscovers compatible protocol") { mismatch.testBanner.isHidden }
        transports += owners.compactMap(\.ssh)
        let missing = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        missing.testRemoteEnvironment = env.merging(["PATH": "/usr/bin:/bin"]) { _, new in new }
        owners.append(missing)
        missing.start()
        try await until("missing kido has actionable banner") { labels(missing.testBanner).contains { $0.contains("noninteractive SSH PATH") && $0.contains("~/.zshenv") } }
        let terminalGeneration = missing.generation
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(missing.generation, terminalGeneration, "missing kido is terminal, not an automatic retry")
        let untrustedConfig = root + "/untrusted.conf"
        try "Host localhost\n  UserKnownHostsFile /dev/null\n  GlobalKnownHostsFile /dev/null\n".write(toFile: untrustedConfig, atomically: true, encoding: .utf8)
        let untrusted = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        untrusted.testSSHConfiguration = untrustedConfig
        untrusted.testRemoteEnvironment = env
        owners.append(untrusted)
        untrusted.start()
        try await until("host trust failure is actionable") { labels(untrusted.testBanner).contains { $0.contains("Host key verification failed") && $0.contains("Establish host trust") } }
        let trustGeneration = untrusted.generation
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(untrusted.generation, trustGeneration, "host trust failure is terminal, not an automatic retry")
        transport.stop()
        for owner in owners {
            XCTAssertFalse(owner.window.isVisible || owner.window.isKeyWindow || owner.window.isMainWindow || NSApp.isActive)
        }
    }

    private func until(_ reason: String, seconds: TimeInterval = 25, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), reason)
        if !condition() { throw Failure(message: reason) }
    }

    private func replies(_ owner: WindowOwner, _ commands: [Command]) async -> [Reply]? {
        var result: [Reply]??
        owner.send(commands) { result = .some($0) }
        try? await until("control command completion") { result != nil }
        return result ?? nil
    }

    private func labels(_ view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
    }

    private func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
}
