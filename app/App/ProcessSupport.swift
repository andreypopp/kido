import AppKit
import KidoPairing

let tools = BundledTools(resources: Bundle.main.resourceURL!, environment: ProcessInfo.processInfo.environment)
#if DEBUG || KIDO_VISUAL || KIDO_STRESS
let background = ProcessInfo.processInfo.environment["KIDO_APP_BACKGROUND"] == "1"
#else
let background = false
#endif
let debugging = ProcessInfo.processInfo.environment["KIDO_APP_DEBUG"] == "1"

#if KIDO_VISUAL || KIDO_STRESS
let appLog = AppLog(destination: .stderr, cap: 8 << 20)
#else
let appLog = AppLog(destination: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ? .stderr : .directory(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kido")), cap: 8 << 20)
#endif

func note(_ line: String) {
    appLog.write(line)
}

func debug(_ line: @autoclosure () -> String) {
    if debugging { note(line()) }
}

func milliseconds(since start: DispatchTime) -> String {
    String(format: "%.1fms", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
}

