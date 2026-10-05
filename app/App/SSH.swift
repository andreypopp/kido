import Foundation
import TmuxControl

@MainActor final class SSH {
    let destination: String
    let directory: String
    let ended = DispatchGroup()
    private(set) var master: Child?
    private var stopped = false
    #if KIDO_VISUAL || KIDO_STRESS
    private var remoteEnvironment: [String] = []
    var testConfiguration: String?
    #endif
    private var options: [String] {
        #if KIDO_VISUAL || KIDO_STRESS
        return Self.options + (testConfiguration.map { ["-F", $0] } ?? [])
        #else
        return Self.options
        #endif
    }
    static let options = [
        "BatchMode=yes", "StrictHostKeyChecking=yes", "ConnectTimeout=10", "ConnectionAttempts=1",
        "ServerAliveInterval=15", "ServerAliveCountMax=3", "ForwardAgent=no", "ForwardX11=no",
        "ClearAllForwardings=yes", "RequestTTY=no", "RemoteCommand=none", "ControlPersist=no",
        "ForkAfterAuthentication=no", "StdinNull=no", "PermitLocalCommand=no", "SendEnv=-*", "UpdateHostKeys=no",
    ].flatMap { ["-o", $0] }

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

    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func launch(_ arguments: [String]) -> Launch {
        guard !stopped, master?.process.isRunning == true else { return Launch("/usr/bin/false", []) }
        #if KIDO_VISUAL || KIDO_STRESS
        let arguments = remoteEnvironment.isEmpty ? arguments : ["/usr/bin/env"] + remoteEnvironment + arguments
        #endif
        let command = arguments.map(Self.quote).joined(separator: " ")
        return Launch("/usr/bin/ssh", options + ["-S", directory + "/c", "-o", "ControlMaster=no", "-T", "--", destination, "exec " + command], environment: tools.environment)
    }

    @discardableResult func start(drain: Drain? = nil, onLoss: @escaping (Failure) -> Void) async throws(Failure) -> String {
        var identity = destination
        let config = try await Child.run("/usr/bin/ssh", options + ["-G", "--", destination], env: tools.environment, drain: drain)
        guard config.status == 0 else { throw Failure.ssh(destination + ": " + config.err) }
        let fields = config.out.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
        if let user = fields.first(where: { $0.first == "user" })?.last,
           let host = fields.first(where: { $0.first == "hostname" })?.last { identity = user + "@" + host }
        guard !stopped, !Task.isCancelled else { throw Failure(message: "Connection cancelled") }
        let child = try Child("/usr/bin/ssh", options + ["-M", "-N", "-T", "-S", directory + "/c", "--", destination], env: tools.environment, stdout: Pipe())
        master = child
        child.ended.notify(queue: .main) { [weak self] in
            guard let self, !stopped else { return }
            onLoss(Failure.ssh(destination + ": " + (child.stderr.isEmpty ? "SSH master exited \(child.process.terminationStatus)" : child.stderr)))
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !stopped, !Task.isCancelled, child.process.isRunning {
            let check = try await Child.run("/usr/bin/ssh", options + ["-S", directory + "/c", "-O", "check", "--", destination], env: tools.environment, deadline: 2, drain: drain)
            if check.status == 0 { return identity }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        throw Failure.ssh(destination + ": " + (child.stderr.isEmpty ? "SSH master did not become ready within 10 seconds" : child.stderr))
    }

    func stop(after drain: Drain? = nil) {
        guard !stopped else { return }
        stopped = true
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
