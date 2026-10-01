public enum Reply: Equatable, Sendable {
    case success([String])
    case failure([String])
}

public enum Origin: Equatable, Sendable {
    case control
    case other
}

public enum Link: Equatable, Sendable {
    case linked
    case unlinked
}

// %exit's reason is client_exit_message (client.c); a bare %exit has none.
public enum Exit: Equatable, Sendable {
    case detached(String)
    case ended(String?)
}

public enum Event: Equatable, Sendable {
    case block(Reply, Origin)
    case output(PaneID, [UInt8])
    case extendedOutput(PaneID, age: UInt64, [UInt8])
    case pause(PaneID)
    case `continue`(PaneID)
    case layoutChange(WindowID, layout: Layout, visible: Layout, flags: String)
    case windowAdd(WindowID, Link)
    case windowClose(WindowID, Link)
    case windowRenamed(WindowID, Link, String)
    case windowPaneChanged(WindowID, PaneID)
    case sessionChanged(SessionID, String)
    case sessionRenamed(SessionID, String)
    case sessionsChanged
    case sessionWindowChanged(SessionID, WindowID)
    case clientSessionChanged(client: String, SessionID, String)
    case clientDetached(String)
    case exit(Exit)
    case unrecognized(String)
}

public func decodeOctal(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
    func octal(_ b: UInt8) -> UInt8? { (0x30...0x37).contains(b) ? b - 0x30 : nil }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = bytes.startIndex
    while i < bytes.endIndex {
        if bytes[i] == 0x5C, i + 3 < bytes.endIndex,
            let a = octal(bytes[i + 1]), let b = octal(bytes[i + 2]), let c = octal(bytes[i + 3])
        {
            out.append(a &<< 6 | b &<< 3 | c)
            i += 4
        } else {
            out.append(bytes[i])
            i += 1
        }
    }
    return out
}

public struct Parser: Sendable {
    private var pending: [UInt8] = []
    private var block: (guard: String, origin: Origin, lines: [String])?

    public init() {}

    public mutating func feed(_ chunk: some Collection<UInt8>, _ emit: (Event) -> Void) {
        pending.append(contentsOf: chunk)
        var start = pending.startIndex
        while let end = pending[start...].firstIndex(of: 0x0A) {
            line(pending[start..<end], emit)
            start = end + 1
        }
        pending.removeFirst(start)
    }

    private mutating func line(_ bytes: ArraySlice<UInt8>, _ emit: (Event) -> Void) {
        if let id = block?.guard {
            let text = String(decoding: bytes, as: UTF8.self)
            guard bytes.first == 0x25 else { block?.lines.append(text); return }
            let w = text.split(separator: " ")
            if w.count == 4, w[0] == "%end" || w[0] == "%error", "\(w[1]) \(w[2])" == id, let open = block {
                block = nil
                emit(.block(w[0] == "%end" ? .success(open.lines) : .failure(open.lines), open.origin))
            } else {
                block?.lines.append(text)
            }
            return
        }
        if let data = bytes.dropPrefix("%output ") {
            guard let space = data.firstIndex(of: 0x20), let pane = PaneID(ascii(data[..<space])) else {
                return emit(.unrecognized(String(decoding: bytes, as: UTF8.self)))
            }
            return emit(.output(pane, decodeOctal(data[(space + 1)...])))
        }
        if let data = bytes.dropPrefix("%extended-output ") {
            let f = data.split(separator: 0x20, maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3, let pane = PaneID(ascii(f[0])), let age = UInt64(ascii(f[1])),
                let colon = f[2].firstIndex(of: 0x3A), colon + 1 < f[2].endIndex, f[2][colon + 1] == 0x20
            else { return emit(.unrecognized(String(decoding: bytes, as: UTF8.self))) }
            return emit(.extendedOutput(pane, age: age, decodeOctal(f[2][(colon + 2)...])))
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let w = text.split(separator: " ")
        if w.count == 4, w[0] == "%begin", let flags = Int(w[3]) {
            block = ("\(w[1]) \(w[2])", flags & 1 == 1 ? .control : .other, [])
            return
        }
        emit(notification(text))
    }

    private func notification(_ text: String) -> Event {
        let w = text.split(separator: " ", omittingEmptySubsequences: false)
        func rest(_ n: Int) -> String { w.dropFirst(n).joined(separator: " ") }
        func window(_ i: Int) -> WindowID? { w.count > i ? WindowID(w[i]) : nil }
        func session(_ i: Int) -> SessionID? { w.count > i ? SessionID(w[i]) : nil }
        func pane(_ i: Int) -> PaneID? { w.count > i ? PaneID(w[i]) : nil }
        let link: Link = w[0].hasPrefix("%unlinked-") ? .unlinked : .linked
        let event: Event? =
            switch w[0] {
            case "%pause": pane(1).map { .pause($0) }
            case "%continue": pane(1).map { .continue($0) }
            case "%layout-change":
                if w.count == 5, let win = window(1), let layout = try? Layout(json: w[2]),
                    let visible = try? Layout(json: w[3])
                { .layoutChange(win, layout: layout, visible: visible, flags: String(w[4])) } else { nil }
            case "%window-add", "%unlinked-window-add": window(1).map { .windowAdd($0, link) }
            case "%window-close", "%unlinked-window-close": window(1).map { .windowClose($0, link) }
            case "%window-renamed", "%unlinked-window-renamed":
                window(1).map { .windowRenamed($0, link, rest(2)) }
            case "%window-pane-changed":
                window(1).flatMap { win in pane(2).map { .windowPaneChanged(win, $0) } }
            case "%session-changed": session(1).map { .sessionChanged($0, rest(2)) }
            case "%session-renamed": session(1).map { .sessionRenamed($0, rest(2)) }
            case "%sessions-changed": .sessionsChanged
            case "%session-window-changed":
                session(1).flatMap { s in window(2).map { .sessionWindowChanged(s, $0) } }
            case "%client-session-changed":
                w.count > 2 ? session(2).map { .clientSessionChanged(client: String(w[1]), $0, rest(3)) } : nil
            case "%client-detached": w.count > 1 ? .clientDetached(rest(1)) : nil
            case "%exit":
                w.count == 1 ? .exit(.ended(nil)) : w[1] == "detached" ? .exit(.detached(rest(1))) : .exit(.ended(rest(1)))
            default: nil
            }
        return event ?? .unrecognized(text)
    }
}

private func ascii(_ bytes: ArraySlice<UInt8>) -> Substring {
    Substring(decoding: bytes, as: UTF8.self)
}

extension ArraySlice<UInt8> {
    fileprivate func dropPrefix(_ prefix: StaticString) -> ArraySlice<UInt8>? {
        let p = UnsafeBufferPointer(start: prefix.utf8Start, count: prefix.utf8CodeUnitCount)
        return starts(with: p) ? dropFirst(p.count) : nil
    }
}
