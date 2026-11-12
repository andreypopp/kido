import Foundation
@_exported import KoClient
import KoModel

public enum KoEvent: Equatable {
    case welcome(client: String, fresh: Bool)
    case layout(revision: UInt64)
    case failed(code: ko_code, message: String)
    case model
    case selected(request: UInt64?, session: SessionID?, window: WindowID?, pane: PaneID?)
    case mismatch(code: ko_code, server: KoSchema.Version, own: KoSchema.Version)
    case clipboardWrite(pane: PaneID, contents: [KoClipboardContent])
    case clipboardRead(KoClipboardRead)
    case viewRestored(view: UnsafeMutableRawPointer?, generation: UInt64, result: ko_restore_result)
    case viewClosed(view: UnsafeMutableRawPointer?, code: ko_code, message: String)
    case viewLink(view: UnsafeMutableRawPointer?, code: ko_code, message: String)
}

public struct KoClipboardRead: Equatable {
    public let pane: PaneID
    public let id: UInt64
    public let mimes: [String]
    public let list: Bool

    public init(pane: PaneID, id: UInt64, mimes: [String], list: Bool) {
        self.pane = pane
        self.id = id
        self.mimes = mimes
        self.list = list
    }
}

public enum KoImage {
    case shm(name: String, length: Int)
    case body(Data)
}

extension KoSchema.Version {
    init(_ version: ko_version) {
        self.init(build: String(cString: version.build), protocol: String(cString: version.protocol), vt: String(cString: version.vt))
    }
}

public struct KoSize: Equatable {
    public let cols: Int
    public let rows: Int
    public let cell: KoSchema.CellPixels?

    public init(cols: Int, rows: Int, cell: KoSchema.CellPixels?) {
        self.cols = cols
        self.rows = rows
        self.cell = cell
    }

    var raw: ko_size {
        ko_size(cols: UInt16(cols), rows: UInt16(rows), cell_width: UInt16(clamping: cell?.width ?? 0), cell_height: UInt16(clamping: cell?.height ?? 0))
    }
}

public struct KoWindowSize: Equatable {
    public let window: WindowID
    let size: KoSize

    public init(window: WindowID, size: KoSize) {
        self.window = window
        self.size = size
    }
}

public struct KoHello {
    var name: String
    var focused: Bool
    var viewport: KoSize?
    var webview: Bool

    public init(name: String = "app", focused: Bool = false, viewport: KoSize? = nil, webview: Bool = false) {
        self.name = name
        self.focused = focused
        self.viewport = viewport
        self.webview = webview
    }
}

// The text of the failing call when the core gave one: for KO_ERR_CONFLICT the newer layout document.
public struct KoError: Error, CustomStringConvertible {
    public let code: ko_code
    public var detail: String

    public init(code: ko_code, detail: String = "") {
        self.code = code
        self.detail = detail
    }

    public var description: String {
        let base = String(cString: ko_code_message(Int32(code.rawValue)))
        return detail.isEmpty ? base : "\(base): \(detail)"
    }
}

private func check(_ code: ko_code) throws {
    guard code == KO_OK else { throw KoError(code: code) }
}

// Takes the bytes of a buffer that the core filled, and frees it.
private func owned(_ buffer: inout ko_buffer) -> Data {
    defer { ko_buffer_free(&buffer) }
    guard let data = buffer.data else { return Data() }
    return Data(bytes: data, count: buffer.len)
}

private func take(_ code: ko_code, _ buffer: inout ko_buffer) throws -> Data {
    let data = owned(&buffer)
    guard code == KO_OK else { throw KoError(code: code, detail: String(decoding: data, as: UTF8.self)) }
    return data
}

private func optional(_ pointer: UnsafePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }

// Frees a core buffer when the last reference goes.
private final class FreedBuffer: @unchecked Sendable {
    private var buffer: ko_buffer
    init(_ buffer: ko_buffer) { self.buffer = buffer }
    deinit { ko_buffer_free(&buffer) }
}

// ko_client_close frees the handle, and no call may start during or after it: every call holds
// the handle while it runs, and the close takes it only when no call holds it.
private final class ClientHandle: @unchecked Sendable {
    private let lock = NSCondition()
    private var pointer: OpaquePointer?
    private var calls = 0

