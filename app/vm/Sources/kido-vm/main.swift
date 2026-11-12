import Darwin
import Foundation
import Virtualization

let user = "kido"
let password = "kido"
let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/kido-vm")
func path(_ name: String) -> URL { state.appendingPathComponent(name) }

var timers: [DispatchSourceTimer] = []

func every(_ seconds: Int, _ body: @escaping (DispatchSourceTimer) -> Void) {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
    timer.setEventHandler { body(timer) }
    timer.resume()
    timers.append(timer)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kido-vm: \(message)\n".utf8))
    exit(1)
}

func say(_ message: String) {
    print(message)
    fflush(stdout)
}

func option(_ name: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}

struct Share {
    let name: String
    let url: URL
    let readOnly: Bool
}

func parseShare(_ text: String) -> Share {
    var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    let readOnly = parts.last == "ro"
    if readOnly { parts.removeLast() }
    guard parts.count == 2, !parts[0].isEmpty else { fail("--dir wants NAME:PATH[:ro]") }
    return Share(name: parts[0], url: URL(fileURLWithPath: parts[1]), readOnly: readOnly)
}

func macAddress() -> VZMACAddress {
    let file = path("mac")
    if let text = try? String(contentsOf: file, encoding: .utf8), let mac = VZMACAddress(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return mac
    }
    let mac = VZMACAddress.randomLocallyAdministered()
    try? mac.string.write(to: file, atomically: true, encoding: .utf8)
    return mac
}

func guestIP(mac: VZMACAddress) -> String? {
    guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
    let want = mac.string.split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
    var ip: String?
    var found: String?
    for line in leases.split(separator: "\n") {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("ip_address=") { ip = String(line.dropFirst(11)) }
        if line.hasPrefix("hw_address=") {
            let hw = line.dropFirst(11).split(separator: ",").last.map(String.init) ?? ""
            if hw == want { found = ip }
        }
    }
    return found
}

func configuration(shares: [Share], cpus: Int, memoryGB: Int) throws -> VZVirtualMachineConfiguration {
    guard let model = (try? Data(contentsOf: path("hardware-model"))).flatMap({ VZMacHardwareModel(dataRepresentation: $0) }),
        let id = (try? Data(contentsOf: path("machine-id"))).flatMap({ VZMacMachineIdentifier(dataRepresentation: $0) })
    else { fail("no VM in \(state.path): run `kido-vm install` first") }
    let config = VZVirtualMachineConfiguration()
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = model
    platform.machineIdentifier = id
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: path("aux"))
    config.platform = platform
    config.bootLoader = VZMacOSBootLoader()
    config.cpuCount = cpus
    config.memorySize = UInt64(memoryGB) << 30
    let disk = try VZDiskImageStorageDeviceAttachment(url: path("disk.img"), readOnly: false)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    net.macAddress = macAddress()
    config.networkDevices = [net]
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 3840, heightInPixels: 2400, pixelsPerInch: 144)]
    config.graphicsDevices = [graphics]
    config.keyboards = [VZMacKeyboardConfiguration()]
    config.pointingDevices = [VZMacTrackpadConfiguration()]
    if !shares.isEmpty {
        var dirs: [String: VZSharedDirectory] = [:]
        for share in shares { dirs[share.name] = VZSharedDirectory(url: share.url, readOnly: share.readOnly) }
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        fs.share = VZMultipleDirectoryShare(directories: dirs)
        config.directorySharingDevices = [fs]
    }
    try config.validate()
    return config
}

func download(_ url: URL, to file: URL) throws {
    final class Delegate: NSObject, URLSessionDownloadDelegate {
        let file: URL
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        var last = -1
        init(file: URL) { self.file = file }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let pct = Int(Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, 1)) * 100)
            if pct != last && pct % 2 == 0 {
                last = pct
                say("download \(pct)% (\(totalBytesWritten >> 20) of \(totalBytesExpectedToWrite >> 20) MB)")
            }
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do { try FileManager.default.moveItem(at: location, to: file) } catch { self.error = error }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { self.error = error }
            done.signal()
        }
    }
    let delegate = Delegate(file: file)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    session.downloadTask(with: url).resume()
    delegate.done.wait()
    if let error = delegate.error { throw error }
}

