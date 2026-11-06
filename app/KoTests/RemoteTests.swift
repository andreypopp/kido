import AppKit
import GhosttyKit
import KoClient
import KoModel
import XCTest
@testable import Kido

// A private sshd on a loopback port with its own keys, and the ssh_config that reaches it: the host of the
// tests, which never read ~/.ssh or the user's agent. "The remote" is this machine under a private HOME and
// XDG_STATE_HOME, so a remote ko server lives in `dir`.
@MainActor final class PrivateHost {
    let root: String
    let port: Int
    let sshd: Child
    var sessions: [SSH] = []
    private var scopes = 0
    var agentSocket: String { root + "/agent.sock" }
    var path: String { (tools.ko as NSString).deletingLastPathComponent + ":/usr/bin:/bin" }

    // The private HOME and XDG_STATE_HOME of "the remote" for one test: its ko server lives in `dir`.
    struct Scope {
        let home: String
        let state: String
        var dir: String { state + "/ko" }
    }

    func scope() throws -> Scope {
        scopes += 1
        let base = root + "/s\(scopes)"
        for directory in [base, base + "/home", base + "/state"] { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        return Scope(home: base + "/home", state: base + "/state")
    }

    static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func listening(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    // The aliases: h (no agent), closed (a port nothing listens on), fwd (forwards the private agent) and plain.
    init(forwarding: Bool = true) throws {
        var template = Array("/tmp/kr-XXXXXX".utf8CString)
        let root = String(cString: try XCTUnwrap(mkdtemp(&template)))
        for name in ["host_key", "client_key"] {
            let keygen = try runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", root + "/" + name], env: ["PATH": "/usr/bin:/bin"])
            XCTAssertEqual(keygen.status, 0)
        }
        try FileManager.default.copyItem(atPath: root + "/client_key.pub", toPath: root + "/authorized_keys")
        let port = try Self.freePort(), closedPort = try Self.freePort()
        let hostKey = try String(contentsOfFile: root + "/host_key.pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:\(port) \(hostKey)\n".write(toFile: root + "/known_hosts", atomically: true, encoding: .utf8)
        try """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(root)/host_key
            PidFile \(root)/sshd.pid
            AuthorizedKeysFile \(root)/authorized_keys
            StrictModes no
            UsePAM no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAuthentication yes
            AllowStreamLocalForwarding \(forwarding ? "yes" : "no")
            AllowAgentForwarding yes

            """.write(toFile: root + "/sshd_config", atomically: true, encoding: .utf8)
        func block(_ alias: String, port: Int, _ extra: String) -> String {
            """
            Host \(alias)
              HostName 127.0.0.1
              Port \(port)
              User \(NSUserName())
              IdentityFile \(root)/client_key
              IdentitiesOnly yes
              UserKnownHostsFile \(root)/known_hosts
              GlobalKnownHostsFile /dev/null
              CheckHostIP no

            """ + extra
        }
        try (block("h", port: port, "  IdentityAgent none\n") + block("closed", port: closedPort, "  IdentityAgent none\n")
            + block("fwd", port: port, "  ForwardAgent yes\n  IdentityAgent \(root)/agent.sock\n") + block("plain", port: port, "  IdentityAgent none\n"))
            .write(toFile: root + "/ssh_config", atomically: true, encoding: .utf8)
        sshd = try Child("/usr/sbin/sshd", ["-D", "-e", "-f", root + "/sshd_config"], env: ["PATH": "/usr/bin:/bin"], stdout: Pipe())
        self.root = root
        self.port = port
    }

    func stop() {
        sshd.stop()
        _ = sshd.ended.wait(timeout: .now() + 10)
        for session in sessions { _ = session.ended.wait(timeout: .now() + 10) }
        try? FileManager.default.removeItem(atPath: root)
    }
}

@MainActor final class RemoteTests: KoTestCase {
    private static var shared: PrivateHost?

    override class func tearDown() {
        MainActor.assumeIsolated {
            shared?.stop()
            shared = nil
        }
        super.tearDown()
    }

    // The sshd of the class: one for all tests, each with its own remote scope.
    private func host() throws -> PrivateHost {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KO_E2E_HOST_SSH"] == "1", "KO_E2E_HOST_SSH=1 runs the tests that need a private sshd")
        let host = try Self.shared ?? PrivateHost()
        Self.shared = host
        wait("sshd listens") { PrivateHost.listening(host.port) }
        addTeardownBlock { @MainActor in
            self.wait("the masters of the test end", within: 10) { host.sessions.allSatisfy { $0.ended.wait(timeout: .now()) == .success } }
        }
        return host
    }

    private func owner(_ host: PrivateHost, _ scope: PrivateHost.Scope, alias: String = "h", path: String? = nil) throws -> WindowOwner {
        let board = NSPasteboard(name: .init("ko-remote-" + UUID().uuidString))
        let owner = WindowOwner(host: .remote(alias), runtime: try XCTUnwrap(GhosttyRuntime(pasteboard: board)), start: false)
        owner.testSSH = { [unowned host] ssh in
            ssh.testConfiguration = host.root + "/ssh_config"
            ssh.testLocalEnvironment = ["PATH": "/usr/bin:/bin", "HOME": scope.home]
            ssh.testEnvironment(["HOME": scope.home, "XDG_STATE_HOME": scope.state, "PATH": path ?? host.path])
            host.sessions.append(ssh)
        }
        addTeardownBlock { @MainActor in
            owner.close()
            board.releaseGlobally()
        }
        owner.start()
        return owner
    }

    private func names(_ owner: WindowOwner) -> [String] { owner.snapshot?.sessions.map(\.name) ?? [] }

    private func connected(_ owner: WindowOwner) {
        wait("the remote session", within: 20) { self.names(owner) == ["s"] && owner.testBanner.isHidden }
        if !owner.testBanner.isHidden { XCTFail("banner: \(owner.testBanner.testText)") }
    }

    // MARK: without ssh

    func testTheForwardTheCheckAndTheHelpersCarryTheirOwnAgentPolicy() throws {
        XCTAssertFalse(SSH.options.contains("ForwardAgent=no"))
        XCTAssertTrue(SSH.options.contains("StreamLocalBindUnlink=yes"))
        let ssh = try SSH("devbox")
        addTeardownBlock { @MainActor in ssh.stop() }
        XCTAssertEqual(Array(ssh.forwardArguments(remote: "/r/ko dir/socket").suffix(8)),
                       ["-S", ssh.directory + "/c", "-O", "forward", "-L", ssh.directory + "/socket:/r/ko dir/socket", "--", "devbox"])
        XCTAssertFalse(ssh.forwardArguments(remote: "/r/socket").contains("ClearAllForwardings=yes"), "it would clear the forward of this command")
        XCTAssertFalse(ssh.masterArguments.contains("ForwardAgent=no"))
        XCTAssertFalse(ssh.probeArguments.contains("ForwardAgent=no"), "the probe shows the configured policy")
        XCTAssertTrue(ssh.checkArguments.contains("ForwardAgent=no"))
        let helper = ssh.passenger(["ko", "server", "--print-socket"])
        XCTAssertTrue(helper.arguments.contains("ForwardAgent=no"))
        XCTAssertEqual(helper.arguments.last, "exec '/usr/bin/env' '-u' 'SSH_AUTH_SOCK' 'ko' 'server' '--print-socket'")
        let publisher = ssh.passenger(["/bin/sh", "-c", SSH.publisherScript, "-", "/r/ko dir"], forwardingAgent: true)
        XCTAssertFalse(publisher.arguments.contains("ForwardAgent=no"))
        XCTAssertTrue(publisher.arguments.contains("ClearAllForwardings=yes"))
        XCTAssertEqual(publisher.arguments.last, "exec " + ["/bin/sh", "-c", SSH.publisherScript, "-", "/r/ko dir"].map(SSH.quote).joined(separator: " "))
        XCTAssertEqual(Host.local.imageFetches, 8)
        XCTAssertEqual(Host.remote("devbox").imageFetches, 4)
    }

    func testThePublisherReplacesASymlinkWithoutFollowingItAndKeepsAnythingElse() throws {
        let root = try stateDir()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        let agent = try KoFakeServer(directory: root, version: nil)
        addTeardownBlock { agent.stop() }
        let fm = FileManager.default
        func publish(_ dir: String) throws {
            let run = try runTool("/bin/sh", ["-c", SSH.publisherScript, "-", dir], env: ["PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": agent.socket])
            XCTAssertEqual(run.status, 0)
        }
        func fresh(_ name: String) throws -> String {
            let dir = root + "/" + name
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return dir
        }
        let absent = try fresh("absent")
        try publish(absent)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: absent + "/agent.sock"), agent.socket)

        let toDirectory = try fresh("link"), target = try fresh("target")
        try fm.createSymbolicLink(atPath: toDirectory + "/agent.sock", withDestinationPath: target)
        try publish(toDirectory)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: toDirectory + "/agent.sock"), agent.socket)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target), [], "the rename did not follow the old link into its directory")

        let file = try fresh("file")
        try "mine".write(toFile: file + "/agent.sock", atomically: true, encoding: .utf8)
        try publish(file)
        XCTAssertEqual(try String(contentsOfFile: file + "/agent.sock", encoding: .utf8), "mine")

        let directory = try fresh("directory")
        try fm.createDirectory(atPath: directory + "/agent.sock", withIntermediateDirectories: false)
        try publish(directory)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory + "/agent.sock"), [])
        for dir in [absent, toDirectory, file, directory] {
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix(".agent.sock.") }, [], "no temporary link is left in \(dir)")
        }
    }

    func testARelaunchRemovesTheStaleControlSocketBeforeItStartsAMaster() async throws {
        let closed = try PrivateHost.freePort()
        let root = try stateDir()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        try "Host h\n  HostName 127.0.0.1\n  Port \(closed)\n  IdentityAgent none\n".write(toFile: root + "/config", atomically: true, encoding: .utf8)
        let ssh = try SSH("h")
        ssh.testConfiguration = root + "/config"
        ssh.testLocalEnvironment = ["PATH": "/usr/bin:/bin", "HOME": root]
        addTeardownBlock { @MainActor in ssh.stop() }
        try "stale".write(toFile: ssh.directory + "/c", atomically: true, encoding: .utf8)
        do throws(Failure) { try await ssh.relaunch() } catch { XCTAssertTrue(error.message.contains("refused") || error.message.contains("Connection"), error.message) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ssh.directory + "/c"), "the stale control socket of a killed master stays only if the app leaves it")
        XCTAssertFalse(ssh.master?.process.isRunning ?? false, "a failed attempt leaves no master")
    }

    func testTheMismatchSheetOfARemoteHostNamesTheSideThatUpdates() {
        let own = KoVersion(protocolVersion: "1.2", vt: "aaaaaaaaaaaa", build: "mine")
        let host = Host.remote("devbox")
        let recovery = "\n\nOn devbox, stop the server with the command below, then run ko server. All sessions and panes on that server will end."
        func alert(_ code: ko_code, _ server: KoVersion) -> NSAlert { WindowOwner.mismatchAlert(host: host, code: code, server: server, own: own, serverDir: "/tmp/remote-ko") }

        let older = alert(KO_ERR_PROTOCOL_MISMATCH, KoVersion(protocolVersion: "0.9", vt: own.vt, build: "theirs"))
        XCTAssertEqual(older.messageText, "Update ko on devbox")
        XCTAssertEqual(older.informativeText, "This app speaks ko protocol 1.2. The server speaks 0.9. Update ko on the host, then reconnect. The server is build theirs; this app is build mine." + recovery)
        let newer = alert(KO_ERR_PROTOCOL_MISMATCH, KoVersion(protocolVersion: "2.0", vt: own.vt, build: "theirs"))
        XCTAssertEqual(newer.messageText, "Update Kido.app to connect to devbox")
        XCTAssertEqual(newer.informativeText, "The server speaks ko protocol 2.0; this app speaks 1.2. Update Kido.app on this Mac. The server is build theirs; this app is build mine." + recovery)
        let revision = alert(KO_ERR_VT_MISMATCH, KoVersion(protocolVersion: "1.2", vt: "bbbbbbbbbbbb", build: "theirs"))
        XCTAssertEqual(revision.messageText, "Kido.app and ko on devbox are from different releases")
        XCTAssertEqual(revision.informativeText, "This app runs terminal revision aaaaaaaaa; the server runs bbbbbbbbb. Install the ko release of this Kido.app on the host, or update Kido.app. The server is build theirs; this app is build mine." + recovery)
        for sheet in [older, newer, revision] {
            XCTAssertEqual(sheet.buttons.map(\.title), ["Reconnect", "Close"])
            XCTAssertFalse(sheet.buttons[0].hasDestructiveAction)
            XCTAssertEqual(sheet.accessoryView?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue, "ko kill-server")
            XCTAssertTrue(sheet.window.defaultButtonCell === sheet.buttons[1].cell, "Close is the default")
        }
    }

    func testTheClassifiersOfTheSshStepsReachTheAppThroughTheCore() {
        func classify(_ status: Int32, signaled: Bool = false, _ out: String = "", _ err: String = "") -> Result<String, KoError> {
            KoClient.remoteSocket(host: "devbox", status: status, signaled: signaled, stdout: out, stderr: err)
        }
        XCTAssertEqual(try? classify(0, "/home/u/.local/state/ko/socket\n").get(), "/home/u/.local/state/ko/socket")
        XCTAssertEqual(classify(127, "", "env: ko: No such file").failure?.code, KO_ERR_NOT_FOUND)
        XCTAssertEqual(classify(255, "", "Permission denied (publickey)").failure?.code, KO_ERR_IO)
        XCTAssertEqual(classify(0, "banner\n").failure?.code, KO_ERR_INVALID)
        XCTAssertEqual(classify(9, signaled: true).failure?.code, KO_ERR_INVALID)
        XCTAssertEqual(KoClient.unreachable(host: "devbox", remoteAnswers: true).code, KO_ERR_REFUSED)
        XCTAssertEqual(KoClient.unreachable(host: "devbox", remoteAnswers: false).detail, "the ko server on devbox did not answer through the forward; reconnect")
        guard case .unreachable(let code, _) = KoClient.probe(socket: "/tmp/ko-kr-none/socket", within: 1) else { return XCTFail("a probe of no socket") }
        XCTAssertEqual(code, KO_ERR_NO_SERVER)
    }

    func testTheBannerOfEachFailureNamesTheHostAndItsRemedy() {
        let rows: [(RemoteFailure, String)] = [
            (.ssh(Failure.transport("down")), "Kido could not reach devbox"),
            (.noKo("t"), "ko is not installed on devbox"),
            (.noServer("t"), "No ko server is running on devbox"),
            (.start("t"), "Could not start the ko server on devbox"),
            (.refused("t"), "devbox refuses unix-socket forwarding"),
            (.badSocket("t"), "Kido could not find the ko socket on devbox"),
        ]
        for (failure, title) in rows { XCTAssertEqual(failure.banner("devbox").title, title) }
    }

    // MARK: with a private sshd (KO_E2E_HOST_SSH=1)

    func testARemoteOwnerRestoresAViewClosesOnEmptyAndCreatesASessionOnReopen() throws {
        let host = try host(), scope = try host.scope()
        _ = try serverWithPane("echo remote-ok; exec sleep 60", at: scope.dir)
        let owner = try owner(host, scope)
        connected(owner)
        XCTAssertEqual(owner.window.title, "\(NSUserName())@127.0.0.1 / s — w")
        let ssh = try XCTUnwrap(owner.ssh)
        XCTAssertEqual(ssh.remoteSocket, scope.dir + "/socket")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ssh.directory + "/socket"))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: scope.dir + "/agent.sock"), "no agent forwarded")

        let client = try XCTUnwrap(owner.testClient)
        let window = try XCTUnwrap(try client.model().layout.layout.windows.first)
        guard case .leaf(let leaf) = window.tree else { return XCTFail("one pane") }
        let surface = KoSurface(cols: leaf.cols, rows: leaf.rows)
        let recorder = Recorder()
        let view = try client.openView(pane: leaf.pane, surface: surface.surface) { recorder.view.append($0) }
        addTeardownBlock { @MainActor in view.close() }
        wait("the restored screen") { surface.text.contains("remote-ok") }
        let session = try XCTUnwrap(owner.testModel?.layout.layout.sessions.first?.id)
        try run(["api", "-X", "DELETE", "/sessions/\(session)"], dir: scope.dir)
        wait("the remote owner detaches") { !owner.alive }
        let reopened = try self.owner(host, scope)
        wait("the remote owner creates one session", within: 20) {
            reopened.navigation.sessions.map(\.name) == ["session"] && reopened.testBanner.isHidden && !reopened.testEditing
        }
    }

    func testEachFailureOfTheConnectSequenceShowsItsBannerAndReconnect() throws {
        let host = try host(), scope = try host.scope()
        let refusing = try PrivateHost(forwarding: false), refusingScope = try refusing.scope()
        addTeardownBlock { @MainActor in refusing.stop() }
        wait("the second sshd listens") { PrivateHost.listening(refusing.port) }
        _ = try serverWithPane("exec sleep 60", at: refusingScope.dir)

        func banner(_ owner: WindowOwner, _ title: String) {
            wait("the banner \(title)", within: 20) { owner.testBanner.testText.title == title }
            XCTAssertEqual(owner.testBanner.testText.button, "Reconnect")
            XCTAssertFalse(owner.testBanner.isHidden)
            XCTAssertNil(owner.testClient)
        }
        let noKo = try owner(host, scope, path: "/usr/bin:/bin")
        banner(noKo, "ko is not installed on h")
        XCTAssertTrue(noKo.testBanner.testText.detail.contains("ko is not on the PATH of non-interactive ssh commands on h"), noKo.testBanner.testText.detail)
        addTeardownBlock { @MainActor in try? self.run(["kill-server"], dir: scope.dir) }
        let started = try owner(host, scope)
        wait("the remote server starts and ensures one session", within: 20) {
            started.navigation.sessions.map(\.name) == ["session"] && started.testBanner.isHidden && !started.testEditing
        }
        let refused = try owner(refusing, refusingScope)
        banner(refused, "h refuses unix-socket forwarding")
        XCTAssertTrue(refused.testBanner.testText.detail.contains("AllowStreamLocalForwarding"))
        banner(try owner(host, scope, alias: "closed"), "Kido could not reach closed")
    }

    func testAServerWithAnotherProtocolOpensTheUpdateSheetAndCloseKeepsTheBanner() throws {
        let host = try host(), scope = try host.scope()
        try FileManager.default.createDirectory(atPath: scope.dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let own = KoClient.version
        let fake = try KoFakeServer(directory: scope.dir, version: #"{"protocol":"0.9","vt":"\#(own.vt)","build":"theirs"}"#)
        addTeardownBlock { fake.stop() }
        let owner = try owner(host, scope)
        wait("the sheet", within: 20) { owner.preparedAlert != nil }
        let alert = try XCTUnwrap(owner.preparedAlert).alert
        XCTAssertEqual(alert.messageText, "Update ko on h")
        XCTAssertEqual(alert.buttons.map(\.title), ["Reconnect", "Close"])
        owner.respondToAlert(.alertSecondButtonReturn)
        XCTAssertEqual(owner.testBanner.testText.title, "Disconnected from h")
        XCTAssertEqual(owner.testBanner.testText.button, "Reconnect")
        XCTAssertNil(owner.testClient)
    }

    func testAKilledMasterIsReplacedAndTheSameClientResumesThenARestartedServerIsFresh() throws {
        let host = try host(), scope = try host.scope()
        let dir = try serverWithWindows([1], at: scope.dir)
        addTeardownBlock { @MainActor in try? self.run(["kill-server"], dir: dir) }
        let owner = try owner(host, scope)
        connected(owner)
        let client = try XCTUnwrap(owner.testClient)
        let before = try XCTUnwrap(owner.ssh?.master?.process.processIdentifier)
        let directory = try XCTUnwrap(owner.ssh?.directory)

        XCTAssertEqual(kill(before, SIGKILL), 0)
        wait("the outage banner", within: 20) { owner.testBanner.testText.title == "Disconnected from h" }
        XCTAssertEqual(owner.testBanner.testText.button, "Reconnect")
        wait("a new master and a hidden banner", within: 30) {
            owner.testBanner.isHidden && owner.ssh?.master?.process.processIdentifier != before && owner.ssh?.master?.process.isRunning == true
        }
        XCTAssertTrue(owner.testClient === client, "the engine reconnected the same client over the same forward")
        XCTAssertEqual(owner.ssh?.directory, directory)
        XCTAssertEqual(names(owner), ["s"])

        try run(["kill-server"], dir: dir)
        wait("the client starts the new server and ensures one session", within: 20) {
            self.names(owner) == ["session"] && owner.testBanner.isHidden && !owner.testEditing
        }
        let layout = try JSONDecoder().decode(KoSchema.Snapshot.self, from: Data(output(["api", "/layout"], dir: dir).utf8))
        let pane = try XCTUnwrap(owner.testModel?.panes.first?.id)
        try put(#"{"revision":\#(layout.revision),"layout":{"sessions":[{"name":"after","windows":[{"name":"w","tree":{"pane":"\#(pane)"}}]}]}}"#, dir: dir)
        wait("the layout of the new server", within: 20) { self.names(owner) == ["after"] }
        XCTAssertTrue(owner.testClient === client)
    }

    func testATerminalFailureWhileRecoveringClosesTheClientAndReconnectConnectsAgain() throws {
        let host = try host(), scope = try host.scope()
        _ = try serverWithWindows([1], at: scope.dir)
        let owner = try owner(host, scope)
        connected(owner)
        let keys = host.root + "/authorized_keys"
        let allowed = try String(contentsOfFile: keys, encoding: .utf8)
        addTeardownBlock { try? allowed.write(toFile: keys, atomically: true, encoding: .utf8) }
        try "".write(toFile: keys, atomically: true, encoding: .utf8)

        XCTAssertEqual(kill(try XCTUnwrap(owner.ssh?.master?.process.processIdentifier), SIGKILL), 0)
        wait("the terminal banner", within: 30) { owner.testBanner.testText.title == "Kido could not reach h" }
        XCTAssertTrue(owner.testBanner.testText.detail.lowercased().contains("permission denied"), owner.testBanner.testText.detail)
        XCTAssertNil(owner.testClient, "the client is closed with the connection")
        XCTAssertNil(owner.ssh)

        try allowed.write(toFile: keys, atomically: true, encoding: .utf8)
        owner.start()
        connected(owner)
        owner.close()
        wait("every master ended", within: 10) { host.sessions.allSatisfy { $0.ended.wait(timeout: .now()) == .success } }
        XCTAssertNil(owner.ssh)
        XCTAssertNil(owner.testClient)
    }

    func testTwoWindowsToOneHostHaveTheirOwnMastersAndOneCloseLeavesTheOther() throws {
        let host = try host(), scope = try host.scope()
        _ = try serverWithWindows([1], at: scope.dir)
        let first = try owner(host, scope), second = try owner(host, scope)
        connected(first)
        connected(second)
        let (one, two) = (try XCTUnwrap(first.ssh), try XCTUnwrap(second.ssh))
        XCTAssertNotEqual(one.directory, two.directory)
        XCTAssertNotEqual(one.master?.process.processIdentifier, two.master?.process.processIdentifier)

        first.close()
        wait("the first window's directory goes", within: 10) { !FileManager.default.fileExists(atPath: one.directory) }
        XCTAssertNotNil(second.testClient)
        XCTAssertTrue(second.testBanner.isHidden)
        XCTAssertEqual(names(second), ["s"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: two.directory + "/socket"))
    }

    func testTheAgentOfTheConfigurationIsLinkedAndRelinkedAndAPlainAliasLeavesTheLink() throws {
        let host = try host(), scope = try host.scope()
        let environment = ["PATH": "/usr/bin:/bin", "HOME": scope.home]
        let agent = try Child("/usr/bin/ssh-agent", ["-D", "-a", host.agentSocket], env: environment, stdout: Pipe())
        addTeardownBlock { @MainActor in
            agent.stop()
            self.wait("the private agent ends", within: 10) { agent.ended.wait(timeout: .now()) == .success }
        }
        wait("the agent socket") { FileManager.default.fileExists(atPath: host.agentSocket) }
        let key = scope.home + "/key"
        XCTAssertEqual(try runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "throwaway-agent-key", "-f", key], env: environment).status, 0)
        XCTAssertEqual(try runTool("/usr/bin/ssh-add", [key], env: environment.merging(["SSH_AUTH_SOCK": host.agentSocket]) { $1 }).status, 0)
        let dir = try serverWithWindows([1], at: scope.dir)
        let link = dir + "/agent.sock"
        func keys() throws -> String {
            try runTool("/usr/bin/ssh-add", ["-l"], env: environment.merging(["SSH_AUTH_SOCK": link]) { $1 }).out
        }

        let forwarding = try owner(host, scope, alias: "fwd")
        connected(forwarding)
        wait("the agent link") { (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil }
        let first = try FileManager.default.destinationOfSymbolicLink(atPath: link)
        XCTAssertTrue(try keys().contains("throwaway-agent-key"))

        let plain = try owner(host, scope, alias: "plain")
        connected(plain)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), first, "an alias that forwards nothing leaves the link")

        XCTAssertEqual(kill(try XCTUnwrap(forwarding.ssh?.master?.process.processIdentifier), SIGKILL), 0)
        wait("the link follows the new master's agent", within: 30) {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link)).map { $0 != first } ?? false
        }
        XCTAssertTrue(try keys().contains("throwaway-agent-key"))
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}
