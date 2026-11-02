import Foundation
import GhosttyKit

let info = ghostty_info()
print("ghostty \(String(cString: info.version))")
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ko-probe SOCKET\n".utf8))
    exit(2)
}
var connection: KoConnection?
MainActor.assumeIsolated {
    connection = try? KoConnection(socket: CommandLine.arguments[1]) { event in
        dispatchPrecondition(condition: .onQueue(.main))
        print(event)
        if case .layout = event { exit(0) }
        if case .failed = event { exit(1) }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(3) }
dispatchMain()