func install(_ args: [String]) {
    var args = args
    let cpus = Int(option("--cpus", in: &args) ?? "6") ?? 6
    let memoryGB = Int(option("--memory", in: &args) ?? "12") ?? 12
    let diskGB = Int(option("--disk", in: &args) ?? "120") ?? 120
    try! FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: path("disk.img").path) else { fail("\(path("disk.img").path) exists; delete the state directory to reinstall") }
    let started = Date()
    VZMacOSRestoreImage.fetchLatestSupported { result in
        guard let image = try? result.get() else { fail("cannot fetch the restore image: \(result)") }
        guard let requirements = image.mostFeaturefulSupportedConfiguration else { fail("host supports no hardware model of \(image.buildVersion)") }
        say("restore image \(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion) (\(image.buildVersion)) \(image.url)")
        let ipsw = path("restore.ipsw")
        do {
            if !FileManager.default.fileExists(atPath: ipsw.path) {
                try download(image.url, to: ipsw)
                say("downloaded in \(Int(Date().timeIntervalSince(started))) s")
            }
            let model = requirements.hardwareModel
            try model.dataRepresentation.write(to: path("hardware-model"))
            try VZMacMachineIdentifier().dataRepresentation.write(to: path("machine-id"))
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: path("aux"), hardwareModel: model, options: [.allowOverwrite])
            let fd = open(path("disk.img").path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0, ftruncate(fd, off_t(diskGB) << 30) == 0 else { fail("cannot create the disk: \(String(cString: strerror(errno)))") }
            close(fd)
            let config = try configuration(shares: [], cpus: max(cpus, requirements.minimumSupportedCPUCount), memoryGB: max(memoryGB, Int(requirements.minimumSupportedMemorySize >> 30)))
            DispatchQueue.main.async {
                let vm = VZVirtualMachine(configuration: config)
                let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
                every(10) { _ in
                    say("install \(Int(installer.progress.fractionCompleted * 100))% after \(Int(Date().timeIntervalSince(started))) s")
                }
                installer.install { result in
                    if case .failure(let error) = result { fail("install failed: \(error)") }
                    say("installed in \(Int(Date().timeIntervalSince(started))) s; disk uses \(diskUsage()) MB")
                    exit(0)
                }
            }
        } catch {
            fail("\(error)")
        }
    }
    dispatchMain()
}

func diskUsage() -> Int {
    var st = stat()
    return stat(path("disk.img").path, &st) == 0 ? (Int(st.st_blocks) * 512) >> 20 : 0
}

final class Runner: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { say("guest stopped"); exit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { fail("guest stopped: \(error)") }
}

func run(_ args: [String]) {
    var args = args
    let cpus = Int(option("--cpus", in: &args) ?? "6") ?? 6
    let memoryGB = Int(option("--memory", in: &args) ?? "12") ?? 12
    var shares: [Share] = []
    while let dir = option("--dir", in: &args) { shares.append(parseShare(dir)) }
    guard args.isEmpty else { fail("unknown arguments: \(args)") }
    guard lock("running", wait: false) != nil else { fail("the VM is already running") }
    let config: VZVirtualMachineConfiguration
    do { config = try configuration(shares: shares, cpus: cpus, memoryGB: memoryGB) } catch { fail("\(error)") }
    let vm = VZVirtualMachine(configuration: config)
    let runner = Runner()
    vm.delegate = runner
    let provisioning = VZMacGuestProvisioningOptions()
    provisioning.fullName = "Kido"
    provisioning.username = user
    provisioning.password = password
    provisioning.logsInAutomatically = true
    provisioning.enablesRemoteLogin = true
    let options = VZMacOSVirtualMachineStartOptions()
    do { try options.setGuestProvisioning(provisioning) } catch { fail("provisioning options: \(error)") }
    let started = Date()
    vm.start(options: options) { error in
        if let error { fail("start failed: \(error)") }
        say("started")
        DispatchQueue.main.async {
            let mac = macAddress()
            every(1) { timer in
                if let ip = guestIP(mac: mac) {
                    timer.cancel()
                    say("ip \(ip) after \(Int(Date().timeIntervalSince(started))) s")
                }
            }
        }
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            say("stopping")
            try? vm.requestStop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                vm.stop { _ in exit(0) }
            }
        }
        source.resume()
        signals.append(source)
    }
    dispatchMain()
}

var signals: [DispatchSourceSignal] = []

let pinnedGuestBuild = "26B131"
let updateHosts = ["swscan.apple.com", "swdist.apple.com", "swcdn.apple.com", "mesu.apple.com", "gdmf.apple.com", "xp.apple.com"]
let xcodeDeveloper = "/Volumes/My Shared Files/Xcode.app/Contents/Developer"
let hostHome = FileManager.default.homeDirectoryForCurrentUser.path

