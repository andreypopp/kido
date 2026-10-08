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

    func testAgentLaunchPolicy() async throws {
        let root = "/tmp/kr-policy-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let configuration = root + "/config"
        let policies = [("omitted", "", "no"), ("off", "ForwardAgent no", "no"), ("on", "ForwardAgent yes", "yes"),
                        ("path", "ForwardAgent /tmp/private-agent.sock", "/tmp/private-agent.sock"),
                        ("variable", "ForwardAgent $PRIVATE_AGENT", "$PRIVATE_AGENT"),
                        ("identity", "ForwardAgent yes\n IdentityAgent /tmp/identity.sock", "yes"),
                        ("none", "ForwardAgent yes\n IdentityAgent none", "yes")]
        try policies.map { "Host \($0.0)\n HostName example.invalid\n \($0.1)\n" }.joined().write(toFile: configuration, atomically: true, encoding: .utf8)
        let options = SSH.options + ["-F", configuration]
        XCTAssertFalse(SSH.options.contains("ForwardAgent=no"))
        for (host, _, policy) in policies {
            let result = try await Child.run("/usr/bin/ssh", options + ["-G", "--", host], env: tools.environment.merging(["PRIVATE_AGENT": "/tmp/private-agent.sock"]) { _, new in new })
            XCTAssertEqual(result.status, 0, result.err)
            XCTAssertTrue(result.out.components(separatedBy: "\n").contains("forwardagent " + policy), result.out)
            XCTAssertTrue(result.out.contains("clearallforwardings yes"))
            let ssh = try SSH(host)
            ssh.testConfiguration = configuration
            addTeardownBlock { @MainActor in ssh.stop() }
            let helper = ssh.passenger(["/usr/bin/printf", "%s", "a'b $c"])
            XCTAssertTrue(helper.arguments.contains("ForwardAgent=no"))
            XCTAssertEqual(helper.arguments.last, "exec '/usr/bin/env' '-u' 'SSH_AUTH_SOCK' '/usr/bin/printf' '%s' 'a'\"'\"'b $c'")
            let endpoint = Endpoint(server: Server(tmux: "/tmp/tmux ' $tool", socket: "/tmp/state ' $dir/socket", protocolVersion: .required), kido: "/tmp/kido")
            let attach = [endpoint.server.tmux] + Launch.attach(endpoint.server.tmux, socket: endpoint.server.socket).arguments
            let control = ssh.passenger(attach, control: endpoint)
            XCTAssertFalse(control.arguments.contains("ForwardAgent=no"))
            XCTAssertEqual(control.arguments.last, "exec " + (["/bin/sh", "-c", SSH.attachScript, "kido-agent", endpoint.directory, endpoint.server.socket] + attach).map(SSH.quote).joined(separator: " "))
            XCTAssertTrue(control.arguments.contains("ClearAllForwardings=yes"))
        }
        var launches: [[String]] = []
        let endpoint = try await Server.locate(prepare: { arguments in
            launches.append(arguments)
            let output = arguments.first == "/bin/sh" ? "/tmp/kido\n/tmp/state ' $dir/kido-app\n" : "{\"tmux\":\"/tmp/tmux\",\"socket\":\"/tmp/state ' $dir/kido-app/socket\",\"server\":\"1.0\",\"protocol\":\"1.0\"}\n"
            return Launch("/usr/bin/printf", ["%s", output])
        })
        XCTAssertEqual(launches.last, ["/usr/bin/env", "SSH_AUTH_SOCK=" + endpoint.directory + "/agent.sock", "/tmp/kido", "server", "--server", endpoint.directory])
    }

    func testPrivateAgentPublication() async throws {
        let root = "/tmp/kr-agent-" + UUID().uuidString.prefix(8)
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let dir = root + "/state ' $d", socket = dir + "/socket", stable = dir + "/agent.sock"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let environment = tools.environment.filter { $0.key != "SSH_AUTH_SOCK" && $0.key != "SSH_AGENT_PID" }
        var agents: [Child] = []
        var controls: [Child] = []
        addTeardownBlock { @MainActor in
            controls.forEach { $0.stop() }
            _ = try? await Child.run(tools.tmux, ["-u", "-S", socket, "kill-session", "-t", "main"], env: environment)
            agents.forEach { $0.stop() }
            defer { try? fm.removeItem(atPath: root) }
            try await self.until("private agents and controls exit", seconds: 5) { !(agents + controls).contains { $0.process.isRunning } }
            XCTAssertFalse((agents + controls).contains { $0.process.isRunning })
        }
        for name in ["a", "b"] {
            let agent = try Child("/usr/bin/ssh-agent", ["-D", "-a", root + "/" + name + ".sock"], env: environment, stdout: Pipe())
            agents.append(agent)
            try await until("private agent socket", seconds: 5) { fm.fileExists(atPath: root + "/" + name + ".sock") }
            let key = root + "/key-" + name
            let generated = try await Child.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "private-test-" + name, "-f", key], env: environment)
            XCTAssertEqual(generated.status, 0, generated.err)
            let added = try await Child.run("/usr/bin/ssh-add", [key], env: environment.merging(["SSH_AUTH_SOCK": root + "/" + name + ".sock"]) { _, new in new })
            XCTAssertEqual(added.status, 0, added.err)
        }
        let initial = root + "/initial"
        let initialCommand = "printf '%s' \"$SSH_AUTH_SOCK\" > " + SSH.quote(initial) + "; exec /bin/sleep 60"
        let started = try await Child.run(tools.tmux, ["-u", "-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "main", initialCommand], env: environment.merging(["SSH_AUTH_SOCK": stable]) { _, new in new })
        XCTAssertEqual(started.status, 0, started.err)
        try await until("first shell has stable path", seconds: 5) { fm.fileExists(atPath: initial) }
        XCTAssertEqual(try String(contentsOfFile: initial, encoding: .utf8), stable)
        XCTAssertFalse(fm.fileExists(atPath: stable))
        for (index, forwarded) in [root + "/a.sock", root + "/b.sock", ""].enumerated() {
            let input = Pipe()
            let args = ["-c", SSH.attachScript, "kido-agent", dir, socket, tools.tmux] + Launch.attach(tools.tmux, socket: socket, session: "main").arguments
            let env = forwarded.isEmpty ? environment : environment.merging(["SSH_AUTH_SOCK": forwarded]) { _, new in new }
            let control = try Child("/bin/sh", args, env: env, stdin: input, stdout: Pipe())
            controls.append(control)
            let windowFile = root + "/window-\(index)", paneFile = root + "/pane-\(index)"
            let windowCommand = "printf '%s' \"$SSH_AUTH_SOCK\" > " + SSH.quote(windowFile) + "; exec /bin/sleep 60"
            let paneCommand = "printf '%s' \"$SSH_AUTH_SOCK\" > " + SSH.quote(paneFile) + "; exec /bin/sleep 60"
            let commands = [Command("new-window", "-d", "-t", "main", windowCommand),
                            Command("split-window", "-d", "-t", "main:0", paneCommand),
                            Command("detach-client")].map(\.line).joined(separator: "\n") + "\n"
            try input.fileHandleForWriting.write(contentsOf: Data(commands.utf8))
            try await until("private attach exits", seconds: 5) { !control.process.isRunning }
            XCTAssertEqual(control.process.terminationStatus, 0, control.stderr)
            try await until("new pane and window inherited stable path", seconds: 5) { fm.fileExists(atPath: paneFile) && fm.fileExists(atPath: windowFile) }
            XCTAssertEqual(try String(contentsOfFile: windowFile, encoding: .utf8), stable)
            XCTAssertEqual(try String(contentsOfFile: paneFile, encoding: .utf8), stable)
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: stable), index == 0 ? root + "/a.sock" : root + "/b.sock")
            let listed = try await Child.run("/usr/bin/ssh-add", ["-l"], env: environment.merging(["SSH_AUTH_SOCK": stable]) { _, new in new })
            XCTAssertEqual(listed.status, 0, listed.err)
            XCTAssertTrue(listed.out.contains(index == 0 ? "private-test-a" : "private-test-b"))
            XCTAssertFalse(listed.out.contains(index == 0 ? "private-test-b" : "private-test-a"))
        }
        agents[1].stop()
        try await until("winning private agent exits", seconds: 5) { !agents[1].process.isRunning }
        let dangling = try await Child.run("/usr/bin/ssh-add", ["-l"], env: environment.merging(["SSH_AUTH_SOCK": stable]) { _, new in new })
        XCTAssertEqual(dangling.status, 2, dangling.err)
        XCTAssertTrue(agents[0].process.isRunning, "the previous agent is live but never a fallback")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        let refused = try await Child.run("/bin/sh", ["-c", SSH.attachScript, "kido-agent", dir, socket, tools.tmux, "-V"], env: environment.merging(["SSH_AUTH_SOCK": root + "/a.sock"]) { _, new in new })
        XCTAssertEqual(refused.status, 1)
        XCTAssertEqual(refused.err, "Kido agent setup refused")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: stable), root + "/b.sock")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        try fm.removeItem(atPath: stable)
        try "unrelated".write(toFile: stable, atomically: true, encoding: .utf8)
        let unrelated = try await Child.run("/bin/sh", ["-c", SSH.attachScript, "kido-agent", dir, socket, tools.tmux, "-V"], env: environment.merging(["SSH_AUTH_SOCK": root + "/a.sock"]) { _, new in new })
        XCTAssertEqual(unrelated.status, 1)
        XCTAssertEqual(try String(contentsOfFile: stable, encoding: .utf8), "unrelated")
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
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))))
        let owner = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        owner.testRemoteEnvironment = ["HOME": "/tmp/kr-queued-unused/home", "XDG_STATE_HOME": "/tmp/kr-queued-unused/state", "PATH": "/usr/bin:/bin"]
        defer { owner.ssh?.stop() }
        owner.start()
        owner.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(owner.ssh, "a cancelled queued discovery must not allocate a transport after window close")
        XCTAssertNil(owner.testConnection)
        let visible = owner.window.isVisible, active = NSApp.isActive
        let state = "\(Date().ISO8601Format()) visible=\(visible) active=\(active)"
        print("queued discovery closed: \(state)")
        XCTAssertFalse(visible, state)
        XCTAssertFalse(active, state)
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
        let trust = try await Child.run("/usr/bin/ssh", SSH.options + ["-o", "ForwardAgent=no","-o", "ControlMaster=no", "-S", "none", "-T", "--", "localhost", "exec /usr/bin/true"])
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
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        owner.testRemoteEnvironment = env
        let config = root + "/ssh.conf"
        try "Host localhost\n  ForwardAgent no\n".write(toFile: config, atomically: true, encoding: .utf8)
        owner.testSSHConfiguration = config
        addTeardownBlock { @MainActor in
            owner.close()
            _ = try? await Child.run(tools.tmux, ["-S", root + "/state/kido-app/socket", "kill-server"])
            try? fm.removeItem(atPath: root)
            board.releaseGlobally()
        }
        let launched = try await Child.run(tools.kido, ["server", "--server", root + "/state/kido-app"], env: tools.environment.merging(env) { _, new in new })
        XCTAssertEqual(launched.status, 0, launched.err)
        let clipboardModeBeforeAttach = try await Child.run(tools.tmux, ["-S", root + "/state/kido-app/socket", "show", "-sv", "get-clipboard"])
        XCTAssertEqual(clipboardModeBeforeAttach.status, 0, clipboardModeBeforeAttach.err)
        owner.start()
        try await until("OSC52 private SSH window connected") { owner.testConnection != nil && owner.testBanner.isHidden }
        let pane = try XCTUnwrap(owner.testSession?.windows.values.first?.panes.first)
        let clipboardMode = await replies(owner, [Command("show", "-sv", "get-clipboard")])
        XCTAssertEqual(clipboardMode, [.success([clipboardModeBeforeAttach.out.trimmingCharacters(in: .whitespacesAndNewlines)])])
        WindowOwner.clipboardConsent.allowAlways(owner.host)
        board.clearContents()
        board.setString("before remote copy", forType: .string)
        let copy = Data("remote copy ✓".utf8).base64EncodedString()
        let ready = root + "/ready", result = root + "/reply", script = root + "/clipboard.py"
        try clipboardQueryScript(ready: ready, result: result, selector: "s", deadline: 8).write(toFile: script, atomically: true, encoding: .utf8)
        _ = await replies(owner, [Command("set-option", "-s", "set-clipboard", "on"), Command("respawn-pane", "-k", "-t", pane.pane, "printf '\\033]52;c;\(copy)\\007'; exec /usr/bin/python3 " + script)])
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
        let trust = try await Child.run("/usr/bin/ssh", SSH.options + ["-o", "ForwardAgent=no","-o", "ControlMaster=no", "-S", "none", "-T", "--", "localhost", "exec /usr/bin/true"])
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
        let cleanup = SSH.options + ["-o", "ForwardAgent=no", "-S", "none", "-o", "ControlMaster=no", "-T", "--", "localhost"]
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
        let normal = "Host localhost\n  HostName localhost\n  ForwardAgent no\n"
        try normal.write(toFile: config, atomically: true, encoding: .utf8)
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: NSPasteboard(name: .init("kido-clipboard-test-\(UUID().uuidString)"))))
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
        first.perform(.switchWindow(next: true))
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
        transport.testConfiguration = config
        try await transport.start { _ in }
        let quoted = try await Child.run(transport.launch(["/usr/bin/printf", "%s", "space $literal ' quote ☃"]))
        XCTAssertEqual(quoted.out, "space $literal ' quote ☃")
        let socket = state + "/kido-app/socket"
        _ = try await Child.run(transport.launch([tools.tmux, "-u", "-S", socket, "set-environment", "-g", "KIDO_PROTOCOL", "9.9"]))
        let mismatch = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        mismatch.testRemoteEnvironment = env
        mismatch.testSSHConfiguration = config
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
        XCTAssertTrue(labels(upgradedContent).contains { $0.contains("Server: 0.9. Host binary: 2.0.") })
        XCTAssertNil(mismatch.testConnection)
        _ = try await Child.run(transport.launch([tools.tmux, "-u", "-S", socket, "set-environment", "-g", "KIDO_PROTOCOL", "2.0"]))
        mismatch.respondToAlert(.alertFirstButtonReturn)
        try await until("Reconnect rediscovers compatible protocol") { mismatch.testBanner.isHidden }
        transports += owners.compactMap(\.ssh)
        let missing = WindowOwner(host: .remote("localhost"), runtime: runtime, start: false)
        missing.testSSHConfiguration = config
        missing.testRemoteEnvironment = env.merging(["PATH": "/usr/bin:/bin"]) { _, new in new }
        owners.append(missing)
        missing.start()
        try await until("missing kido has actionable banner") { labels(missing.testBanner).contains { $0.contains("noninteractive SSH PATH") && $0.contains("~/.zshenv") } }
        let terminalGeneration = missing.generation
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(missing.generation, terminalGeneration, "missing kido is terminal, not an automatic retry")
        let untrustedConfig = root + "/untrusted.conf"
        try "Host localhost\n  ForwardAgent no\n  UserKnownHostsFile /dev/null\n  GlobalKnownHostsFile /dev/null\n".write(toFile: untrustedConfig, atomically: true, encoding: .utf8)
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
