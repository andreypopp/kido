import Foundation
import GhosttyKit
import KoClient
import KoModel

enum KoEvent: Equatable {
    case welcome(client: String, fresh: Bool)
    case layout(revision: UInt64)
    case failed(code: ko_code, message: String)
    case model
    case selected(session: SessionID?, window: WindowID?, pane: PaneID?)
    case mismatch(code: ko_code, server: KoSchema.Version, own: KoSchema.Version)
    case clipboardWrite(pane: PaneID, contents: [KoClipboardContent])
    case clipboardRead(KoClipboardRead)
}

struct KoClipboardRead: Equatable {
    let pane: PaneID
    let id: UInt64
    let mimes: [String]
    let list: Bool
}

enum KoImage {
    case shm(name: String, length: Int)
    case body(Data)
}

extension KoSchema.Version {
    var major: Int? { `protocol`.split(separator: ".").first.flatMap { Int($0) } }

    init(_ version: ko_version) {
        self.init(build: String(cString: version.build), protocol: String(cString: version.protocol), vt: String(cString: version.vt))
    }
}

struct KoSize: Equatable {
    let cols: Int
    let rows: Int
    let cell: KoSchema.CellPixels?
    var raw: ko_size {
        ko_size(cols: UInt16(cols), rows: UInt16(rows), cell_width: UInt16(clamping: cell?.width ?? 0), cell_height: UInt16(clamping: cell?.height ?? 0))
    }
}

struct KoWindowSize: Equatable {
    let window: WindowID
    let size: KoSize
}

struct KoHello {
    var name = "app"
    var focused = false
    var viewport: KoSize?
}

// The core's restore results and Ghostty's, matched by name. ko_restore_result is a closed C enum,
// so a new case stops the compile here; Ghostty's is an open one, so a new case traps.
private func koResult(_ result: ghostty_snapshot_restore_result_e) -> Int32 {
    switch result {
    case GHOSTTY_SNAPSHOT_RESTORE_OK: Int32(ko_restore_result.KO_RESTORE_OK.rawValue)
    case GHOSTTY_SNAPSHOT_RESTORE_REJECTED: Int32(ko_restore_result.KO_RESTORE_REJECTED.rawValue)
    case GHOSTTY_SNAPSHOT_RESTORE_HISTORY_INCOMPLETE: Int32(ko_restore_result.KO_RESTORE_HISTORY_INCOMPLETE.rawValue)
    default: preconditionFailure("unknown restore result \(result.rawValue)")
    }
}

private func ghosttyResult(_ result: ko_restore_result) -> ghostty_snapshot_restore_result_e {
    switch result {
    case .KO_RESTORE_OK: GHOSTTY_SNAPSHOT_RESTORE_OK
    case .KO_RESTORE_REJECTED: GHOSTTY_SNAPSHOT_RESTORE_REJECTED
    case .KO_RESTORE_HISTORY_INCOMPLETE: GHOSTTY_SNAPSHOT_RESTORE_HISTORY_INCOMPLETE
    }
}

enum KoViewEvent: Equatable {
    case restored(generation: UInt64, result: ghostty_snapshot_restore_result_e)
    case closed(code: ko_code, message: String)
    case link(code: ko_code, message: String)
}

// The text of the failing call when the core gave one: for KO_ERR_CONFLICT the newer layout document.
struct KoError: Error, CustomStringConvertible {
    let code: ko_code
    var detail = ""
    var description: String {
        let base = String(cString: ko_code_message(Int32(code.rawValue)))
        return detail.isEmpty ? base : "\(base): \(detail)"
    }
}

