import Foundation
import Synchronization

final class PrivateTemporaryDirectory: Sendable {
    let root: URL
    let directory: URL
    private let lock = Mutex<FileHandle?>(nil)

    init(_ name: String) {
        #if KIDO_VISUAL || KIDO_STRESS
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name + "-test-" + UUID().uuidString)
        #else
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        #endif
        directory = root.appendingPathComponent(UUID().uuidString)
    }

    static func isPrivate(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
    }

    private static func matches(_ url: URL, _ fd: Int32) -> Bool {
        var opened = stat(), named = stat()
        return fstat(fd, &opened) == 0 && lstat(url.path, &named) == 0 && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }

    func prepare() throws {
        try lock.withLock { handle in
            for url in [root, directory] {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                guard Self.isPrivate(url) else { throw CocoaError(.fileWriteNoPermission) }
            }
            if handle.map({ Self.matches(directory, $0.fileDescriptor) }) != true {
                let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
                let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                guard flock(fd, LOCK_EX | LOCK_NB) == 0, Self.matches(directory, fd) else { throw CocoaError(.fileWriteNoPermission) }
                handle = opened
            }
        }
    }

    func sweep() {
        guard Self.isPrivate(root) else { return }
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard Self.isPrivate(url) else { continue }
            let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, Self.matches(url, fd) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func remove() {
        guard Self.isPrivate(root), Self.isPrivate(directory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