    func set(_ pointer: OpaquePointer?) {
        lock.withLock { self.pointer = pointer }
    }

    func call<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let pointer: OpaquePointer? = lock.withLock {
            if self.pointer != nil { calls += 1 }
            return self.pointer
        }
        guard let pointer else { throw KoError(code: KO_ERR_CLOSED) }
        defer {
            lock.withLock {
                calls -= 1
                lock.broadcast()
            }
        }
        return try body(pointer)
    }

    // Nil when it was taken already.
    func take() -> OpaquePointer? {
        lock.withLock {
            let pointer = self.pointer
            self.pointer = nil
            while calls > 0 { lock.wait() }
            return pointer
        }
    }
}

@MainActor public final class KoClient {
    private let sink: (KoEvent) -> Void
    private let handle = ClientHandle()
    public let imageFetches = OperationQueue()
    public let rendersWebview: Bool
    private var user: Unmanaged<KoClient>?
    private var closed = false

    public init(socket: String, hello: KoHello = KoHello(), fetches: Int = 8, sink: @escaping (KoEvent) -> Void) throws {
        self.sink = sink
        rendersWebview = hello.webview
        imageFetches.maxConcurrentOperationCount = fetches
        imageFetches.qualityOfService = .utility
        let user = Unmanaged.passRetained(self)
        var pointer: OpaquePointer?
        let code = hello.name.withCString { name in
            var hello = ko_hello(cols: UInt16(hello.viewport?.cols ?? 80), rows: UInt16(hello.viewport?.rows ?? 24), focused: hello.focused, sizes_windows: hello.viewport != nil, webview: hello.webview, name: name)
            return ko_client_connect(socket, .main, { user, event in
                let client = Unmanaged<KoClient>.fromOpaque(user!).takeUnretainedValue()
                let event = event!.pointee
                MainActor.assumeIsolated { client.deliver(event) }
            }, user.toOpaque(), &hello, &pointer)
        }
        handle.set(pointer)
        guard code == KO_OK else {
            user.release()
            throw KoError(code: code)
        }
        self.user = user
    }

    public func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T { try handle.call(body) }

    // Returns at once: the close waits for the calls in flight and every view's restore, so it runs
    // on a utility queue, and the client stays alive until it returned. No event follows it.
    public func close(then done: (@MainActor () -> Void)? = nil) {
        guard !closed else { return }
        closed = true
        let handle = handle
        let user = user
        self.user = nil
        DispatchQueue.global(qos: .utility).async {
            if let pointer = handle.take() { ko_client_close(pointer) }
            DispatchQueue.main.async {
                user?.release()
                done?()
            }
        }
    }

    func webviewFetch(pane: PaneID, request: URLRequest, callbacks: inout ko_webview_fetch_callbacks) throws -> OpaquePointer {
        var out: OpaquePointer?
        let headers = (request.allHTTPHeaderFields ?? [:]).map { (strdup($0.key)!, strdup($0.value)!) }
        defer { for (name, value) in headers { free(name); free(value) } }
        let fields = headers.map { ko_webview_header(name: UnsafePointer($0.0), value: UnsafePointer($0.1)) }
        let body = request.httpBody ?? Data()
        let path = try webviewPath(request.url!)
        let code = try handle.call { pointer in
            fields.withUnsafeBufferPointer { headers in
                body.withUnsafeBytes { bytes in
                    ko_client_webview_fetch(pointer, pane.description, request.httpMethod ?? "GET", path,
                                         headers.baseAddress, headers.count, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &callbacks, &out)
                }
            }
        }
        guard code == KO_OK, let out else { throw KoError(code: code) }
        return out
    }

    func webviewWebSocket(pane: PaneID, path: String, callbacks: inout ko_webview_ws_callbacks) throws -> OpaquePointer {
        var out: OpaquePointer?
        let code = try handle.call { ko_client_webview_ws_open($0, pane.description, path, nil, 0, &callbacks, &out) }
        guard code == KO_OK, let out else { throw KoError(code: code) }
        return out
    }