// What a failure says to the user: the server's text when it gave one.
func failureText(_ error: Error) -> String {
    guard let error = error as? KoError else { return "\(error)" }
    return error.detail.isEmpty ? "\(error)" : error.detail
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

@MainActor final class KoClient {
    private let sink: (KoEvent) -> Void
    private let handle = ClientHandle()
    let imageFetches = OperationQueue()
    private var user: Unmanaged<KoClient>?
    private var closed = false

    init(socket: String, hello: KoHello = KoHello(), fetches: Int = 8, sink: @escaping (KoEvent) -> Void) throws {
        self.sink = sink
        imageFetches.maxConcurrentOperationCount = fetches
        imageFetches.qualityOfService = .utility
        let user = Unmanaged.passRetained(self)
        var pointer: OpaquePointer?
        let code = hello.name.withCString { name in
            var hello = ko_hello(cols: UInt16(hello.viewport?.cols ?? 80), rows: UInt16(hello.viewport?.rows ?? 24), focused: hello.focused, sizes_windows: hello.viewport != nil, name: name)
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

    // Returns at once: the close waits for the calls in flight and every view's restore, so it runs
    // on a utility queue, and the client stays alive until it returned. No event follows it.
    func close(then done: (@MainActor () -> Void)? = nil) {
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
            sink(.selected(session: optional(selected.session).flatMap(SessionID.init(ko:)), window: optional(selected.window).flatMap(WindowID.init(ko:)),
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
            KoView.of(restored.view).sink(.restored(generation: restored.generation, result: ghosttyResult(restored.result)))
        case KO_EVENT_VIEW_CLOSED:
            let closed = event.view_closed
            KoView.of(closed.view).sink(.closed(code: closed.code, message: String(cString: closed.message)))
        case KO_EVENT_VIEW_LINK:
            let link = event.view_closed
            KoView.of(link.view).sink(.link(code: link.code, message: String(cString: link.message)))
        default:
            sink(.failed(code: event.failure.code, message: String(cString: event.failure.message)))
        }
    }

    nonisolated static func defaultDir() -> String {
        var buffer = ko_buffer()
        do {
            return String(decoding: try take(ko_client_default_dir(&buffer), &buffer), as: UTF8.self)
        } catch {
            fatalError("Kido cannot resolve ko's server directory: \(error)")
        }
    }

    // These two block until the server started or ended: run them off the main queue.
    // The state directory's server is started with `executable` unless one runs there. Returns its socket path.
    nonisolated static func launch(dir: String, executable: String, path: String?) throws -> String {
        var buffer = ko_buffer()
        return String(decoding: try take(ko_client_launch(dir, executable, path, &buffer), &buffer), as: UTF8.self)
    }

    nonisolated static func stopServer(dir: String) throws {
        var buffer = ko_buffer()
        _ = try take(ko_client_stop_server(dir, &buffer), &buffer)
    }

    // The remote host's steps. The probe blocks until the server answered: run it off the main queue.
    enum Probe {
        case compatible(KoSchema.Version)
        case mismatch(code: ko_code, server: KoSchema.Version)
        case unreachable(code: ko_code, detail: String)
    }

    nonisolated static func probe(socket: String, within: TimeInterval) -> Probe {
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
    nonisolated static func remoteSocket(host: String, status: Int32, signaled: Bool, stdout: String, stderr: String) -> Result<String, KoError> {
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

    nonisolated static func unreachable(host: String, remoteAnswers: Bool) -> KoError {
        var buffer = ko_buffer()
        let code = ko_remote_unreachable(host, remoteAnswers, &buffer)
        return KoError(code: code, detail: String(decoding: owned(&buffer), as: UTF8.self))
    }

    static var version: KoSchema.Version {
        var version = ko_version()
        precondition(ko_client_version(&version) == KO_OK)
        return KoSchema.Version(version)
    }

    // A snapshot of the core's model: read it again after an event.
    func model() throws -> KoModel {
        var buffer = ko_buffer()
        return try JSONDecoder().decode(KoModel.self, from: handle.call { try take(ko_client_model($0, &buffer), &buffer) })
    }

    func select<Kind>(_ kind: Int, _ id: ID<Kind>) throws {
        try handle.call { try check(ko_client_select($0, Int32(kind), id.description)) }
        note("selection sent kind=\(kind) id=\(id)")
    }

    // The cell's pixel size answers a program's size queries; the C call takes 0 and 0 for unknown.
    func size(viewport: KoSize, windows: [KoWindowSize]) throws {
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

    func switchOver(_ over: Int, _ direction: Int) throws {
        try handle.call { try check(ko_client_switch($0, Int32(over), Int32(direction))) }
        note("selection switch sent over=\(over) direction=\(direction)")
    }

    // Blocks until the server answered: run it off the main queue.
    nonisolated func delete<Kind>(_ kind: Int, _ id: ID<Kind>) throws {
        var buffer = ko_buffer()
        _ = try handle.call { try take(ko_client_delete($0, Int32(kind), id.description, &buffer), &buffer) }
    }

    nonisolated func runtimeUp(_ key: RuntimeKey) throws {
        _ = try handle.call { client in
            var buffer = ko_buffer()
            if case .session(let source) = key.source {
                return try source.id.description.withCString { try take(ko_client_runtime_up(client, key.name, $0, &buffer), &buffer) }
            }
            return try take(ko_client_runtime_up(client, key.name, nil, &buffer), &buffer)
        }
    }

    nonisolated func runtimeDown(_ key: RuntimeKey) throws {
        var buffer = ko_buffer()
        let session: String? = if case .session(let session) = key.source { session.id.description } else { nil }
        _ = try handle.call { client in
            if let session {
                return try session.withCString { try take(ko_client_runtime_down(client, key.name, $0, &buffer), &buffer) }
            }
            return try take(ko_client_runtime_down(client, key.name, nil, &buffer), &buffer)
        }
    }

    func focus(_ focused: Bool) throws {
        try handle.call { try check(ko_client_focus($0, focused)) }
    }

    func observe(_ panes: [PaneID], attending: Bool) throws {
        let pointers: [UnsafePointer<CChar>?] = panes.map { UnsafePointer(strdup($0.description)) }
        defer { pointers.forEach { $0.map { free(UnsafeMutablePointer(mutating: $0)) } } }
        try handle.call { pointer in try check(pointers.withUnsafeBufferPointer { ko_client_observe(pointer, $0.baseAddress, $0.count, attending) }) }
    }

    // These block until the server answers, so they are not main-actor calls:
    // run them off the main queue. A close on another thread ends them with KO_ERR_CLOSED.
    // Applies one layout edit, converged in the core. Returns the layout that resulted and what it made.
    nonisolated func edit(_ edit: KoSchema.Edit) throws -> KoSchema.Edited {
        var buffer = ko_buffer()
        let bytes = Array(try JSONEncoder().encode(edit))
        let document = try handle.call { try take(ko_client_edit($0, bytes, bytes.count, &buffer), &buffer) }
        return try JSONDecoder().decode(KoSchema.Edited.self, from: document)
    }

    // The agents that a prompt from `from` reaches; those of its window when it has any.
    nonisolated func promptCandidates(from: PaneID, windowOnly: Bool = false) throws -> [KoSchema.Candidate] {
        var buffer = ko_buffer()
        return try JSONDecoder().decode([KoSchema.Candidate].self, from: handle.call {
            try take(ko_client_prompt_resolve($0, from.description, windowOnly, &buffer), &buffer)
        })
    }

    nonisolated func prompt(from: PaneID, to target: PaneID, _ text: String) throws {
        var buffer = ko_buffer()
        let bytes = Array(text.utf8)
        _ = try handle.call { try take(ko_client_prompt($0, from.description, target.description, bytes, bytes.count, &buffer), &buffer) }
    }

    func answerClipboard(id: UInt64, contents: [KoClipboardContent]?, available: [String] = []) {
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

    var kittyImagesMaxBytes: UInt64? {
        var limits = ko_limits()
        return (try? handle.call { ko_client_limits($0, &limits) }) == KO_OK ? limits.kitty_images_max_bytes : nil
    }

    // Blocks until the server answered: run it off the main queue. A frame that is gone is KO_ERR_NOT_FOUND.
    nonisolated func image(pane: PaneID, image: UInt32, frame: UInt32, generation: UInt64, acceptShm: Bool) throws -> KoImage {
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

    func openView(pane: PaneID, history: Bool = true, surface: ghostty_surface_t, hooks: KoViewHooks = KoViewHooks(), sink: @escaping @MainActor (KoViewEvent) -> Void) throws -> KoView {
        var limits = ko_limits()
        try check(handle.call { ko_client_limits($0, &limits) })
        let scrollback: KoScrollback = limits.scrollback.kind == KO_SCROLLBACK_DISABLED ? .disabled
            : .bounded(bytes: limits.scrollback.max_bytes == 0 ? nil : UInt(limits.scrollback.max_bytes), lines: limits.scrollback.max_lines == 0 ? nil : UInt(limits.scrollback.max_lines))
        let view = KoView(surface: surface, scrollback: scrollback, hooks: hooks, sink: sink)
        view.label = pane.description
        let user = Unmanaged.passRetained(view)
        let code = (try? handle.call { ko_view_open($0, pane.description, history, KoView.restoreCallback, KoView.feedCallback, user.toOpaque(), &view.handle) }) ?? KO_ERR_CLOSED
        guard code == KO_OK else {
            user.release()
            throw KoError(code: code)
        }
        view.user = user
        return view
    }
}

private enum KoScrollback: Sendable {
    case disabled
    case bounded(bytes: UInt?, lines: UInt?)

    func apply(to surface: ghostty_surface_t) {
        switch self {
        case .disabled:
            ghostty_surface_set_scrollback_limits(surface, false, 0, 0)
        case .bounded(let bytes, let lines):
            ghostty_surface_set_scrollback_limits(surface, true, bytes ?? 0, lines ?? 0)
        }
    }
}

// The closures run on the decoder thread: `bytes` takes the pty output in place of the surface's
// process_output; `afterFeed` runs after each feed and `afterRestore` after each restore. In test builds,
// continuationOverride replaces the server's limit and beforeRestore sees each snapshot.
struct KoViewHooks: Sendable {
    var bytes: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    var afterFeed: (@Sendable (ko_feed) -> Void)?
    var afterRestore: (@Sendable (Int32) -> Void)?
    #if KIDO_VISUAL || KIDO_STRESS
    var beforeRestore: (@Sendable (ko_snapshot) -> Void)?
    var continuationOverride: Int?
    #endif
}

// One pane's view, feeding a Ghostty surface of the app's fork. The core calls the
// restore and the feed on the view's decoder thread, in the server's order, so the
// surface never takes bytes of an older snapshot after a newer restore.
final class KoView: @unchecked Sendable {
    nonisolated(unsafe) fileprivate(set) var handle: OpaquePointer?
    fileprivate var user: Unmanaged<KoView>?
    let surface: ghostty_surface_t
    @MainActor let sink: @MainActor (KoViewEvent) -> Void
    private let hooks: KoViewHooks
    private let scrollback: KoScrollback
    fileprivate var label = ""
    fileprivate let opened = ContinuousClock.now
    private let inputStamp = NSLock()
    private var inputAt: ContinuousClock.Instant?

    @MainActor fileprivate init(surface: ghostty_surface_t, scrollback: KoScrollback, hooks: KoViewHooks, sink: @escaping @MainActor (KoViewEvent) -> Void) {
        self.surface = surface
        self.hooks = hooks
        self.scrollback = scrollback
        self.sink = sink
    }

    @MainActor fileprivate static func of(_ pointer: UnsafeMutableRawPointer?) -> KoView {
        Unmanaged<KoView>.fromOpaque(pointer!).takeUnretainedValue()
    }

    // Not main-actor isolated: the core calls these on the view's decoder thread.
    fileprivate static let restoreCallback: ko_restore_fn = { user, snapshot in
        Unmanaged<KoView>.fromOpaque(user!).takeUnretainedValue().restore(snapshot!.pointee)
    }

    fileprivate static let feedCallback: ko_feed_fn = { user, feed in
        Unmanaged<KoView>.fromOpaque(user!).takeUnretainedValue().feed(feed!.pointee)
    }

    fileprivate func restore(_ snapshot: ko_snapshot) -> Int32 {
        var limit = snapshot.continuation_max_bytes
        #if KIDO_VISUAL || KIDO_STRESS
        hooks.beforeRestore?(snapshot)
        limit = hooks.continuationOverride ?? limit
        #endif
        let result = Timing.enabled ? timedRestore(snapshot, limit) : koResult(ghostty_surface_restore_snapshot(surface, snapshot.read, snapshot.reader, snapshot.history, limit))
        // Snapshot restore carries dimension-adjusted limits, not the server policy.
        scrollback.apply(to: surface)
        hooks.afterRestore?(result)
        return result
    }

    fileprivate func feed(_ item: ko_feed) {
        switch Int(item.kind) {
        case KO_FEED_BYTES:
            guard let data = item.data else { break }
            if Timing.enabled, let start = takeInputStamp() {
                Timing.emit(["t": "echo", "pane": label, "ms": Timing.milliseconds(since: start)])
            }
            if let bytes = hooks.bytes { bytes(UnsafeRawBufferPointer(start: data, count: item.len)) }
            else { ghostty_surface_process_output(surface, UnsafeRawPointer(data).assumingMemoryBound(to: CChar.self), UInt(item.len)) }
        case KO_FEED_RESIZE:
            _ = ghostty_surface_set_grid_size(surface, item.cols, item.rows, nil)
        default:
            break
        }
        hooks.afterFeed?(item)
    }

    private func takeInputStamp() -> ContinuousClock.Instant? {
        inputStamp.withLock { defer { inputAt = nil }; return inputAt }
    }

    // Counts what the restore reads; the core calls the reads on the decoder thread that runs the restore.
    private final class CountingReader {
        let read: ko_read_fn
        let reader: UnsafeMutableRawPointer?
        let opened: ContinuousClock.Instant
        var bytes = 0
        var first: Double?
        init(read: ko_read_fn, reader: UnsafeMutableRawPointer?, opened: ContinuousClock.Instant) { self.read = read; self.reader = reader; self.opened = opened }
    }

    private func timedRestore(_ snapshot: ko_snapshot, _ limit: Int) -> Int32 {
        let counting = CountingReader(read: snapshot.read!, reader: snapshot.reader, opened: opened)
        let result = koResult(ghostty_surface_restore_snapshot(surface, { context, buffer, capacity, count in
            let counting = Unmanaged<CountingReader>.fromOpaque(context!).takeUnretainedValue()
            let more = counting.read(counting.reader, buffer, capacity, count)
            if more, let count {
                counting.bytes += count.pointee
                if counting.first == nil { counting.first = Timing.milliseconds(since: counting.opened) }
            }
            return more
        }, Unmanaged.passUnretained(counting).toOpaque(), snapshot.history, limit))
        var fields: [String: Any] = ["t": "restore", "pane": label, "bytes": counting.bytes, "total_ms": Timing.milliseconds(since: opened)]
        if let first = counting.first { fields["ready_ms"] = first }
        Timing.emit(fields)
        return result
    }

    func text(_ data: Data) throws {
        if Timing.enabled { inputStamp.withLock { if inputAt == nil { inputAt = .now } } }
        try check(data.withUnsafeBytes { ko_view_input(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }

    func resync(history: Bool = true) throws {
        try check(ko_view_resync(handle, history))
    }

    // It waits for a running restore or feed: call it off the main queue, once.
    func close() {
        guard let handle else { return }
        self.handle = nil
        ko_view_close(handle)
        user?.release()
        user = nil
    }
}
