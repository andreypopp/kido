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
    case mismatch(code: ko_code, server: KoVersion, own: KoVersion)
}

struct KoVersion: Equatable {
    let protocolVersion: String
    let vt: String
    let build: String

    init(_ version: ko_version) {
        self.init(protocolVersion: String(cString: version.protocol), vt: String(cString: version.vt), build: String(cString: version.build))
    }

    init(protocolVersion: String, vt: String, build: String) {
        self.protocolVersion = protocolVersion
        self.vt = vt
        self.build = build
    }
}

struct KoHello {
    var name = "app"
    var cols = 80
    var rows = 24
    var focused = false
    var sizesWindows = false
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
    private var user: Unmanaged<KoClient>?
    private var closed = false

    init(socket: String, hello: KoHello = KoHello(), sink: @escaping (KoEvent) -> Void) throws {
        self.sink = sink
        let user = Unmanaged.passRetained(self)
        var pointer: OpaquePointer?
        let code = hello.name.withCString { name in
            var hello = ko_hello(cols: UInt16(hello.cols), rows: UInt16(hello.rows), focused: hello.focused, sizes_windows: hello.sizesWindows, name: name)
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
        case KO_EVENT_ALERT:
            // Bell and notify alerts reach the user in a later step.
            break
        case KO_EVENT_MISMATCH:
            let mismatch = event.mismatch
            sink(.mismatch(code: mismatch.code, server: KoVersion(mismatch.server), own: KoVersion(mismatch.own)))
        case KO_EVENT_VIEW_RESTORED:
            let restored = event.view_restored
            KoView.of(restored.view).sink(.restored(generation: restored.generation, result: ghosttyResult(restored.result)))
        case KO_EVENT_VIEW_CLOSED:
            let closed = event.view_closed
            KoView.of(closed.view).sink(.closed(code: closed.code, message: String(cString: closed.message)))
        default:
            sink(.failed(code: event.failure.code, message: String(cString: event.failure.message)))
        }
    }

    // These two block until the server started or ended: run them off the main queue.
    // The state directory's server is started with `executable` unless one runs there. Returns its socket path.
    nonisolated static func launch(dir: String, executable: String) throws -> String {
        var buffer = ko_buffer()
        return String(decoding: try take(ko_client_launch(dir, executable, &buffer), &buffer), as: UTF8.self)
    }

    nonisolated static func stopServer(dir: String) throws {
        var buffer = ko_buffer()
        _ = try take(ko_client_stop_server(dir, &buffer), &buffer)
    }

    static var version: KoVersion {
        var version = ko_version()
        precondition(ko_client_version(&version) == KO_OK)
        return KoVersion(version)
    }

    // A snapshot of the core's model: read it again after an event.
    func model() throws -> KoModel {
        var buffer = ko_buffer()
        return try JSONDecoder().decode(KoModel.self, from: handle.call { try take(ko_client_model($0, &buffer), &buffer) })
    }

    func select<Kind>(_ kind: Int, _ id: ID<Kind>) throws {
        try handle.call { try check(ko_client_select($0, Int32(kind), id.description)) }
    }

    // The cell's pixel size answers a program's size queries; 0 and 0 when unknown.
    func size(cols: Int, rows: Int, cell: (width: UInt32, height: UInt32) = (0, 0)) throws {
        try handle.call { try check(ko_client_size($0, UInt16(cols), UInt16(rows), UInt16(clamping: cell.width), UInt16(clamping: cell.height))) }
    }

    func switchOver(_ over: Int, _ direction: Int) throws {
        try handle.call { try check(ko_client_switch($0, Int32(over), Int32(direction))) }
    }

    // Blocks until the server answered: run it off the main queue.
    nonisolated func delete<Kind>(_ kind: Int, _ id: ID<Kind>) throws {
        var buffer = ko_buffer()
        _ = try handle.call { try take(ko_client_delete($0, Int32(kind), id.description, &buffer), &buffer) }
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

    // The agents that a prompt from `caller` reaches; those of its window when it has any.
    nonisolated func promptCandidates(from caller: PaneID, windowOnly: Bool = false) throws -> [KoSchema.Candidate] {
        var buffer = ko_buffer()
        return try JSONDecoder().decode([KoSchema.Candidate].self, from: handle.call {
            try take(ko_client_prompt_resolve($0, caller.description, windowOnly, &buffer), &buffer)
        })
    }

    nonisolated func prompt(from caller: PaneID, to target: PaneID, _ text: String) throws {
        var buffer = ko_buffer()
        let bytes = Array(text.utf8)
        _ = try handle.call { try take(ko_client_prompt($0, caller.description, target.description, bytes, bytes.count, &buffer), &buffer) }
    }

    func openView(pane: PaneID, history: Bool = true, surface: ghostty_surface_t, hooks: KoViewHooks = KoViewHooks(), sink: @escaping @MainActor (KoViewEvent) -> Void) throws -> KoView {
        let view = KoView(surface: surface, hooks: hooks, sink: sink)
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

    @MainActor fileprivate init(surface: ghostty_surface_t, hooks: KoViewHooks, sink: @escaping @MainActor (KoViewEvent) -> Void) {
        self.surface = surface
        self.hooks = hooks
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
        let result = koResult(ghostty_surface_restore_snapshot(surface, snapshot.read, snapshot.reader, snapshot.history, limit))
        hooks.afterRestore?(result)
        return result
    }

    fileprivate func feed(_ item: ko_feed) {
        switch Int(item.kind) {
        case KO_FEED_BYTES:
            guard let data = item.data else { break }
            if let bytes = hooks.bytes { bytes(UnsafeRawBufferPointer(start: data, count: item.len)) }
            else { ghostty_surface_process_output(surface, UnsafeRawPointer(data).assumingMemoryBound(to: CChar.self), UInt(item.len)) }
        case KO_FEED_RESIZE:
            _ = ghostty_surface_set_grid_size(surface, item.cols, item.rows, nil)
        default:
            break
        }
        hooks.afterFeed?(item)
    }

    func text(_ data: Data) throws {
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
