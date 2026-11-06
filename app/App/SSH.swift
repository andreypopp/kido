import Foundation
import PaneGeometry

@MainActor final class SSH {
    let destination: String
    let directory: String
    let ended = DispatchGroup()
    private(set) var master: Child?
    var remoteSocket: String? { didSet { remoteDir = remoteSocket.map { ($0 as NSString).deletingLastPathComponent } } }
    private(set) var remoteDir: String?
    private(set) var forwardsAgent = false
    private var publishing: Task<Void, Never>?
    private var serving: Child?
    private var forwardedSocket: String?
    private var lost: ((Failure) -> Void)?
    var mark: (String) -> Void = { _ in }
    private var stopped = false
    #if KIDO_VISUAL || KIDO_STRESS
    private var remoteEnvironment: [String] = []
    var testConfiguration: String?
    var testLocalEnvironment: [String: String]?
    #endif
    var options: [String] {
        #if KIDO_VISUAL || KIDO_STRESS
        return Self.options + (testConfiguration.map { ["-F", $0] } ?? [])
        #else
        return Self.options
        #endif
    }
    var environment: [String: String] {
        #if KIDO_VISUAL || KIDO_STRESS
        return testLocalEnvironment ?? tools.environment
        #else
        return tools.environment
        #endif
    }
    static let options = [
        "BatchMode=yes", "StrictHostKeyChecking=yes", "ConnectTimeout=10", "ConnectionAttempts=1",
        "ServerAliveInterval=15", "ServerAliveCountMax=3", "ForwardX11=no", "StreamLocalBindUnlink=yes",
        "RequestTTY=no", "RemoteCommand=none", "ControlPersist=no",
        "ForkAfterAuthentication=no", "StdinNull=no", "PermitLocalCommand=no", "SendEnv=-*", "UpdateHostKeys=no",
    ].flatMap { ["-o", $0] }

    var probeArguments: [String] { options + ["-o", "ClearAllForwardings=yes", "-G", "--", destination] }
    var masterArguments: [String] { options + ["-o", "ExitOnForwardFailure=no", "-M", "-N", "-T", "-S", directory + "/c", "--", destination] }
    var checkArguments: [String] { options + ["-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-S", directory + "/c", "-O", "check", "--", destination] }
    // No ClearAllForwardings: it would clear the forward of this very command.
    func forwardArguments(remote: String) -> [String] {
        options + ["-S", directory + "/c", "-O", "forward", "-L", directory + "/socket:" + remote, "--", destination]
    }

