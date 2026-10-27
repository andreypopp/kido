import Foundation
import os
import TmuxControl

struct ScrollbackFile: Sendable {
    static let prefix = "kido-scrollback-"
    private static let live = OSAllocatedUnfairLock(initialState: Set<URL>())

    let directory: URL
    let url: URL

    static func write(_ text: String, pane: PaneID, in base: URL = FileManager.default.temporaryDirectory) throws -> ScrollbackFile {
        let directory = base.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = ScrollbackFile(directory: directory, url: directory.appendingPathComponent("pane-\(pane.number).txt"))
        live.withLock { _ = $0.insert(directory) }
        do {
            let fd = open(file.url.path, O_WRONLY | O_CREAT | O_EXCL, 0o400)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            try FileHandle(fileDescriptor: fd, closeOnDealloc: true).write(contentsOf: Data(text.utf8))
        } catch {
            file.remove()
            throw error
        }
        return file
    }

    var statusURL: URL { directory.appendingPathComponent("status") }

    var exitStatus: Int? { (try? String(contentsOf: statusURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }

    func remove() {
        Self.live.withLock { _ = $0.remove(directory) }
        try? FileManager.default.removeItem(at: directory)
    }

    static func removeAll() {
        for directory in live.withLock({ let all = $0; $0 = []; return all }) { try? FileManager.default.removeItem(at: directory) }
    }

    static func sweepStale(in base: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 86400, now: Date = Date()) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