    private func deliver(_ event: ko_event) {
        guard !closed else { return }
        switch Int(event.kind) {
        case KO_EVENT_WELCOME:
            let welcome = event.welcome
            sink(.welcome(client: String(cString: welcome.client), fresh: welcome.fresh))
        case KO_EVENT_LAYOUT:
            sink(.layout(revision: event.layout.revision))
        case KO_EVENT_MODEL:
            sink(.model)
        case KO_EVENT_SELECTED:
            let selected = event.selected
            sink(.selected(request: selected.request == 0 ? nil : selected.request, session: optional(selected.session).flatMap(SessionID.init(ko:)), window: optional(selected.window).flatMap(WindowID.init(ko:)),
                           pane: optional(selected.pane).flatMap(PaneID.init(ko:))))
        case KO_EVENT_CLIPBOARD_WRITE:
            let write = event.clipboard_write
            guard let pane = PaneID(ko: String(cString: write.pane)) else { break }
            let contents = (0..<write.count).map { i in
                let item = write.contents![i]
                return KoClipboardContent(mime: String(cString: item.mime), data: item.len == 0 ? Data() : Data(bytes: item.data, count: item.len))
            }
            sink(.clipboardWrite(pane: pane, contents: contents))
        case KO_EVENT_CLIPBOARD_READ:
            let read = event.clipboard_read
            guard let pane = PaneID(ko: String(cString: read.pane)) else { break }
            sink(.clipboardRead(KoClipboardRead(pane: pane, id: read.id, mimes: (0..<read.count).map { String(cString: read.mimes![$0]!) }, list: read.list)))
        case KO_EVENT_ALERT:
            // Bell and notify alerts reach the user in a later step.
            break
        case KO_EVENT_MISMATCH:
            let mismatch = event.mismatch
            sink(.mismatch(code: mismatch.code, server: KoSchema.Version(mismatch.server), own: KoSchema.Version(mismatch.own)))
        case KO_EVENT_VIEW_RESTORED:
            let restored = event.view_restored
            sink(.viewRestored(view: restored.view, generation: restored.generation, result: restored.result))
        case KO_EVENT_VIEW_CLOSED:
            let closed = event.view_closed
            sink(.viewClosed(view: closed.view, code: closed.code, message: String(cString: closed.message)))
        case KO_EVENT_VIEW_LINK:
            let link = event.view_closed
            sink(.viewLink(view: link.view, code: link.code, message: String(cString: link.message)))
        default:
            sink(.failed(code: event.failure.code, message: String(cString: event.failure.message)))
        }
    }

    #if os(macOS)
    nonisolated public static func defaultDirectory() throws -> String {
        var buffer = ko_buffer()
        return String(decoding: try take(ko_client_default_dir(&buffer), &buffer), as: UTF8.self)
    }

    // These two block until the server started or ended: run them off the main queue.
    // The state directory's server is started with `executable` unless one runs there. Returns its socket path.
    nonisolated public static func launch(dir: String, executable: String, path: String?, cwd: String?) throws -> String {
        var buffer = ko_buffer()
        return String(decoding: try take(ko_client_launch(dir, executable, path, cwd, &buffer), &buffer), as: UTF8.self)
    }

    nonisolated public static func stopServer(dir: String) throws {
        var buffer = ko_buffer()
        _ = try take(ko_client_stop_server(dir, &buffer), &buffer)
    }
    #endif

    // The remote host's steps. The probe blocks until the server answered: run it off the main queue.
    public enum Probe: Sendable {
        case compatible(KoSchema.Version)
        case mismatch(code: ko_code, server: KoSchema.Version)
        case unreachable(code: ko_code, detail: String)
    }

    nonisolated public static func probe(socket: String, within: TimeInterval) -> Probe {
        var buffer = ko_buffer()
        let code = ko_client_probe(socket, UInt32(within * 1000), &buffer)
        let text = String(decoding: owned(&buffer), as: UTF8.self)
        switch code {
        case KO_OK, KO_ERR_PROTOCOL_MISMATCH, KO_ERR_VT_MISMATCH:
            guard let server = try? JSONDecoder().decode(KoSchema.Version.self, from: Data(text.utf8)) else { return .unreachable(code: KO_ERR_PROTOCOL, detail: text) }
            return code == KO_OK ? .compatible(server) : .mismatch(code: code, server: server)
        default: return .unreachable(code: code, detail: text)
        }
    }