    init(_ destination: String) throws(Failure) {
        self.destination = destination
        directory = "/tmp/ka-" + UUID().uuidString.prefix(12)
        do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw Failure(message: error.localizedDescription) }
        ended.enter()
    }

    #if KIDO_VISUAL || KIDO_STRESS
    func testEnvironment(_ environment: [String: String]) {
        precondition(environment["HOME"]?.hasPrefix("/tmp/") == true && environment["XDG_STATE_HOME"]?.hasPrefix("/tmp/") == true)
        remoteEnvironment = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
    #endif

    nonisolated static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func launch(_ arguments: [String], forwardingAgent: Bool = false) -> Launch {
        guard !stopped, master?.process.isRunning == true else { return Launch("/usr/bin/false", []) }
        return passenger(arguments, forwardingAgent: forwardingAgent)
    }

    // OpenSSH tries the control socket before the transport; a dead master
    // falls through to the proxy, which fails before any authentication.
    func upload(_ arguments: [String]) -> Launch {
        let launch = launch(arguments)
        guard launch.path == "/usr/bin/ssh" else { return launch }
        return Launch(launch.path, ["-o", "ProxyCommand=/usr/bin/false"] + launch.arguments, environment: launch.environment)
    }

    static func recorded(_ recorded: [String], _ arguments: [String]) -> Launch {
        let options = [
            "BatchMode=yes", "ClearAllForwardings=yes", "RemoteCommand=none", "RequestTTY=no", "SessionType=default",
            "StdinNull=no", "PermitLocalCommand=no", "ControlMaster=no",
        ].flatMap { ["-o", $0] }
        return Launch("/usr/bin/ssh", options + recorded.dropLast() + ["--"] + recorded.suffix(1) + ["exec " + arguments.map(quote).joined(separator: " ")],
                      environment: tools.environment)
    }

    // A helper never gets the master's agent in its environment, except the publisher, which links it.
    func passenger(_ arguments: [String], forwardingAgent: Bool = false) -> Launch {
        var arguments = (forwardingAgent ? [] : ["/usr/bin/env", "-u", "SSH_AUTH_SOCK"]) + arguments
        #if KIDO_VISUAL || KIDO_STRESS
        if !remoteEnvironment.isEmpty { arguments = ["/usr/bin/env"] + remoteEnvironment + arguments }
        #endif
        let command = arguments.map(Self.quote).joined(separator: " ")
        let agent = forwardingAgent ? [] : ["-o", "ForwardAgent=no"]
        return Launch("/usr/bin/ssh", options + ["-o", "ClearAllForwardings=yes"] + agent + ["-S", directory + "/c", "-o", "ControlMaster=no", "-T", "--", destination, "exec " + command], environment: environment)
    }

    @discardableResult func start(drain: Drain? = nil, onLoss: @escaping (Failure) -> Void) async throws(Failure) -> String {
        var identity = destination
        let config = try await Child.run("/usr/bin/ssh", probeArguments, env: environment, drain: drain)
        guard config.status == 0 else { throw Failure.ssh(destination + ": " + config.err) }
        let fields = config.out.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
        if let user = fields.first(where: { $0.first == "user" })?.last,
           let host = fields.first(where: { $0.first == "hostname" })?.last { identity = user + "@" + host }
        forwardsAgent = fields.first { $0.first == "forwardagent" }?.last != "no"
        mark("identity")
        lost = onLoss
        try await launchMaster(within: 10, drain: drain)
        return identity
    }

    // A killed master leaves its control socket behind, and ssh then starts a master without one. A master of an
    // earlier attempt is ended first, so no attempt leaves one running.
    func relaunch(drain: Drain? = nil) async throws(Failure) {
        serving = nil
        if let old = master {
            old.stop()
            await old.finished()
        }
        try? FileManager.default.removeItem(atPath: directory + "/c")
        try await launchMaster(within: 15, drain: drain)
    }

    private func launchMaster(within seconds: TimeInterval, drain: Drain?) async throws(Failure) {
        guard !stopped, !Task.isCancelled else { throw Failure(message: "Connection cancelled") }
        serving = nil
        forwardedSocket = nil
        let child = try Child("/usr/bin/ssh", masterArguments, env: environment, stdout: Pipe())
        master = child
        var ready = false
        defer { if !ready { child.stop() } }
        child.ended.notify(queue: .main) { [weak self] in
            guard let self, !stopped, serving === child else { return }
            lost?(Failure.ssh(destination + ": " + (child.stderr.isEmpty ? "SSH master exited \(child.process.terminationStatus)" : child.stderr)))
        }
        let deadline = Date().addingTimeInterval(seconds)
        var delay = 0.1
        while Date() < deadline, !stopped, !Task.isCancelled, child.process.isRunning {
            if FileManager.default.fileExists(atPath: directory + "/c") {
                let check = try await Child.run("/usr/bin/ssh", checkArguments, env: environment, deadline: 2, drain: drain)
                if check.status == 0 {
                    ready = true
                    serving = child
                    mark("master")
                    return
                }
            }
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            delay = min(delay * 1.5, 1)
        }
        if !child.process.isRunning { await child.finished() }
        throw Failure.ssh(destination + ": " + (child.stderr.isEmpty ? "SSH master did not become ready within \(Int(seconds)) seconds" : child.stderr))
    }

    // The forward of the remote socket to <directory>/socket. Exit 255 is ssh failing; another failure shows when the
    // probe finds nothing at the socket.
    func forward(drain: Drain) async throws(Failure) {
        guard let remote = remoteSocket, remote != forwardedSocket else { return }
        if let old = forwardedSocket {
            let arguments = options + ["-S", directory + "/c", "-O", "cancel", "-L", directory + "/socket:" + old, "--", destination]
            let cancelled = try await Child.run("/usr/bin/ssh", arguments, env: environment, deadline: 10, drain: drain)
            guard cancelled.status == 0 else { throw Failure.ssh(destination + ": " + cancelled.err) }
            forwardedSocket = nil
        }
        let run = try await Child.run("/usr/bin/ssh", forwardArguments(remote: remote), env: environment, deadline: 10, drain: drain)
        if run.status == 255 { throw Failure.ssh(destination + ": " + run.err) }
        forwardedSocket = remote
        mark("forward")
    }

    // The agent link is for the next shell, so nothing waits for it; stop() cancels it.
    func publishAgent(drain: Drain) {
        guard forwardsAgent, let dir = remoteDir else { return }
        let publisher = launch(["/bin/sh", "-c", Self.publisherScript, "-", dir], forwardingAgent: true)
        publishing = Task {
            guard let run = try? await Child.run(publisher, deadline: 10, drain: drain) else { return }
            if run.status != 0 || !run.err.isEmpty { note("\(destination): agent link: exit \(run.status) \(run.err)") }
        }
    }

    // Links <state dir>/agent.sock, the SSH_AUTH_SOCK of every pane, to the agent that the master forwards. The
    // rename does not follow a symlink at agent.sock (mv -h on BSD and macOS, -T on GNU); a directory or a regular
    // file there is kept.
    static let publisherScript = """
        dir=$1; link=$1/agent.sock
        [ -n "${SSH_AUTH_SOCK-}" ] && [ -S "$SSH_AUTH_SOCK" ] && [ -d "$dir" ] || exit 0
        [ ! -e "$link" ] || [ -L "$link" ] || exit 0
        tmp=$dir/.agent.sock.$$
        ln -s "$SSH_AUTH_SOCK" "$tmp" || exit 0
        mv -fh "$tmp" "$link" 2>/dev/null || mv -fT "$tmp" "$link" 2>/dev/null || rm -f "$tmp"
        exit 0
        """

    // After the master ended: a new master and the same forward. The engine of the client reconnects by itself.
    func recover(drain: Drain) async throws(Failure) {
        try await relaunch(drain: drain)
        do throws(RemoteFailure) { try await ensure(drain: drain) } catch { throw Failure.ssh(error.banner(destination).detail) }
        publishAgent(drain: drain)
    }

    func stop(after drain: Drain? = nil) {
        guard !stopped else { return }
        stopped = true
        publishing?.cancel()
        let child = master, directory = directory, ended = ended
        master = nil
        let finish: @Sendable () -> Void = {
            child?.stop()
            if let child {
                child.ended.notify(queue: .global()) { try? FileManager.default.removeItem(atPath: directory); ended.leave() }
            } else { try? FileManager.default.removeItem(atPath: directory); ended.leave() }
        }
        if let drain { drain.ended.notify(queue: .global(), execute: finish) }
        else { finish() }
    }
}
