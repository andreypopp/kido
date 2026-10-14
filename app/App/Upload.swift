import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Upload: Sendable {
    enum Bytes: Sendable { case file(FileHandle, path: String), data(Data) }
    struct Source: Sendable { let name: String; let size: Int; let bytes: Bytes }
    let sources: [Source]
    var size: Int { sources.reduce(0) { $0 + $1.size } }
    var originals: [String]? {
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
