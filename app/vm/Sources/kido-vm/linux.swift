import Darwin
import Foundation
import Virtualization

func linux(_ args: [String]) -> Never {
    do {
        switch args.first {
        case "install":
            var options = Array(args.dropFirst())
            let template = option("--cloud-init", in: &options) ?? "deploy/terraform/cloud-init.yaml"
            guard options.isEmpty, !isRunning() else { fail("usage: kido-vm linux install [--cloud-init FILE] (VM must be stopped)") }
            let userData = try String(contentsOfFile: template, encoding: .utf8)
            guard userData.contains("${ssh_key}") else { fail("cloud-init template has no ${ssh_key} placeholder") }
            guard lock("install", wait: false) != nil else { fail("Linux installation is already running") }
            guard !FileManager.default.fileExists(atPath: path("disk.img").path) else { fail("Linux disk already exists") }
            let base = URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/")!
            let image = "debian-13-genericcloud-arm64.raw"
            try download(base.appendingPathComponent("SHA512SUMS"), to: path("SHA512SUMS"), timeout: 60)
            try download(base.appendingPathComponent(image), to: path(image), timeout: 600)
            let sums = try String(contentsOf: path("SHA512SUMS"), encoding: .utf8)
            guard let line = sums.split(separator: "\n").first(where: { $0.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) == image }) else { fail("image is absent from SHA512SUMS") }
            let checksum = path("image.sha512")
            try "\(line.split(whereSeparator: { $0.isWhitespace })[0])  \(path(image).path)\n".write(to: checksum, atomically: true, encoding: .utf8)
            guard execute("/usr/bin/shasum", ["-a", "512", "-c", checksum.path]) == 0 else { fail("Debian image SHA-512 mismatch") }
            let fd = open(path(image).path, O_RDWR)
            guard fd >= 0, ftruncate(fd, off_t(20) << 30) == 0 else { fail("cannot grow Linux disk") }
            close(fd)
            guard execute("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path("id_ed25519").path]) == 0 else { fail("ssh-keygen failed") }
            let key = try String(contentsOf: path("id_ed25519.pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let seed = path("seed")
            try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
            try userData.replacingOccurrences(of: "${ssh_key}", with: String(decoding: try JSONEncoder().encode(key), as: UTF8.self)).write(to: seed.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
            try "instance-id: kido-debian-13\nlocal-hostname: kido-linux\n".write(to: seed.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
            try "version: 2\nethernets:\n  all:\n    match:\n      name: 'en*'\n    dhcp4: true\n    dhcp-identifier: mac\n".write(to: seed.appendingPathComponent("network-config"), atomically: true, encoding: .utf8)
            guard execute("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", path("seed.iso").path, seed.path]) == 0 else { fail("cannot create NoCloud ISO") }
            _ = try VZEFIVariableStore(creatingVariableStoreAt: path("efi"))
            _ = macAddress()
            try FileManager.default.moveItem(at: path(image), to: path("disk.img"))
            say("Linux installed in \(state.path)")
        case "run":
            guard args.count == 1 else { fail("usage: kido-vm linux run") }
            guard lock("running", wait: false) != nil else { fail("Linux VM is already running") }
            let config = VZVirtualMachineConfiguration()
            let boot = VZEFIBootLoader()
            boot.variableStore = VZEFIVariableStore(url: path("efi"))
            config.bootLoader = boot
            config.platform = VZGenericPlatformConfiguration()
            config.cpuCount = 4
            config.memorySize = 4 << 30
            config.storageDevices = try [("disk.img", false), ("seed.iso", true)].map {
                VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: path($0.0), readOnly: $0.1))
            }
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            net.macAddress = macAddress()
            config.networkDevices = [net]
            config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = try VZFileSerialPortAttachment(url: path("console.log"), append: true)
            config.serialPorts = [serial]
            try config.validate()
            let vm = VZVirtualMachine(configuration: config)
            let runner = Runner()
            vm.delegate = runner
            vm.start { result in
                if case .failure(let error) = result { fail("Linux start: \(error)") }
                say("Linux started")
            }
            dispatchMain()
        case "up":
            if !isRunning() {
                var attributes: posix_spawnattr_t?
                posix_spawnattr_init(&attributes)
                defer { posix_spawnattr_destroy(&attributes) }
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
                var actions: posix_spawn_file_actions_t?
                posix_spawn_file_actions_init(&actions)
                defer { posix_spawn_file_actions_destroy(&actions) }
                posix_spawn_file_actions_addopen(&actions, 1, path("run.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                posix_spawn_file_actions_adddup2(&actions, 1, 2)
                posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
                let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
                let argv = [exe, "linux", "run"].map { strdup($0) } + [nil]
                defer { argv.forEach { free($0) } }
                var pid: pid_t = 0
                guard posix_spawn(&pid, exe, &actions, &attributes, argv, environ) == 0 else { fail("cannot start Linux VM") }
            }
            let deadline = Date().addingTimeInterval(300)
            while true {
                if let ip = guestIP(mac: macAddress()), execute("/usr/bin/ssh", sshArgs() + ["-o", "BatchMode=yes", "me@\(ip)", "true"]) == 0 {
                    say("Linux SSH ready: \(ip)")
                    break
                }
                guard Date() < deadline else { fail("Linux SSH timeout; see \(path("console.log").path)") }
                say("waiting for Linux SSH")
                usleep(1_000_000)
            }
        case "ssh", "down":
            guard isRunning(), let ip = guestIP(mac: macAddress()) else { fail("Linux VM is not running or has no address") }
            let command = args.first == "down" ? ["sudo shutdown -h now"] : Array(args.dropFirst())
            let status = execute("/usr/bin/ssh", sshArgs() + ["me@\(ip)"] + command)
            if args.first == "ssh" { exit(status) }
            let deadline = Date().addingTimeInterval(60)
            while isRunning() {
                guard Date() < deadline else { fail("Linux shutdown timeout") }
                usleep(500_000)
            }
        default: fail("usage: kido-vm linux install|run|up|down|ssh [CMD]")
        }
    } catch { fail("Linux: \(error)") }
    exit(0)
}
