import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Upload: Sendable {
    enum Bytes: Sendable { case file(FileHandle, path: String), data(Data) }
    struct Source: Sendable { let name: String; let size: Int; let bytes: Bytes }
    let sources: [Source]
    private var temporary = false
    var size: Int { sources.reduce(0) { $0 + $1.size } }
    var originals: [String]? {
        guard !temporary else { return nil }
        let paths = sources.compactMap { if case .file(_, let path) = $0.bytes { path } else { nil } }
        return paths.count == sources.count ? paths : nil
    }

    static let fileLimit = 64 << 20, countLimit = 16, totalLimit = 256 << 20, pixelLimit = 40_000_000

    init(files urls: [URL], copying: Bool) throws(Failure) {
        guard !urls.isEmpty else { throw Failure(message: "Kido only uploads files that already exist on disk.") }
        guard urls.count <= Self.countLimit else { throw Failure(message: "Kido uploads at most \(Self.countLimit) files at once.") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var sources: [Source] = []
        for url in urls {
            let path = url.path
            var link = stat()
            guard url.isFileURL, lstat(path, &link) == 0 else { throw Failure(message: "Kido only uploads files that already exist on disk.") }
            let alias = try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile
            guard link.st_mode & S_IFMT == S_IFREG, alias != true else {
                throw Failure(message: "\(url.lastPathComponent) is not a regular file. Kido uploads only regular files, not folders, packages, symlinks or aliases.")
            }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure(message: "Kido could not open \(path): \(String(cString: strerror(errno)))") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
                throw Failure(message: "\(url.lastPathComponent) is not a regular file.")
            }
            let size = Int(opened.st_size)
            guard !copying || size <= Self.fileLimit else { throw Failure(message: "\(url.lastPathComponent) is larger than 64 MiB.") }
            var name = String(url.lastPathComponent.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(128))
            if name.isEmpty || name.hasPrefix(".") || name.hasPrefix("-") { name = "_" + name.dropFirst() }
            let dot = name.lastIndex(of: ".") ?? name.endIndex
            var unique = name, n = 1
            while sources.contains(where: { $0.name == unique }) {
                n += 1
                unique = String(name[..<dot]) + "-\(n)" + String(name[dot...])
            }
            sources.append(Source(name: unique, size: size, bytes: .file(handle, path: path)))
        }
        guard !copying || sources.reduce(0, { $0 + $1.size }) <= Self.totalLimit else {
            throw Failure(message: "Kido uploads at most 256 MiB at once.")
        }
        self.sources = sources
    }

    #if KIDO_VISUAL || KIDO_STRESS
    @MainActor static let promiseRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kido-promises-test-" + UUID().uuidString)
    #else
    static let promiseRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kido-promises")
    #endif
    @MainActor static let promiseDirectory = promiseRoot.appendingPathComponent(UUID().uuidString)
    @MainActor private static var promiseLock: FileHandle?
    #if KIDO_VISUAL
    @MainActor static var promiseTimeout: TimeInterval = 30
    #else
    static let promiseTimeout: TimeInterval = 30
    #endif
    @MainActor private static var promises: [String: PromisedFiles] = [:]

    fileprivate static func privatePromiseDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
    }

    private static func promiseDirectoryMatches(_ url: URL, _ fd: Int32) -> Bool {
        var opened = stat(), named = stat()
        return fstat(fd, &opened) == 0 && lstat(url.path, &named) == 0 && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }

    @MainActor static func sweepPromises(launch: Bool = false) {
        guard privatePromiseDirectory(promiseRoot) else { return }
        if !launch {
            Array(promises.values).forEach { $0.finish(.failure(Failure(message: "Upload cancelled."))) }
            if privatePromiseDirectory(promiseDirectory) { try? FileManager.default.removeItem(at: promiseDirectory) }
            return
        }
        for directory in (try? FileManager.default.contentsOfDirectory(at: promiseRoot, includingPropertiesForKeys: nil)) ?? [] {
            guard privatePromiseDirectory(directory) else { continue }
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, promiseDirectoryMatches(directory, fd) else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor static func cancelPromises(_ ids: [String]) {
        ids.forEach { promises[$0]?.finish(.failure(Failure(message: "Upload cancelled."))) }
    }

    @MainActor static func promised(_ receivers: [NSFilePromiseReceiver], id: String) async throws(Failure) -> Upload {
        guard !receivers.isEmpty, receivers.reduce(0, { $0 + max(1, $1.fileTypes.count) }) <= countLimit else {
            throw Failure(message: "Kido uploads at most \(countLimit) files at once.")
        }
        let directory = promiseDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: promiseRoot.path) {
                try FileManager.default.createDirectory(at: promiseRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard privatePromiseDirectory(promiseRoot) else { throw Failure(message: "The temporary upload directory is not private.") }
            if !FileManager.default.fileExists(atPath: promiseDirectory.path) {
                try FileManager.default.createDirectory(at: promiseDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard privatePromiseDirectory(promiseDirectory) else { throw Failure(message: "The temporary upload directory is not private.") }
            if promiseLock.map({ promiseDirectoryMatches(promiseDirectory, $0.fileDescriptor) }) != true {
                let fd = open(promiseDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Failure(message: "Kido could not open the temporary upload directory.") }
                let lock = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                guard flock(fd, LOCK_EX | LOCK_NB) == 0, promiseDirectoryMatches(promiseDirectory, fd) else { throw Failure(message: "Kido could not lock the temporary upload directory.") }
                promiseLock = lock
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw Failure(message: "Kido could not create a temporary upload directory: \(error.localizedDescription)") }
        let state = PromisedFiles(directory: directory, deadline: .now.advanced(by: .seconds(promiseTimeout)))
        promises[id] = state
        defer { promises[id] = nil }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.continuation = continuation
                guard !Task.isCancelled else { return state.finish(.failure(Failure(message: "Upload cancelled."))) }
                state.timer = Task {
                    do { try await Task.sleep(until: state.deadline, clock: .continuous) } catch { return }
                    state.finish(.failure(Failure(message: "The source app did not provide the files within 30 seconds.")))
                }
                let queue = OperationQueue()
                queue.name = "Kido file promises"
                for receiver in receivers {
                    receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { @Sendable url, error in
                        let message = error?.localizedDescription
                        Task { @MainActor in state.received(url, error: message) }
                    }
                }
                state.expected = receivers.reduce(0) { $0 + $1.fileNames.count }
                if state.expected == 0 || state.expected > countLimit { state.finish(.failure(Failure(message: "Kido uploads at most \(countLimit) files at once."))) }
            }
        } onCancel: {
            Task { @MainActor in state.finish(.failure(Failure(message: "Upload cancelled."))) }
        }
        var upload = try result.get()
        upload.temporary = true
        return upload
    }

    init(image raw: Data?) async throws(Failure) {
        guard let raw, raw.count <= Self.fileLimit, let image = CGImageSourceCreateWithData(raw as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width * height <= Self.pixelLimit else {
            throw Failure(message: "The clipboard image is larger than 64 MiB or 40 million pixels, or is not readable.")
        }
        var png: Data? = raw
        if CGImageSourceGetType(image) as String? != UTType.png.identifier {
            png = await withCheckedContinuation { done in
                nonisolated(unsafe) var result: Data?
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) {
                    let data = NSMutableData()
                    guard let image = CGImageSourceCreateWithData(raw as CFData, nil),
                          let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
                    CGImageDestinationAddImageFromSource(destination, image, 0, nil)
                    if CGImageDestinationFinalize(destination) { result = data as Data }
                }
                DispatchQueue.global().async { done.resume(returning: group.wait(timeout: .now() + 10) == .success ? result : nil) }
            }
        }
        guard let png, png.count <= Self.fileLimit else { throw Failure(message: "Kido could not convert the clipboard image to a PNG of at most 64 MiB within 10 seconds.") }
        sources = [Source(name: "clipboard-\(UUID().uuidString.prefix(8).lowercased()).png", size: png.count, bytes: .data(png))]
    }

    static let script = """
    base=${1:-${XDG_STATE_HOME:-$HOME/.local/state}/kido-app}; id=$2; shift 2
    refuse() { printf '%s\\n' "kido-drop: $1" >&2; exit 1; }
    me=$(id -u)
    check() { case $(uname -s) in
      Darwin) m=$(stat -f '%u:%Lp' "$1") ;; Linux) m=$(stat -c '%u:%a' "$1") ;; *) refuse platform ;; esac
      [ -d "$1" ] && [ ! -L "$1" ] && [ "$m" = "$me:700" ] || refuse "unsafe $1"; }
    umask 077
    [ -e "$base" ] || mkdir -p "$base" || refuse mkdir
    check "$base"
    mkdir -p "$base/drops" || refuse mkdir
    check "$base/drops"
    find "$base/drops" -mindepth 1 -maxdepth 1 -type d \\( -name '[0-9a-f]*-*' -o -name '.[0-9a-f]*-*' \\) -mtime +7 -exec rm -rf {} +
    [ "$(du -sk "$base/drops" | cut -f1)" -le 2097152 ] || refuse "more than 2 GiB of uploads are kept in $base/drops"
    stage=$base/drops/.$id
    [ ! -e "$base/drops/$id" ] && mkdir "$stage" || refuse exists
    cat > "$stage/.stream" || refuse write
    offset=1
    while [ $# -gt 0 ]; do
      name=$1; size=$2; shift 2
      if [ "$size" -eq 0 ]; then : > "$stage/$name" || refuse write
      else tail -c "+$offset" "$stage/.stream" | head -c "$size" > "$stage/$name" || refuse write; fi
      got=$(wc -c < "$stage/$name" | tr -d ' ')
      [ "$got" -eq "$size" ] || refuse "short $name"
      offset=$((offset + size))
    done
    got=$(wc -c < "$stage/.stream" | tr -d ' ')
    [ "$got" -eq $((offset - 1)) ] || refuse "long stream"
    rm "$stage/.stream" && mv "$stage" "$base/drops/$id" || refuse publish
    printf '%s\\n' "$base/drops/$id"
    """

    func arguments(base: String, id: String) -> [String] {
        // tcsh, as a remote login shell, rejects a newline inside single quotes.
        ["/bin/sh", "-c", "eval \"$(printf %s \(Data(Self.script.utf8).base64EncodedString()) | base64 -d)\"", "kido-drop", base, id] + sources.flatMap { [$0.name, String($0.size)] }
    }

    func send(_ pipe: FileHandle) {
        for source in sources {
            switch source.bytes {
            case .data(let data): guard (try? pipe.write(contentsOf: data)) != nil else { return }
            case .file(let file, _):
                var left = source.size
                while left > 0, let chunk = try? file.read(upToCount: min(left, 1 << 20)), !chunk.isEmpty {
                    guard (try? pipe.write(contentsOf: chunk)) != nil else { return }
                    left -= chunk.count
                }
                if left > 0 { return }
            }
        }
    }

    static func text(_ paths: [String]) -> String? {
        guard paths.allSatisfy({ !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }) else { return nil }
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@%+=:,-")
        return paths.map { path in
            path.unicodeScalars.allSatisfy(plain.contains) ? path : SSH.quote(path)
        }.joined(separator: " ")
    }
}

@MainActor private final class PromisedFiles {
    let directory: URL
    let deadline: ContinuousClock.Instant
    var expected = 0
    var urls: [URL] = []
    var continuation: CheckedContinuation<Result<Upload, Failure>, Never>?
    var timer: Task<Void, Never>?

    init(directory: URL, deadline: ContinuousClock.Instant) { self.directory = directory; self.deadline = deadline }

    func received(_ url: URL, error: String?) {
        guard continuation != nil else { return clean() }
        guard ContinuousClock.now < deadline else { return finish(.failure(Failure(message: "The source app did not provide the files within 30 seconds."))) }
        if let error { return finish(.failure(Failure(message: "Kido could not receive the promised files: \(error)"))) }
        urls.append(url)
        if urls.count == expected { finish(Result { () throws(Failure) in try Upload(files: urls, copying: true) }) }
    }

    func finish(_ result: Result<Upload, Failure>) {
        clean()
        timer?.cancel()
        timer = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }

    private func clean() {
        guard Upload.privatePromiseDirectory(Upload.promiseRoot), Upload.privatePromiseDirectory(Upload.promiseDirectory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