    // The remote socket path that `ko server --print-socket` printed, or the text for the banner.
    nonisolated public static func remoteSocket(host: String, status: Int32, signaled: Bool, stdout: String, stderr: String) -> Result<String, KoError> {
        var buffer = ko_buffer()
        let code = Array(stdout.utf8).withUnsafeBufferPointer { out in
            Array(stderr.utf8).withUnsafeBufferPointer { err in
                var run = ko_ssh_run(status: status, signaled: signaled, stdout_data: out.baseAddress, stdout_len: out.count, stderr_data: err.baseAddress, stderr_len: err.count)
                return ko_remote_socket(host, &run, &buffer)
            }
        }
        let text = String(decoding: owned(&buffer), as: UTF8.self)
        return code == KO_OK ? .success(text) : .failure(KoError(code: code, detail: text))
    }

    nonisolated public static func unreachable(host: String, remoteAnswers: Bool) -> KoError {
        var buffer = ko_buffer()
        let code = ko_remote_unreachable(host, remoteAnswers, &buffer)
        return KoError(code: code, detail: String(decoding: owned(&buffer), as: UTF8.self))
    }

    public static var version: KoSchema.Version {
        var version = ko_version()
        precondition(ko_client_version(&version) == KO_OK)
        return KoSchema.Version(version)
    }

    // A snapshot of the core's model: read it again after an event.
    public func model() throws -> KoModel {
        var buffer = ko_buffer()
        return try JSONDecoder().decode(KoModel.self, from: handle.call { try take(ko_client_model($0, &buffer), &buffer) })
    }

    @discardableResult public func selectRequest<Kind>(_ kind: Int, _ id: ID<Kind>) throws -> UInt64 {
        var request: UInt64 = 0
        try handle.call { try check(ko_client_select($0, Int32(kind), id.description, &request)) }
        return request
    }

    // The cell's pixel size answers a program's size queries; the C call takes 0 and 0 for unknown.
    public func size(viewport: KoSize, windows: [KoWindowSize]) throws {
        var names: [CChar] = []
        let entries = windows.map { entry in
            let offset = names.count
            names.append(contentsOf: entry.window.description.utf8CString)
            return (offset: offset, size: entry.size.raw)
        }
        try names.withUnsafeBufferPointer { names in
            let windows = entries.map { entry in ko_window_size(window: names.baseAddress?.advanced(by: entry.offset), size: entry.size) }
            try windows.withUnsafeBufferPointer { windows in
                try handle.call { try check(ko_client_size($0, viewport.raw, windows.baseAddress, windows.count)) }
            }
        }
    }

    @discardableResult public func switchRequest(_ over: Int, _ direction: Int) throws -> UInt64 {
        var request: UInt64 = 0
        try handle.call { try check(ko_client_switch($0, Int32(over), Int32(direction), &request)) }
        return request
    }

    // Blocks until the server answered: run it off the main queue.
    nonisolated public func delete<Kind>(_ kind: Int, _ id: ID<Kind>) throws {
        var buffer = ko_buffer()
        _ = try handle.call { try take(ko_client_delete($0, Int32(kind), id.description, &buffer), &buffer) }
    }

    nonisolated public func runtimeUp(_ key: RuntimeKey) throws {
        _ = try handle.call { client in
            var buffer = ko_buffer()
            if case .session(let source) = key.source {
                return try source.id.description.withCString { try take(ko_client_runtime_up(client, key.name, $0, &buffer), &buffer) }
            }
            return try take(ko_client_runtime_up(client, key.name, nil, &buffer), &buffer)
        }
    }

    nonisolated public func runtimeDown(_ key: RuntimeKey) throws {
        var buffer = ko_buffer()
        let session: String? = if case .session(let session) = key.source { session.id.description } else { nil }
        _ = try handle.call { client in
            if let session {
                return try session.withCString { try take(ko_client_runtime_down(client, key.name, $0, &buffer), &buffer) }
            }
            return try take(ko_client_runtime_down(client, key.name, nil, &buffer), &buffer)
        }
    }

    public func focus(_ focused: Bool) throws {
        try handle.call { try check(ko_client_focus($0, focused)) }
    }

