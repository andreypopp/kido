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
        "ServerAliveInterval=15", "ServerAliveCountMax=3", "ForwardX11=no",
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

    static let attachScript = """
    dir=$1; socket=$2; tmux=$3; shift 3
    stable=$dir/agent.sock
    refuse() { printf '%s\\n' 'Kido agent setup refused' >&2; exit 1; }
    platform=$(uname -s)
    case $platform in
      Darwin) metadata=$(stat -f '%u:%Lp' "$dir" 2>/dev/null) || refuse; limit=104 ;;
      Linux) metadata=$(stat -c '%u:%a' "$dir" 2>/dev/null) || refuse; limit=108 ;;
      *) refuse ;;
    esac
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$metadata" = "$(id -u):700" ] || refuse
    length=$(printf '%s' "$stable" | LC_ALL=C wc -c)
    [ "$length" -lt "$limit" ] || refuse
    if [ -S "${SSH_AUTH_SOCK-}" ]; then
      [ -L "$stable" ] || [ ! -e "$stable" ] || refuse
      umask 077
      temporary=$(mktemp -d "$dir/.agent.XXXXXXXX") || refuse
      trap 'rm -f "$temporary/link"; rmdir "$temporary"' 0
      trap 'exit 1' 1 2 3 15
      ln -s "$SSH_AUTH_SOCK" "$temporary/link" || refuse
      case $platform in
        Darwin) mv -fh "$temporary/link" "$stable" || refuse ;;
        Linux) mv -fT "$temporary/link" "$stable" || refuse ;;
      esac
      rmdir "$temporary" || refuse
      trap - 0 1 2 3 15
    fi
    SSH_AUTH_SOCK=$stable; export SSH_AUTH_SOCK
    "$tmux" -u -N -S "$socket" set-environment -g SSH_AUTH_SOCK "$stable" || exit 1
    exec "$tmux" "$@"
    """

    func launch(_ arguments: [String], control: Endpoint? = nil) -> Launch {
        guard !stopped, master?.process.isRunning == true else { return Launch("/usr/bin/false", []) }
        return passenger(arguments, control: control)
    }

    func passenger(_ arguments: [String], control: Endpoint? = nil) -> Launch {
        var arguments = control.map { ["/bin/sh", "-c", Self.attachScript, "kido-agent", $0.directory, $0.server.socket] + arguments } ?? ["/usr/bin/env", "-u", "SSH_AUTH_SOCK"] + arguments
        #if KIDO_VISUAL || KIDO_STRESS
        if !remoteEnvironment.isEmpty { arguments = ["/usr/bin/env"] + remoteEnvironment + arguments }
        #endif
        let command = arguments.map(Self.quote).joined(separator: " ")
        return Launch("/usr/bin/ssh", options + (control == nil ? ["-o", "ForwardAgent=no"] : []) + ["-S", directory + "/c", "-o", "ControlMaster=no", "-T", "--", destination, "exec " + command], environment: tools.environment)
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
            let check = try await Child.run("/usr/bin/ssh", options + ["-o", "ForwardAgent=no", "-S", directory + "/c", "-O", "check", "--", destination], env: tools.environment, deadline: 2, drain: drain)
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