func standardShares() -> [Share] {
    [
        Share(name: "Xcode.app", url: URL(fileURLWithPath: "/Applications/Xcode.app"), readOnly: true),
        Share(name: "homebrew", url: URL(fileURLWithPath: "/opt/homebrew"), readOnly: true),
        Share(name: "Workspace", url: URL(fileURLWithPath: hostHome + "/Workspace"), readOnly: false),
        Share(name: "tmp", url: URL(fileURLWithPath: "/tmp"), readOnly: false),
    ]
}

func lock(_ name: String, wait: Bool) -> Int32? {
    let fd = open(path(name + ".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { fail("cannot open the \(name) lock: \(String(cString: strerror(errno)))") }
    guard flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else { close(fd); return nil }
    return fd
}

func isRunning() -> Bool {
    guard let fd = lock("running", wait: false) else { return true }
    close(fd)
    return false
}

func sshArgs() -> [String] {
    ["-i", path("id_ed25519").path, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5"]
}

func execute(_ tool: String, _ args: [String], input: Data? = nil, env: [String: String] = [:]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let pipe = Pipe()
    if input != nil { process.standardInput = pipe }
    do { try process.run() } catch { fail("\(tool): \(error)") }
    if let input {
        pipe.fileHandleForWriting.write(input)
        pipe.fileHandleForWriting.closeFile()
    }
    process.waitUntilExit()
    return process.terminationStatus
}

func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func authorizeKey(ip: String) -> Bool {
    let key = path("id_ed25519")
    if !FileManager.default.fileExists(atPath: key.path) {
        guard execute("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path]) == 0 else { fail("ssh-keygen failed") }
    }
    let marker = path("key-authorized")
    guard !FileManager.default.fileExists(atPath: marker.path) else { return true }
    let askpass = path("askpass")
    try! "#!/bin/sh\necho \(password)\n".write(to: askpass, atomically: true, encoding: .utf8)
    chmod(askpass.path, 0o700)
    let pub = (try? Data(contentsOf: path("id_ed25519.pub"))) ?? Data()
    let status = execute("/usr/bin/ssh", sshArgs() + ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "\(user)@\(ip)", "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"], input: pub, env: ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "none"])
    guard status == 0 else { return false }
    try! Data().write(to: marker)
    return true
}

func execSSH(_ command: [String]) -> Never {
    guard let ip = guestIP(mac: macAddress()) else { fail("the guest has no IP; is the VM running? (`kido-vm up`)") }
    guard authorizeKey(ip: ip) else { fail("cannot authorize the SSH key in the guest") }
    exit(execute("/usr/bin/ssh", sshArgs() + ["\(user)@\(ip)"] + command))
}

func remote(_ script: String, quiet: Bool = false) -> Int32 {
    guard let ip = guestIP(mac: macAddress()), authorizeKey(ip: ip) else { return 255 }
    return execute("/usr/bin/ssh", sshArgs() + (quiet ? ["-o", "LogLevel=QUIET"] : []) + ["\(user)@\(ip)", script])
}

func sudo(_ script: String) -> String {
    "echo \(password) | sudo -S -p '' sh -c \(quoted("export DEVELOPER_DIR=\(quoted(xcodeDeveloper)); " + script))"
}

func guestSetup() {
    let marker = path("guest-ready")
    guard !FileManager.default.fileExists(atPath: marker.path) else { return }
    say("setting up the guest")
    let script = [
        "softwareupdate --schedule off",
        "mkdir -p /usr/local/bin && ln -sfn /opt/homebrew/bin/node /usr/local/bin/node",
        "xcode-select -s \(quoted(xcodeDeveloper))",
        "xcodebuild -license accept",
        "xcodebuild -runFirstLaunch",
        "mkdir -p /Users/\(NSUserName()) /opt",
        "[ -L \(quoted(hostHome + "/Workspace")) ] || rm -rf \(quoted(hostHome + "/Workspace"))",
        "ln -sfn \(quoted("/Volumes/My Shared Files/Workspace")) \(quoted(hostHome + "/Workspace"))",
        "ln -sfn \(quoted("/Volumes/My Shared Files/homebrew")) /opt/homebrew",
        "for key in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates CriticalUpdateInstall ConfigDataInstall; do defaults write /Library/Preferences/com.apple.SoftwareUpdate $key -bool false; done",
        "pmset -a displaysleep 0 sleep 0 disksleep 0",
        "grep -q kido-vm-updates /etc/hosts || printf '%s\\n' '# kido-vm-updates' " + updateHosts.map { "'0.0.0.0 \($0)'" }.joined(separator: " ") + " >> /etc/hosts",
    ].joined(separator: " && ")
    guard remote(sudo(script)) == 0, remote("defaults -currentHost write com.apple.screensaver idleTime 0") == 0 else { fail("guest setup failed") }
    try! Data().write(to: marker)
}

func up() {
    guard let upLock = lock("up", wait: true) else { return }
    defer { close(upLock) }
    if !isRunning() {
        say("starting the VM")
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 1, path("run.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let argv = [exe, "run"] + standardShares().flatMap { ["--dir", "\($0.name):\($0.url.path)" + ($0.readOnly ? ":ro" : "")] }
        var pid: pid_t = 0
        let cargv = argv.map { strdup($0) } + [nil]
        guard posix_spawn(&pid, exe, &actions, &attributes, cargv, environ) == 0 else { fail("cannot start the VM") }
    }
    let deadline = Date().addingTimeInterval(300)
    while remote("true", quiet: true) != 0 {
        guard Date() < deadline else { fail("the guest did not accept SSH within 300 s; see \(path("run.log").path)") }
        guard isRunning() else { fail("the VM stopped; see \(path("run.log").path)") }
        usleep(1_000_000)
    }
    guestSetup()
}

func down() {
    guard isRunning() else { return }
    _ = remote(sudo("shutdown -h now"))
    let deadline = Date().addingTimeInterval(60)
    while isRunning() {
        guard Date() < deadline else { fail("the VM did not stop within 60 s") }
        usleep(500_000)
    }
}

func exec(_ args: [String]) -> Never {
    var args = args
    guard let split = args.firstIndex(of: "--") else { fail("usage: kido-vm exec --dir PATH [--link PATH]... -- CMD") }
    let command = Array(args[(split + 1)...])
    args.removeSubrange(split...)
    guard let dir = option("--dir", in: &args) else { fail("exec needs --dir PATH") }
    var links: [String] = []
    while let link = option("--link", in: &args) { links.append(link) }
    guard args.isEmpty, !command.isEmpty else { fail("usage: kido-vm exec --dir PATH [--link PATH]... -- CMD") }
    var tmpLinks: [String] = []
    for text in [dir] + links {
        let resolved = URL(fileURLWithPath: text).resolvingSymlinksInPath().path
        if resolved.hasPrefix(hostHome + "/Workspace/") { continue }
        let tmp = ["/private/tmp/", "/tmp/"].first { resolved.hasPrefix($0) }
        guard let tmp, let first = resolved.dropFirst(tmp.count).split(separator: "/").first else {
            fail("\(text) is not under \(hostHome)/Workspace or /tmp: the guest sees only those")
        }
        tmpLinks.append(String(first))
    }
    _ = lock("exec", wait: false) ?? {
        say("kido-vm: waiting for the VM (another run holds it)")
        return lock("exec", wait: true)
    }()
    up()
    let linkCommands = Set(tmpLinks).sorted().map { "ln -sfn \(quoted("/Volumes/My Shared Files/tmp/" + $0)) \(quoted("/tmp/" + $0)); " }.joined()
    let share = "\"/Volumes/My Shared Files\""
    let remount = "echo \(password) | sudo -S -p '' sh -c 'umount -f \(share); mkdir -p \(share); mount_virtiofs com.apple.virtio-fs.automount \(share)' >/dev/null || exit 1; "
    let script = remount + "export DEVELOPER_DIR=\(quoted(xcodeDeveloper)); \(linkCommands)"
        + "build=$(sw_vers -buildVersion); printf 'kido-vm: guest macOS %s (%s)\\n' \"$(sw_vers -productVersion)\" \"$build\"; "
        + "[ \"$build\" = \(pinnedGuestBuild) ] || { echo \"kido-vm: the guest is build $build but the snapshots are pinned to \(pinnedGuestBuild); refusing to run\" >&2; exit 1; }; "
        + "cd \(quoted(URL(fileURLWithPath: dir).resolvingSymlinksInPath().path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))) && "
        + command.map(quoted).joined(separator: " ")
    execSSH([script])
}

var argv = Array(CommandLine.arguments.dropFirst())
try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
switch argv.first {
case "install": install(Array(argv.dropFirst()))
case "run": run(Array(argv.dropFirst()))
case "up": up()
case "down": down()
case "exec": exec(Array(argv.dropFirst()))
case "ssh": execSSH(argv.dropFirst().first == "--" ? Array(argv.dropFirst(2)) : Array(argv.dropFirst()))
default: fail("usage: kido-vm install [--cpus N] [--memory GB] [--disk GB] | run [--cpus N] [--memory GB] [--dir NAME:PATH[:ro]]... | up | down | exec --dir PATH [--link PATH]... -- CMD | ssh [--] CMD")
}
