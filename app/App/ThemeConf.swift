import Foundation
import Darwin

enum ThemeConf {
    struct Pair: Equatable {
        var light = "kido-light"
        var dark = "kido-dark"
    }
    struct Parsed {
        let lines: [String]
        let themeLine: Int?
        let pair: Pair
    }
    static func parse(_ text: String) -> Parsed {
        let lines = text.components(separatedBy: "\n")
        var index: Int?
        var pair = Pair()
        for (i, line) in lines.enumerated() {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "theme" else { continue }
            index = i
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if isBareName(value) { pair = Pair(light: value, dark: value); continue }
            var sides: [String: String] = [:]
            for side in value.split(separator: ",", omittingEmptySubsequences: false) {
                let fields = side.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count == 2, ["light", "dark"].contains(fields[0]), isBareName(fields[1]) else { sides.removeAll(); break }
                sides[fields[0]] = fields[1]
            }
            if let light = sides["light"], let dark = sides["dark"] { pair = Pair(light: light, dark: dark) }
        }
        return Parsed(lines: lines, themeLine: index, pair: pair)
    }
    static func isBareName(_ value: String) -> Bool { !value.isEmpty && !value.contains(where: { ",:=".contains($0) }) }
    static func read(_ path: String) throws -> Parsed {
        parse(FileManager.default.fileExists(atPath: path) ? try String(contentsOfFile: path, encoding: .utf8) : "")
    }
    static func line(_ pair: Pair) -> String { "theme = light:\(pair.light),dark:\(pair.dark)" }
    static func set(_ text: String, _ pair: Pair) -> String {
        set(parse(text), pair)
    }
    private static func set(_ parsed: Parsed, _ pair: Pair) -> String {
        let text = parsed.lines.joined(separator: "\n")
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        if let i = parsed.themeLine {
            var lines = parsed.lines
            lines[i] = line(pair) + (lines[i].hasSuffix("\r") ? "\r" : "")
            return lines.joined(separator: "\n")
        }
        return text + (text.isEmpty || text.hasSuffix("\n") ? "" : newline) + line(pair) + newline
    }
    @discardableResult static func write(to path: String, update: (Pair) -> Pair) throws -> Bool {
        var target = path
        var links = 0
        while true {
            if let resolved = realpath(target, nil) {
                target = String(cString: resolved)
                free(resolved)
                break
            }
            var info = stat()
            guard lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { break }
            guard links < 40 else { throw POSIXError(.ELOOP) }
            links += 1
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: target)
            target = link.hasPrefix("/") ? link : URL(fileURLWithPath: target).deletingLastPathComponent().appendingPathComponent(link).standardized.path
        }
        let directory = URL(fileURLWithPath: target).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        let exists = stat(target, &info) == 0
        let parsed = try read(target)
        let pair = update(parsed.pair)
        guard pair != parsed.pair else { return false }
        if exists, access(target, W_OK) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
        let temporary = target + ".tmp-\(getpid())"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, exists ? info.st_mode & 0o7777 : 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); unlink(temporary) }
        if fchmod(fd, exists ? info.st_mode & 0o7777 : 0o600) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try Data(set(parsed, pair).utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary, target) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return true
    }
}
