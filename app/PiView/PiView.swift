import AppKit
import SwiftUI
import PiSurface
import Darwin

@MainActor @Observable final class Host {
    var session: Session?
    var error = ""
    private var process: Process?
    private var master: FileHandle?
    func launch(command: String, args: String, cwd: String, environment: String) {
        stop()
        var main: Int32 = -1, slave: Int32 = -1
        var dimensions = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&main, &slave, nil, nil, &dimensions) == 0 else { error = String(cString: strerror(errno)); return }
        let master = FileHandle(fileDescriptor: main, closeOnDealloc: true)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        self.master = master
        let session = Session { data in try master.write(contentsOf: data) }
        self.session = session
        master.readabilityHandler = { [weak session] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in if data.isEmpty { session?.disconnect() } else { session?.receive(data) } }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args.split(separator: " ").map(String.init)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment.filter { $0.key != "TMUX" && $0.key != "TMUX_PANE" && !$0.key.hasPrefix("KIDO_AGENT_") }
        for line in environment.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { error = "Environment requires KEY=value lines"; stop(); self.session = nil; try? terminal.close(); return }
            env[String(parts[0])] = String(parts[1])
        }
        process.environment = env
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        process.terminationHandler = { [weak session] _ in Task { @MainActor in session?.disconnect() } }
        do { try process.run(); self.process = process; try terminal.close() }
        catch { self.error = error.localizedDescription; master.readabilityHandler = nil; try? master.close(); session.disconnect(); self.session = nil }
    }
    func resize(_ size: CGSize) {
        guard let master else { return }
        var dimensions = winsize(ws_row: UInt16(max(1, min(65535, size.height / 18))), ws_col: UInt16(max(1, min(65535, size.width / 8))), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master.fileDescriptor, TIOCSWINSZ, &dimensions)
    }
    func replay(_ path: String) {
        do { let session = Session { _ in }; self.session = session; session.receive(try Data(contentsOf: URL(fileURLWithPath: path))) }
        catch { self.error = error.localizedDescription }
    }
    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil; master?.readabilityHandler = nil; try? master?.close(); master = nil; session?.disconnect()
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["KIDO_APP_BACKGROUND"] == "1" { NSApp.setActivationPolicy(.prohibited) }
    }
}

@main struct PiViewApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @State private var host = Host()
    @State private var command = "kido-pi"
    @State private var args = ""
    @State private var environment = ""
    @State private var cwd = FileManager.default.currentDirectoryPath
    private let background = ProcessInfo.processInfo.environment["KIDO_APP_BACKGROUND"] == "1"
    init() {
        let host = Host()
        var options: [String: String] = [:]
        let arguments = CommandLine.arguments
        for index in arguments.indices.dropFirst() where arguments[index].hasPrefix("--") && arguments.indices.contains(index + 1) { options[arguments[index]] = arguments[index + 1] }
        if let replay = options["--replay"] { host.replay(replay) }
        else if let command = options["--command"] { host.launch(command: command, args: options["--args"] ?? "", cwd: options["--cwd"] ?? FileManager.default.currentDirectoryPath, environment: "") }
        _host = State(initialValue: host)
    }
    var body: some Scene {
        WindowGroup {
            VStack {
                if let session = host.session { Surface(session: session) }
                else {
                    Form {
                        TextField("Command", text: $command)
                        TextField("Arguments (space separated)", text: $args)
                        TextField("Directory", text: $cwd)
                        Text("Environment (KEY=value per line)")
                        TextEditor(text: $environment).frame(height: 90)
                        Button("Launch") { host.launch(command: command, args: args, cwd: cwd, environment: environment) }
                        Text(host.error)
                    }.padding()
                }
            }.frame(minWidth: 600, minHeight: 400)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { host.resize($0) }
                .onDisappear { host.stop() }
        }.defaultLaunchBehavior(background ? .suppressed : .presented)
    }
}