    public func observe(_ panes: [PaneID], attending: Bool) throws {
        let pointers: [UnsafePointer<CChar>?] = panes.map { UnsafePointer(strdup($0.description)) }
        defer { pointers.forEach { $0.map { free(UnsafeMutablePointer(mutating: $0)) } } }
        try handle.call { pointer in try check(pointers.withUnsafeBufferPointer { ko_client_observe(pointer, $0.baseAddress, $0.count, attending) }) }
    }

    // These block until the server answers, so they are not main-actor calls:
    // run them off the main queue. A close on another thread ends them with KO_ERR_CLOSED.
    // Applies one layout edit, converged in the core. Returns the layout that resulted and what it made.
    nonisolated public func edit(_ edit: KoSchema.Edit) throws -> KoSchema.Edited {
        var buffer = ko_buffer()
        let bytes = Array(try JSONEncoder().encode(edit))
        let document = try handle.call { try take(ko_client_edit($0, bytes, bytes.count, &buffer), &buffer) }
        return try JSONDecoder().decode(KoSchema.Edited.self, from: document)
    }

    // The agents that a prompt from `from` reaches; those of its window when it has any.
    nonisolated public func promptCandidates(from: PaneID, windowOnly: Bool = false) throws -> [KoSchema.Candidate] {
        var buffer = ko_buffer()
        return try JSONDecoder().decode([KoSchema.Candidate].self, from: handle.call {
            try take(ko_client_prompt_resolve($0, from.description, windowOnly, &buffer), &buffer)
        })
    }

    nonisolated public func prompt(from: PaneID, to target: PaneID, _ text: String) throws {
        var buffer = ko_buffer()
        let bytes = Array(text.utf8)
        _ = try handle.call { try take(ko_client_prompt($0, from.description, target.description, bytes, bytes.count, &buffer), &buffer) }
    }

    public func answerClipboard(id: UInt64, contents: [KoClipboardContent]?, available: [String] = []) {
        withClipboard(contents ?? [], available: available, item: { ko_clipboard_content(mime: $0, data: $1.assumingMemoryBound(to: UInt8.self), len: $2) }) { items, types in
            // An answer with no contents still needs an array: NULL refuses.
            let empty = [ko_clipboard_content()]
            _ = try? handle.call { client in
                empty.withUnsafeBufferPointer { empty in
                    ko_client_clipboard_answer(client, id, contents == nil ? nil : (items.baseAddress ?? empty.baseAddress), items.count, types.baseAddress, types.count)
                }
            }
        }
    }

    public var kittyImagesMaxBytes: UInt64? {
        var limits = ko_limits()
        return (try? handle.call { ko_client_limits($0, &limits) }) == KO_OK ? limits.kitty_images_max_bytes : nil
    }

    // Blocks until the server answered: run it off the main queue. A frame that is gone is KO_ERR_NOT_FOUND.
    nonisolated public func image(pane: PaneID, image: UInt32, frame: UInt32, generation: UInt64, acceptShm: Bool) throws -> KoImage {
        var out = ko_image()
        let code = try handle.call { ko_client_image($0, pane.description, image, frame, generation, acceptShm, &out) }
        guard code == KO_OK else { throw KoError(code: code, detail: String(decoding: owned(&out.body), as: UTF8.self)) }
        let name = withUnsafeBytes(of: &out.shm_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard name.isEmpty else {
            ko_buffer_free(&out.body)
            return .shm(name: name, length: Int(out.length))
        }
        guard let bytes = out.body.data else { return .body(Data()) }
        let box = FreedBuffer(out.body)
        return .body(Data(bytesNoCopy: bytes, count: out.body.len, deallocator: .custom { _, _ in withExtendedLifetime(box) {} }))
    }
}

private func webviewPath(_ url: URL) throws -> String {
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
    return (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath) + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
}

@MainActor public final class KoWebviewFetch {
    nonisolated(unsafe) private var handle: OpaquePointer?
    private let response: (UInt16, [String: String]) -> Void
    private let body: (Data) -> Void
    private let end: (Result<Void, Error>) -> Void

