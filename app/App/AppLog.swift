import Darwin
import Foundation
import Synchronization

final class AppLog: Sendable {
    enum Destination: Sendable {
        case stderr
        case directory(URL)
    }

    private let destination: Destination
    private let cap: UInt64
    private let formatter: Mutex<ISO8601DateFormatter>

    init(destination: Destination, cap: UInt64) {
        self.destination = destination
        self.cap = cap
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        format.timeZone = TimeZone(secondsFromGMT: 0)
        formatter = Mutex(format)
        if case .directory(let directory) = destination {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    func write(_ message: String) {
        formatter.withLock { format in
            let escaped = message.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
            let data = Data("\(format.string(from: Date())) kido-app[\(ProcessInfo.processInfo.processIdentifier)] \(escaped)\n".utf8)
            FileHandle.standardError.write(data)
            guard case .directory(let directory) = destination else { return }
            do {
                let manager = FileManager.default
                let path = directory.appendingPathComponent("app.log")
                if manager.fileExists(atPath: path.path) {
                    let size = (try manager.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.uint64Value ?? 0
                    if size + UInt64(data.count) > cap {
                        guard Darwin.rename(path.path, directory.appendingPathComponent("app.log.1").path) == 0 else { return }
                    }
                }
                let descriptor = Darwin.open(path.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
                guard descriptor >= 0 else { return }
                let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? file.close() }
                try file.write(contentsOf: data)
            } catch {}
        }
    }
}