    public init(client: KoClient, pane: PaneID, request: URLRequest, response: @escaping (UInt16, [String: String]) -> Void,
         body: @escaping (Data) -> Void, end: @escaping (Result<Void, Error>) -> Void) throws {
        self.response = response
        self.body = body
        self.end = end
        var callbacks = ko_webview_fetch_callbacks(response: { user, status, headers, count in
            let fetch = Unmanaged<KoWebviewFetch>.fromOpaque(user!).takeUnretainedValue()
            MainActor.assumeIsolated {
                var fields: [String: String] = [:]
                for index in 0..<count {
                    let header = headers![index]
                    let name = String(cString: header.name), value = String(cString: header.value)
                    fields[name] = fields[name].map { $0 + ", " + value } ?? value
                }
                fetch.response(status, fields)
            }
        }, body: { user, bytes, count in
            let fetch = Unmanaged<KoWebviewFetch>.fromOpaque(user!).takeUnretainedValue()
            MainActor.assumeIsolated { fetch.body(count == 0 ? Data() : Data(bytes: bytes!, count: count)) }
        }, end: { user, code, _ in
            let fetch = Unmanaged<KoWebviewFetch>.fromOpaque(user!).takeUnretainedValue()
            MainActor.assumeIsolated {
                fetch.cancel()
                fetch.end(code == KO_OK ? .success(()) : .failure(KoError(code: code)))
            }
        }, user: Unmanaged.passUnretained(self).toOpaque())
        handle = try client.webviewFetch(pane: pane, request: request, callbacks: &callbacks)
    }

    public func cancel() {
        if let handle { self.handle = nil; ko_webview_fetch_cancel(handle) }
    }

    deinit { if let handle { ko_webview_fetch_cancel(handle) } }
}

@MainActor public final class KoWebviewSocket {
    private enum Phase { case connecting, open, ended }
    private var phase = Phase.connecting
    nonisolated(unsafe) private var handle: OpaquePointer?
    private let opened: () -> Void
    private let message: (Data, Bool) -> Void
    private let ended: (UInt16, String, Bool) -> Void

    public init(client: KoClient, pane: PaneID, url: URL, opened: @escaping () -> Void,
         message: @escaping (Data, Bool) -> Void, ended: @escaping (UInt16, String, Bool) -> Void) throws {
        self.opened = opened
        self.message = message
        self.ended = ended
        var callbacks = ko_webview_ws_callbacks(open: { user, _, _, _ in
            let socket = Unmanaged<KoWebviewSocket>.fromOpaque(user!).takeUnretainedValue()
            MainActor.assumeIsolated { socket.phase = .open; socket.opened() }
        }, message: { user, bytes, count, binary in
            let socket = Unmanaged<KoWebviewSocket>.fromOpaque(user!).takeUnretainedValue()
            MainActor.assumeIsolated { socket.message(count == 0 ? Data() : Data(bytes: bytes!, count: count), binary) }
        }, close: { user, result, code, reason in
            let socket = Unmanaged<KoWebviewSocket>.fromOpaque(user!).takeUnretainedValue()
            let text = reason.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated { socket.cancel(); socket.ended(code, text, result == KO_OK) }
        }, user: Unmanaged.passUnretained(self).toOpaque())
        handle = try client.webviewWebSocket(pane: pane, path: webviewPath(url), callbacks: &callbacks)
    }

    public var bufferedAmount: Int { handle.map { Int(ko_webview_ws_buffered_amount($0)) } ?? 0 }

    public func send(_ data: Data, binary: Bool) throws {
        guard let handle else { throw KoError(code: KO_ERR_CLOSED) }
        let code = data.withUnsafeBytes { ko_webview_ws_send(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, binary) }
        guard code == KO_OK else { throw KoError(code: code) }
    }

    public func close(code: UInt16, reason: String) throws {
        guard phase != .ended else { return }
        guard phase == .open, let handle else {
            cancel()
            ended(1006, "Closed before open", false)
            return
        }
        let result = ko_webview_ws_close(handle, code, reason)
        guard result == KO_OK else { throw KoError(code: result) }
    }

    public func cancel() {
        phase = .ended
        if let handle { self.handle = nil; ko_webview_ws_cancel(handle) }
    }

    deinit { if let handle { ko_webview_ws_cancel(handle) } }
}
